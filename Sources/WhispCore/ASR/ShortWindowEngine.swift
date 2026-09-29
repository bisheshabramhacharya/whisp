@preconcurrency import CoreML
import FluidAudio
import Foundation

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
/// behaves exactly like the 15 s engine; input > 15 s →
/// `UnifiedAsrManager`'s sliding-window path.
public final class ShortWindowEngine: Transcribing, StatusReporting {
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
        return try await engine.transcribe(input)
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
        private static let maxWindowSamples = 15 * 16_000

        private var prepared = false
        private var preparing: Task<Void, Error>?
        private var lastRun: UInt64 = 0

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

            variants = Self.discoverVariants(in: dir)
            for variant in variants {
                let model = try await MLModel.load(contentsOf: variant.url, configuration: encConfig)
                encoders[variant.windowSamples] = model
                mels[variant.windowSamples] = UnifiedMel(
                    windowSamples: variant.windowSamples, nMels: config.melFeatures)
            }

            await status("Warming up…")
            lastRun = DispatchTime.now().uptimeNanoseconds
            let silence = [Float](repeating: 0, count: 16_000)
            for variant in variants {
                // One decode per window pays model-compile outside timed runs.
                _ = try? transcribeWindow(silence, variant: variant)
            }
            prepared = true
            await status("Ready")
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

        /// Skipped when the model ran recently enough to still be warm.
        func rewarm() async {
            guard prepared, DispatchTime.now().uptimeNanoseconds - lastRun > 20_000_000_000,
                let smallest = variants.first
            else { return }
            let silence = [Float](repeating: 0, count: 16_000)
            _ = try? transcribeWindow(silence, variant: smallest)
            lastRun = DispatchTime.now().uptimeNanoseconds
        }

        func transcribe(_ samples: [Float]) async throws -> String {
            defer { lastRun = DispatchTime.now().uptimeNanoseconds }
            guard let variant = variant(for: samples.count) else {
                if fallbackManager == nil {
                    fallbackManager = UnifiedAsrManager()
                    try await fallbackManager!.loadModels(progressHandler: nil)
                }
                return try await fallbackManager!.transcribe(samples)
            }
            return try transcribeWindow(samples, variant: variant)
        }

        /// mel → encoder → greedy RNNT over the valid encoder frames → text.
        /// Identical decode path to `UnifiedAsrManager.transcribe` on one
        /// window, at the variant's window length.
        private func transcribeWindow(_ samples: [Float], variant: WindowVariant) throws -> String {
            guard let mel = mels[variant.windowSamples],
                let encoder = encoders[variant.windowSamples],
                let rnnt, let tokenizer
            else { throw TranscriberError.notPrepared }

            var buffer = [Float](repeating: 0, count: variant.windowSamples)
            samples.withUnsafeBufferPointer { src in
                buffer.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: src.baseAddress!, count: samples.count)
                }
            }
            let (melArray, melLength) = try mel.features(
                window: buffer, validCount: samples.count)

            let encoderOutput = try encoder.prediction(
                from: EncoderFeatureProvider(mel: melArray, melLength: melLength))
            guard let encoded = encoderOutput.featureValue(for: "encoder")?.multiArrayValue,
                let encodedLength = encoderOutput.featureValue(for: "encoder_length")?.multiArrayValue
            else { throw TranscriberError.notPrepared }

            try rnnt.reset()
            let encoderLength = min(encodedLength[0].intValue, encoded.shape[2].intValue)
            let tokens = try rnnt.decode(encoded: encoded, frameRange: 0..<encoderLength)
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
