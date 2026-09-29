@preconcurrency import CoreML
import FluidAudio
import Foundation

// Stage-level profiler for the offline Parakeet Unified pipeline.
//
// Drives the exact .mlmodelc files FluidAudio's UnifiedAsrManager loads
// (same cache directory, same int8/fp16 variants) with an identical mel
// front-end and greedy RNNT loop, timing every stage and counting every
// CoreML dispatch. Transcript output is byte-identical to
// `UnifiedAsrManager.transcribe` for single-window (<= 15 s) input; longer
// input throws `ProfiledError.tooLong` — the caller falls back to the
// library path or slices first.

/// Per-stage timings (ms) and CoreML dispatch counts for one decode.
public struct DecodeProfile: Sendable {
    public var melMs: Double = 0
    public var encoderMs: Double = 0
    /// Sum of all joint-decision prediction calls.
    public var jointMs: Double = 0
    /// Sum of all decoder prediction calls.
    public var decoderMs: Double = 0
    /// Encoder-extract + feature-provider + misc inside the RNNT loop.
    public var decodeOverheadMs: Double = 0
    public var jointCalls = 0
    public var decoderCalls = 0
    public var encoderCalls = 0
    public var totalMs: Double = 0
    public var tokens = 0
    /// Valid (non-pad) encoder frames decoded — `encoded_length`.
    public var encoderFrames = 0
}

public enum ProfiledError: Error, LocalizedError {
    case modelNotFound(URL)
    case tooLong(samples: Int, maxSamples: Int)
    case encoderOutputMissing
    case jointOutputMissing
    case decoderOutputMissing
    case notPrepared

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let url):
            return "Model file not found: \(url.path) — run whisp-bench once to download models"
        case .tooLong(let samples, let maxSamples):
            return "ProfiledUnified decodes one window (<= \(maxSamples) samples); got \(samples)"
        case .encoderOutputMissing: return "encoder did not produce 'encoder'/'encoder_length'"
        case .jointOutputMissing: return "joint decision did not produce 'token_id'"
        case .decoderOutputMissing: return "decoder did not produce 'decoder'/'h_out'/'c_out'"
        case .notPrepared: return "ProfiledUnified.load() not called"
        }
    }
}

// MARK: - Mel extractor (identical to FluidAudio's internal UnifiedMelExtractor)

/// Native-Swift log-mel features for Parakeet Unified, bit-exact port of
/// FluidAudio's internal `UnifiedMelExtractor` (kept in sync by construction:
/// same `AudioMelSpectrogram` configuration and the same per_feature
/// normalization). `AudioMelSpectrogram` supplies the spectrogram; this type
/// adds the NeMo `normalize: per_feature` standardization and packs the
/// fixed-shape encoder input.
struct UnifiedMel {
    private let mel: AudioMelSpectrogram
    private let nMels: Int
    private let hopLength = 160

    /// Total samples in the (zero-padded) encoder window.
    let windowSamples: Int
    /// Fixed mel frame count the encoder expects (`windowSamples / hop + 1`).
    let totalFrames: Int

    init(windowSamples: Int, nMels: Int = 128) {
        self.windowSamples = windowSamples
        self.nMels = nMels
        self.totalFrames = windowSamples / hopLength + 1
        self.mel = AudioMelSpectrogram(
            sampleRate: 16000,
            nMels: nMels,
            nFFT: 512,
            hopLength: 160,
            winLength: 400,
            preemph: 0.97,
            padTo: 0,
            windowPeriodic: false
        )
    }

    /// `(mel, melLength)` for one encoder window — same contract as the
    /// CoreML preprocessor outputs the models were exported against.
    func features(window: [Float], validCount: Int) throws -> (mel: MLMultiArray, length: MLMultiArray) {
        var flat = mel.computeFlatTransposed(
            audio: window,
            lastAudioSample: 0,
            paddingMode: .center,
            expectedFrameCount: totalFrames
        ).mel

        // NeMo `get_seq_len` (center padding, stft_pad_amount=0): floor(L/hop),
        // NO +1 — the final tensor frame stays normalized to 0.
        let validFrames = min(validCount / hopLength, totalFrames)
        normalizePerFeature(&flat, frames: totalFrames, validFrames: validFrames)

        let melArray = try MLMultiArray(
            shape: [1, NSNumber(value: nMels), NSNumber(value: totalFrames)], dataType: .float32)
        melArray.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
            for t in 0..<totalFrames {
                let base = t * nMels
                for m in 0..<nMels {
                    ptr[m * totalFrames + t] = flat[base + m]
                }
            }
        }

