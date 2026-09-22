import Accelerate
import FluidAudio
import Foundation

/// Errors thrown by `ParakeetTranscriber`.
public enum TranscriberError: Error, LocalizedError {
    case notPrepared
    case audioTooShort

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "Transcriber is not prepared. Call prepare() first."
        case .audioTooShort:
            return "Audio buffer is empty."
        }
    }
}

/// Batch speech-to-text engine backed by FluidAudio Parakeet CoreML models.
///
/// Input contract (`Transcribing`): 16 kHz mono Float32 PCM in [-1, 1].
/// Output is the raw model transcript — punctuation and capitalization as the
/// model emits them — optionally passed through NeMo inverse text
/// normalization ("twenty five dollars" -> "$25") and custom-vocabulary
/// rescoring.
public final class ParakeetTranscriber: Transcribing {

    /// ASR model backend.
    public enum Model: String, Sendable, CaseIterable {
        /// Parakeet TDT 0.6B v2 — English-only, punctuation + capitalization.
        case tdtV2 = "parakeet-tdt-0.6b-v2"
        /// Parakeet TDT 0.6B v3 — 25-language multilingual.
        case tdtV3 = "parakeet-tdt-0.6b-v3"
        /// Parakeet TDT-CTC 110M — smallest/fastest English model.
        case tdtCtc110m = "parakeet-tdt-ctc-110m"
        /// Parakeet Unified 0.6B — English, best WER, native written-form
        /// output (digits/currency) with punctuation + capitalization.
        case unified = "parakeet-unified-en-0.6b"
    }

    /// Human-readable status updates ("Downloading model…", "Ready", …).
    /// Always invoked on the main thread.
    public var onStatus: ((String) -> Void)?

    /// Apply NeMo inverse text normalization to the transcript
    /// ("twenty five dollars" -> "$25"). Off by default: Parakeet v2 already
    /// emits written-form numbers, and the extra pass garbles some amounts
    /// ("4.2 million dollars" -> "$4.2 1000000").
    public var inverseTextNormalization = false

    /// Custom vocabulary terms (proper nouns, product names). When non-empty,
    /// a CTC keyword-spotting model (~110M) is loaded and the transcript is
    /// rescored against acoustic evidence — misheard terms are replaced only when
    /// the audio supports it. Costs ~2-3x latency on M1, so the app leaves it off.
    public var vocabulary: [String] = []

    /// Frames whose RMS is below this level are treated as silence.
    /// Whole-clip RMS below `silenceThreshold` short-circuits to "" so the
    /// model never hallucinates on quiet noise.
    public var silenceThreshold: Float = 0.004

    /// The model backend in use.
    public let model: Model

    private let engine: Engine
    private let normalizer = TextNormalizer()

    /// Create a transcriber with the default model (`Model.unified`). On the
    /// owner's real dictations it was clearly more accurate than `tdtV2`
    /// ("with the ChatGPT thing" vs "with the chatty bitty thing") and faster
    /// for clips under ~15 s (80-160 ms vs 100-190 ms on M1); it is slower
    /// only on long clips (~570 ms vs ~330 ms at 38 s).
    public convenience init() {
        self.init(model: .unified)
    }

    /// Create a transcriber with a specific model backend.
    public init(model: Model) {
        self.model = model
        self.engine = Engine(model: model)
    }

    /// Download (first run), load and warm up the model.
    /// Idempotent and safe to call concurrently — calls are serialized.
    public func prepare() async throws {
        try await engine.prepare(status: { [weak self] message in
            await self?.emitStatus(message)
        })
        await engine.prepareVocabulary(vocabulary)
    }

    /// Transcribe 16 kHz mono Float32 samples. Serialized internally.
    /// Returns "" for silent/near-silent audio.
    public func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { throw TranscriberError.audioTooShort }

        // Cheap RMS gate — never run the model on silence.
        var rms: Float = 0
        var peak: Float = 0
        samples.withUnsafeBufferPointer { buf in
            vDSP_rmsqv(buf.baseAddress!, 1, &rms, vDSP_Length(buf.count))
            vDSP_maxmgv(buf.baseAddress!, 1, &peak, vDSP_Length(buf.count))
        }
        guard rms >= silenceThreshold || peak >= 0.05 else { return "" }

        // Trim leading/trailing silence, keeping a 150 ms margin so no
        // speech onset/offset is ever cut.
        let trimmed = Self.trimSilence(samples)
        let speech = trimmed.isEmpty ? samples : trimmed

