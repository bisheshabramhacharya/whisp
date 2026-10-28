@preconcurrency import CoreML
import FluidAudio
import Foundation
import os

private let asrLogger = Logger(subsystem: "com.bishesha.whisp", category: "ASR")

/// Offline Parakeet Unified engine driven at the encoder's shortest fitting
/// window instead of the fixed 15 s export.
///
/// The stock `parakeet_unified_encoder_int8.mlmodelc` is traced at mel
/// [1,128,1501] (240,000 samples): every decode pays a 15 s encoder pass even
/// for a 1 s tail. This engine looks for additional full-attention encoder
/// bundles in the same FluidAudio model cache, named
/// `parakeet_unified_encoder_w{ms}[_int8].mlmodelc` (re-exports of the same
/// weights traced at shorter windows — see `tools/convert/`), picks the
/// smallest window that fits the gated input, and runs the identical
/// mel → encoder → greedy RNNT → tokenizer pipeline.
///
/// Transcript parity argument: full attention masks by `mel_length` only, and
/// mel `per_feature` normalization uses only valid frames, so a short window
/// computes the same values for the valid region as the 15 s model. A 7 s
/// tail on the 10 s window matches the 15 s model; chunking that tail into
/// 5 s pieces would not, because each piece would attend to different audio.
///
/// Fallbacks: a pinned bundle that isn't on disk is fetched in the background
/// once its checksum is published, then used without a relaunch. Until then
/// the next larger window runs, which with no short bundles at all is the
/// stock 15 s encoder. Audio longer than every loaded window is split across
/// those windows.
public final class ShortWindowEngine: Transcribing, StatusReporting {
    /// Largest window the offline export supports (the stock encoder).
    public static let maxWindowSamples = 15 * 16_000
    /// Stock weights re-traced at 5 s. Clips that fit here are the fast path
    /// measured at 48.6 ms p50 on the 8 GB M1 (vs 98.9 ms on the 15 s encoder).
    public static let fastWindowSeconds = 5
    /// Tails longer than 5 s and up to 10 s. Room noise keeps the segmenter
    /// from cutting, so this is the speech a release still has to encode.
    /// 8 s would leave 8–15 s on the stock encoder; 10 s is the size that
    /// covers most of those tails without a third extra bundle.
    public static let middleWindowSeconds = 10

    /// The stock encoder weights re-traced at a 5 s window (`tools/convert/`).
    public static let fastBundle = RemoteBundle(
        name: "parakeet_unified_encoder_w5000_int8.mlmodelc",
        url: URL(string: "https://github.com/bisheshabramhacharya/whisp/releases/download/models-v1/parakeet_unified_encoder_w5000_int8.mlmodelc.zip")!,
        sha256: "2ebd982a4e5b896f41d6cc05554de76c04a837c7879e07d7b9475d80129f4584")

    /// Same weights traced at 10 s. A separate int8 bundle, not a multi-function
    /// model: those only load on macOS 15 (this app is macOS 14), the int8
    /// quantizer rejects them, and each window's traced constants differ so
    /// two bundles cannot share one weight file.
    ///
    /// `sha256` is intentionally empty. No release asset exists yet, and an
    /// invented checksum would make every launch reject the download. The app
    /// does not fetch this bundle, so people who only install Whisp do not get
    /// the 10 s window until a follow-up: build it with
    /// `tools/convert/convert-short-window.py --windows 10`, publish
    /// `parakeet_unified_encoder_w10000_int8.mlmodelc.zip` on the `models-v2`
    /// release (`tools/convert/RELEASE.md`), then paste that zip's real
    /// SHA-256 into `sha256` below.
    ///
    /// A bundle that is already on disk is used with no checksum and no
    /// download. `convert-short-window.py --install` copies it into
    /// `~/Library/Application Support/FluidAudio/Models/parakeet-unified-en-0.6b/`,
    /// the directory this engine scans. `WHISP_MODEL_DIR` points a bench run
    /// at another folder of the same files.
    public static let middleBundle = RemoteBundle(
        name: "parakeet_unified_encoder_w\(middleWindowSeconds * 1000)_int8.mlmodelc",
        url: URL(string: "https://github.com/bisheshabramhacharya/whisp/releases/download/models-v2/parakeet_unified_encoder_w\(middleWindowSeconds * 1000)_int8.mlmodelc.zip")!,
        sha256: "")

