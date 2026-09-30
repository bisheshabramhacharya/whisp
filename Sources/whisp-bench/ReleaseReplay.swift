import Accelerate
import FluidAudio
import Foundation
import WhispCore

// Release replay: replays the app's real live loop (`SpeechSegmenter` cuts,
// 100 ms ticks, pause speculation, `finish()` tail decode) over a recorded
// clip, then simulates key releases at fixed offsets after the end of the last
// word. For each release it reports the release→transcript wait (tail decode +
// any in-flight background decode the app would still be waiting on) and
// whether the last word survived vs the full-clip transcript.

/// A background decode the live loop would have issued at some tick.
struct ReplayEvent {
    enum Kind { case chunk, speculation }
    /// Sample index (== simulated ms * 16) where the decode was triggered.
    var atSample: Int
    var kind: Kind
    /// [start, end) of the audio the decode covered (absolute indices).
    var start: Int
    var end: Int
    var text: String
    /// Measured wall-clock decode time.
    var decodeMs: Double
}

/// What one simulated release produced.
public struct ReleaseOutcome: Sendable {
    /// Offset after last-word end (ms).
    public let offsetMs: Int
    /// release→transcript wait in ms (tail decode + in-flight remainder).
    public let waitMs: Double
    /// The final transcript for the clipped take.
    public let text: String
    /// Whether the last word of the full-clip transcript appears at the end.
    public let lastWordSurvived: Bool
    /// True when speculation covered the tail (no decode needed at release).
    public let speculationHit: Bool
}

public struct ReplayReport: Sendable {
    public let file: String
    public let durationMs: Int
    /// Sample index of the end of the last word (energy-based).
    public let lastWordEndSample: Int
    public let fullText: String
    public let outcomes: [ReleaseOutcome]
}

public enum ReplayError: Error, LocalizedError {
    case emptyClip
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyClip: return "clip has no samples"
        case .decodeFailed(let m): return "decode failed: \(m)"
        }
    }
}

/// Replays DictationController's live loop over `samples`. All times are in
/// samples (16 kHz). Decodes really run via `transcribe` so durations are
/// measured, not modelled.
public struct ReleaseReplayer {

    /// The transcriber every decode goes through (engine under test).
    private let transcribe: (ArraySlice<Float>) async throws -> String
    /// When the engine under test decodes live (`LiveDecoding`), releases are
    /// simulated by feeding the captured audio in 100 ms slices and timing
    /// `finish()` — the chunk/speculate event pass is skipped.
    private let live: (any LiveDecoding)?
    /// Audio the app's `stop()` would drop: the in-flight IO quantum the real
    /// MicRecorder discards. Simulated releases truncate at
    /// `releaseAt - micDropSamples`.
    public var micDropSamples: Int

    public init(transcriber: Transcribing, micDropSamples: Int = 0) {
        self.transcribe = { slice in try await transcriber.transcribe(Array(slice)) }
        self.live = transcriber as? LiveDecoding
        self.micDropSamples = micDropSamples
    }

    /// Last frame (10 ms) whose energy the segmenter would count as speech, +150 ms
    /// margin — the same boundary `trimSpeech` keeps, so "last word end" is the
    /// point `SpeechSegmenter` itself would stop keeping audio.
    public static func lastWordEnd(_ samples: [Float]) -> Int {
        let trimmed = SpeechSegmenter.trimSpeech(samples)
        guard !trimmed.isEmpty else { return samples.count }
        // trimSpeech returns the kept span but not its offset; recompute the end
        // directly: last frame above the speech threshold + margin. With
        // WHISP_LAST_WORD=hum the frames are judged above 200 Hz and against the
        // background level, so clips with fan/room hum get a real last-word end
        // instead of "the clip end".
        let frame = 160  // SpeechSegmenter.frame (10 ms) — internal constant
        let humAware = ProcessInfo.processInfo.environment["WHISP_LAST_WORD"] == "hum"
        let source = humAware ? highPassed(samples) : samples
        let frameCount = samples.count / frame
        guard frameCount > 2 else { return samples.count }
        var energies = [Float](repeating: 0, count: frameCount)
        source.withUnsafeBufferPointer { buf in
            for f in 0..<frameCount {
                var rms: Float = 0
                vDSP_rmsqv(buf.baseAddress! + f * frame, 1, &rms, vDSP_Length(frame))
                energies[f] = rms
            }
        }
        guard let peak = energies.max(), peak > 0 else { return samples.count }
        let sorted = energies.sorted()
        let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        var threshold = max(1.5e-3, loud * 0.06)
        if humAware, frameCount >= 10 {
            var means: [Float] = []
            for i in 0...(frameCount - 10) { means.append(energies[i..<(i + 10)].reduce(0, +) / 10) }
            let floor = means.sorted()[means.count / 10]
            threshold = max(threshold, min(floor * 2, loud * 0.3))
        }
        var last = frameCount - 1
        while last > 0, energies[last] < threshold { last -= 1 }
        return min(samples.count, (last + 1) * frame + 2400)
    }

