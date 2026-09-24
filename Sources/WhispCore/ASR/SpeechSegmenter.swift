import Accelerate
import Foundation

/// Finds safe places to cut a recording while the user is still talking, so finished
/// chunks can be transcribed in the background and release-to-paste only has to decode
/// the tail. Cuts land in the middle of a pause, so no word is ever split — except the
/// forced cut after `forceChunk` of pause-free speech, which picks the quietest spot.
///
/// Input is 16 kHz mono Float32, same as `Transcribing`.
public enum SpeechSegmenter {

    /// Don't cut before this much new audio — short chunks give the model too little context.
    public static let minChunk = 6 * 16_000
    /// With no pause found, cut anyway once this much audio is pending.
    public static let forceChunk = 25 * 16_000
    /// A pause must be at least this long to cut in it.
    static let minPauseFrames = 35  // 350 ms
    static let frame = 160  // 10 ms

    /// Where to cut `samples` (audio pending since the last cut), or nil to wait for more.
    /// Always returns an index in `minChunk / 2 ..< samples.count`.
    public static func nextCut(in samples: [Float]) -> Int? {
        guard samples.count >= minChunk else { return nil }
        let energies = frameEnergies(samples)
        guard let loud = percentile(energies, 0.9), loud > 0 else { return nil }
        let threshold = max(Float(1.5e-3), loud * 0.08)
        let earliest = minChunk / 2 / frame

        // Latest pause of >= minPauseFrames that starts after `earliest`.
        var best: Int?
        var runEnd = energies.count
        var f = energies.count - 1
        while f >= earliest {
            if energies[f] < threshold {
                if f == earliest || energies[f - 1] >= threshold {
                    if runEnd - f >= minPauseFrames {
                        best = (f + runEnd) / 2
                        break
                    }
                }
            } else {
                runEnd = f
            }
            f -= 1
        }
        // A chunk the transcriber would drop as silence may still hold quiet speech;
        // keep it attached to what follows, as whole-clip decoding would.
        if let best, !isNearSilent(Array(samples[..<(best * frame)])) { return best * frame }

        guard samples.count >= forceChunk else { return nil }
        // Quietest 100 ms window in the last 5 s.
        let window = 10
        let searchStart = max(earliest, energies.count - 500)
        var quietest = searchStart
        var quietestSum = Float.greatestFiniteMagnitude
        var i = searchStart
        while i + window <= energies.count {
            let sum = energies[i..<(i + window)].reduce(0, +)
            if sum < quietestSum { quietestSum = sum; quietest = i }
            i += 1
        }
        let cut = (quietest + window / 2) * frame
        return isNearSilent(Array(samples[..<cut])) ? nil : cut
    }

    /// The transcriber's silence gate: whole-buffer RMS and peak both low.
    public static func isNearSilent(_ samples: [Float], rmsThreshold: Float = 0.004) -> Bool {
        guard !samples.isEmpty else { return true }
        var rms: Float = 0
        var peak: Float = 0
        samples.withUnsafeBufferPointer { buf in
            vDSP_rmsqv(buf.baseAddress!, 1, &rms, vDSP_Length(buf.count))
            vDSP_maxmgv(buf.baseAddress!, 1, &peak, vDSP_Length(buf.count))
        }
        return rms < rmsThreshold && peak < 0.05
    }

    /// Replays the live loop offline (bench/tests): every `tick` samples, look for a cut
    /// in the audio pending since the previous one. Returns absolute cut indices.
    public static func plan(_ samples: [Float], tick: Int = 16_000) -> [Int] {
        var cuts: [Int] = []
        var committed = 0
        var available = tick
        while available <= samples.count {
            if let cut = nextCut(in: Array(samples[committed..<available])) {
                committed += cut
                cuts.append(committed)
            }
            available += tick
        }
        return cuts
    }

    /// Release step: transcribe the tail and join it to the chunk transcripts.
    /// `chunkStarts[i]` is where the audio behind `texts[i]` began; the tail starts at
    /// `committed`. A near-silent tail may still hold quiet trailing words the silence
    /// gate would drop, so the last chunk is then re-decoded together with it — unless
    /// no tail frame reaches the level `trimSilence` would keep as speech next to that
    /// chunk, in which case the re-decode would see the same audio and is skipped.
    public static func finish(
        _ samples: [Float], chunkStarts: [Int], texts: [String], committed: Int,
        transcriber: Transcribing
    ) async throws -> String {
        var texts = texts
        var tailStart = committed
        if tailStart < samples.count, isNearSilent(Array(samples[tailStart...])),
           let last = chunkStarts.last, !texts.isEmpty, last < committed {
            let chunkPeak = frameEnergies(Array(samples[last..<committed])).max() ?? 0
            let tailPeak = frameEnergies(Array(samples[tailStart...])).max() ?? 0
            if tailPeak < speechThreshold(peak: chunkPeak) {
                return join(texts)
            }
            texts.removeLast()
            tailStart = last
        }
        let tail = Array(samples[tailStart...])
        texts.append(tail.isEmpty ? "" : try await transcriber.transcribe(tail))
        return join(texts)
    }

    /// Joins chunk transcripts. A chunk boundary sits in a pause, which the model often
    /// reads as a sentence start; when the previous chunk didn't end a sentence and the
    /// next starts with a capitalized common word ("And", "The"), lowercase it back.
    public static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            var text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !result.isEmpty {
                let endsSentence = result.last.map { ".?!".contains($0) } ?? true
                let firstWord = text.prefix { $0.isLetter }
                if !endsSentence, lowercaseable.contains(firstWord.lowercased()) {
                    text = firstWord.lowercased() + text.dropFirst(firstWord.count)
                }
                result += " "
            }
            result += text
        }
        return result
    }

    private static let lowercaseable: Set<String> = [
        "and", "but", "or", "so", "because", "then", "the", "a", "an", "to", "of", "in", "on",
        "at", "for", "with", "that", "this", "it", "is", "was", "if", "like", "just", "we",
        "you", "they", "he", "she", "my", "your", "our", "their", "what", "which", "when",
    ]

    // MARK: - Helpers

    /// A 10 ms frame counts as speech when its RMS exceeds this, given the loudest frame
    /// in the clip. Deliberately low so quiet consonants are never clipped.
    static func speechThreshold(peak: Float) -> Float {
        max(1.5e-3, peak * 0.06)
    }

    static func frameEnergies(_ samples: [Float]) -> [Float] {
        let count = samples.count / frame
        var energies = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { buf in
            for f in 0..<count {
                vDSP_rmsqv(buf.baseAddress! + f * frame, 1, &energies[f], vDSP_Length(frame))
            }
        }
        return energies
    }

    private static func percentile(_ values: [Float], _ p: Double) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }
}