        let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArray[0] = NSNumber(value: validFrames)
        return (melArray, lengthArray)
    }

    /// NeMo `normalize_batch(..., normalize_type="per_feature")`.
    private func normalizePerFeature(_ x: inout [Float], frames: Int, validFrames: Int) {
        guard validFrames > 0 else {
            for i in x.indices { x[i] = 0 }
            return
        }
        let denom = Float(validFrames > 1 ? validFrames - 1 : 1)
        for m in 0..<nMels {
            var mean: Float = 0
            for t in 0..<validFrames { mean += x[t * nMels + m] }
            mean /= Float(validFrames)

            var varSum: Float = 0
            for t in 0..<validFrames {
                let d = x[t * nMels + m] - mean
                varSum += d * d
            }
            let std = (varSum / denom).squareRoot() + 1e-5

            for t in 0..<frames {
                x[t * nMels + m] = t < validFrames ? (x[t * nMels + m] - mean) / std : 0
            }
        }
    }
}

// MARK: - Feature providers (identical to FluidAudio's internal ones)

final class EncoderFeatureProvider: MLFeatureProvider {
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

final class DecoderFeatureProvider: MLFeatureProvider {
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

final class JointFeatureProvider: MLFeatureProvider {
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

// MARK: - Instrumented greedy RNNT decoder

/// One emitted (non-blank) token and where it was emitted.
public struct Emission: Sendable {
    public let token: Int
    public let frame: Int
    public let prob: Float
}

/// Same math as FluidAudio's `UnifiedRnntDecoder`, with a call counter and a
/// per-model nanosecond timer around every `prediction`.
final class ProfiledRnnt {
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

    private struct DecoderStep {
        let output: MLMultiArray
        let h: MLMultiArray
        let c: MLMultiArray
    }

    /// Greedy RNNT over `frameRange` of `encoded` [1, D, T]; reported frames are
    /// `globalFrameOffset + t`. Accumulates timings/counters into `profile`.
    func decode(
        encoded: MLMultiArray,
        frameRange: Range<Int>,
        globalFrameOffset: Int = 0,
        profile: inout DecodeProfile
    ) throws -> [Emission] {
        var currentToken = lastToken
        var currentH = hState
        var currentC = cState
        var emissions: [Emission] = []

        var decoderStep = try runDecoder(token: currentToken, h: currentH, c: currentC, profile: &profile)

        for t in frameRange {
            let extractStart = DispatchTime.now().uptimeNanoseconds
            let encStep = try extractEncoderStep(from: encoded, timeIndex: t)
            profile.decodeOverheadMs += Self.ms(extractStart)

            for _ in 0..<config.maxSymbolsPerFrame {
                let jointStart = DispatchTime.now().uptimeNanoseconds
                let jointOutput = try jointModel.prediction(
                    from: JointFeatureProvider(encoderStep: encStep, decoderStep: decoderStep.output)
                )
                profile.jointMs += Self.ms(jointStart)
                profile.jointCalls += 1
                guard let tokenArray = jointOutput.featureValue(for: "token_id")?.multiArrayValue else {
                    throw ProfiledError.jointOutputMissing
                }
                let tokenId = tokenArray[0].int32Value

                if tokenId == Int32(config.blankIdx) { break }
                let prob = jointOutput.featureValue(for: "token_prob")?.multiArrayValue?[0].floatValue ?? 0
                emissions.append(Emission(token: Int(tokenId), frame: globalFrameOffset + t, prob: prob))
                currentToken = tokenId
                currentH = decoderStep.h
                currentC = decoderStep.c
                decoderStep = try runDecoder(token: currentToken, h: currentH, c: currentC, profile: &profile)
            }
        }

        lastToken = currentToken
        hState = currentH
        cState = currentC
        profile.tokens = emissions.count
        return emissions
    }