    /// 2nd-order Butterworth high-pass at 200 Hz: removes the hum below speech.
    private static func highPassed(_ samples: [Float]) -> [Float] {
        let k = tan(Double.pi * 200 / 16_000), q = 1 / 2.0.squareRoot()
        let norm = 1 / (1 + k / q + k * k)
        let c: [Double] = [norm, -2 * norm, norm, 2 * (k * k - 1) * norm, (1 - k / q + k * k) * norm]
        guard let setup = vDSP_biquad_CreateSetup(c, 1) else { return samples }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 4)
        var out = [Float](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                vDSP_biquad(setup, &delay, src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(samples.count))
            }
        }
        return out
    }

    /// Run the live loop over the whole clip once, collecting every decode the
    /// controller would have issued (in order, with measured durations).
    private func collectEvents(_ samples: [Float]) async -> [ReplayEvent] {
        var events: [ReplayEvent] = []
        var committed = 0
        var previousSpecEnd: Int?
        var tick = SpeechSegmenter.tick
        // Ticks that find `chunks.inFlight != nil` return immediately in the app —
        // no cut check, no speculation — so a decode that starts at tick T and runs
        // D ms masks every tick until T + D.
        var busyUntilSample = 0
        while tick <= samples.count {
            if tick <= busyUntilSample {
                tick += SpeechSegmenter.tick
                continue
            }
            let pending = samples[committed..<tick]
            if let cut = SpeechSegmenter.nextCut(in: Array(pending)) {
                // `cut` indexes the 0-based copy; `pending` is a slice based at
                // `committed` — use prefix to avoid the wrong index space.
                let slice = pending.prefix(cut)
                let t0 = DispatchTime.now().uptimeNanoseconds
                let text = (try? await transcribe(slice)) ?? ""
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                events.append(ReplayEvent(atSample: tick, kind: .chunk,
                                        start: committed, end: committed + cut,
                                        text: text, decodeMs: ms))
                busyUntilSample = tick + Int(ms * 16)
                committed += cut
                previousSpecEnd = nil
            } else if SpeechSegmenter.endsInPause(Array(pending)) {
                // Same skip as `DictationController.speculate`: don't redo an
                // unchanged span.
                if previousSpecEnd != nil, SpeechSegmenter.quietAfter(
                    Array(samples[committed..<tick]), start: 0,
                    end: (previousSpecEnd! - committed)) {
                    tick += SpeechSegmenter.tick
                    continue
                }
                let t0 = DispatchTime.now().uptimeNanoseconds
                let text = (try? await transcribe(pending)) ?? ""
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                events.append(ReplayEvent(atSample: tick, kind: .speculation,
                                        start: committed, end: tick,
                                        text: text, decodeMs: ms))
                busyUntilSample = tick + Int(ms * 16)
                previousSpecEnd = tick
            }
            tick += SpeechSegmenter.tick
        }
        return events
    }

    /// Replay one clip: full decode (reference text), the live-loop event pass,
    /// then a simulated release at every `offsets` ms after last-word end.
    public func replay(
        _ samples: [Float],
        offsets: [Int] = [0, 50, 100, 150, 200, 350, 600, 1000],
        file: String = ""
    ) async throws -> ReplayReport {
        guard !samples.isEmpty else { throw ReplayError.emptyClip }

        // Reference: whole-clip decode, untruncated.
        let fullText = try await transcribe(samples[...])
        let lastWordEnd = Self.lastWordEnd(samples)

        // LiveDecoding engine: each simulated release feeds the captured audio
        // like the mic would have, then finish() is the release wait.
        if let live {
            let outcomes = try await streamingReleases(
                live, samples: samples, lastWordEnd: lastWordEnd,
                offsets: offsets, fullText: fullText)
            return ReplayReport(
                file: file, durationMs: samples.count / 16,
                lastWordEndSample: lastWordEnd, fullText: fullText, outcomes: outcomes)
        }

        let events = await collectEvents(samples)

        var outcomes: [ReleaseOutcome] = []
        for offset in offsets {
            // A release at lastWordEnd+offset is only simulable if the capture
            // actually ran that long: beyond the clip end the user was still
            // holding, so that release scenario never occurred — skip it.
            let releaseAt = lastWordEnd + offset * 16
            guard releaseAt <= samples.count else { continue }
            let captured = max(0, releaseAt - micDropSamples)
            let clipped = samples[..<captured]
            let outcome = try await simulateRelease(
                clipped: clipped, releaseAt: releaseAt, events: events,
                offsetMs: offset, fullText: fullText)
            outcomes.append(outcome)
        }
        return ReplayReport(
            file: file, durationMs: samples.count / 16,
            lastWordEndSample: lastWordEnd, fullText: fullText, outcomes: outcomes)
    }

    /// Token identifying one simulated take for `LiveDecoding` (the app passes
    /// its `LiveChunks`); a fresh instance per release keeps takes isolated.
    private final class StreamTakeToken {}

    /// One fresh take per simulated release: feed the audio the capture would
    /// have held at `releaseAt` in 100 ms slices (decode overlaps capture, as
    /// live), then `finish()` is the wait. In-flight feed remainder is bounded
    /// to one ~100 ms feed on the real path and is not modelled here.
    private func streamingReleases(
        _ live: any LiveDecoding, samples: [Float], lastWordEnd: Int,
        offsets: [Int], fullText: String
    ) async throws -> [ReleaseOutcome] {
        var outcomes: [ReleaseOutcome] = []
        var feedMs = 0.0
        for offset in offsets {
            // Same rule as the offline path: a release beyond the clip end
            // never occurred, so it isn't simulated.
            let releaseAt = lastWordEnd + offset * 16
            guard releaseAt <= samples.count else { continue }
            let captured = max(0, releaseAt - micDropSamples)
            let take = StreamTakeToken()
            var fed = 0
            let feedTick = ProcessInfo.processInfo.environment["WHISP_FEED_TICK"].flatMap(Int.init) ?? SpeechSegmenter.tick
            while fed < captured {
                let end = min(fed + feedTick, captured)
                let tFeed = DispatchTime.now().uptimeNanoseconds
                try await live.feed(Array(samples[fed..<end]), take: take)
                feedMs += Double(DispatchTime.now().uptimeNanoseconds - tFeed) / 1e6
                fed = end
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let text = try await live.finish(take: take)
            let wait = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            outcomes.append(ReleaseOutcome(
                offsetMs: offset, waitMs: wait, text: text,
                lastWordSurvived: Self.lastWordSurvives(releaseText: text, fullText: fullText),
                speculationHit: false))
        }
        // Feed busy% = total time spent inside feed() across all simulated
        // releases vs the audio they covered — the live-path CPU tax.
        let fedAudio = Double(outcomes.count * max(0, lastWordEnd - micDropSamples)) / 16.0
        if fedAudio > 0 {
            print(String(
                format: "  [streaming] feed-busy %.0f ms over %d releases = %.1f%% of captured audio",
                feedMs, outcomes.count, 100 * feedMs / fedAudio))
        }
        return outcomes
    }

    /// One simulated release: live state at `releaseAt`, the app's `finish()`
    /// semantics on the clipped audio, wait = tail decode + in-flight remainder.
    private func simulateRelease(
        clipped: ArraySlice<Float>,
        releaseAt: Int,
        events: [ReplayEvent],
        offsetMs: Int,
        fullText: String
    ) async throws -> ReleaseOutcome {
        // Live state at release: events triggered at a tick <= releaseAt.
        let done = events.filter { $0.atSample <= releaseAt }
        var committed = 0
        var texts: [String] = []
        var starts: [Int] = []
        var speculation: (end: Int, text: String, decodeMs: Double, at: Int)?
        for e in done {
            switch e.kind {
            case .chunk:
                starts.append(e.start)
                texts.append(e.text)
                committed = e.end
                speculation = nil
            case .speculation:
                speculation = (e.end, e.text, e.decodeMs, e.atSample)
            }
        }

        // In-flight decode still running at release: the app awaits it first.
        var inFlightRemainder = 0.0
        if let last = done.last {
            let finishAtMs = Double(last.atSample) / 16.0 + last.decodeMs
            inFlightRemainder = max(0, finishAtMs - Double(releaseAt) / 16.0)
        }

        // finish() on the clipped audio.
        var speculationHit = false
        var text = ""
        var wait = inFlightRemainder
        if let spec = speculation,
            SpeechSegmenter.quietAfter(Array(clipped), start: committed, end: spec.end) {
            // Reuse pause speculation; a speculation still in flight is waited on.
            speculationHit = true
            text = SpeechSegmenter.join(texts + [spec.text])
        } else {
            // Same tail logic as SpeechSegmenter.finish (rewind to last chunk on
            // a near-silent tail), but decoding the clipped samples.
            var tailStart = committed
            var kept = texts
            if tailStart < clipped.count, let last = starts.last, !kept.isEmpty, last < committed,
                SpeechSegmenter.isNearSilent(Array(clipped[tailStart...])) {
                if SpeechSegmenter.quietAfter(Array(clipped), start: last, end: committed) {
                    text = SpeechSegmenter.join(kept)
                } else {
                    kept.removeLast()
                    tailStart = last
                }
            }
            if text.isEmpty {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let tailText = tailStart < clipped.count
                    ? try await transcribe(clipped[tailStart...]) : ""
                wait += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                kept.append(tailText)
                text = SpeechSegmenter.join(kept)
            }
        }

        return ReleaseOutcome(
            offsetMs: offsetMs, waitMs: wait, text: text,
            lastWordSurvived: Self.lastWordSurvives(releaseText: text, fullText: fullText),
            speculationHit: speculationHit)
    }

    /// The last word of the full transcript survives when it (or its prefix,
    /// for a mid-word release) still ends the release transcript.
    static func lastWordSurvives(releaseText: String, fullText: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let full = words(fullText)
        let rel = words(releaseText)
        guard let lastFull = full.last else { return rel.isEmpty }
        guard let lastRel = rel.last else { return false }
        if lastRel == lastFull { return true }
        // Release inside the word: what was said so far is a prefix of it.
        if lastFull.hasPrefix(lastRel) { return true }
        return false
    }
}

