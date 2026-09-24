import Foundation
import Combine
import os

// MARK: - Extra service contracts (not in Contracts.swift; concrete impls are owned by other modules)

/// Ducks/restores system audio while dictating.
public protocol AudioMuting: AnyObject {
    func mute()
    func restore()
}

/// UI feedback sounds. Implementations may keep their own `enabled` flag;
/// DictationController additionally guards every call with `AppSettings.sounds`.
public protocol SoundPlaying: AnyObject {
    func playStart()
    func playStop()
    func playCancel()
    func playError()
}

// MARK: - DictationController

/// Orchestrates one push-to-talk dictation loop:
/// hotkey event -> sounds/mute -> record -> transcribe -> clean -> paste -> history.
///
/// All public surface is on the main actor. Hotkey events arrive on the main thread.
/// Transcriptions run through a strictly serial pipeline so pastes always land in
/// recording order even if the user starts a new dictation while the previous one
/// is still being transcribed.
@MainActor
public final class DictationController: ObservableObject {

    public enum State: String, Sendable {
        case idle, recording, transcribing
    }

    // MARK: Observable state (for UI)

    /// Current UI state: idle -> recording -> transcribing -> idle.
    /// `recording` takes visual precedence over a still-draining transcription queue.
    @Published public private(set) var state: State = .idle
    /// Most recent finished entry (drives "last transcript" UI).
    @Published public private(set) var lastResult: HistoryEntry?
    /// Human-readable model status, e.g. "Downloading model…" / "Ready".
    /// Composition wires `ParakeetTranscriber.onStatus` into this.
    @Published public var modelStatus: String = "Model not started"
    /// Last surfaced error/info message, shown in the menu. Not auto-cleared.
    @Published public private(set) var statusMessage: String?
    /// Whether the global hotkey monitor is currently running.
    @Published public private(set) var isHotkeyRunning = false

    // MARK: Level passthrough for the recording pill

    /// Forwarded from `recorder.onLevel` (~30 Hz, main thread). The floating pill
    /// subscribes here so the recorder keeps a single consumer.
    public var onLevel: ((Float) -> Void)?

    // MARK: Dependencies

    private let transcriber: Transcribing
    private let recorder: AudioRecording
    private let hotkey: HotkeyMonitoring
    private let paster: TextPasting
    private let cleaner: TextCleaning
    private let muter: AudioMuting
    private let sounds: SoundPlaying
    private let settings: AppSettings
    private let history: HistoryStore
    private let recordings: RecordingArchive

    // MARK: Internals

    private let logger = Logger(subsystem: "com.bishesha.whisp", category: "Dictation")

    private var isRecording = false
    private var systemMuted = false
    private var pendingTranscriptions = 0
    private var recordingStartedAt: Date?
    private var capTask: Task<Void, Never>?
    private var muteTask: Task<Void, Never>?
    /// Every finished recording gets an increasing id; Esc after release (or quit)
    /// drops the paste of every id up to `cancelledThrough`.
    private var lastClipID = 0
    private var cancelledThrough = 0
    /// History/WAV writes happen here, in order, so they never hold up the next paste.
    private let persistQueue = DispatchQueue(label: "com.bishesha.whisp.persist", qos: .utility)
    /// Tail of the serial transcribe->clean->paste pipeline.
    private var pipelineTail: Task<Void, Never>?
    private var prepareStarted = false
    /// Chunks of the current recording already sent to the transcriber, and the loop
    /// that cuts them at pauses while the user is still talking.
    private var live: LiveChunks?
    private var chunkLoop: Task<Void, Never>?

    /// Clips shorter than this are dropped. Accidental taps (< 0.25 s holds) are already
    /// cancelled by the hotkey state machine, so this only catches an empty capture.
    public var minimumDuration: TimeInterval = 0.05
    /// Hard safety cap so a stuck key can never record forever.
    public var maximumDuration: TimeInterval = 10 * 60
    /// Assumed sample rate delivered by AudioRecording (per contract: 16 kHz mono).
    public let sampleRate = 16_000