    /// Shortest first. Fetched when missing, but only with a published checksum.
    public static let pinnedBundles: [RemoteBundle] = [fastBundle, middleBundle]

    /// Pinned bundles that still need a download. Already-present names and
    /// bundles with an empty checksum are left out.
    public static func bundlesToFetch(
        _ bundles: [RemoteBundle] = pinnedBundles, presentNames: Set<String>
    ) -> [RemoteBundle] {
        bundles.filter { !$0.sha256.isEmpty && !presentNames.contains($0.name) }
    }

    /// Smallest window length that can hold `samples`, or nil when every
    /// window is shorter. `windows` need not be sorted. A release wakes this
    /// same window while you talk; waking the next one early would run a cold
    /// encoder the release might not use, and that decode sits on the same
    /// queue as the real one.
    public static func fittingWindowSamples(_ samples: Int, windows: [Int]) -> Int? {
        windows.sorted().first { $0 >= samples }
    }

    /// Human-readable status updates ("Downloading model…", "Ready", …).
    /// Always invoked on the main thread.
    public var onStatus: ((String) -> Void)?

    /// Frames whose RMS is below this level are treated as silence —
    /// same default as `ParakeetTranscriber`.
    public var silenceThreshold: Float = 0.004

    private let engine = Engine()

    public init() {}

    public func prepare() async throws {
        try await engine.prepare(status: { [weak self] message in
            await self?.emitStatus(message)
        })
    }

    public func rewarm() async {
        await engine.rewarm()
    }

    /// While recording: wake the window a release of `samples` would use, so
    /// crossing from the 5 s window into the 10 s one (or from 10 s into 15 s)
    /// doesn't pay that wake-up at release.
    public func prewarm(forSamples samples: Int) async {
        await engine.prewarm(forSamples: samples)
    }

    /// Encoder windows actually loaded, shortest first. Empty before `prepare`.
    public func loadedWindowSamples() async -> [Int] {
        await engine.loadedWindowSamples()
    }

    /// Per-stage wall time of one windowed decode, for speed tooling.
    public struct DecodeTimings: Sendable {
        public let windowSamples: Int
        public let inputSamples: Int
        public let melMs: Double
        public let encoderMs: Double
        public let rnntMs: Double
    }

    /// Called after every windowed decode (not the >15 s fallback), on the
    /// engine's executor.
    public func observeDecodes(_ observer: @escaping @Sendable (DecodeTimings) -> Void) async {
        await engine.setObserver(observer)
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { throw TranscriberError.audioTooShort }
        guard !SpeechSegmenter.isNearSilent(samples, rmsThreshold: silenceThreshold) else { return "" }
        let trimmed = SpeechSegmenter.trimSpeech(samples)
        let speech = trimmed.isEmpty ? samples : trimmed
        var input = speech
        let minSamples = Int(0.3 * 16_000)
        if input.count < minSamples {
            input.append(contentsOf: [Float](repeating: 0, count: minSamples - input.count))
        }
        try await prepare()
        return ParakeetTranscriber.removingUnknownTokens(try await engine.transcribe(input))
    }

    @MainActor
    private func emitStatus(_ message: String) {
        onStatus?(message)
    }
}

extension ShortWindowEngine {

    /// One encoder window variant: a bundle in the model cache and the window
    /// length it was traced at (in 16 kHz samples).
    public struct WindowVariant: Sendable {
        public let windowSamples: Int
        public let url: URL
        public let int8: Bool

        public init(windowSamples: Int, url: URL, int8: Bool) {
            self.windowSamples = windowSamples
            self.url = url
            self.int8 = int8
        }
    }

