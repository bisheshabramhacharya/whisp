import Foundation
import WhispCore

// --live: real-time replay through DictationController itself. Each clip is
// played as if it were the mic (audio appears in 100 ms quanta as wall time
// passes), the key is released when the clip ends, and the controller's own
// release→paste latency is read back — the number history.jsonl stores for
// real dictations. Unlike --replay, background decodes run at the moments the
// app would run them, so Neural Engine idle gaps and queueing behind an
// in-flight decode match real use.

/// Plays a recorded clip as the microphone.
final class ClipRecorder: AudioRecording {
    var onLevel: ((Float) -> Void)?
    let lostInput = false
    /// Input IO quantum of the built-in mic on the M1 (100 ms at 16 kHz).
    static let quantum = 1_600
    private let lock = NSLock()
    private var clip: [Float] = []
    private var startedNs: UInt64 = 0
    private var recording = false

    func load(_ samples: [Float]) { lock.withLock { clip = samples } }

    func start() throws {
        lock.withLock {
            startedNs = DispatchTime.now().uptimeNanoseconds
            recording = true
        }
    }

    func samples(from start: Int) -> [Float] {
        lock.withLock {
            guard recording else { return [] }
            let heard = Int((DispatchTime.now().uptimeNanoseconds - startedNs) / 62_500)
            let end = min(clip.count, heard / Self.quantum * Self.quantum)
            return start < end ? Array(clip[start..<end]) : []
        }
    }

    /// Saved WAVs hold exactly what the real `stop()` returned at release.
    func stop() -> [Float] {
        lock.withLock {
            recording = false
            return clip
        }
    }

    func cancel() { lock.withLock { recording = false } }
}

final class ReplayHotkey: HotkeyMonitoring {
    var onEvent: ((HotkeyEvent) -> Void)?
    func start() throws {}
    func stop() {}
    func reset() {}
}

@MainActor final class NullPaster: TextPasting {
    func target() -> PasteTarget { PasteTarget(pid: nil, precedingCharacter: Task { nil }) }
    func paste(_ text: String, into target: PasteTarget) async -> PasteResult { .pasted }
    func copy(_ text: String) -> PasteResult { .copiedSessionInterrupt }
}

final class SilentMuter: AudioMuting {
    func mute() {}
    func restore() {}
}

final class SilentSounds: SoundPlaying {
    func playStart() {}
    func playStop() {}
    func playCancel() {}
    func playError() {}
}

/// Records when every decode (and rewarm) ran, so a release's wait can be
/// split into "still finishing a background decode" and "final decode".
final class TimedTranscriber: Transcribing {
    struct Call {
        let start: UInt64
        let end: UInt64
        /// Input length in samples; -1 for a rewarm.
        let samples: Int
    }

    private let inner: Transcribing
    private let lock = NSLock()
    private var calls: [Call] = []

    init(_ inner: Transcribing) { self.inner = inner }

    func prepare() async throws { try await inner.prepare() }

    func rewarm() async {
        let t0 = DispatchTime.now().uptimeNanoseconds
        await inner.rewarm()
        let t1 = DispatchTime.now().uptimeNanoseconds
        if t1 - t0 > 2_000_000 { record(Call(start: t0, end: t1, samples: -1)) }
    }

    func prewarm(forSamples samples: Int) async {
        let t0 = DispatchTime.now().uptimeNanoseconds
        await inner.prewarm(forSamples: samples)
        let t1 = DispatchTime.now().uptimeNanoseconds
        // Most calls return at once (window still warm); only real wake-ups count.
        if t1 - t0 > 2_000_000 { record(Call(start: t0, end: t1, samples: -1)) }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { record(Call(start: t0, end: DispatchTime.now().uptimeNanoseconds, samples: samples.count)) }
        return try await inner.transcribe(samples)
    }

    func drain() -> [Call] {
        lock.withLock {
            defer { calls = [] }
            return calls
        }
    }

    private func record(_ call: Call) { lock.withLock { calls.append(call) } }
}

struct LiveRow {
    let seconds: Double
    let latencyMs: Int
    /// What the app measured for this recording when it was dictated.
    let realMs: Int?
    let backgroundWaitMs: Double
    let finalDecodeMs: Double
    let finalDecodes: Int
    /// How long no decode had run when the key was released.
    let idleBeforeMs: Double
    /// Stage split of the final decode(s) (short engine only).
    let melMs: Double
    let encoderMs: Double
    let rnntMs: Double
}

/// Stage timings reported by the short engine, stamped with when they ended.
final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(end: UInt64, t: ShortWindowEngine.DecodeTimings)] = []
    func add(_ t: ShortWindowEngine.DecodeTimings) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock { entries.append((now, t)) }
    }
    func drain() -> [(end: UInt64, t: ShortWindowEngine.DecodeTimings)] {
        lock.withLock {
            defer { entries = [] }
            return entries
        }
    }
}