        // Pad to the model's minimum (300 ms).
        let minSamples = Int(0.3 * 16_000)
        var input = speech
        if input.count < minSamples {
            input.append(contentsOf: [Float](repeating: 0, count: minSamples - input.count))
        }

        var text = try await engine.transcribe(input, vocabulary: vocabulary)
        if text.contains("<unk>") {
            text = text.replacingOccurrences(of: "<unk>", with: "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        if inverseTextNormalization, !text.isEmpty {
            text = normalizer.normalizeSentence(text)
        }
        return text
    }

    @MainActor
    private func emitStatus(_ message: String) {
        onStatus?(message)
    }

    // MARK: - Silence trimming

    /// Trim leading/trailing near-silence with a 150 ms safety margin.
    /// Uses 10 ms frame energies; a frame counts as speech when its RMS
    /// exceeds max(1.5e-3, 6% of the loudest frame) — deliberately low so
    /// quiet consonants are never clipped.
    private static func trimSilence(_ samples: [Float]) -> [Float] {
        let frameSize = 160  // 10 ms @ 16 kHz
        let margin = 2400  // 150 ms
        let frameCount = samples.count / frameSize
        guard frameCount > 2 else { return samples }

        var energies = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buf in
            for f in 0..<frameCount {
                var rms: Float = 0
                vDSP_rmsqv(buf.baseAddress! + f * frameSize, 1, &rms, vDSP_Length(frameSize))
                energies[f] = rms
            }
        }
        guard let peak = energies.max(), peak > 0 else { return [] }
        let threshold = max(Float(1.5e-3), peak * 0.06)

        var first = 0
        while first < frameCount, energies[first] < threshold { first += 1 }
        var last = frameCount - 1
        while last > first, energies[last] < threshold { last -= 1 }
        guard first <= last else { return [] }

        let start = max(0, first * frameSize - margin)
        let end = min(samples.count, (last + 1) * frameSize + margin)
        guard end > start else { return [] }
        return Array(samples[start..<end])
    }
}

// MARK: - Engine actor

extension ParakeetTranscriber {

    /// Owns the loaded model and serializes prepare()/transcribe().
    fileprivate actor Engine {
        private let model: ParakeetTranscriber.Model
        private var prepared = false

        // TDT backend
        private var asrManager: AsrManager?
        private var decoderLayers = 2

        // Unified backend
        private var unifiedManager: UnifiedAsrManager?

        // Vocabulary boosting (lazily downloaded CTC spotter + rescorer)
        private var ctcModels: CtcModels?
        private var boostSession: VocabularyBoostingSession?
        private var boostTerms: [String] = []

        init(model: ParakeetTranscriber.Model) {
            self.model = model
        }

        func prepare(status: @Sendable @escaping (String) async -> Void) async throws {
            guard !prepared else { return }
            switch model {
            case .tdtV2, .tdtV3, .tdtCtc110m:
                try await prepareTDT(status: status)
            case .unified:
                try await prepareUnified(status: status)
            }
            await status("Warming up…")
            try await warmUp()
            prepared = true
            await status("Ready")
        }

        private func prepareTDT(status: @Sendable @escaping (String) async -> Void) async throws {
            let version: AsrModelVersion =
                switch model {
                case .tdtV2: .v2
                case .tdtV3: .v3
                case .tdtCtc110m: .tdtCtc110m
                case .unified: fatalError("unreachable")
                }

            let progress = Self.makeProgressHandler(status: status)
            await status("Downloading model…")
            let models = try await AsrModels.downloadAndLoad(
                version: version, progressHandler: progress)
            await status("Loading model…")
            let config = ASRConfig(
                tdtConfig: TdtConfig(blankId: version.blankId),
                encoderHiddenSize: version.encoderHiddenSize)
            let manager = AsrManager(config: config)
            try await manager.loadModels(models)
            self.asrManager = manager
            self.decoderLayers = models.version.decoderLayers
        }

        private func prepareUnified(status: @Sendable @escaping (String) async -> Void) async throws {
            let progress = Self.makeProgressHandler(status: status)
            await status("Downloading model…")
            let manager = UnifiedAsrManager()
            try await manager.loadModels(progressHandler: progress)
            self.unifiedManager = manager
        }

        /// Build a download/compile progress handler that only forwards a
        /// status line when the phase text actually changes.
        private static func makeProgressHandler(
            status: @Sendable @escaping (String) async -> Void
        ) -> ProgressHandler {
            let last = LastPhase()
            return { progress in
                let phase: String
                switch progress.phase {
                case .downloading(let done, let total):
                    phase = "Downloading model… \(done)/\(total) files (\(Int(progress.fractionCompleted * 100))%)"
                case .compiling(let name):
                    phase = "Compiling \(name)…"
                default:
                    phase = "Preparing model…"
                }
                if last.updateIfChanged(phase) {
                    Task { await status(phase) }
                }
            }
        }

        /// One full encoder pass over silent audio so the first real
        /// dictation never pays model-compile / first-dispatch cost.
        private func warmUp() async throws {
            let silence = [Float](repeating: 0, count: 16_000)  // 1 s
            switch model {
            case .unified:
                _ = try await unifiedManager?.transcribe(silence)
            default:
                if let asrManager {
                    var state = TdtDecoderState.make(decoderLayers: decoderLayers)
                    _ = try await asrManager.transcribe(silence, decoderState: &state)
                }
            }
        }

        /// Transcribe already-cleaned samples; returns post-rescored text.
        func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
            switch model {
            case .unified:
                guard let unifiedManager else { throw TranscriberError.notPrepared }
                if vocabulary.isEmpty {
                    return try await unifiedManager.transcribe(samples)
                }
                let result = try await unifiedManager.transcribeWithTimings(samples)
                return await rescoreIfNeeded(
                    text: result.text, tokenTimings: result.tokenTimings,
                    audioSamples: samples, vocabulary: vocabulary)
            default:
                guard let asrManager else { throw TranscriberError.notPrepared }
                var state = TdtDecoderState.make(decoderLayers: decoderLayers)
                let result = try await asrManager.transcribe(samples, decoderState: &state)
                return await rescoreIfNeeded(
                    text: result.text, tokenTimings: result.tokenTimings ?? [],
                    audioSamples: samples, vocabulary: vocabulary)
            }
        }

