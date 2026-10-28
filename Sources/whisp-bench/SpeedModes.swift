import FluidAudio
import Foundation
import WhispCore

// Track A speed modes for whisp-bench: --profile, --replay, --compare.
// All timings are produced on whatever hardware runs the bench — label them
// accordingly in reports ("VM" on the virtual Mac).

struct LoadedFile {
    let name: String
    let path: String
    let samples: [Float]
    let ref: String?
}

func loadFiles(_ paths: [String]) -> [LoadedFile] {
    var out: [LoadedFile] = []
    for path in paths {
        do {
            let samples = try loadSamples16kMono(path: path)
            // WER reference: "<file>.<ext>.txt" first, then "<file>.txt" —
            // LibriSpeech refs are .flac.txt, generated dictation refs .txt.
            let refPath = path + ".txt"
            let altRefPath = URL(fileURLWithPath: path).deletingPathExtension().path + ".txt"
            let refText = (try? String(contentsOfFile: refPath, encoding: .utf8))
                ?? (try? String(contentsOfFile: altRefPath, encoding: .utf8))
            let ref = refText?.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(LoadedFile(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path, samples: samples,
                ref: ref?.isEmpty == false ? ref : nil))
        } catch {
            print("\(path): \(error.localizedDescription)")
        }
    }
    return out
}

// MARK: - --profile

/// Per-file stage breakdown through the profiled engine.
func runProfile(engineName: String, runs: Int, files: [LoadedFile], show: Bool) async throws {
    let engine = try CompareRunner.makeEngine(named: engineName)
    try await engine.prepare()

    var allProfiles: [DecodeProfile] = []
    var skipped = 0
    var werSum = 0.0
    var werN = 0
    for f in files {
        guard f.samples.count <= ProfiledUnified.windowSamples else {
            skipped += 1
            if show { print("\(f.name): skipped (>15 s — profile is single-window only)") }
            continue
        }
        var text = ""
        var profile: DecodeProfile?
        for _ in 0..<runs {
            do {
                text = try await engine.transcribe(f.samples)
            } catch {
                print("\(f.name): \(error.localizedDescription)")
                break
            }
            if let p = engine as? ProfiledTranscriber { profile = p.lastProfile }
        }
        guard let profile else { continue }
        allProfiles.append(profile)
        if let ref = f.ref {
            werSum += werPercent(ref: ref, hyp: text)
            werN += 1
        }
        if show {
            print(String(
                format: "%@: mel %5.1f | enc %5.1f | joint %5.1f (%d calls) | dec %5.1f (%d calls) | ovh %4.1f | total %5.1f | %d frames %d tok | %@",
                f.name, profile.melMs, profile.encoderMs, profile.jointMs, profile.jointCalls,
                profile.decoderMs, profile.decoderCalls, profile.decodeOverheadMs,
                profile.totalMs, profile.encoderFrames, profile.tokens, text))
        }
    }

    if !allProfiles.isEmpty {
        let m = CompareRunner.mean(allProfiles)
        print("")
        print(String(format: "Mean stage profile over %d files (%d runs each, last run kept):", allProfiles.count, runs))
        print(String(
            format: "  mel %5.1f ms | encoder %5.1f ms | joint %5.1f ms (%d calls) | decoder %5.1f ms (%d calls) | loop-overhead %4.1f ms | total %5.1f ms",
            m.melMs, m.encoderMs, m.jointMs, m.jointCalls, m.decoderMs, m.decoderCalls,
            m.decodeOverheadMs, m.totalMs))
        print(String(format: "  encoder frames %d | tokens %d | CoreML calls/decode %d",
                     m.encoderFrames, m.tokens, m.jointCalls + m.decoderCalls + 1))
        if werN > 0 { print(String(format: "  mean WER vs refs: %.2f%% (%d files)", werSum / Double(werN), werN)) }
    }
    if skipped > 0 { print("  (\(skipped) files skipped: >15 s, multi-window)") }
}

// MARK: - Load report

/// Counts which encoder window each short-engine decode actually used.
final class WindowHistogram: @unchecked Sendable {
    private let lock = NSLock()
    private var stats: [Int: (count: Int, minIn: Int, maxIn: Int)] = [:]
    private var missedMiddle = 0
    /// Set when the 10 s bundle was actually loaded. The missing-bundle warning
    /// is printed once at load; this flag keeps a second warning from firing
    /// for the same fact after the decodes.
    var middleLoaded = false

    func add(window: Int, input: Int) {
        lock.lock()
        defer { lock.unlock() }
        if var row = stats[window] {
            row.count += 1
            row.minIn = min(row.minIn, input)
            row.maxIn = max(row.maxIn, input)
            stats[window] = row
        } else {
            stats[window] = (1, input, input)
        }
        let fast = ShortWindowEngine.fastWindowSeconds * 16_000
        let middle = ShortWindowEngine.middleWindowSeconds * 16_000
        if input > fast && input <= middle && window > middle { missedMiddle += 1 }
    }

    var line: String {
        lock.lock()
        defer { lock.unlock() }
        if stats.isEmpty { return "none" }
        return stats.keys.sorted().map { key in
            let row = stats[key]!
            return String(
                format: "%.0fs×%d (input %.1f–%.1fs)",
                Double(key) / 16_000, row.count,
                Double(row.minIn) / 16_000, Double(row.maxIn) / 16_000)
        }.joined(separator: "  ")
    }

    var missedMiddleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return missedMiddle
    }
}

