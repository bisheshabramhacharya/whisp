import AVFoundation
import Accelerate
import Foundation
import os

/// Errors thrown by `MicRecorder.start()`.
public enum MicRecorderError: Error {
    /// The input node reports no usable audio format (no input device, or mic permission denied).
    case inputUnavailable
    /// A 16 kHz mono converter could not be created for the current input format.
    case converterCreationFailed
    /// The audio engine failed to start.
    case engineStartFailed(underlying: Error)
}

/// Records the default input device via AVAudioEngine and converts everything to
/// 16 kHz mono Float32 PCM, which is what the `Transcribing` engine expects.
///
/// Latency notes:
///  - Audio is read with an `AVAudioSinkNode`, which is called once per hardware IO
///    quantum (512 frames, ~10.7 ms on the built-in mic). An input tap is not used:
///    its buffer size is only a hint, and on this hardware it delivers 4800 frames
///    every 100 ms. That made the live loop see speech up to 100 ms late and left
///    up to 100 ms of audio in flight at key-up, more than the stop-time wait covers.
///  - The sink runs on the realtime IO thread, so it only copies into a ring; a
///    converter thread resamples and appends.
///  - `init` reserves sample-buffer capacity and calls `engine.prepare()` so hardware
///    resources are pre-allocated. `start()` only has to connect the sink (if needed)
///    and spin up the engine.
///  - The engine is fully stopped on `stop()`, and 0.5 s after `cancel()`, so the
///    orange mic indicator never stays on while idle.
///  - Device changes (AirPods connect/disconnect) are handled by observing
///    `AVAudioEngineConfigurationChange`: the converter is rebuilt for the new input
///    format and, if we were recording, capture resumes transparently.
public final class MicRecorder: AudioRecording {

    public var onLevel: ((Float) -> Void)?
    public private(set) var lostInput = false

    private let logger = Logger(subsystem: "com.bishesha.whisp", category: "Mic")

    private let engine = AVAudioEngine()

    /// What the ASR engine consumes: 16 kHz, mono, non-interleaved Float32.
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Guards `pipeline`, `tapInstalled`, `inputMaterialized` and the first-buffer
    /// timestamps. The converter thread appends; start/stop run on the caller's thread
    /// (normally main). Critical sections are kept tiny (no conversion under lock).
    /// Captured audio and the recording flag live in `capture`.
    private let lock = NSLock()
    /// Serializes engine lifecycle operations: tap install/removal, engine.start/stop,
    /// and the configuration-change rebuild. The realtime audio thread never takes it,
    /// so there is no priority-inversion risk; without it a device change racing
    /// `stop()` could leave the engine running (mic indicator on) while idle.
    /// Lock order when both are needed: `engineLock` -> `lock`, never the reverse.
    private let engineLock = NSLock()
    private let teardownQueue = DispatchQueue(label: "com.bishesha.whisp.mic-teardown", qos: .userInitiated)
    /// Captured audio plus the recording flag, with the bounded stop-time drain
    /// that keeps the IO buffer in flight at key-up (the end of the last word).
    private let capture = CaptureBuffer()
    /// The ring and converter for the current input format; nil while torn down.
    private var pipeline: CapturePipeline?
    /// Whether the sink is connected to the input node.
    private var tapInstalled = false
    /// What the realtime sink block can reach: the ring to fill and the semaphore
    /// that wakes the converter thread. `ring` only changes while the engine is
    /// stopped, so the IO thread never races the write.
    private final class SinkState {
        var ring: AudioRing?
        let wake = DispatchSemaphore(value: 0)
        var stopping = false
    }
    private let sinkState = SinkState()
    private let sink: AVAudioSinkNode
    private var sinkAttached = false
    /// Signalled by the converter thread each time it has emptied the ring, with
    /// the quantum count it reached, so `stop()` can wait for the one in flight.
    private let tailCond = NSCondition()
    private var convertedThrough: UInt64 = 0
    private weak var convertedPipeline: CapturePipeline?
    /// Set when a device change could not be recovered mid-recording.
    private var inputLost = false
    /// When `start()` was called, and when the first converted buffer arrived (uptime ns).
    private var startedAtNs: UInt64 = 0
    private var firstBufferAtNs: UInt64 = 0
    private var firstBufferSamples = 0
    /// Whether `engine.inputNode` has been materialized at least once. `engine.prepare()`
    /// crashes with an NSException on an engine with zero nodes, so every prepare() must
    /// be preceded by an inputNode access.
    private var inputMaterialized = false

