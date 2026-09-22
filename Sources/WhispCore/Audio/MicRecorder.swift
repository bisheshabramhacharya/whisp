import AVFoundation
import Accelerate
import Foundation

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
///  - `init` reserves sample-buffer capacity and calls `engine.prepare()` so hardware
///    resources are pre-allocated. `start()` only has to install a tap (if needed) and
///    spin up the engine.
///  - The engine is fully stopped on `stop()`/`cancel()`, so the orange mic indicator
///    never stays on while idle.
///  - Device changes (AirPods connect/disconnect) are handled by observing
///    `AVAudioEngineConfigurationChange`: the converter is rebuilt for the new input
///    format and, if we were recording, capture resumes transparently.
public final class MicRecorder: AudioRecording {

    public var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()

    /// What the ASR engine consumes: 16 kHz, mono, non-interleaved Float32.
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Guards `samples`, `converter`, `tapInstalled`, `recording` and `inputMaterialized`.
    /// The tap callback appends on a realtime audio thread; start/stop run on the caller's
    /// thread (normally main). Critical sections are kept tiny (no conversion under lock).
    private let lock = NSLock()
    /// Serializes engine lifecycle operations: tap install/removal, engine.start/stop,
    /// and the configuration-change rebuild. The realtime audio thread never takes it,
    /// so there is no priority-inversion risk; without it a device change racing
    /// `stop()` could leave the engine running (mic indicator on) while idle.
    /// Lock order when both are needed: `engineLock` -> `lock`, never the reverse.
    private let engineLock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var recording = false
    /// Whether `engine.inputNode` has been materialized at least once. `engine.prepare()`
    /// crashes with an NSException on an engine with zero nodes, so every prepare() must
    /// be preceded by an inputNode access.
    private var inputMaterialized = false

    /// Most recent dB-scaled input level 0...1. Written on the realtime audio thread,
    /// read on the main thread by `levelTimer`. A lone Float — no lock needed.
    private var latestLevel: Float = 0
    /// ~30 Hz level emitter on the main runloop while recording. The tap's real cadence
    /// is the device's IO quantum (100 ms / 4800 frames on this Mac — the installTap
    /// bufferSize is only a hint), so per-buffer reporting can't reach 30 Hz on all
    /// hardware; this timer replays the freshest level at a fixed rate instead.
    private var levelTimer: Timer?
    private static let levelInterval: TimeInterval = 1.0 / 30.0 // ~30 Hz

    private var configChangeObserver: NSObjectProtocol?

    public init() {
        // Pre-reserve ~2 minutes of 16 kHz audio (~7.7 MB) so the realtime thread
        // never has to grow the array mid-recording.
        samples.reserveCapacity(16_000 * 120)
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
        if inputMaterialized {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        engineLock.unlock()
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
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        recording = true
        lock.unlock()

        engineLock.lock()
        do {
            try installTapLocked()
        } catch {
            engineLock.unlock()
            lock.lock()
            recording = false
            lock.unlock()
            throw error
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            teardownLocked()
            engineLock.unlock()
            lock.lock()
            recording = false
            lock.unlock()
            throw MicRecorderError.engineStartFailed(underlying: error)
        }
        engineLock.unlock()
        latestLevel = 0
        DispatchQueue.main.async { [weak self] in self?.armLevelTimer() }
    }

    public func stop() -> [Float] {
        // engineLock stays held until `recording` is cleared: a configuration change
        // interleaving here either fully precedes us (we tear down its restart too)
        // or sees recording==false and does not restart. No mic-while-idle window.
        engineLock.lock()
        teardownLocked()
        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        recording = false
        lock.unlock()
        engineLock.unlock()
        endLevelReporting()
        return captured
    }

    public func cancel() {
        engineLock.lock()
        teardownLocked()
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        recording = false
        lock.unlock()
        engineLock.unlock()
        endLevelReporting()
    }

    // MARK: - Engine plumbing

    /// Stops the engine (mic indicator off) and drops the tap so the next start()
    /// re-reads the input format — cheap, and always correct after device changes.
    /// MUST be called with `engineLock` held.
    private func teardownLocked() {
        lock.lock()
        let touched = inputMaterialized
        lock.unlock()
        if touched {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        lock.lock()
        tapInstalled = false
        converter = nil
        lock.unlock()
        // Pre-allocate for the next start() to shave a few ms off it.
        if touched {
            engine.prepare()
        }
    }

    /// Installs the input tap and builds the sample-rate converter for the *current*
    /// input format. MUST be called with `engineLock` held; the engine may be stopped
    /// or running.
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
        guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicRecorderError.converterCreationFailed
        }
        // Publish the converter before the tap can fire so no callback is dropped.
        lock.lock()
        converter = conv
        lock.unlock()

        // ~21 ms per callback at 48 kHz — small enough for a smooth 30 Hz level meter.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        lock.lock()
        tapInstalled = true
        lock.unlock()
    }

    /// Runs on the realtime audio thread. Converts to 16 kHz mono and appends.
    private func process(buffer: AVAudioPCMBuffer) {
        lock.lock()
        let conv = converter
        lock.unlock()

        guard let conv, buffer.frameLength > 0 else { return }
        // Defensive: a device change can deliver a buffer in the old format before the
        // configuration-change handler has rebuilt the converter — drop that chunk.
        guard buffer.format.sampleRate == conv.inputFormat.sampleRate,
              buffer.format.channelCount == conv.inputFormat.channelCount else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 8
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channelData = out.floatChannelData else { return }

        let count = Int(out.frameLength)
        // Resampling can overshoot beyond [-1, 1]; the ASR contract requires that range.
        var lo: Float = -1, hi: Float = 1
        vDSP_vclip(channelData[0], 1, &lo, &hi, channelData[0], 1, vDSP_Length(count))
        lock.lock()
        if recording {
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))
        }
        lock.unlock()

        // RMS → dB → 0...1. -60 dB (silence) maps to 0, 0 dBFS maps to 1.
        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(count))
        let db = 20 * log10f(max(rms, 1e-6))
        latestLevel = min(max((db + 60) / 60, 0), 1)
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
        lock.lock()
        let wasRecording = recording
        lock.unlock()
        if wasRecording {
            do {
                try installTapLocked()
                try engine.start()
            } catch {
                // New device unusable. `recording` stays true so a later device change
                // retries, and samples captured so far are preserved for stop().
            }
        }
        engineLock.unlock()
    }
}
