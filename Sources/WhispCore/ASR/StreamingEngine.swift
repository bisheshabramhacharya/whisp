import AVFoundation
import FluidAudio
import Foundation
import os

/// A `Transcribing` engine that decodes while audio is still being captured
/// (true streaming ASR). `DictationController` checks for this conformance at
/// each 100 ms capture tick and on release, instead of the chunk/speculate loop.
///
/// `take` is any object that identifies one capture session (the controller
/// passes its `LiveChunks`; the bench passes a fresh token per simulated
/// release). The first `feed` for a take starts a fresh stream; calls carrying
/// a stale token — a finished or cancelled take — reset and adopt it, and
/// `finish` only ever serves the current take. Dictation is serial (the app's
/// pipeline chains takes), so the token's job is making a delayed or
/// mis-ordered call fail loudly instead of mixing audio between takes.
public protocol LiveDecoding: Transcribing {
    /// Append newly captured audio for `take` and run every decode step the
    /// buffered audio allows. Runs the encode before returning so release-time
    /// debt stays bounded to one in-flight feed.
    func feed(_ samples: [Float], take: AnyObject) async throws
    /// Flush the take's held-back right context and return the final
    /// transcript. Throws `CancellationError` for a stale take.
    func finish(take: AnyObject) async throws -> String
}

/// Streaming Parakeet Unified 0.6B engine ("asrEngine streaming").
///
/// While the user holds the key, each ~100 ms mic buffer is appended to
/// `StreamingUnifiedAsrManager` and every complete encoder chunk is decoded
/// immediately (the streaming encoder re-runs a `[left | chunk | right]`
/// window whose attention mask was baked in at conversion). At key release
/// the transcript is already mostly decoded — release→text is just
/// `finish()` flushing the held-back right-context frames.
///
/// Accuracy fallback: if any feed or the final flush throws, `finish` retries
/// once as a batch decode over the take's retained audio, so a mid-stream
/// failure degrades to the offline path instead of losing the dictation.
///
/// Latency tier: `defaults write com.bishesha.whisp streamingTier <ms>` with
/// 320/640/1120/2080 (encoder context [70,2,2]/[70,7,1]/[70,7,7]/[70,13,13]).
/// `WHISP_STREAM_TIER` env var overrides for bench runs.
public final class StreamingEngine: Transcribing, StatusReporting, LiveDecoding {

    /// Streaming latency tier — the `[chunk + right]` context baked into the
    /// streaming encoder bundle.
    public enum Tier: Int, Sendable, CaseIterable {
        case t320 = 320
        case t640 = 640
        case t1120 = 1120
        case t2080 = 2080