    /// Most recent dB-scaled input level 0...1. Written on the converter thread,
    /// read on the main thread by `levelTimer`. A lone Float — no lock needed.
    private var latestLevel: Float = 0
    /// ~30 Hz level emitter on the main runloop while recording. The capture cadence
    /// depends on the device's IO quantum, so this timer replays the freshest level
    /// at a fixed rate instead of reporting per buffer.
    private var levelTimer: Timer?
    private static let levelInterval: TimeInterval = 1.0 / 30.0 // ~30 Hz

    private var configChangeObserver: NSObjectProtocol?

    /// Reserved capacity of the capture buffer — introspection for tests.
    public var reservedSampleCapacity: Int { capture.reservedCapacity }

    public init() {
        let state = sinkState
        sink = AVAudioSinkNode { _, frameCount, audioBufferList in
            state.ring?.write(audioBufferList, frames: Int(frameCount))
            state.wake.signal()
            return noErr
        }
        let pump = Thread { [weak self, state] in
            while true {
                state.wake.wait()
                if state.stopping { return }
                self?.convertPending()
            }
        }
        pump.name = "com.bishesha.whisp.mic-convert"
        pump.qualityOfService = .userInteractive
        pump.start()
        warmUpEngine()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        levelTimer?.invalidate()
        engineLock.lock()
        engine.stop()
        engineLock.unlock()
        sinkState.stopping = true
        sinkState.wake.signal()
    }

    /// Accessing `inputNode` lazily materializes it — required before `engine.prepare()`,
    /// which otherwise crashes on an engine with no nodes. Does not trigger a TCC prompt
    /// (the prompt only appears when capture actually starts), so warming up here is safe.
    /// Skipped entirely when permission is already denied.
    private func warmUpEngine() {
        guard AVAudioApplication.shared.recordPermission != .denied else { return }
        lock.lock()
        inputMaterialized = true
        lock.unlock()
        _ = engine.inputNode
        engine.prepare()
    }

    // MARK: - AudioRecording

    public func start() throws {
        guard AVAudioApplication.shared.recordPermission != .denied else {
            throw MicRecorderError.inputUnavailable
        }
        // Grows to full-take size on the caller's thread — the realtime tap
        // thread then never has to reallocate mid-recording.
        capture.begin()
        lock.lock()
        inputLost = false
        startedAtNs = DispatchTime.now().uptimeNanoseconds
        firstBufferAtNs = 0
        firstBufferSamples = 0
        lock.unlock()

        engineLock.lock()
        do {
            try installTapLocked()
        } catch {
            engineLock.unlock()
            capture.discard()
            throw error
        }
        do {
            // Still running after a tap (first half of a double-tap): keep it.
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            teardownLocked()
            engineLock.unlock()
            capture.discard()
            throw MicRecorderError.engineStartFailed(underlying: error)
        }
        engineLock.unlock()
        latestLevel = 0
        DispatchQueue.main.async { [weak self] in self?.armLevelTimer() }
    }

    public func samples(from start: Int) -> [Float] {
        capture.tail(from: start)
    }

