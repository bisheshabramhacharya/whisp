@preconcurrency import CoreML
import FluidAudio
import Foundation
import WhispCore

/// WER% between a reference and hypothesis string (normalized words).
func werPercent(ref: String, hyp: String) -> Double {
    let r = normalizedWords(ref)
    let h = normalizedWords(hyp)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 100 }
    return Double(wordEditDistance(r, h)) / Double(r.count) * 100
}

// A/B(/C) compare runner: interleaved timed decodes per engine over a file
// set, warm and after-idle+rewarm, with word agreement vs the baseline engine.

/// `Transcribing` adapter for `ProfiledUnified` so profiled decodes run through
/// the same harness as app engines. Applies the same input gates as
/// `ParakeetTranscriber.transcribe` (silence check, trim-to-speech, min pad) so
/// compared times are like-for-like. Inputs > 15 s fall back to
/// `UnifiedAsrManager` (multi-window merge) and report no stage profile.
public final class ProfiledTranscriber: Transcribing {
    private let profiled = ProfiledUnified()
    private var fallback: UnifiedAsrManager?

    public private(set) var lastProfile: DecodeProfile?
    public private(set) var usedFallback = false

    public init() {}

    public func prepare() async throws {
        try await profiled.load()
        lastProfile = nil
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        lastProfile = nil
        usedFallback = false
        var gated = samples
        // Mirror ParakeetTranscriber.transcribe's gates so timings are comparable.
        if SpeechSegmenter.isNearSilent(gated) { return "" }
        let trimmed = SpeechSegmenter.trimSpeech(gated)
        if !trimmed.isEmpty { gated = trimmed }
        let minSamples = 4_800
        if gated.count < minSamples {
            gated.append(contentsOf: [Float](repeating: 0, count: minSamples - gated.count))
        }
        if gated.count <= ProfiledUnified.windowSamples {
            let out = try await profiled.transcribeWindow(gated)
            lastProfile = out.profile
            return out.text
        }
        usedFallback = true
        if fallback == nil {
            fallback = UnifiedAsrManager()
            try await fallback!.loadModels()
        }
        return try await fallback!.transcribe(gated)
    }

    public func rewarm() {}
}

/// Percentile + mean summary of one engine's runs over the file set.
public struct EngineStats: Sendable {
    public let name: String
    public let files: Int
    public let runsPerFile: Int
    /// Sorted decode times (ms) for warm runs.
    public let warm: [Double]
    /// Decode time for the first run after `idleSeconds` + `rewarm()`.
    public let idleRewarm: [Double]
    public let wer: Double
    /// Word agreement vs baseline transcripts (1.0 = identical words).
    public let agreement: Double
    /// Files where this engine's words differed from baseline's.
    public let disagreements: [String]
    /// Mean stage profile over <=15 s files (nil when the engine isn't profiled).
    public let meanProfile: DecodeProfile?

    static func pct(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    public var summaryLine: String {
        let w = warm
        let idle = idleRewarm
        return String(
            format: "  %-12s warm p50 %6.1f  p95 %6.1f | idle+rewarm p50 %6.1f  max %6.1f | WER %.2f | agree %.4f (%d files, %d runs/file)",
            (name as NSString).utf8String!,
            Self.pct(w, 0.5), Self.pct(w, 0.95),
            Self.pct(idle, 0.5), idle.max() ?? 0,
            wer, agreement, files, runsPerFile)
    }
}

public enum CompareError: Error, LocalizedError {
    case unknownEngine(String)

    public var errorDescription: String? {
        switch self {
        case .unknownEngine(let n): return "unknown bench engine '\(n)' (built-ins: parakeet, profiled; or any asrEngine name)"
        }
    }
}

/// Interleaved A/B decode runner. `make` must return a prepared engine.
public struct CompareRunner {

    /// Build an engine by name: "parakeet"/"baseline" → ParakeetTranscriber,
    /// "profiled" → ProfiledTranscriber. Track B/C engines get registered here
    /// as their branches land on speed/all.
    public static func makeEngine(named name: String) throws -> Transcribing {
        switch name {
        case "parakeet", "baseline": return ParakeetTranscriber()
        case "profiled": return ProfiledTranscriber()
        case "short": return ShortWindowEngine()
        default: throw CompareError.unknownEngine(name)
        }
    }

