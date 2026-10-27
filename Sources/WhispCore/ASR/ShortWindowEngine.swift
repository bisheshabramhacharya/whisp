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
/// computes the same values for the valid region as the 15 s model.
///
/// Fallbacks keep the engine safe on any machine: no short bundles present →
/// behaves exactly like the 15 s engine (and `fastBundle` is fetched in the
/// background, then used without a relaunch); input > 15 s →
/// `UnifiedAsrManager`'s sliding-window path.
///
/// `piecewise` mode (engine name "split") covers the band where the stock
/// engine pays a flat 15 s pass for a leftover barely past the short encoder:
/// an input in `(short window, 2×short window]` that only the 15 s window
/// would otherwise fit decodes as two quiet-cut pieces on the short window
/// (`SpeechSegmenter.splitTwo`). Anything a non-stock window already fits is
/// routed there instead, and inputs past twice the short window keep `short`'s
/// own path — two half-stock passes cost more than one stock pass. With no
/// short bundle loaded it degrades to the stock path, so the engine is safe
/// before `fastBundle` arrives.
public final class ShortWindowEngine: Transcribing, StatusReporting {
    /// The stock encoder weights re-traced at a 5 s window (`tools/convert/`).
    public static let fastBundle = RemoteBundle(
        name: "parakeet_unified_encoder_w5000_int8.mlmodelc",
        url: URL(string: "https://github.com/bisheshabramhacharya/whisp/releases/download/models-v1/parakeet_unified_encoder_w5000_int8.mlmodelc.zip")!,
        sha256: "2ebd982a4e5b896f41d6cc05554de76c04a837c7879e07d7b9475d80129f4584")

    /// Human-readable status updates ("Downloading model…", "Ready", …).
    /// Always invoked on the main thread.
    public var onStatus: ((String) -> Void)?

    /// Frames whose RMS is below this level are treated as silence —
    /// same default as `ParakeetTranscriber`.
    public var silenceThreshold: Float = 0.004

    /// The window `piecewise` mode cuts pieces on, in samples: the largest
    /// loaded window at most a third of the stock 15 s, i.e. genuinely short
    /// (w5000 today). A half-stock window (w10000) is not a piece candidate —
    /// two of its passes cost more than one stock pass. Returns the stock
    /// window when no such bundle is loaded, making piecewise a no-op.
    public static func piecewiseLimit(windows: [Int]) -> Int {
        windows.filter { $0 <= Engine.maxWindowSamples / 3 }.max() ?? Engine.maxWindowSamples
    }

    private let engine: Engine

    public init(piecewise: Bool = false) {
        engine = Engine(piecewise: piecewise)
    }

    public func prepare() async throws {
        try await engine.prepare(status: { [weak self] message in
            await self?.emitStatus(message)
        })
    }

    public func rewarm() async {
        await engine.rewarm()
    }

    public func prewarm(forSamples samples: Int) async {
        await engine.prewarm(forSamples: samples)
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
    struct WindowVariant: Sendable {
        let windowSamples: Int
        let url: URL
        let int8: Bool
    }

    fileprivate actor Engine {
        /// Largest window the offline export supports.
        static let maxWindowSamples = 15 * 16_000

        /// `split` engine: an input in `(piece window, 2×piece window]` that
        /// only the 15 s window would otherwise fit decodes as two quiet-cut
        /// pieces on the piece window instead of one flat 15 s pass.
        private let piecewise: Bool

        init(piecewise: Bool) {
            self.piecewise = piecewise
        }

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
                extra = Self.discoverVariants(in: URL(fileURLWithPath: env))
            }
            variants = Self.discoverVariants(in: dir)
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
            await status("Ready")
            if !variants.contains(where: { $0.windowSamples < Self.maxWindowSamples }) {
                fetchFastBundle(into: dir)
            }
        }