/// `phys_footprint` after `prepare` (not `ps` RSS), plus which short-window
/// encoders loaded. Returns a histogram filled in as decodes run.
func reportEncoderLoad(_ name: String, _ engine: Transcribing) async -> WindowHistogram? {
    var windows = ""
    var histogram: WindowHistogram?
    if let short = engine as? ShortWindowEngine {
        let loaded = await short.loadedWindowSamples()
        let labels = loaded.map { String(format: "%.0fs", Double($0) / 16_000) }
        windows = " windows " + (labels.isEmpty ? "none" : labels.joined(separator: "+"))
        let hist = WindowHistogram()
        hist.middleLoaded = loaded.contains(ShortWindowEngine.middleWindowSeconds * 16_000)
        if !hist.middleLoaded {
            let fast = ShortWindowEngine.fastWindowSeconds
            let middle = ShortWindowEngine.middleWindowSeconds
            print("  warning: \(ShortWindowEngine.middleBundle.name) is not loaded, so audio from \(fast)s to \(middle)s still uses the 15s encoder.")
            print("  build it with: tools/convert/convert-short-window.py --windows \(middle) --install")
        }
        await short.observeDecodes { hist.add(window: $0.windowSamples, input: $0.inputSamples) }
        histogram = hist
    }
    // phys_footprint, not ps RSS. RSS stayed at 72 MB with the 5 s and 15 s
    // encoders loaded and does not include those weights.
    print("\(name) loaded\(windows)  phys_footprint \(formatMB(physicalFootprint()))")
    if let tool = footprintToolPhys() {
        print("  footprint(1) \(tool)")
    }
    return histogram
}

func reportWindowUse(_ histogram: WindowHistogram?) {
    guard let histogram else { return }
    print("encoder decodes: \(histogram.line)")
    if histogram.missedMiddleCount > 0, histogram.middleLoaded {
        print("  warning: \(histogram.missedMiddleCount) decodes of 5–10s audio used a window larger than 10s. The 10s bundle was loaded and was not the one that ran.")
    }
}

// MARK: - --replay

/// Release replay over all files with aggregate output.
func runReplay(
    engineName: String, files: [LoadedFile], offsets: [Int],
    micDropMs: Double, show: Bool
) async throws {
    let engine = try CompareRunner.makeEngine(named: engineName)
    try await engine.prepare()
    let histogram = await reportEncoderLoad(engineName, engine)

    let replayer = ReleaseReplayer(
        transcriber: engine, micDropSamples: Int(micDropMs * 16))
    var aggregate = ReplayAggregate()
    for f in files {
        do {
            let report = try await replayer.replay(
                f.samples, offsets: offsets, file: f.name)
            aggregate.add(report)
            if ProcessInfo.processInfo.environment["WHISP_REPLAY_FLAGS"] == "1" {
                // Per-file outcome without transcript text.
                let flags = report.outcomes.map { "\($0.offsetMs):\($0.lastWordSurvived ? "ok" : "LOST")" }
                print(String(format: "  file %@ %5.1f s cuts %d | %@", String(f.name.prefix(8)),
                             Double(f.samples.count) / 16000, SpeechSegmenter.plan(f.samples).count,
                             flags.joined(separator: " ")))
            }
            if show {
                print(String(format: "%@ (%.2f s, last word ends %.0f ms): %@",
                             f.name, Double(f.samples.count) / 16000,
                             Double(report.lastWordEndSample) / 16, report.fullText))
                for o in report.outcomes {
                    print(String(
                        format: "  +%4d ms: wait %5.0f ms  spec %@  last-word %@  | %@",
                        o.offsetMs, o.waitMs, o.speculationHit ? "hit " : "miss",
                        o.lastWordSurvived ? "ok" : "LOST", o.text))
                }
            }
        } catch {
            print("\(f.name): replay failed: \(error.localizedDescription)")
        }
    }
    print("")
    print(String(format: "Release replay over %d files (engine %@, mic-drop %.0f ms):",
                 files.count, engineName, micDropMs))
    for line in aggregate.lines() { print(line) }
    reportWindowUse(histogram)
}

// MARK: - --compare

/// Interleaved A/B over the file set.
func runCompare(
    names: [String], runs: Int, idleSeconds: Double,
    files: [LoadedFile], show: Bool
) async throws {
    var engines: [(name: String, t: Transcribing)] = []
    var histograms: [WindowHistogram?] = []
    for name in names {
        let engine = try CompareRunner.makeEngine(named: name)
        try await engine.prepare()
        histograms.append(await reportEncoderLoad(name, engine))
        engines.append((name, engine))
    }

    let inputs = files.map { (name: $0.name, samples: $0.samples, ref: $0.ref) }
    let stats = try await CompareRunner.run(
        engines: engines, files: inputs, runs: runs, idleSeconds: idleSeconds)

    print("")
    print(String(format: "Compare (%d files, %d runs/file interleaved, idle %.0f s + rewarm):",
                 files.count, runs, idleSeconds))
    for s in stats { print(s.summaryLine) }
    for s in stats.dropFirst() where !s.disagreements.isEmpty {
        print("  disagreements vs \(stats[0].name): \(s.disagreements.joined(separator: ", "))")
    }
    for s in stats {
        guard let p = s.meanProfile else { continue }
        print(String(
            format: "  %@ stages: mel %.1f | enc %.1f | joint %.1f (%d) | dec %.1f (%d) | total %.1f",
            s.name, p.melMs, p.encoderMs, p.jointMs, p.jointCalls, p.decoderMs,
            p.decoderCalls, p.totalMs))
    }
    for (name, histogram) in zip(names, histograms) {
        guard let histogram else { continue }
        print("\(name) encoder decodes: \(histogram.line)")
        if histogram.missedMiddleCount > 0, histogram.middleLoaded {
            print("  warning: \(name) ran \(histogram.missedMiddleCount) decodes of 5–10s audio on a window larger than 10s. The 10s bundle was loaded and was not the one that ran.")
        }
    }
}