    private func runDecoder(token: Int32, h: MLMultiArray, c: MLMultiArray,
                            profile: inout DecodeProfile) throws -> DecoderStep {
        let targets = try MLMultiArray(shape: [1, 1], dataType: .int32)
        targets[0] = NSNumber(value: token)
        let targetLength = try MLMultiArray(shape: [1], dataType: .int32)
        targetLength[0] = 1

        let start = DispatchTime.now().uptimeNanoseconds
        let output = try decoderModel.prediction(
            from: DecoderFeatureProvider(targets: targets, targetLength: targetLength, hIn: h, cIn: c)
        )
        profile.decoderMs += Self.ms(start)
        profile.decoderCalls += 1
        guard let decoderOut = output.featureValue(for: "decoder")?.multiArrayValue,
            let hOut = output.featureValue(for: "h_out")?.multiArrayValue,
            let cOut = output.featureValue(for: "c_out")?.multiArrayValue
        else { throw ProfiledError.decoderOutputMissing }
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

    private static func ms(_ since: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - since) / 1e6
    }
}

// MARK: - Profiled engine

/// One window's decoded text plus its stage profile.
public struct ProfiledTranscript: Sendable {
    public let text: String
    public let emissions: [Emission]
    public let profile: DecodeProfile
}

/// Drives the offline Parakeet Unified 15 s pipeline directly on the cached
/// `.mlmodelc` bundles, timing mel / encoder / RNNT (with per-model call
/// counts) so the cost of each stage is visible. Output is byte-identical to
/// `UnifiedAsrManager.transcribe` for inputs that fit one window.
public actor ProfiledUnified {
    /// Fixed 15 s encoder window of the offline export.
    public static let windowSamples = 15 * 16_000

    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var rnnt: ProfiledRnnt?
    private var tokenizer: Tokenizer?
    private var mel: UnifiedMel?
    private var layoutSamples: Int { Self.windowSamples }

    private let config = UnifiedConfig()

    public init() {}

    /// Default FluidAudio model cache for the Unified repo.
    public static func defaultModelDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("FluidAudio/Models/parakeet-unified-en-0.6b")
    }

    /// Load encoder/decoder/joint from `directory` (must already be populated —
    /// run `UnifiedAsrManager.loadModels` or whisp-bench once first).
    public func load(
        from directory: URL = ProfiledUnified.defaultModelDir(),
        encoderPrecision: UnifiedEncoderPrecision = .int8,
        encoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) async throws {
        func existing(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ProfiledError.modelNotFound(url)
            }
            return url
        }

        let encConfig = MLModelConfiguration()
        encConfig.computeUnits = encoderComputeUnits
        let cpuConfig = MLModelConfiguration()
        cpuConfig.computeUnits = .cpuOnly

        encoder = try await MLModel.load(
            contentsOf: existing(ModelNames.ParakeetUnified.offlineEncoderFile(precision: encoderPrecision)),
            configuration: encConfig)
        decoder = try await MLModel.load(
            contentsOf: existing(ModelNames.ParakeetUnified.decoderFile),
            configuration: cpuConfig)
        joint = try await MLModel.load(
            contentsOf: existing(ModelNames.ParakeetUnified.jointDecisionFile),
            configuration: cpuConfig)
        tokenizer = try Tokenizer(vocabPath: existing(ModelNames.ParakeetUnified.vocab))
        rnnt = try ProfiledRnnt(decoderModel: decoder!, jointModel: joint!, config: config)
        mel = UnifiedMel(windowSamples: layoutSamples, nMels: config.melFeatures)
    }

    /// Decode a single <= 15 s window with stage profiling. Throws `tooLong`
    /// for longer input — slice or use `UnifiedAsrManager` there.
    public func transcribeWindow(_ samples: [Float]) async throws -> ProfiledTranscript {
        guard let mel, let encoder, let rnnt, let tokenizer else { throw ProfiledError.notPrepared }
        guard samples.count <= layoutSamples else {
            throw ProfiledError.tooLong(samples: samples.count, maxSamples: layoutSamples)
        }

        var profile = DecodeProfile()
        let totalStart = DispatchTime.now().uptimeNanoseconds

        // mel (full padded window — same as production)
        var buffer = [Float](repeating: 0, count: layoutSamples)
        samples.withUnsafeBufferPointer { src in
            buffer.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: src.baseAddress!, count: samples.count)
            }
        }
        let melStart = DispatchTime.now().uptimeNanoseconds
        let (melArray, melLength) = try mel.features(window: buffer, validCount: samples.count)
        profile.melMs = Self.ms(melStart)

        // encoder — 1 call
        let encStart = DispatchTime.now().uptimeNanoseconds
        let encoderOutput = try await encoder.prediction(
            from: EncoderFeatureProvider(mel: melArray, melLength: melLength))
        profile.encoderMs = Self.ms(encStart)
        profile.encoderCalls = 1
        guard let encoded = encoderOutput.featureValue(for: "encoder")?.multiArrayValue,
            let encodedLength = encoderOutput.featureValue(for: "encoder_length")?.multiArrayValue
        else { throw ProfiledError.encoderOutputMissing }

        // RNNT greedy loop
        try rnnt.reset()
        let encoderLength = min(encodedLength[0].intValue, encoded.shape[2].intValue)
        profile.encoderFrames = encoderLength
        let emissions = try rnnt.decode(
            encoded: encoded, frameRange: 0..<encoderLength, globalFrameOffset: 0,
            profile: &profile)

        profile.totalMs = Self.ms(totalStart)
        let text = tokenizer.decode(ids: emissions.map(\.token))
        return ProfiledTranscript(text: text, emissions: emissions, profile: profile)
    }

    private static func ms(_ since: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - since) / 1e6
    }
}