/// Aggregate over many files' reports.
public struct ReplayAggregate {
    public var perOffset: [Int: [ReleaseOutcome]] = [:]
    /// Word edits vs the whole-clip transcript, and its word count, per offset.
    public var wordDiffs: [Int: (diffs: Int, words: Int)] = [:]

    public mutating func add(_ report: ReplayReport) {
        let full = normalizedWords(report.fullText)
        for o in report.outcomes {
            perOffset[o.offsetMs, default: []].append(o)
            let d = wordEditDistance(full, normalizedWords(o.text))
            let prev = wordDiffs[o.offsetMs] ?? (0, 0)
            wordDiffs[o.offsetMs] = (prev.diffs + d, prev.words + full.count)
        }
    }

    static func pct(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    /// One table line per offset: wait p50/p95/mean, no-wait share, survival.
    public func lines() -> [String] {
        var out: [String] = []
        for offset in perOffset.keys.sorted() {
            let o = perOffset[offset]!
            let waits = o.map(\.waitMs).sorted()
            let mean = waits.reduce(0, +) / Double(max(waits.count, 1))
            let noWait = Double(o.filter { $0.waitMs < 1 }.count) / Double(o.count) * 100
            let survived = Double(o.filter(\.lastWordSurvived).count) / Double(o.count) * 100
            let spec = Double(o.filter(\.speculationHit).count) / Double(o.count) * 100
            let wd = wordDiffs[offset] ?? (0, 0)
            out.append(String(
                format: "  +%4d ms: wait p50 %5.0f  p95 %5.0f  mean %5.0f | no-wait %4.0f%% | spec-hit %4.0f%% | last-word ok %5.1f%% | words vs whole clip %d/%d differ (%d releases)",
                offset, Self.pct(waits, 0.5), Self.pct(waits, 0.95), mean, noWait, spec, survived,
                wd.diffs, wd.words, o.count))
        }
        return out
    }
}
