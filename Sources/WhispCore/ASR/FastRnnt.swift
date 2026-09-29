@preconcurrency import CoreML
import FluidAudio
import Foundation

// Greedy RNNT decode over the batched joint export
// (`parakeet_unified_joint.mlmodelc`) instead of the per-step
// `joint_decision_single_step` model.
//
// The wide joint takes the WHOLE encoder output [1, 1024, T=188] plus one
// decoder step [1, 640, 1] and returns logits [1, 188, 1, 1025] — every
// frame's decision under the current decoder state in ONE CoreML call.
// While the decoder emits blank the decoder state is unchanged, so the same
// logits stay valid across a run of blank frames: joint calls collapse from
// ~1 + blanks + tokens (≈120 for a 5 s clip) to ~1 + tokens (≈46), i.e.
// total CoreML dispatches per decode drop ~45% (170 → ~92). Each wide call
// computes 188 positions instead of 1, so it wins where dispatch overhead
// dominates (ANE / small batches) and can lose on pure-CPU throughput —
// measure per-hardware, hence `jointComputeUnits` is an init knob.
//
// Greedy decisions are identical to FluidAudio's `UnifiedRnntDecoder`:
// logits argmax (first-max ties, like reduce_argmax) at frame t, blank → t+1,
// token → emit + re-run decoder + re-run wide joint; ≤ maxSymbolsPerFrame
// decisions per frame. Inputs > 15 s fall back to `UnifiedAsrManager`
// (overlap-merge) like `ProfiledTranscriber`.

/// One emitted (non-blank) token and its frame.
public struct FastEmission: Sendable {
    public let token: Int
    public let frame: Int
    public let prob: Float
}

public enum FastRnntError: Error, LocalizedError {
    case modelNotFound(URL)
    case encoderOutputMissing
    case jointOutputMissing
    case decoderOutputMissing
    case notPrepared

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let url):
            return "Model file not found: \(url.path)"
        case .encoderOutputMissing: return "encoder did not produce 'encoder'/'encoder_length'"
        case .jointOutputMissing: return "wide joint did not produce a 4-D 'logits' output"
        case .decoderOutputMissing: return "decoder did not produce 'decoder'/'h_out'/'c_out'"
        case .notPrepared: return "FastRnnt.prepare() not called"
        }
    }
}

// MARK: - Mel extractor (same math as FluidAudio's internal UnifiedMelExtractor)

/// Log-mel features: `AudioMelSpectrogram` + NeMo `per_feature` normalization,
/// packed into the fixed-shape encoder input. Kept private so this file is
/// self-contained in WhispCore.
private struct FastMel {
    private let mel: AudioMelSpectrogram
    private let nMels: Int
    private let hopLength = 160

    let windowSamples: Int
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