/// id → latencyMs from the app's history. Transcripts are never read out.
func historyLatencies(_ path: String?) -> [String: Int] {
    guard let path, let data = FileManager.default.contents(atPath: path),
        let text = String(data: data, encoding: .utf8)
    else { return [:] }
    var out: [String: Int] = [:]
    for line in text.split(separator: "\n") {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let id = obj["id"] as? String, let ms = obj["latencyMs"] as? Int
        else { continue }
        out[id] = ms
    }
    return out
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

@MainActor
func runLive(engineName: String, paths: [String], gapSeconds: Double, historyPath: String?) async throws {
    let inner = ASREngine.make(named: engineName)
    let engine = TimedTranscriber(inner)
    let stages = StageLog()
    if let short = inner as? ShortWindowEngine {
        await short.observeDecodes { stages.add($0) }
    }
    let loadStart = Date()
    try await engine.prepare()
    print(String(format: "Live replay: engine %@ ready in %.1f s, %.1f s between dictations",
                 engineName, Date().timeIntervalSince(loadStart), gapSeconds))

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-live-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let suite = "whisp-bench-live-\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    settings.sounds = false
    settings.autoMute = false
    settings.keepRecordings = false
    let recorder = ClipRecorder(), hotkey = ReplayHotkey()
    let controller = DictationController(
        transcriber: engine, recorder: recorder, hotkey: hotkey, paster: NullPaster(),
        cleaner: FillerCleaner(), muter: SilentMuter(), sounds: SilentSounds(), settings: settings,
        history: HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl")),
        recordings: RecordingArchive(directory: dir.appendingPathComponent("recordings")))
    controller.startHotkey()
    let real = historyLatencies(historyPath)

    var rows: [LiveRow] = []
    for path in paths {
        guard let samples = try? loadSamples16kMono(path: path), !samples.isEmpty else {
            print("  skip \(path): unreadable")
            continue
        }
        let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        recorder.load(samples)
        _ = engine.drain()
        _ = stages.drain()
        let before = controller.lastResult?.id
        hotkey.onEvent?(.start)
        try? await Task.sleep(nanoseconds: UInt64(samples.count) * 62_500)
        let releaseNs = DispatchTime.now().uptimeNanoseconds
        hotkey.onEvent?(.stop)
        var waitedMs = 0
        while controller.lastResult?.id == before, waitedMs < 120_000 {
            try? await Task.sleep(nanoseconds: 1_000_000)
            waitedMs += 1
        }
        guard let entry = controller.lastResult, entry.id != before else {
            print("  \(id.prefix(8)): no result after 120 s")
            continue
        }
        let calls = engine.drain()
        let overlapping = calls.filter { $0.start < releaseNs && $0.end > releaseNs }
        let after = calls.filter { $0.start >= releaseNs && $0.samples >= 0 }
        let lastEnd = calls.filter { $0.end <= releaseNs }.map(\.end).max()
        let finalStages = stages.drain().filter { $0.end > releaseNs }.map(\.t)
        let row = LiveRow(
            seconds: Double(samples.count) / 16_000,
            latencyMs: entry.latencyMs,
            realMs: real[id],
            backgroundWaitMs: overlapping.map { Double($0.end - releaseNs) / 1e6 }.max() ?? 0,
            finalDecodeMs: after.map { Double($0.end - $0.start) / 1e6 }.reduce(0, +),
            finalDecodes: after.count,
            idleBeforeMs: overlapping.isEmpty ? lastEnd.map { Double(releaseNs - $0) / 1e6 } ?? -1 : 0,
            melMs: finalStages.map(\.melMs).reduce(0, +),
            encoderMs: finalStages.map(\.encoderMs).reduce(0, +),
            rnntMs: finalStages.map(\.rnntMs).reduce(0, +))
        rows.append(row)
        let window = finalStages.last.map { "\($0.windowSamples / 16_000)s" } ?? "-"
        print(String(format: "  %@ %6.1f s  release→paste %4d ms (real: %@)  bg wait %4.0f  final %4.0f ms x%d [%@ mel %3.0f enc %4.0f rnnt %4.0f]  idle before %5.0f ms",
                     String(id.prefix(8)), row.seconds, row.latencyMs,
                     row.realMs.map { "\($0) ms" } ?? "—",
                     row.backgroundWaitMs, row.finalDecodeMs, row.finalDecodes,
                     window, row.melMs, row.encoderMs, row.rnntMs, row.idleBeforeMs))
        try? await Task.sleep(nanoseconds: UInt64(gapSeconds * 1e9))
    }

    print("\nSummary (release→paste ms; 'real' = what the app measured when you dictated it)")
    let buckets: [(String, ClosedRange<Double>)] = [
        ("<=5 s", 0...5), ("5-15 s", 5.000001...15), ("15-60 s", 15.000001...60), (">60 s", 60.000001...1e9),
    ]
    for (label, range) in buckets + [("all", 0...1e9)] {
        let group = rows.filter { range.contains($0.seconds) }
        guard !group.isEmpty else { continue }
        let live = group.map { Double($0.latencyMs) }
        let realMs = group.compactMap { $0.realMs.map(Double.init) }
        let bg = group.map(\.backgroundWaitMs), fin = group.map(\.finalDecodeMs)
        print(String(format: "  %@ n=%3d  now p50 %4.0f p90 %4.0f max %5.0f | real p50 %4.0f p90 %4.0f | bg wait p50 %3.0f, final decode p50 %3.0f (enc %3.0f, rnnt %3.0f)",
                     label.padding(toLength: 8, withPad: " ", startingAt: 0), group.count,
                     percentile(live, 0.5), percentile(live, 0.9), live.max() ?? 0,
                     percentile(realMs, 0.5), percentile(realMs, 0.9),
                     percentile(bg, 0.5), percentile(fin, 0.5),
                     percentile(group.map(\.encoderMs), 0.5), percentile(group.map(\.rnntMs), 0.5)))
    }
}