        /// Build the boosting session ahead of the first dictation.
        func prepareVocabulary(_ vocabulary: [String]) async {
            guard !vocabulary.isEmpty else { return }
            try? await ensureBoostSession(vocabulary)
        }

        /// Rescore against `vocabulary`, rebuilding the session when it
        /// changes. Failures fall back to the raw transcript — boosting must
        /// never break dictation.
        private func rescoreIfNeeded(
            text: String, tokenTimings: [TokenTiming],
            audioSamples: [Float], vocabulary: [String]
        ) async -> String {
            guard !vocabulary.isEmpty else { return text }
            do {
                try await ensureBoostSession(vocabulary)
                let output = await boostSession?.rescore(
                    text: text, tokenTimings: tokenTimings, audioSamples: audioSamples)
                return output?.text ?? text
            } catch {
                return text
            }
        }

        private func ensureBoostSession(_ vocabulary: [String]) async throws {
            guard boostSession == nil || boostTerms != vocabulary else { return }
            if ctcModels == nil {
                ctcModels = try await CtcModels.downloadAndLoad()
            }
            guard let ctcModels else { return }
            // minSimilarity 0.65 (default 0.52) — measured on
            // dictation audio, the default admitted false
            // replacements like "name" → "Kwame". 0.65 still lets
            // high-similarity fixes through ("wisp" → "Whisp").
            let context = CustomVocabularyContext(
                terms: vocabulary.map { CustomVocabularyTerm(text: $0) },
                minSimilarity: 0.65)
            // Disable the spotter-anchored acoustic rescue pass:
            // with the rescue enabled the rescorer over-fires badly
            // on dictation-style audio (FluidAudio issues #702/#724),
            // replacing ordinary words with vocabulary terms. The
            // similarity floors still gate real replacements.
            let config = VocabularyRescorer.Config(
                spotterRescueMinSimilarity: 0.30,
                spotterRescueMultiWordMinSimilarity: 0.50,
                spotterRescueEnabled: false)
            boostSession = try await VocabularyBoostingSession(
                vocabulary: context, ctcModels: ctcModels, config: config)
            boostTerms = vocabulary
        }
    }
}

/// Lock-protected dedup box for progress phase strings (progress handlers are
/// `@Sendable` and can fire on arbitrary queues at high frequency).
private final class LastPhase: @unchecked Sendable {
    private var value = ""
    private let lock = NSLock()

    /// Store `newValue`; returns true when it differed from the stored one.
    func updateIfChanged(_ newValue: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard newValue != value else { return false }
        value = newValue
        return true
    }
}