        var config: UnifiedConfig {
            switch self {
            case .t320: return UnifiedConfig(leftFrames: 70, chunkFrames: 2, rightFrames: 2)
            case .t640: return UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 1)
            case .t1120: return UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7)
            case .t2080: return UnifiedConfig()
            }
        }
    }

    /// Default tier chosen by measurement (see docs/speed-log-c.md): 2080 ms —
    /// the model card's best-WER streaming mode [70,13,13]. Measured on the
    /// dictation set, agreement vs the offline engine climbs monotonically
    /// with right context: 0.9602 (320/640-class) → 0.9818 (1120) → 0.9891
    /// (2080), while each step's bigger window also lowers encoder busy%.
    public static let defaultTier: Tier = .t2080

    /// Human-readable status updates ("Downloading model…", "Ready", …).
    /// Always invoked on the main thread.
    public var onStatus: ((String) -> Void)?

    public let tier: Tier
    private let engine: Engine

    public convenience init() {
        self.init(tier: Self.configuredTier())
    }

    public init(tier: Tier) {
        self.tier = tier
        self.engine = Engine(tier: tier)
    }

    /// Tier from `WHISP_STREAM_TIER` (bench), then `streamingTier` in the app
    /// defaults domain, else the default. Unknown values fall back.
    private static func configuredTier() -> Tier {
        if let raw = ProcessInfo.processInfo.environment["WHISP_STREAM_TIER"],
           let ms = Int(raw), let tier = Tier(rawValue: ms) {
            return tier
        }
        let defaults = UserDefaults(suiteName: "com.bishesha.whisp") ?? .standard
        let ms = defaults.integer(forKey: "streamingTier")
        return Tier(rawValue: ms) ?? defaultTier
    }

    /// Download (first run), load and warm up the model. Idempotent.
    public func prepare() async throws {
        try await engine.prepare(status: { [weak self] message in
            await self?.emitStatus(message)
        })
    }

    /// Runs one throwaway decode so the first real take doesn't pay the
    /// compile/first-dispatch cost after idle. Skipped while a take is live —
    /// the take's own feeds keep the model warm.
    public func rewarm() async {
        await engine.rewarm()
    }

    /// Batch path: decode a finished clip (bench, fallback). Gates the input
    /// like `ParakeetTranscriber.transcribe` (silence check, trim, min pad) so
    /// compared transcripts are like-for-like. Not used on the live path —
    /// a live take goes feed→finish and is never re-decoded.
    public func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { throw TranscriberError.audioTooShort }
        guard !SpeechSegmenter.isNearSilent(samples) else { return "" }
        let trimmed = SpeechSegmenter.trimSpeech(samples)
        var input = trimmed.isEmpty ? samples : trimmed
        let minSamples = Int(0.3 * 16_000)
        if input.count < minSamples {
            input.append(contentsOf: [Float](repeating: 0, count: minSamples - input.count))
        }
        return try await engine.transcribe(input)
    }

    // MARK: - LiveDecoding

    public func feed(_ samples: [Float], take: AnyObject) async throws {
        try await engine.feed(samples, take: ObjectIdentifier(take))
    }

    public func finish(take: AnyObject) async throws -> String {
        try await engine.finish(take: ObjectIdentifier(take))
    }

    @MainActor
    private func emitStatus(_ message: String) {
        onStatus?(message)
    }

    // MARK: - Engine actor

    private actor Engine {
        private let tier: Tier
        private var manager: StreamingUnifiedAsrManager?
        private var prepared = false
        private var preparing: Task<Void, Error>?
        private var lastRun: UInt64 = 0

        /// The take currently owning the stream, nil between takes.
        private var currentTake: ObjectIdentifier?
        /// Raw take audio, retained so `finish` can fall back to a batch decode.
        private var takeAudio: [Float] = []
        /// A feed failed mid-take — `finish` then goes straight to the fallback.
        private var feedFailed = false
        /// Retained token object for warm-up decodes — must stay allocated so
        /// its ObjectIdentifier can never collide with a live take token.
        private let warmObject = NSObject()
        private var warmToken: ObjectIdentifier { ObjectIdentifier(warmObject) }

        private let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false)!

        init(tier: Tier) {
            self.tier = tier
        }

        // MARK: Lifecycle

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
            await status("Downloading model…")
            let manager = StreamingUnifiedAsrManager(config: tier.config)
            try await manager.loadModels(progressHandler: Self.makeProgressHandler(status: status))
            self.manager = manager
            await status("Warming up…")
            // One streaming decode over silence so the first real take never
            // pays model-compile / first-dispatch cost. Uses feedCore directly —
            // the feed()/finish() wrappers would deadlock re-awaiting `load`.
            let silence = [Float](repeating: 0, count: 16_000)  // 1 s
            try? await feedCore(silence, take: warmToken)
            _ = try? await finishTake(warmToken)
            lastRun = DispatchTime.now().uptimeNanoseconds
            prepared = true
            await status("Ready")
        }

        private static func makeProgressHandler(
            status: @Sendable @escaping (String) async -> Void
        ) -> ProgressHandler {
            let last = StreamPhaseDedup()
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

        /// Skipped when the model ran recently enough to still be warm, or a
        /// take is live (its feeds are the warm decodes — a warm decode here
        /// would adopt the warm token and reset the take's stream).
        func rewarm() async {
            guard prepared, currentTake == nil,
                  DispatchTime.now().uptimeNanoseconds - lastRun > 20_000_000_000 else { return }
            let silence = [Float](repeating: 0, count: 16_000)
            try? await feedCore(silence, take: warmToken)
            _ = try? await finishTake(warmToken)
            lastRun = DispatchTime.now().uptimeNanoseconds
        }

        // MARK: Live take

        /// Public feed: ensures the model is loaded, then appends + decodes.
        func feed(_ samples: [Float], take: ObjectIdentifier) async throws {
            try await prepare(status: { _ in })
            try await feedCore(samples, take: take)
        }

        /// Append take audio and run every decode the buffered audio allows.
        /// A feed naming a different take starts that take fresh — including
        /// `warmToken`, which a real take's first feed supersedes mid-warm.
        private func feedCore(_ samples: [Float], take: ObjectIdentifier) async throws {
            guard let manager else { throw TranscriberError.notPrepared }
            if take != currentTake {
                try? await manager.reset()
                takeAudio.removeAll(keepingCapacity: true)
                feedFailed = false
                currentTake = take
            }
            try await manager.appendAudio(buffer(of: samples))
            takeAudio.append(contentsOf: samples)
            do {
                try await manager.processBufferedAudio()
            } catch {
                feedFailed = true
                throw error
            }
        }

        /// Flush right-context holdback and return the take's transcript.
        func finish(take: ObjectIdentifier) async throws -> String {
            let text = try await finishTake(take)
            lastRun = DispatchTime.now().uptimeNanoseconds
            return text
        }

        /// On any stream failure, retry once as a batch decode of the retained
        /// audio — a mid-stream hiccup then costs latency, not the dictation.
        private func finishTake(_ take: ObjectIdentifier) async throws -> String {
            guard take == currentTake, let manager else { throw CancellationError() }
            let audio = takeAudio
            let failed = feedFailed
            currentTake = nil
            takeAudio = []
            feedFailed = false
            do {
                if !failed { return try await manager.finish() }
            } catch {}
            guard !audio.isEmpty else { return "" }
            try await manager.reset()
            return try await decodeAll(manager, audio)
        }

        // MARK: Batch path

        /// Decode a finished clip through the streaming pipeline (bench/fallback).
        func transcribe(_ samples: [Float]) async throws -> String {
            try await prepare(status: { _ in })
            guard let manager else { throw TranscriberError.notPrepared }
            currentTake = nil
            takeAudio = []
            feedFailed = false
            try await manager.reset()
            let text = try await decodeAll(manager, samples)
            lastRun = DispatchTime.now().uptimeNanoseconds
            return text
        }

        /// Append the whole clip and decode every window, then flush.
        private func decodeAll(_ manager: StreamingUnifiedAsrManager, _ samples: [Float]) async throws -> String {
            try await manager.appendAudio(buffer(of: samples))
            try await manager.processBufferedAudio()
            return try await manager.finish()
        }

        private func buffer(of samples: [Float]) -> AVAudioPCMBuffer {
            let buf = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer {
                buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
            }
            return buf
        }
    }
}

/// Lock-protected dedup box for progress phase strings (same role as the
/// fileprivate one in ParakeetTranscriber.swift).
private final class StreamPhaseDedup: @unchecked Sendable {
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