    /// Every usable encoder bundle in `dir`: the stock 15 s offline encoder
    /// (int8 preferred, fp16 accepted) plus any
    /// `parakeet_unified_encoder_w{ms}[_int8]` export, shortest first.
    /// int8 wins when a window exists in both precisions.
    public static func discoverVariants(in dir: URL) -> [WindowVariant] {
        let fm = FileManager.default
        var found: [WindowVariant] = []
        for suffix in ["_int8.mlmodelc", ".mlmodelc"] {
            let int8 = suffix == "_int8.mlmodelc"
            let name = "parakeet_unified_encoder\(suffix)"
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                found.append(WindowVariant(
                    windowSamples: maxWindowSamples, url: url, int8: int8))
                break
            }
        }
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var shorts: [WindowVariant] = []
        for entry in entries where entry.hasSuffix(".mlmodelc") {
            guard let range = entry.range(
                of: #"parakeet_unified_encoder_w(\d+)(?:_int8)?\.mlmodelc"#,
                options: .regularExpression), range == entry.startIndex..<entry.endIndex,
                let ms = Int(entry.dropFirst("parakeet_unified_encoder_w".count)
                    .prefix(while: \.isNumber))
            else { continue }
            shorts.append(WindowVariant(
                windowSamples: ms * 16,
                url: dir.appendingPathComponent(entry),
                int8: entry.contains("_int8")))
        }
        var byWindow: [Int: WindowVariant] = [:]
        for v in shorts {
            if let existing = byWindow[v.windowSamples], existing.int8 { continue }
            byWindow[v.windowSamples] = v
        }
        return byWindow.values.sorted { $0.windowSamples < $1.windowSamples } + found
    }

    fileprivate actor Engine {
        private var prepared = false
        private var preparing: Task<Void, Error>?
        /// When each window's encoder last ran (uptime ns), keyed by windowSamples.
        private var lastRun: [Int: UInt64] = [:]
        /// An encoder that hasn't run for this long is slow on its next run,
        /// even if the other window kept the Neural Engine busy meanwhile. On
        /// the 8 GB M1: 5 s window after ~60 s of 15 s-only use 329 ms vs
        /// 27-54 ms warm; after 3-6 s of disuse only ~30 ms extra.
        private static let staleNs: UInt64 = 8_000_000_000

        /// Sorted by windowSamples ascending. Always ends with the stock 15 s
        /// bundle when present, so the engine works with zero extra downloads.
        private var variants: [WindowVariant] = []
        private var encoders: [Int: MLModel] = [:]
        private var mels: [Int: UnifiedMel] = [:]

        private var decoder: MLModel?
        private var joint: MLModel?
        private var rnnt: UnifiedGreedyRnnt?
        private var tokenizer: Tokenizer?
        private var fallbackManager: UnifiedAsrManager?

        private let config = UnifiedConfig()
        private var observer: (@Sendable (DecodeTimings) -> Void)?

        func setObserver(_ observer: @escaping @Sendable (DecodeTimings) -> Void) {
            self.observer = observer
        }

        private var modelDir: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("FluidAudio/Models/parakeet-unified-en-0.6b")
        }

        func prepare(status: @Sendable @escaping (String) async -> Void) async throws {
            guard !prepared else { return }
            if let preparing { return try await preparing.value }
            let task = Task { try await self.load(status: status) }
            preparing = task
            do {
                try await task.value
            } catch {
                preparing = nil
                throw error
            }
        }

        private func load(status: @Sendable @escaping (String) async -> Void) async throws {
            let dir = modelDir
            if !FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(ModelNames.ParakeetUnified.decoderFile).path)
            {
                // First run on this machine: let the library download the base set.
                await status("Downloading model…")
                let manager = UnifiedAsrManager()
                try await manager.loadModels(progressHandler: nil)
                self.fallbackManager = manager
            }

            await status("Loading model…")
            let cpuConfig = MLModelConfiguration()
            cpuConfig.computeUnits = .cpuOnly
            let encConfig = MLModelConfiguration()
            encConfig.computeUnits = .cpuAndNeuralEngine

            decoder = try await MLModel.load(
                contentsOf: dir.appendingPathComponent(ModelNames.ParakeetUnified.decoderFile),
                configuration: cpuConfig)
            joint = try await MLModel.load(
                contentsOf: dir.appendingPathComponent(ModelNames.ParakeetUnified.jointDecisionFile),
                configuration: cpuConfig)
            tokenizer = try Tokenizer(
                vocabPath: dir.appendingPathComponent(ModelNames.ParakeetUnified.vocab))
            rnnt = try UnifiedGreedyRnnt(
                decoderModel: decoder!, jointModel: joint!, config: config)

            // WHISP_MODEL_DIR lets the M1 check point at a scratch dir of
            // downloaded candidate bundles instead of touching the cache.
            var extra: [WindowVariant] = []
            if let env = ProcessInfo.processInfo.environment["WHISP_MODEL_DIR"] {
                extra = ShortWindowEngine.discoverVariants(in: URL(fileURLWithPath: env))
            }
            variants = ShortWindowEngine.discoverVariants(in: dir)
            for variant in extra where variants.allSatisfy({ $0.windowSamples != variant.windowSamples }) {
                variants.append(variant)
            }
            variants.sort { $0.windowSamples < $1.windowSamples }
            for variant in variants {
                let model = try await MLModel.load(contentsOf: variant.url, configuration: encConfig)
                encoders[variant.windowSamples] = model
                mels[variant.windowSamples] = UnifiedMel(
                    windowSamples: variant.windowSamples, nMels: config.melFeatures)
            }

            await status("Warming up…")
            let silence = [Float](repeating: 0, count: 16_000)
            for variant in variants {
                // One decode per window pays model-compile outside timed runs.
                _ = try? transcribeWindow(silence, variant: variant)
            }
            prepared = true
            let labels = variants.map { "\($0.windowSamples / 16_000)s" }.joined(separator: ",")
            asrLogger.info("Encoder windows: \(labels, privacy: .public)")
            await status("Ready")
            fetchMissingBundles(into: dir)
        }

        func loadedWindowSamples() -> [Int] {
            variants.map(\.windowSamples)
        }

        /// Once per launch, in the background, one task per missing published
        /// bundle. A failed fetch leaves the next larger window in use; the
        /// next launch tries again. The 5 s bundle still downloads when a
        /// longer short window is already installed, and the other way around.
        private func fetchMissingBundles(into dir: URL) {
            let present = Set(variants.map { $0.url.lastPathComponent })
            for bundle in ShortWindowEngine.bundlesToFetch(presentNames: present) {
                Task.detached(priority: .utility) { [weak self] in
                    do {
                        let url = try await bundle.fetch(into: dir)
                        await self?.adopt(url)
                    } catch {
                        asrLogger.error(
                            "Encoder window download failed (\(bundle.name, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }

        /// Loads the encoder before listing the window in `variants`: a decode
        /// that runs while `MLModel.load` is suspended must never pick a
        /// window whose encoder isn't there yet.
        private func adopt(_ url: URL) async {
            guard let variant = ShortWindowEngine.discoverVariants(in: url.deletingLastPathComponent())
                .first(where: { $0.url.lastPathComponent == url.lastPathComponent }),
                encoders[variant.windowSamples] == nil
            else { return }
            let encConfig = MLModelConfiguration()
            encConfig.computeUnits = .cpuAndNeuralEngine
            do {
                encoders[variant.windowSamples] = try await MLModel.load(
                    contentsOf: variant.url, configuration: encConfig)
            } catch {
                asrLogger.error(
                    "Encoder window failed to load (\(url.lastPathComponent, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                return
            }
            mels[variant.windowSamples] = UnifiedMel(
                windowSamples: variant.windowSamples, nMels: config.melFeatures)
            _ = try? transcribeWindow([Float](repeating: 0, count: 16_000), variant: variant)
            variants.append(variant)
            variants.sort { $0.windowSamples < $1.windowSamples }
            asrLogger.info("Encoder window ready: \(variant.url.lastPathComponent, privacy: .public)")
        }

        private func variant(for samples: Int) -> WindowVariant? {
            guard let n = ShortWindowEngine.fittingWindowSamples(
                samples, windows: variants.map(\.windowSamples))
            else { return nil }
            return variants.first { $0.windowSamples == n }
        }

        /// Key press: every take starts short, so wake the smallest window.
        func rewarm() async {
            warmIfStale(variants.first)
        }

        /// While recording: wake the window a release of `samples` would use.
        func prewarm(forSamples samples: Int) {
            warmIfStale(variant(for: samples))
        }

        private func warmIfStale(_ variant: WindowVariant?) {
            guard prepared, let variant,
                DispatchTime.now().uptimeNanoseconds - (lastRun[variant.windowSamples] ?? 0) > Self.staleNs
            else { return }
            _ = try? transcribeWindow([Float](repeating: 0, count: 16_000), variant: variant)
        }

        func transcribe(_ samples: [Float]) async throws -> String {
            if let variant = variant(for: samples.count) {
                return try transcribeWindow(samples, variant: variant)
            }
            // Longer than the largest window: decode it in window-sized pieces on
            // the encoders already loaded. Loading a second model set here instead
            // cost 30-75 s at release when Core ML had to recompile it.
            if let largest = variants.last {
                var parts: [String] = []
                for piece in SpeechSegmenter.split(samples, maxSamples: largest.windowSamples) {
                    parts.append(try transcribeWindow(piece, variant: variant(for: piece.count) ?? largest))
                }
                return SpeechSegmenter.join(parts)
            }
            if fallbackManager == nil {
                fallbackManager = UnifiedAsrManager()
                try await fallbackManager!.loadModels(progressHandler: nil)
            }
            return try await fallbackManager!.transcribe(samples)
        }

        /// mel → encoder → greedy RNNT over the valid encoder frames → text.
        /// Identical decode path to `UnifiedAsrManager.transcribe` on one
        /// window, at the variant's window length.
        private func transcribeWindow(_ samples: [Float], variant: WindowVariant) throws -> String {
            guard let mel = mels[variant.windowSamples],
                let encoder = encoders[variant.windowSamples],
                let rnnt, let tokenizer
            else { throw TranscriberError.notPrepared }

            let t0 = DispatchTime.now().uptimeNanoseconds
            var buffer = [Float](repeating: 0, count: variant.windowSamples)
            samples.withUnsafeBufferPointer { src in
                buffer.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: src.baseAddress!, count: samples.count)
                }
            }
            let (melArray, melLength) = try mel.features(
                window: buffer, validCount: samples.count)
            let t1 = DispatchTime.now().uptimeNanoseconds

            let encoderOutput = try encoder.prediction(
                from: EncoderFeatureProvider(mel: melArray, melLength: melLength))
            guard let encoded = encoderOutput.featureValue(for: "encoder")?.multiArrayValue,
                let encodedLength = encoderOutput.featureValue(for: "encoder_length")?.multiArrayValue
            else { throw TranscriberError.notPrepared }
            let t2 = DispatchTime.now().uptimeNanoseconds
            lastRun[variant.windowSamples] = t2

            try rnnt.reset()
            let encoderLength = min(encodedLength[0].intValue, encoded.shape[2].intValue)
            let tokens = try rnnt.decode(encoded: encoded, frameRange: 0..<encoderLength)
            if let observer {
                let t3 = DispatchTime.now().uptimeNanoseconds
                observer(DecodeTimings(
                    windowSamples: variant.windowSamples, inputSamples: samples.count,
                    melMs: Double(t1 - t0) / 1e6, encoderMs: Double(t2 - t1) / 1e6,
                    rnntMs: Double(t3 - t2) / 1e6))
            }
            return tokenizer.decode(ids: tokens)
        }
    }
}

/// Greedy RNNT decode over `encoded` [1, D, T] — same math as FluidAudio's
/// `UnifiedRnntDecoder` (and whisp-bench's `ProfiledRnnt`).
final class UnifiedGreedyRnnt {
    private let decoderModel: MLModel
    private let jointModel: MLModel
    private let config: UnifiedConfig

    private var hState: MLMultiArray
    private var cState: MLMultiArray
    private var lastToken: Int32

    init(decoderModel: MLModel, jointModel: MLModel, config: UnifiedConfig) throws {
        self.decoderModel = decoderModel
        self.jointModel = jointModel
        self.config = config
        self.hState = try Self.zeroState(config: config)
        self.cState = try Self.zeroState(config: config)
        self.lastToken = Int32(config.blankIdx)
    }

    private static func zeroState(config: UnifiedConfig) throws -> MLMultiArray {
        let state = try MLMultiArray(
            shape: [NSNumber(value: config.decoderLayers), 1, NSNumber(value: config.decoderHidden)],
            dataType: .float32
        )
        state.dataPointer.bindMemory(to: Float.self, capacity: state.count)
            .update(repeating: 0, count: state.count)
        return state
    }

    func reset() throws {
        hState = try Self.zeroState(config: config)
        cState = try Self.zeroState(config: config)
        lastToken = Int32(config.blankIdx)
    }

    func decode(encoded: MLMultiArray, frameRange: Range<Int>) throws -> [Int] {
        var currentToken = lastToken
        var currentH = hState
        var currentC = cState
        var tokens: [Int] = []

        var decoderStep = try runDecoder(token: currentToken, h: currentH, c: currentC)

        for t in frameRange {
            let encStep = try extractEncoderStep(from: encoded, timeIndex: t)
            for _ in 0..<config.maxSymbolsPerFrame {
                let jointOutput = try jointModel.prediction(
                    from: JointFeatureProvider(
                        encoderStep: encStep, decoderStep: decoderStep.output))
                guard let tokenArray = jointOutput.featureValue(for: "token_id")?.multiArrayValue
                else { throw TranscriberError.notPrepared }
                let tokenId = tokenArray[0].int32Value
                if tokenId == Int32(config.blankIdx) { break }
                tokens.append(Int(tokenId))
                currentToken = tokenId
                currentH = decoderStep.h
                currentC = decoderStep.c
                decoderStep = try runDecoder(token: currentToken, h: currentH, c: currentC)
            }
        }

        lastToken = currentToken
        hState = currentH
        cState = currentC
        return tokens
    }

    private struct DecoderStep {
        let output: MLMultiArray
        let h: MLMultiArray
        let c: MLMultiArray
    }

    private func runDecoder(token: Int32, h: MLMultiArray, c: MLMultiArray) throws -> DecoderStep {
        let targets = try MLMultiArray(shape: [1, 1], dataType: .int32)
        targets[0] = NSNumber(value: token)
        let targetLength = try MLMultiArray(shape: [1], dataType: .int32)
        targetLength[0] = 1

        let output = try decoderModel.prediction(
            from: DecoderFeatureProvider(
                targets: targets, targetLength: targetLength, hIn: h, cIn: c))
        guard let decoderOut = output.featureValue(for: "decoder")?.multiArrayValue,
            let hOut = output.featureValue(for: "h_out")?.multiArrayValue,
            let cOut = output.featureValue(for: "c_out")?.multiArrayValue
        else { throw TranscriberError.notPrepared }
        return DecoderStep(output: decoderOut, h: hOut, c: cOut)
    }

    private func extractEncoderStep(from encoded: MLMultiArray, timeIndex: Int) throws -> MLMultiArray {
        let dim = encoded.shape[1].intValue
        let step = try MLMultiArray(shape: [1, NSNumber(value: dim), 1], dataType: .float32)
        let srcPtr = encoded.dataPointer.bindMemory(to: Float.self, capacity: encoded.count)
        let dstPtr = step.dataPointer.bindMemory(to: Float.self, capacity: step.count)
        let stride1 = encoded.strides[1].intValue
        let stride2 = encoded.strides[2].intValue
        for c in 0..<dim {
            dstPtr[c] = srcPtr[c * stride1 + timeIndex * stride2]
        }
        return step
    }
}

// MARK: - Feature providers (same contracts as FluidAudio's internal ones)

private final class EncoderFeatureProvider: MLFeatureProvider {
    let featureNames: Set<String> = ["mel", "mel_length"]
    let mel: MLFeatureValue
    let melLength: MLFeatureValue

    func featureValue(for featureName: String) -> MLFeatureValue? {
        featureName.count == 3 ? mel : melLength
    }

    init(mel: MLMultiArray, melLength: MLMultiArray) {
        self.mel = MLFeatureValue(multiArray: mel)
        self.melLength = MLFeatureValue(multiArray: melLength)
    }
}

private final class DecoderFeatureProvider: MLFeatureProvider {
    let featureNames: Set<String> = ["targets", "target_length", "h_in", "c_in"]
    let hIn: MLFeatureValue
    let cIn: MLFeatureValue
    let targets: MLFeatureValue
    let targetLength: MLFeatureValue

    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName.count {
        case 4: return featureName.first == "h" ? hIn : cIn
        case 7: return targets
        default: return targetLength
        }
    }

    init(targets: MLMultiArray, targetLength: MLMultiArray, hIn: MLMultiArray, cIn: MLMultiArray) {
        self.targets = MLFeatureValue(multiArray: targets)
        self.targetLength = MLFeatureValue(multiArray: targetLength)
        self.hIn = MLFeatureValue(multiArray: hIn)
        self.cIn = MLFeatureValue(multiArray: cIn)
    }
}

private final class JointFeatureProvider: MLFeatureProvider {
    let featureNames: Set<String> = ["encoder_step", "decoder_step"]
    let encoderStep: MLFeatureValue
    let decoderStep: MLFeatureValue

    func featureValue(for featureName: String) -> MLFeatureValue? {
        featureName.first == "e" ? encoderStep : decoderStep
    }

    init(encoderStep: MLMultiArray, decoderStep: MLMultiArray) {
        self.encoderStep = MLFeatureValue(multiArray: encoderStep)
        self.decoderStep = MLFeatureValue(multiArray: decoderStep)
    }
}