    func features(window: [Float], validCount: Int) throws -> (mel: MLMultiArray, length: MLMultiArray) {
        var flat = mel.computeFlatTransposed(
            audio: window,
            lastAudioSample: 0,
            paddingMode: .center,
            expectedFrameCount: totalFrames
        ).mel

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

// MARK: - Feature providers

private final class FastEncoderProvider: MLFeatureProvider {
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

private final class FastDecoderProvider: MLFeatureProvider {
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

/// Wide joint inputs: `decoder` [1, 640, 1] + `encoder` [1, 1024, 188].
private final class FastWideJointProvider: MLFeatureProvider {
    let featureNames: Set<String> = ["decoder", "encoder"]
    let decoder: MLFeatureValue
    let encoder: MLFeatureValue

    func featureValue(for featureName: String) -> MLFeatureValue? {
        featureName.first == "d" ? decoder : encoder
    }

    init(decoder: MLMultiArray, encoder: MLMultiArray) {
        self.decoder = MLFeatureValue(multiArray: decoder)
        self.encoder = MLFeatureValue(multiArray: encoder)
    }
}

// MARK: - Batched-joint greedy RNNT

private struct FastDecoderStep {
    let output: MLMultiArray
    let h: MLMultiArray
    let c: MLMultiArray
}

/// Read-only view over one wide-joint output `[1, T, 1, V]`: argmax + softmax
/// per frame read straight out of the MLMultiArray buffer.
private struct FastLogits {
    let ptr: UnsafePointer<Float>
    let timeStride: Int
    let vocabStride: Int
    let vocab: Int

    init(_ array: MLMultiArray) {
        self.ptr = UnsafePointer(array.dataPointer.bindMemory(to: Float.self, capacity: array.count))
        self.timeStride = array.strides[1].intValue
        self.vocabStride = array.strides[3].intValue
        self.vocab = array.shape[3].intValue
    }

    /// Argmax (first max wins, matching reduce_argmax) + softmax prob for the
    /// winning token at frame `t`.
    func argmaxSoftmax(frame t: Int) -> (Int32, Float) {
        let base = t * timeStride
        var best = 0
        var bestV = ptr[base]
        for u in 1..<vocab {
            let v = ptr[base + u * vocabStride]
            if v > bestV { bestV = v; best = u }
        }
        var sum = 0.0 as Float
        for u in 0..<vocab {
            sum += expf(ptr[base + u * vocabStride] - bestV)
        }
        return (Int32(best), 1.0 / sum)
    }
}

private final class FastRnntDecoder {
    private let decoderModel: MLModel
    private let jointModel: MLModel
    private let config: UnifiedConfig

    /// Reused decoder input buffers (targets/target_length are tiny; avoid a
    /// fresh MLMultiArray per token).
    private let targetsArray: MLMultiArray
    private let targetLengthArray: MLMultiArray

    init(decoderModel: MLModel, jointModel: MLModel, config: UnifiedConfig) throws {
        self.decoderModel = decoderModel
        self.jointModel = jointModel
        self.config = config
        self.targetsArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
        self.targetLengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        self.targetLengthArray[0] = 1
    }

    /// Greedy decode over `encoded` [1, D, T]. One wide-joint call covers every
    /// frame for the current decoder state; the logits are re-read (not
    /// recomputed) across blank runs and refreshed after each emitted token.
    /// `jointCalls`/`decoderCalls` count CoreML dispatches for reporting.
    func decode(
        encoded: MLMultiArray,
        encoderLength: Int,
        jointCalls: inout Int,
        decoderCalls: inout Int
    ) throws -> [FastEmission] {
        var emissions: [FastEmission] = []
        var h = try Self.zeroState(config: config)
        var c = try Self.zeroState(config: config)

        var step = try runDecoder(token: Int32(config.blankIdx), h: h, c: c, calls: &decoderCalls)
        var logits = FastLogits(try runJoint(encoded: encoded, decoderOut: step.output, calls: &jointCalls))

        var t = 0
        var symbolsThisFrame = 0
        while t < encoderLength {
            let (tokenId, prob) = logits.argmaxSoftmax(frame: t)
            if Int(tokenId) == config.blankIdx {
                t += 1
                symbolsThisFrame = 0
                continue
            }
            emissions.append(FastEmission(token: Int(tokenId), frame: t, prob: prob))
            h = step.h
            c = step.c
            step = try runDecoder(token: tokenId, h: h, c: c, calls: &decoderCalls)
            symbolsThisFrame += 1
            if symbolsThisFrame >= config.maxSymbolsPerFrame {
                t += 1
                symbolsThisFrame = 0
            }
            if t < encoderLength {
                logits = FastLogits(
                    try runJoint(encoded: encoded, decoderOut: step.output, calls: &jointCalls))
            }
        }
        return emissions
    }

    private func runDecoder(
        token: Int32, h: MLMultiArray, c: MLMultiArray, calls: inout Int
    ) throws -> FastDecoderStep {
        targetsArray[0] = NSNumber(value: token)
        let output = try decoderModel.prediction(
            from: FastDecoderProvider(
                targets: targetsArray, targetLength: targetLengthArray, hIn: h, cIn: c))
        calls += 1
        guard let decoderOut = output.featureValue(for: "decoder")?.multiArrayValue,
            let hOut = output.featureValue(for: "h_out")?.multiArrayValue,
            let cOut = output.featureValue(for: "c_out")?.multiArrayValue
        else { throw FastRnntError.decoderOutputMissing }
        return FastDecoderStep(output: decoderOut, h: hOut, c: cOut)
    }

    private func runJoint(
        encoded: MLMultiArray, decoderOut: MLMultiArray, calls: inout Int
    ) throws -> MLMultiArray {
        let output = try jointModel.prediction(
            from: FastWideJointProvider(decoder: decoderOut, encoder: encoded))
        calls += 1
        if let logits = output.featureValue(for: "logits")?.multiArrayValue, logits.shape.count == 4 {
            return logits
        }
        for name in output.featureNames {
            if let arr = output.featureValue(for: name)?.multiArrayValue, arr.shape.count == 4 {
                return arr
            }
        }
        throw FastRnntError.jointOutputMissing
    }

    /// Argmax (first max wins, like reduce_argmax) + softmax prob over one
    /// logits row, read straight out of the joint output buffer.
    private static func argmaxSoftmax(
        _ ptr: UnsafePointer<Float>, base: Int, stride: Int, count: Int
    ) -> (Int32, Float) {
        var best = 0
        var bestV = ptr[base]
        for u in 1..<count {
            let v = ptr[base + u * stride]
            if v > bestV { bestV = v; best = u }
        }
        var sum = 0.0 as Float
        for u in 0..<count {
            sum += expf(ptr[base + u * stride] - bestV)
        }
        return (Int32(best), 1.0 / sum)
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
}

// MARK: - Engine

/// `Transcribing` engine: same int8 encoder + Swift mel front-end as
/// `ParakeetTranscriber`, RNNT loop via the batched joint.
public actor FastRnnt: Transcribing {

    /// Batched joint bundle shipped in the HF repo but not fetched by
    /// `ModelHub.requiredModels(variant: "offline")`.
    public static let wideJointFile = "parakeet_unified_joint.mlmodelc"

    /// Fixed 15 s encoder window of the offline export.
    public static let windowSamples = 15 * 16_000

    private var encoder: MLModel?
    private var decoderModel: MLModel?
    private var jointModel: MLModel?
    private var rnnt: FastRnntDecoder?
    private var tokenizer: Tokenizer?
    private var mel: FastMel?
    private var fallback: UnifiedAsrManager?
    private var lastRun: ContinuousClock.Instant?
    /// Diagnostics: dispatch counts of the most recent windowed decode.
    public private(set) var lastJointCalls = 0
    public private(set) var lastDecoderCalls = 0
    public private(set) var usedFallback = false

    private let config = UnifiedConfig()
    private let jointComputeUnits: MLComputeUnits

    public init(jointComputeUnits: MLComputeUnits = .cpuOnly) {
        self.jointComputeUnits = jointComputeUnits
    }

    /// Default FluidAudio model cache for the Unified repo.
    public static func defaultModelDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("FluidAudio/Models/parakeet-unified-en-0.6b")
    }

    /// Download (incl. the wide joint, which FluidAudio's required list omits)
    /// then load encoder/decoder/joint + tokenizer.
    public func prepare() async throws {
        if rnnt != nil { return }
        let modelsBaseDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        .appendingPathComponent("FluidAudio", isDirectory: true)
        .appendingPathComponent("Models", isDirectory: true)

        try await ModelHub.download(
            .parakeetUnified,
            to: modelsBaseDir,
            variant: "offline",
            additionalModelNames: [Self.wideJointFile])

        let cacheDir = modelsBaseDir.appendingPathComponent(Repo.parakeetUnified.folderName)
        func existing(_ name: String) throws -> URL {
            let url = cacheDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FastRnntError.modelNotFound(url)
            }
            return url
        }

        let encConfig = MLModelConfiguration()
        encConfig.computeUnits = .cpuAndNeuralEngine
        let cpuConfig = MLModelConfiguration()
        cpuConfig.computeUnits = .cpuOnly
        let jointConfig = MLModelConfiguration()
        jointConfig.computeUnits = jointComputeUnits

        encoder = try await MLModel.load(
            contentsOf: existing(ModelNames.ParakeetUnified.offlineEncoderFile(precision: .int8)),
            configuration: encConfig)
        decoderModel = try await MLModel.load(
            contentsOf: existing(ModelNames.ParakeetUnified.decoderFile),
            configuration: cpuConfig)
        jointModel = try await MLModel.load(
            contentsOf: existing(Self.wideJointFile),
            configuration: jointConfig)
        tokenizer = try Tokenizer(vocabPath: existing(ModelNames.ParakeetUnified.vocab))
        rnnt = try FastRnntDecoder(decoderModel: decoderModel!, jointModel: jointModel!, config: config)
        mel = FastMel(windowSamples: Self.windowSamples, nMels: config.melFeatures)

        try await warmUp()
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        lastJointCalls = 0
        lastDecoderCalls = 0
        usedFallback = false
        lastRun = ContinuousClock.now

        var gated = samples
        if SpeechSegmenter.isNearSilent(gated) { return "" }
        let trimmed = SpeechSegmenter.trimSpeech(gated)
        if !trimmed.isEmpty { gated = trimmed }
        if gated.count < 4_800 {
            gated.append(contentsOf: [Float](repeating: 0, count: 4_800 - gated.count))
        }
        guard gated.count <= Self.windowSamples else {
            usedFallback = true
            if fallback == nil {
                fallback = UnifiedAsrManager()
                try await fallback!.loadModels()
            }
            return try await fallback!.transcribe(gated)
        }

        guard let mel, let encoder, let rnnt, let tokenizer else { throw FastRnntError.notPrepared }

        var buffer = [Float](repeating: 0, count: Self.windowSamples)
        gated.withUnsafeBufferPointer { src in
            buffer.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: src.baseAddress!, count: gated.count)
            }
        }
        let (melArray, melLength) = try mel.features(window: buffer, validCount: gated.count)

        let encoderOutput = try await encoder.prediction(
            from: FastEncoderProvider(mel: melArray, melLength: melLength))
        guard let encoded = encoderOutput.featureValue(for: "encoder")?.multiArrayValue,
            let encodedLength = encoderOutput.featureValue(for: "encoder_length")?.multiArrayValue
        else { throw FastRnntError.encoderOutputMissing }

        let encoderLength = min(encodedLength[0].intValue, encoded.shape[2].intValue)
        var jointCalls = 0
        var decoderCalls = 0
        let emissions = try rnnt.decode(
            encoded: encoded, encoderLength: encoderLength,
            jointCalls: &jointCalls, decoderCalls: &decoderCalls)
        lastJointCalls = jointCalls
        lastDecoderCalls = decoderCalls
        if ProcessInfo.processInfo.environment["WHISP_FAST_CALLS"] != nil {
            FileHandle.standardError.write(
                "[fast] frames=\(encoderLength) tokens=\(emissions.count) jointCalls=\(jointCalls) decoderCalls=\(decoderCalls)\n"
                    .data(using: .utf8)!)
        }
        return tokenizer.decode(ids: emissions.map(\.token))
    }

    /// Same contract as `ParakeetTranscriber.Engine.rewarm`: decode 1 s of
    /// silence when the last decode was >20 s ago.
    public func rewarm() async {
        guard let lastRun else {
            try? await warmUp()
            return
        }
        guard ContinuousClock.now - lastRun > .seconds(20) else { return }
        try? await warmUp()
        self.lastRun = ContinuousClock.now
    }

    private func warmUp() async throws {
        guard rnnt != nil else { return }
        _ = try await transcribe([Float](repeating: 0, count: 16_000))
    }
}
