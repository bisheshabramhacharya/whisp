import Accelerate
import Foundation
import WhispCore

// --idle-curve: how much slower a decode gets after the engine sat idle, per
// idle length. Decodes the first file after sleeping each gap in turn.
//
// --pauses: per file, how often the live loop would find a pause to decode
// ahead in (`SpeechSegmenter.endsInPause` at each 100 ms tick), and the
// clip's noise floor vs speech level.

@MainActor
func runIdleCurve(engineName: String, file: String, rounds: Int) async throws {
    let inner = ASREngine.make(named: engineName)
    let stages = StageLog()
    if let short = inner as? ShortWindowEngine {
        await short.observeDecodes { stages.add($0) }
    }
    try await inner.prepare()
    let samples = try loadSamples16kMono(path: file)
    print(String(format: "Idle curve: engine %@, %.1f s clip, %d rounds", engineName,
                 Double(samples.count) / 16_000, rounds))
    let gapsMs = [0, 100, 250, 500, 1000, 2000, 4000, 8000]
    var totals = [Int: [Double]](), encoders = [Int: [Double]]()
    for _ in 0..<rounds {
        for gap in gapsMs.shuffled() {
            _ = try await inner.transcribe(samples)  // leaves the engine hot
            _ = stages.drain()
            try? await Task.sleep(nanoseconds: UInt64(gap) * 1_000_000)
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try await inner.transcribe(samples)
            totals[gap, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            encoders[gap, default: []].append(stages.drain().map(\.t.encoderMs).reduce(0, +))
        }
    }
    for gap in gapsMs {
        let t = (totals[gap] ?? []).sorted(), e = (encoders[gap] ?? []).sorted()
        guard !t.isEmpty else { continue }
        print(String(format: "  idle %5d ms: decode p50 %4.0f max %4.0f | encoder p50 %4.0f max %4.0f",
                     gap, t[t.count / 2], t.last!, e[e.count / 2], e.last!))
    }
}

/// --switch-test A B: does alternating between encoder windows cost extra?
/// A should fit the smallest window, B only the 15 s one.
@MainActor
func runSwitchTest(engineName: String, files: [String], rounds: Int, gapSeconds: Double) async throws {
    guard files.count >= 2 else {
        print("--switch-test needs two files: a short one and a 5-15 s one")
        return
    }
    let inner = ASREngine.make(named: engineName)
    let stages = StageLog()
    if let short = inner as? ShortWindowEngine {
        await short.observeDecodes { stages.add($0) }
    }
    try await inner.prepare()
    let a = try loadSamples16kMono(path: files[0]), b = try loadSamples16kMono(path: files[1])
    func decode(_ s: [Float]) async throws -> (window: Int, enc: Double, total: Double) {
        _ = stages.drain()
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = try await inner.transcribe(s)
        let total = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let st = stages.drain()
        return ((st.last?.t.windowSamples ?? 0) / 16_000, st.map(\.t.encoderMs).reduce(0, +), total)
    }
    var same = [Int: [Double]](), switched = [Int: [Double]]()
    var lastWindow = -1
    let pattern: [Bool] = Array(repeating: false, count: 4) + Array(repeating: true, count: 4)
        + [false, true, false, true, false, true, false, true]
    for _ in 0..<rounds {
        for useB in pattern {
            try? await Task.sleep(nanoseconds: UInt64(gapSeconds * 1e9))
            let r = try await decode(useB ? b : a)
            if lastWindow == r.window { same[r.window, default: []].append(r.enc) }
            else if lastWindow != -1 { switched[r.window, default: []].append(r.enc) }
            lastWindow = r.window
        }
    }
    func p50(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
    for w in Set(same.keys).union(switched.keys).sorted() {
        let s = same[w] ?? [], x = switched[w] ?? []
        print(String(format: "  %2d s window encoder: same as last p50 %4.0f max %4.0f (n=%d) | after a switch p50 %4.0f max %4.0f (n=%d)",
                     w, p50(s), s.max() ?? 0, s.count, p50(x), x.max() ?? 0, x.count))
    }
}

func runPauses(files: [String]) {
    let frame = 160
    print("Pause check: per file, ticks where a decode-ahead could start")
    var withAny = 0, total = 0
    for path in files {
        guard let samples = try? loadSamples16kMono(path: path), samples.count > frame * 10 else { continue }
        total += 1
        var hits = 0, ticks = 0
        var t = SpeechSegmenter.tick
        while t <= samples.count {
            ticks += 1
            if SpeechSegmenter.endsInPause(Array(samples[..<t])) { hits += 1 }
            t += SpeechSegmenter.tick
        }
        if hits > 0 { withAny += 1 }
        let n = samples.count / frame
        var energies = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { buf in
            for f in 0..<n { vDSP_rmsqv(buf.baseAddress! + f * frame, 1, &energies[f], vDSP_Length(frame)) }
        }
        let sorted = energies.sorted()
        let floor = sorted[n / 10], loud = sorted[min(n - 1, n * 9 / 10)]
        print(String(format: "  %@ %6.1f s  pause ticks %3d/%3d  noise floor %.4f  speech p90 %.4f  floor/speech %4.1f%% (pause needs < 8%%)",
                     String(URL(fileURLWithPath: path).lastPathComponent.prefix(8)),
                     Double(samples.count) / 16_000, hits, ticks, floor, loud,
                     loud > 0 ? 100 * floor / loud : 0))
    }
    print("  files with at least one decode-ahead point: \(withAny)/\(total)")
}