    public init(
        transcriber: Transcribing,
        recorder: AudioRecording,
        hotkey: HotkeyMonitoring,
        paster: TextPasting,
        cleaner: TextCleaning,
        muter: AudioMuting,
        sounds: SoundPlaying,
        settings: AppSettings,
        history: HistoryStore,
        recordings: RecordingArchive
    ) {
        self.transcriber = transcriber
        self.recorder = recorder
        self.hotkey = hotkey
        self.paster = paster
        self.cleaner = cleaner
        self.muter = muter
        self.sounds = sounds
        self.settings = settings
        self.history = history
        self.recordings = recordings

        self.hotkey.onEvent = { [weak self] event in
            self?.handle(event)
        }
        self.recorder.onLevel = { [weak self] level in
            self?.onLevel?(level)
        }
    }

    // MARK: - Lifecycle

    /// Starts listening for the global hotkey. Safe to call repeatedly;
    /// failures surface via `statusMessage` instead of throwing.
    public func startHotkey() {
        guard !isHotkeyRunning else { return }
        do {
            try hotkey.start()
            isHotkeyRunning = true
            logger.info("Hotkey monitor started")
            if statusMessage?.hasPrefix("Grant Accessibility") == true {
                statusMessage = nil
            }
        } catch {
            if case HotkeyError.permissionDenied = error {
                statusMessage = "Grant Accessibility + Input Monitoring to enable the hotkey"
            } else {
                statusMessage = "Hotkey failed: \(error.localizedDescription)"
            }
            logger.error("Hotkey start failed: \(error.localizedDescription, privacy: .public)")
            if settings.sounds { sounds.playError() }
        }
    }

    public func stopHotkey() {
        guard isHotkeyRunning else { return }
        hotkey.stop()
        isHotkeyRunning = false
    }

    /// Accessibility or Input Monitoring was turned off while running: the event tap is
    /// now deaf, so drop it (a fresh one is created once the grant is back).
    public func hotkeyPermissionLost() {
        guard isHotkeyRunning else { return }
        stopHotkey()
        statusMessage = "Grant Accessibility + Input Monitoring to enable the hotkey"
    }

    /// Downloads/loads/warms the model. Safe to call more than once; after a failure
    /// the next call (or the next dictation) retries.
    public func prepareModel() {
        guard !prepareStarted else { return }
        prepareStarted = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriber.prepare()
            } catch {
                self.prepareStarted = false
                self.modelStatus = "Model failed: \(error.localizedDescription)"
                self.logger.error("Model prepare failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Clean shutdown for app termination. Queued dictations are not pasted.
    public func shutdown() {
        stopHotkey()
        cancelledThrough = lastClipID
        capTask?.cancel()
        if isRecording {
            isRecording = false
            recorder.cancel()
            restoreAudioIfNeeded()
            recomputeState()
        }
        flushPersistence()
    }

    // MARK: - Hotkey events

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .start:  startCapture()
        case .stop:   stopCapture()
        case .cancel: cancelCapture()
        }
    }