    public func stop() -> [Float] {
        // Wait for the IO quantum in flight at release — it holds the end of
        // the last word. One quantum is ~10.7 ms, so this is ~5 ms on average;
        // CaptureBuffer.tailDrainCap (~30 ms) bounds it if the input has died.
        let stoppedAtNs = DispatchTime.now().uptimeNanoseconds
        let drained = awaitQuantumInFlight()
        let (captured, _) = capture.finish(drainCap: 0)
        lastDrainMs = Double(DispatchTime.now().uptimeNanoseconds - stoppedAtNs) / 1e6
        lock.lock()
        lostInput = inputLost
        let (started, firstBuffer, firstCount) = (startedAtNs, firstBufferAtNs, firstBufferSamples)
        lock.unlock()
        // Stopping the engine (~40 ms) happens on `teardownQueue` so
        // transcription doesn't wait for it.
        teardownWhenIdle()
        endLevelReporting()
        // Audio missing from the clip = wall time since start() minus audio captured.
        // "head" = arrival of the first buffer minus the audio it held: time after start()
        // that was never captured. A negative "missing" means the drain kept audio
        // past the release instant. "drained" = the in-flight buffer arrived in time.
        let wallMs = Double(stoppedAtNs - started) / 1e6
        let audioMs = Double(captured.count) / 16.0
        let firstBufferMs = firstBuffer > 0 ? Double(firstBuffer - started) / 1e6 : -1
        let headMs = firstBuffer > 0 ? firstBufferMs - Double(firstCount) / 16.0 : -1
        logger.notice("""
            capture: wall=\(Int(wallMs))ms audio=\(Int(audioMs))ms missing=\(Int(wallMs - audioMs))ms \
            firstBuffer=\(Int(firstBufferMs))ms head=\(Int(headMs))ms drained=\(drained) \
            drain=\(self.lastDrainMs, format: .fixed(precision: 1))ms
            """)
        return captured
    }

    /// How long the last `stop()` waited for the quantum in flight (ms).
    public private(set) var lastDrainMs: Double = 0

    /// Blocks until the converter thread has appended a quantum the hardware
    /// delivered after this call, or the cap passes. False when there is no live
    /// take, or nothing arrived in time (dead input, device change mid-stop).
    private func awaitQuantumInFlight() -> Bool {
        lock.lock()
        let current = pipeline
        lock.unlock()
        guard let current, capture.isRecording else { return false }
        let target = current.ring.quanta + 1
        let deadline = Date().addingTimeInterval(CaptureBuffer.tailDrainCap)
        tailCond.lock()
        defer { tailCond.unlock() }
        while !(convertedPipeline === current && convertedThrough >= target) {
            if !tailCond.wait(until: deadline) { return false }
        }
        return true
    }

    /// Converter thread: resample whatever the IO thread has written and append
    /// it to the take, then report how far the ring has been emptied.
    private func convertPending() {
        lock.lock()
        let current = pipeline
        lock.unlock()
        guard let current else { return }
        let through = current.drain { [self] chunk in
            // Appends only while a take is live; audio outside one is dropped.
            if capture.append(chunk) {
                lock.lock()
                if firstBufferAtNs == 0 {
                    firstBufferAtNs = DispatchTime.now().uptimeNanoseconds
                    firstBufferSamples = chunk.count
                }
                lock.unlock()
            }
            // RMS → dB → 0...1. -60 dB (silence) maps to 0, 0 dBFS maps to 1.
            var rms: Float = 0
            vDSP_rmsqv(chunk.baseAddress!, 1, &rms, vDSP_Length(chunk.count))
            let db = 20 * log10f(max(rms, 1e-6))
            latestLevel = min(max((db + 60) / 60, 0), 1)
        }
        if current.ring.droppedFrames != reportedDrops {
            reportedDrops = current.ring.droppedFrames
            logger.error("mic ring overflow: \(self.reportedDrops) frames dropped so far")
        }
        tailCond.lock()
        convertedPipeline = current
        convertedThrough = through
        tailCond.broadcast()
        tailCond.unlock()
    }

    /// Converter thread only: the ring's drop count last logged.
    private var reportedDrops = 0

    public func cancel() {
        capture.discard()
        // A tap is usually the first half of a double-tap: leave the mic running long
        // enough for the second press to record without restarting it.
        teardownWhenIdle(after: 0.5)
        endLevelReporting()
    }