    /// For each engine: N interleaved runs/file (round-robin engine order per
    /// iteration keeps drift symmetric), then `idleSeconds` of sleep + rewarm()
    /// + one run/file. Returns stats per engine plus transcripts.
    public static func run(
        engines: [(name: String, t: Transcribing)],
        files: [(name: String, samples: [Float], ref: String?)],
        runs: Int,
        idleSeconds: Double
    ) async throws -> [EngineStats] {
        var times = engines.map { _ in [Double]() }
        var idleTimes = engines.map { _ in [Double]() }
        var texts = engines.map { _ in [String]() }
        var profiles = engines.map { _ in [DecodeProfile]() }

        // Warm runs, interleaved engine-per-iteration.
        for iteration in 0..<runs {
            for (e, engine) in engines.enumerated() {
                for f in files {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let text = try await engine.t.transcribe(f.samples)
                    times[e].append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                    if iteration == 0 { texts[e].append(text) }
                    if let p = engine.t as? ProfiledTranscriber, let prof = p.lastProfile {
                        profiles[e].append(prof)
                    }
                }
            }
        }

        // Idle + rewarm pass (one run per file per engine).
        if idleSeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(idleSeconds * 1e9))
            for (e, engine) in engines.enumerated() {
                await engine.t.rewarm()
                for f in files {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = try await engine.t.transcribe(f.samples)
                    idleTimes[e].append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                }
            }
        }

        // Stats vs engine 0 as baseline.
        var stats: [EngineStats] = []
        for (e, engine) in engines.enumerated() {
            var werSum = 0.0
            var werN = 0
            var agreeSum = 0.0
            var disagreements: [String] = []
            for (i, f) in files.enumerated() {
                if let ref = f.ref {
                    werSum += werPercent(ref: ref, hyp: texts[e][i])
                    werN += 1
                }
                if e > 0 {
                    let a = wordAgreement(baseline: texts[0][i], other: texts[e][i])
                    agreeSum += a
                    if a < 1.0 { disagreements.append(f.name) }
                }
            }
            let meanProfile: DecodeProfile? = profiles[e].isEmpty ? nil : mean(profiles[e])
            stats.append(EngineStats(
                name: engine.name, files: files.count, runsPerFile: runs,
                warm: times[e].sorted(), idleRewarm: idleTimes[e].sorted(),
                wer: werN > 0 ? werSum / Double(werN) : 0,
                agreement: e == 0 ? 1.0 : agreeSum / Double(max(files.count, 1)),
                disagreements: disagreements, meanProfile: meanProfile))
        }
        return stats
    }

    /// Fraction of baseline words present identically in `other` (multiset
    /// comparison on normalized words; 1.0 = same words).
    static func wordAgreement(baseline: String, other: String) -> Double {
        var counts: [String: Int] = [:]
        for w in normalizedWords(baseline) { counts[w, default: 0] += 1 }
        var matched = 0
        let total = counts.values.reduce(0, +)
        for w in normalizedWords(other) {
            if let c = counts[w], c > 0 {
                counts[w] = c - 1
                matched += 1
            }
        }
        return total == 0 ? (matched == 0 ? 1.0 : 0.0) : Double(matched) / Double(total)
    }

    static func mean(_ profiles: [DecodeProfile]) -> DecodeProfile {
        var m = DecodeProfile()
        let n = Double(profiles.count)
        for p in profiles {
            m.melMs += p.melMs; m.encoderMs += p.encoderMs; m.jointMs += p.jointMs
            m.decoderMs += p.decoderMs; m.decodeOverheadMs += p.decodeOverheadMs
            m.jointCalls += p.jointCalls; m.decoderCalls += p.decoderCalls
            m.totalMs += p.totalMs; m.tokens += p.tokens; m.encoderFrames += p.encoderFrames
        }
        m.melMs /= n; m.encoderMs /= n; m.jointMs /= n; m.decoderMs /= n
        m.decodeOverheadMs /= n; m.totalMs /= n
        m.jointCalls = Int(Double(m.jointCalls) / n); m.decoderCalls = Int(Double(m.decoderCalls) / n)
        m.tokens = Int(Double(m.tokens) / n); m.encoderFrames = Int(Double(m.encoderFrames) / n)
        return m
    }
}