    private func startCapture() {
        guard !isRecording else { return } // already recording (e.g. double .start)

        // 1. Feedback first so the user hears the ack even if the mic fails.
        if settings.sounds { sounds.playStart() }

        // 2. Start capture.
        let micStart = DispatchTime.now()
        do {
            try recorder.start()
            logger.notice("mic started in \(Self.ms(since: micStart))ms")
        } catch {
            if settings.sounds { sounds.playError() }
            statusMessage = "Microphone failed: \(error.localizedDescription)"
            logger.error("recorder.start failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        isRecording = true
        recordingStartedAt = Date()
        recomputeState()
        startChunkLoop()

        // 3. Mute system output so the model hears the user, not the speakers —
        //    after the start sound has played, since muting the device cuts it off.
        //    Cancelled on stop, so a quick take can't mute the next one's start sound.
        if settings.autoMute {
            let delay: UInt64 = settings.sounds ? 250_000_000 : 0
            muteTask = Task { [weak self] in
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled, let self, self.isRecording, !self.systemMuted else { return }
                self.muter.mute()
                self.systemMuted = true
            }
        }

        // Safety cap: auto-stop (and transcribe) after maximumDuration.
        capTask = Task { [weak self, maximumDuration, logger] in
            try? await Task.sleep(nanoseconds: UInt64(maximumDuration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            logger.notice("Auto-stop: \(maximumDuration)s cap reached")
            self.stopCapture()
        }
    }

    private func stopCapture() {
        guard isRecording else { return }
        let releasedAt = DispatchTime.now()
        isRecording = false
        capTask?.cancel()
        capTask = nil
        muteTask?.cancel()
        muteTask = nil
        let chunks = stopChunkLoop()

        let startedAt = recordingStartedAt ?? Date()
        let target = paster.target()
        let samples = recorder.stop()
        let stopMs = Self.ms(since: releasedAt)
        if recorder.lostInput {
            statusMessage = "Microphone disconnected mid-recording — only the audio before it was used"
        }

        let duration = Double(samples.count) / Double(sampleRate)
        guard duration >= minimumDuration else {
            logger.notice("Discarded \(duration, format: .fixed(precision: 2))s clip (< \(self.minimumDuration)s)")
            finishRelease()
            recomputeState()
            return
        }

        enqueueTranscription(samples: samples, chunks: chunks, target: target, duration: duration,
                             startedAt: startedAt, releasedAt: releasedAt, stopMs: stopMs)
        // Unmute and the stop sound run after transcription has been handed off.
        DispatchQueue.main.async { [weak self] in self?.finishRelease() }
    }

    private func finishRelease() {
        restoreAudioIfNeeded()
        if settings.sounds { sounds.playStop() }
    }

    private func cancelCapture() {
        guard isRecording else {
            // Esc after release: drop every dictation still being transcribed.
            if pendingTranscriptions > 0, cancelledThrough < lastClipID {
                cancelledThrough = lastClipID
                if settings.sounds { sounds.playCancel() }
                logger.notice("Pending dictation cancelled")
            }
            return
        }
        isRecording = false
        capTask?.cancel()
        capTask = nil
        muteTask?.cancel()
        muteTask = nil
        _ = stopChunkLoop()
        recorder.cancel()
        restoreAudioIfNeeded()
        if settings.sounds { sounds.playCancel() }
        recomputeState()
        logger.debug("Recording cancelled")
    }

    private func restoreAudioIfNeeded() {
        guard systemMuted else { return }
        muter.restore()
        systemMuted = false
    }

    private func recomputeState() {
        let newState: State = isRecording ? .recording : (pendingTranscriptions > 0 ? .transcribing : .idle)
        if newState != state {
            state = newState
        }
    }

    // MARK: - Transcribe while recording

    /// Every second, cut the audio pending since the last cut at a pause and transcribe
    /// it in the background, so on release only the tail is left to decode.
    private func startChunkLoop() {
        let chunks = LiveChunks()
        live = chunks
        chunkLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.live === chunks else { return }
                self.transcribeFinishedChunk(chunks)
            }
        }
    }

    private func stopChunkLoop() -> LiveChunks? {
        chunkLoop?.cancel()
        chunkLoop = nil
        defer { live = nil }
        return live
    }

    private func transcribeFinishedChunk(_ chunks: LiveChunks) {
        guard chunks.inFlight == nil, !chunks.failed else { return }
        let pending = recorder.samples(from: chunks.committed)
        guard let cut = SpeechSegmenter.nextCut(in: pending) else { return }
        let chunk = Array(pending[..<cut])
        chunks.starts.append(chunks.committed)
        chunks.committed += cut
        chunks.inFlight = Task { [transcriber] in
            do {
                chunks.texts.append(try await transcriber.transcribe(chunk))
            } catch {
                chunks.failed = true
            }
            chunks.inFlight = nil
        }
    }

    /// Chunk transcripts first, then the tail. Falls back to the whole clip if any chunk failed.
    private func transcribe(_ samples: [Float], chunks: LiveChunks?) async throws -> String {
        guard let chunks, chunks.committed > 0 else {
            return try await transcriber.transcribe(samples)
        }
        await chunks.inFlight?.value
        if chunks.failed || chunks.committed > samples.count {
            return try await transcriber.transcribe(samples)
        }
        return try await SpeechSegmenter.finish(
            samples, chunkStarts: chunks.starts, texts: chunks.texts, committed: chunks.committed,
            transcriber: transcriber)
    }

    // MARK: - Serial transcription pipeline

    /// Starts transcribing a finished clip right away, then pastes it once every earlier
    /// clip has pasted, so pastes land in the order the recordings finished.
    private func enqueueTranscription(samples: [Float], chunks: LiveChunks?, target: PasteTarget,
                                      duration: TimeInterval, startedAt: Date,
                                      releasedAt: DispatchTime, stopMs: Int) {
        lastClipID += 1
        let id = lastClipID
        pendingTranscriptions += 1
        recomputeState()

        let transcription = Task { [weak self] () -> Result<(String, Int), Error> in
            guard let self else { return .failure(CancellationError()) }
            let start = DispatchTime.now()
            do {
                let raw = try await self.transcribe(samples, chunks: chunks)
                return .success((raw, Self.ms(since: start)))
            } catch {
                return .failure(error)
            }
        }
        let previous = pipelineTail
        pipelineTail = Task { [weak self] in
            await previous?.value
            let result = await transcription.value
            guard let self else { return }
            await self.process(id: id, result: result, samples: samples, chunks: chunks.map(\.texts.count),
                               target: target, duration: duration, startedAt: startedAt,
                               releasedAt: releasedAt, stopMs: stopMs)
            self.pendingTranscriptions -= 1
            self.recomputeState()
        }
    }

    private func process(id: Int, result: Result<(String, Int), Error>, samples: [Float], chunks: Int?,
                         target: PasteTarget, duration: TimeInterval, startedAt: Date,
                         releasedAt: DispatchTime, stopMs: Int) async {
        let transcribedAt = DispatchTime.now()
        let raw: String, transcribeMs: Int
        switch result {
        case .success(let value):
            (raw, transcribeMs) = value
        case .failure(let error):
            guard id > cancelledThrough else { return }
            logger.error("transcribe failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Transcription failed: \(error.localizedDescription)"
            if settings.sounds { sounds.playError() }
            return
        }
        guard id > cancelledThrough else {
            logger.notice("dictation \(id) cancelled before paste")
            return
        }

        let cleaned = cleaner.clean(raw)
        let cleanMs = Self.ms(since: transcribedAt)

        let pasteStart = DispatchTime.now()
        var outcome = PasteResult.pasted
        if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outcome = await paster.paste(cleaned, into: target)
        }
        let pasteMs = Self.ms(since: pasteStart)
        let latencyMs = Self.ms(since: releasedAt)
        if outcome == .copiedAppChanged {
            statusMessage = "You switched apps while transcribing — text copied, press ⌘V to paste"
            if settings.sounds { sounds.playError() }
        }

        logger.notice("""
            dictation done: audio=\(duration, format: .fixed(precision: 2))s chunks=\(chunks ?? 0) \
            stop=\(stopMs)ms transcribe=\(transcribeMs)ms clean=\(cleanMs)ms paste=\(pasteMs)ms \
            release→paste=\(latencyMs)ms
            """)

        let entry = HistoryEntry(
            id: UUID().uuidString,
            date: startedAt,
            durationSec: duration,
            raw: raw,
            cleaned: cleaned,
            latencyMs: latencyMs
        )
        lastResult = entry
        persist(entry, samples: settings.keepRecordings ? samples : nil)
    }

    /// Writes history and the WAV off the main thread, in order.
    private func persist(_ entry: HistoryEntry, samples: [Float]?) {
        let history = history, recordings = recordings, logger = logger
        persistQueue.async {
            do {
                try history.append(entry)
            } catch {
                logger.error("history append failed: \(error.localizedDescription, privacy: .public)")
            }
            guard let samples else { return }
            do {
                try recordings.save(samples: samples, id: entry.id)
            } catch {
                logger.error("recording archive failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Blocks until queued history/WAV writes are on disk (app termination, tests).
    public func flushPersistence() {
        persistQueue.sync {}
    }

    private static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}

/// Background transcripts of one recording's finished chunks. Main actor only.
@MainActor
private final class LiveChunks {
    /// Samples already handed to the transcriber.
    var committed = 0
    /// Where each chunk in `texts` began.
    var starts: [Int] = []
    var texts: [String] = []
    var inFlight: Task<Void, Never>?
    var failed = false
}