        /// Once per launch, in the background. A failed fetch only means the
        /// 15 s window stays in use; the next launch tries again.
        private func fetchFastBundle(into dir: URL) {
            let bundle = ShortWindowEngine.fastBundle
            Task.detached(priority: .utility) { [weak self] in
                do {
                    let url = try await bundle.fetch(into: dir)
                    await self?.adopt(url)
                } catch {
                    asrLogger.error("Fast model download failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        /// Loads the encoder before listing the window in `variants`: a decode
        /// that runs while `MLModel.load` is suspended must never pick a
        /// window whose encoder isn't there yet.
        private func adopt(_ url: URL) async {
            guard let variant = Self.discoverVariants(in: url.deletingLastPathComponent())
                .first(where: { $0.url.lastPathComponent == url.lastPathComponent }),
                encoders[variant.windowSamples] == nil
            else { return }
            let encConfig = MLModelConfiguration()
            encConfig.computeUnits = .cpuAndNeuralEngine
            do {
                encoders[variant.windowSamples] = try await MLModel.load(
                    contentsOf: variant.url, configuration: encConfig)
            } catch {
                asrLogger.error("Fast model failed to load: \(error.localizedDescription, privacy: .public)")
                return
            }
            mels[variant.windowSamples] = UnifiedMel(
                windowSamples: variant.windowSamples, nMels: config.melFeatures)
            _ = try? transcribeWindow([Float](repeating: 0, count: 16_000), variant: variant)
            variants.append(variant)
            variants.sort { $0.windowSamples < $1.windowSamples }
            asrLogger.info("Fast model ready: \(variant.url.lastPathComponent, privacy: .public)")
        }

        /// Every usable encoder bundle in the cache: the stock 15 s offline
        /// encoder (int8 preferred, fp16 accepted) plus any
        /// `parakeet_unified_encoder_w{ms}[_int8]` short-window exports,
        /// shortest first.
        private static func discoverVariants(in dir: URL) -> [WindowVariant] {
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
            // int8 wins when a window exists in both precisions.
            var byWindow: [Int: WindowVariant] = [:]
            for v in shorts {
                if let existing = byWindow[v.windowSamples], existing.int8 { continue }
                byWindow[v.windowSamples] = v
            }
            return byWindow.values.sorted { $0.windowSamples < $1.windowSamples } + found
        }

        private func variant(for samples: Int) -> WindowVariant? {
            variants.first { $0.windowSamples >= samples }
        }

        /// The variant `piecewise` decodes pieces on, when one is loaded.
        /// The overlap between pieces, in samples (0.5 s): long enough for a
        /// word spanning the cut to be complete inside both pieces.
        static let piecewiseOverlapSamples = 16_000 / 2
        private var piecewiseWindow: WindowVariant? {
            guard piecewise else { return nil }
            let limit = ShortWindowEngine.piecewiseLimit(windows: variants.map(\.windowSamples))
            return limit < Self.maxWindowSamples
                ? variants.first { $0.windowSamples == limit } : nil
        }

        /// Key press: every take starts short, so wake the smallest window.
        func rewarm() async {
            warmIfStale(variants.first)
        }

        /// While recording: wake the window a release decode of `samples`
        /// would use, so crossing into the 15 s window doesn't pay its wake-up
        /// at release. A band input under `piecewise` decodes on the piece
        /// window, so that's the window to keep warm.
        func prewarm(forSamples samples: Int) {
            var target = samples
            if let pieceW = piecewiseWindow, target > pieceW.windowSamples,
                target <= 2 * pieceW.windowSamples {
                target = pieceW.windowSamples
            }
            warmIfStale(variant(for: min(target, Self.maxWindowSamples)))
        }

        private func warmIfStale(_ variant: WindowVariant?) {
            guard prepared, let variant,
                DispatchTime.now().uptimeNanoseconds - (lastRun[variant.windowSamples] ?? 0) > Self.staleNs
            else { return }
            _ = try? transcribeWindow([Float](repeating: 0, count: 16_000), variant: variant)
        }

        func transcribe(_ samples: [Float]) async throws -> String {
            // Piecewise band: the stock engine would pay a flat 15 s pass, but
            // two quiet-cut pieces on the short window are cheaper. Only when
            // no non-stock window already fits the input — a fitting mid
            // window (w10000) decodes it in one pass, which is cheaper still.
            // The 0.5 s overlap keeps a word spanning the cut whole in at
            // least one piece; joinOverlap drops its second decode.
            if let pieceW = piecewiseWindow,
                samples.count > pieceW.windowSamples,
                variant(for: samples.count)?.windowSamples == Self.maxWindowSamples {
                let pieces = SpeechSegmenter.splitTwo(
                    samples, maxSamples: pieceW.windowSamples,
                    overlap: Self.piecewiseOverlapSamples)
                if pieces.count == 2 {
                    let first = try transcribeWindow(
                        pieces[0], variant: variant(for: pieces[0].count) ?? pieceW)
                    let second = try transcribeWindow(
                        pieces[1], variant: variant(for: pieces[1].count) ?? pieceW)
                    return SpeechSegmenter.joinOverlap(first, second)
                }
            }
            if let variant = variant(for: samples.count) {
                return try transcribeWindow(samples, variant: variant)
            }
            // Longer than the largest window the engine may use: decode it in
            // window-sized pieces on the encoders already loaded. Loading a
            // second model set here instead cost 30-75 s at release when
            // Core ML had to recompile it.
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