    /// Grows the capture buffer to full-take size on the caller's thread —
    /// `start()` calls it before touching the engine so the realtime tap
    /// thread never reallocates mid-recording (a realloc + copy there can
    /// drop buffers).
    public func reserveTakeCapacity() {
        capture.reserveTake()
    }

    // MARK: - Engine plumbing

    /// Stops the engine in the background unless a new recording started first.
    /// Holding `engineLock` serializes it with start() and device changes, so the
    /// mic is never left running while idle.
    private func teardownWhenIdle(after delay: TimeInterval = 0) {
        teardownQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.engineLock.lock()
            let idle = !self.capture.isRecording
            if idle { self.teardownLocked() }
            self.engineLock.unlock()
        }
    }

    /// Stops the engine (mic indicator off) and disconnects the sink so the next start()
    /// re-reads the input format — cheap, and always correct after device changes.
    /// MUST be called with `engineLock` held.
    private func teardownLocked() {
        lock.lock()
        let touched = inputMaterialized
        lock.unlock()
        // Stop first: once stop() returns the IO thread no longer calls the sink,
        // so the ring can be swapped out safely.
        engine.stop()
        lock.lock()
        let connected = tapInstalled
        tapInstalled = false
        pipeline = nil
        lock.unlock()
        if connected { engine.disconnectNodeInput(sink) }
        sinkState.ring = nil
        // Pre-allocate for the next start() to shave a few ms off it.
        if touched {
            engine.prepare()
        }
    }

    /// Connects the sink to the input node and builds the ring and sample-rate
    /// converter for the *current* input format. MUST be called with `engineLock`
    /// held. When already connected (engine kept warm after a tap) it does nothing;
    /// otherwise the engine is stopped, which is what makes swapping the ring safe.
    private func installTapLocked() throws {
        lock.lock()
        let alreadyInstalled = tapInstalled
        lock.unlock()
        guard !alreadyInstalled else { return }

        lock.lock()
        inputMaterialized = true
        lock.unlock()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicRecorderError.inputUnavailable
        }
        guard let built = CapturePipeline(inputFormat: inputFormat, outputFormat: outputFormat) else {
            throw MicRecorderError.converterCreationFailed
        }
        // Publish the ring before the engine can start so no quantum is dropped.
        sinkState.ring = built.ring
        lock.lock()
        pipeline = built
        lock.unlock()

        if !sinkAttached {
            engine.attach(sink)
            sinkAttached = true
        }
        engine.connect(input, to: sink, format: inputFormat)

        lock.lock()
        tapInstalled = true
        lock.unlock()
    }

    // MARK: - Level reporting (~30 Hz on main)

    /// Main-thread only (via dispatch). Emits the freshest level at ~30 Hz;
    /// scheduled in common modes so the meter keeps moving during UI tracking.
    private func armLevelTimer() {
        guard levelTimer == nil else { return }
        let timer = Timer(timeInterval: Self.levelInterval, repeats: true) { [weak self] _ in
            guard let self, let onLevel = self.onLevel else { return }
            onLevel(self.latestLevel)
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    /// Stops the emitter and pushes one final 0 so the pill collapses. Safe to
    /// call from any thread — hops to main if needed.
    private func endLevelReporting() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.levelTimer?.invalidate()
            self.levelTimer = nil
            self.onLevel?(0)
        }
    }

    /// The system stopped our engine when the input device changed. Rebuild the
    /// converter for the new format and resume if we were mid-recording. Serialized
    /// with start()/stop() via `engineLock` so a device change can never leave the
    /// mic running after the caller already stopped.
    private func handleConfigurationChange() {
        engineLock.lock()
        teardownLocked()
        let wasRecording = capture.isRecording
        if wasRecording {
            do {
                try installTapLocked()
                try engine.start()
                lock.lock()
                inputLost = false
                lock.unlock()
            } catch {
                // New device unusable. `recording` stays true so a later device change
                // retries, and samples captured so far are preserved for stop(), which
                // reports the loss via `lostInput`.
                lock.lock()
                inputLost = true
                lock.unlock()
                logger.error("Mic restart after device change failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        engineLock.unlock()
    }
}
