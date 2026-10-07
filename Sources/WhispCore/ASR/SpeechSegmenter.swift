import Accelerate
import Foundation

/// Finds safe places to cut a recording while the user is still talking, so finished
/// chunks can be transcribed in the background and release-to-paste only has to decode
/// the tail. Cuts land in the middle of a pause, so no word is ever split — except the
/// forced cut after `forceChunk` of pause-free speech, which picks the quietest spot.
///
/// Input is 16 kHz mono Float32, same as `Transcribing`.
public enum SpeechSegmenter {

    /// How often the live loop looks for a cut or a pause to speculate in.
    public static let tick = 16_000 / 10  // 100 ms
    /// Don't cut before this much new audio — short chunks give the model too little context.
    public static let minChunk = 6 * 16_000
    /// With no pause found, cut anyway once this much audio is pending. Kept under the
    /// model's fixed 15 s encoder window: longer audio costs a second window, and clips
    /// just over 15 s lose punctuation and casing.
    public static let forceChunk = 14 * 16_000
    /// A pause must be at least this long to cut in it. Env-overridable for the
    /// speed grid sweep (`WHISP_MIN_PAUSE_FRAMES`); default 350 ms.
    static let minPauseFrames =
        Int(ProcessInfo.processInfo.environment["WHISP_MIN_PAUSE_FRAMES"] ?? "") ?? 35
    /// A pause this long is enough to decode ahead of release: most releases come
    /// sooner than 350 ms after the last word, and a speculation is only used when
    /// nothing audible follows it, so starting early can't change the text.
    /// Env-overridable for the speed grid sweep (`WHISP_SPEC_PAUSE_FRAMES`);
    /// default 180 ms (grid: 150 drops a quiet-variant last word on edge; 180 keeps
    /// every offset's last-word rate identical to 200 while cutting release wait).
    static let speculatePauseFrames =
        Int(ProcessInfo.processInfo.environment["WHISP_SPEC_PAUSE_FRAMES"] ?? "") ?? 18
    static let frame = 160  // 10 ms

    /// Where to cut `samples` (audio pending since the last cut), or nil to wait for more.
    /// Always returns an index in `minChunk / 2 ..< samples.count`.
    public static func nextCut(in samples: [Float]) -> Int? {
        guard samples.count >= minChunk else { return nil }
        let energies = frameEnergies(samples)
        guard let loud = percentile(energies, 0.9), loud > 0 else { return nil }
        let threshold = pauseThreshold(loud: loud)
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

    /// Whether `samples` (audio pending since the last cut) holds speech and ends in a
    /// pause: the user may be done, so its transcript is worth computing ahead of release.
    public static func endsInPause(_ samples: [Float]) -> Bool {
        guard samples.count > minPauseFrames * frame, !isNearSilent(samples) else { return false }
        let energies = frameEnergies(samples)
        guard let loud = percentile(energies, 0.9), loud > 0 else { return false }
        let threshold = pauseThreshold(loud: loud)
        return energies.suffix(speculatePauseFrames).allSatisfy { $0 < threshold }
    }

    /// Whether nothing from `end` on would be kept as speech next to `samples[start..<end]`,
    /// i.e. decoding `samples[start...]` would give the same text as `samples[start..<end]`.
    public static func quietAfter(_ samples: [Float], start: Int, end: Int) -> Bool {
        guard end < samples.count else { return true }
        let rest = Array(samples[end...])
        guard isNearSilent(rest) else { return false }
        // Same reference as trimSpeech on samples[start...], so this predicts exactly
        // what a re-decode would keep.
        let loud = percentile(frameEnergies(Array(samples[start...])), 0.9) ?? 0
        return (frameEnergies(rest).max() ?? 0) < speechThreshold(peak: loud)
    }

    /// Trim leading/trailing near-silence with a 150 ms safety margin.
    /// A frame counts as speech when its RMS exceeds `speechThreshold` of the clip's
    /// 90th-percentile frame — a percentile, not the max, so one cough or bump can't
    /// raise the bar past quiet edge words.
    public static func trimSpeech(_ samples: [Float]) -> [Float] {
        let margin = 2400  // 150 ms
        let frameCount = samples.count / frame
        guard frameCount > 2 else { return samples }

        let energies = frameEnergies(samples)
        guard let peak = energies.max(), peak > 0 else { return [] }
        let loud = percentile(energies, 0.9) ?? peak
        let threshold = speechThreshold(peak: loud)

        var first = 0
        while first < frameCount, energies[first] < threshold { first += 1 }
        var last = frameCount - 1
        while last > first, energies[last] < threshold { last -= 1 }
        guard first <= last else { return [] }

        let start = max(0, first * frame - margin)
        let end = min(samples.count, (last + 1) * frame + margin)
        guard end > start else { return [] }
        return Array(samples[start..<end])
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
    public static func plan(_ samples: [Float]) -> [Int] {
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
    /// `committed`. `speculation` is a transcript of `samples[committed..<end]` made
    /// during a pause; it is the tail's text when nothing audible came after it.
    /// A near-silent tail may still hold quiet trailing words the silence gate would
    /// drop, so the last chunk is then re-decoded together with it — unless no tail
    /// frame reaches the level `trimSpeech` would keep as speech next to that chunk,
    /// in which case the re-decode would see the same audio and is skipped.
    public static func finish(
        _ samples: [Float], chunkStarts: [Int], texts: [String], committed: Int,
        speculation: (end: Int, text: String)? = nil, transcriber: Transcribing
    ) async throws -> String {
        if let speculation, quietAfter(samples, start: committed, end: speculation.end) {
            return join(texts + [speculation.text])
        }
        var texts = texts
        var tailStart = committed
        if tailStart < samples.count, let last = chunkStarts.last, !texts.isEmpty, last < committed,
           isNearSilent(Array(samples[tailStart...])) {
            if quietAfter(samples, start: last, end: committed) {
                return join(texts)
            }
            texts.removeLast()
            tailStart = last
        }
        let tail = Array(samples[tailStart...])
        texts.append(tail.isEmpty ? "" : try await transcriber.transcribe(tail))
        return join(texts)
    }

    /// Splits `samples` into two overlapping pieces `[0, cut]` and
    /// `[cut - overlap, end]`, each at most `maxSamples`, cutting at the
    /// quietest 100 ms inside `[count - max + overlap, max]`. The overlap
    /// keeps a word spanning the cut whole in at least one piece — the second
    /// piece re-decodes it, and `joinOverlap` drops the duplicate. Expects
    /// `maxSamples < samples.count <= 2 * maxSamples - overlap`; returns
    /// `[samples]` outside that range, letting callers treat it as the contract.
    public static func splitTwo(
        _ samples: [Float], maxSamples: Int, overlap: Int
    ) -> [[Float]] {
        guard samples.count > maxSamples, samples.count <= 2 * maxSamples - overlap,
            overlap >= 0, overlap < maxSamples
        else { return [samples] }
        let window = 10  // 100 ms, same granularity as split()
        let lo = samples.count - maxSamples + overlap
        let hi = maxSamples
        // A mid-word cut needs the tail piece to reach far enough back for the
        // boundary word to decode whole (~1.2 s covers any spoken word). That
        // shortens where the tail may start, shrinking the band this works on.
        let wordOverlap = max(overlap, 19_200)
        let energies = frameEnergies(samples)
        let threshold = pauseThreshold(loud: percentile(energies, 0.9) ?? 0)
        // Prefer cuts inside a real pause: a run of >=8 below-threshold frames
        // (~80 ms) is a word gap, while dips inside a word are shorter. The
        // quietest mid-word cut is the fallback for genuinely unbroken speech.
        var runEnd = [Int](repeating: -1, count: energies.count)
        var runStart = [Int](repeating: 0, count: energies.count)
        var end = energies.count - 1
        var start = 0
        for f in 0..<energies.count {
            if energies[f] >= threshold { start = f + 1 }
            runStart[f] = start
        }
        for f in (0..<energies.count).reversed() {
            if energies[f] >= threshold { end = f - 1 }
            runEnd[f] = end
        }
        var cut = -1
        var pad = overlap
        var quietestSum = Float.greatestFiniteMagnitude
        var center = lo / frame
        while center * frame <= hi {
            let i0 = max(0, center - window / 2)
            let i1 = min(energies.count, center + window / 2)
            guard i1 > i0 else { break }
            if center < energies.count, runEnd[center] - runStart[center] + 1 >= 8 {
                let sum = energies[i0..<i1].reduce(0, +)
                if sum < quietestSum {
                    quietestSum = sum
                    cut = center * frame
                }
            }
            center += 1
        }
        if cut < 0 {
            center = max(0, (samples.count - maxSamples + wordOverlap) / frame)
            while center * frame <= hi {
                let i0 = max(0, center - window / 2)
                let i1 = min(energies.count, center + window / 2)
                guard i1 > i0 else { break }
                let sum = energies[i0..<i1].reduce(0, +)
                if sum < quietestSum {
                    quietestSum = sum
                    cut = center * frame
                }
                center += 1
            }
            pad = wordOverlap
        }
        if cut < 0 { return [samples] }  // no split fits both pieces in a window
        let tailStart = max(0, cut - pad)
        return [Array(samples[..<cut]), Array(samples[tailStart...])]
    }

    /// Joins the transcripts of `splitTwo` pieces, which share `overlap` of
    /// audio. Words inside the overlap are decoded twice — once as the head's
    /// last words and once as the tail's first — so the largest run of
    /// matching boundary words is kept once, preferring whichever side has
    /// the complete word when the cut truncated the other. Anything that
    /// doesn't match is kept: a real new word must never be dropped, so a
    /// short common word is never read as a fragment.
    public static func joinOverlap(_ head: String, _ tail: String) -> String {
        let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !t.isEmpty else { return join([h, t]) }
        var hw = h.split(separator: " ").map(String.init)
        var tw = t.split(separator: " ").map(String.init)
        let norm = { (w: String) in w.lowercased().filter(\.isLetter) }
        let fragment = { (a: String, _ b: String) in
            a.count >= 2 && a != b && (b.hasPrefix(a) || b.hasSuffix(a))
        }
        let match = { (a: String, b: String) in
            a == b || fragment(a, b) || fragment(b, a)
        }
        // Largest boundary run decoded twice (the overlap can hold several
        // words). All `k` pairs must match to count as a shared run.
        var k = 0
        let maxK = min(hw.count, tw.count, 4)
        outer: for cand in (1...maxK).reversed() {
            for j in 0..<cand {
                if !match(norm(hw[hw.count - cand + j]), norm(tw[j])) { continue outer }
            }
            k = cand
        }
        if k > 0 {
            var dropTail = Set<Int>()
            var dropHead = Set<Int>()
            for j in 0..<k {
                let a = norm(hw[hw.count - k + j]), b = norm(tw[j])
                if a == b {
                    dropTail.insert(j)
                } else if fragment(a, b) {
                    // a truncated at the cut — unless it's a real word that
                    // merely shares letters with the boundary word.
                    if !joinOverlapWholeWords.contains(a) { dropHead.insert(hw.count - k + j) }
                } else if !joinOverlapWholeWords.contains(b) {
                    dropTail.insert(j)  // b is a fragment of a's complete word
                }
            }
            hw = hw.enumerated().compactMap { dropHead.contains($0.offset) ? nil : $0.element }
            tw = tw.enumerated().compactMap { dropTail.contains($0.offset) ? nil : $0.element }
        }
        return join([hw.joined(separator: " "), tw.joined(separator: " ")])
    }

    /// Words too common to risk dropping as "fragments" — "the" must never
    /// vanish just because the previous word happened to start with it.
    private static let joinOverlapWholeWords: Set<String> = [
        "a", "i", "an", "as", "at", "am", "be", "by", "do", "go", "he", "if",
        "in", "is", "it", "me", "my", "no", "of", "on", "or", "so", "to", "up",
        "us", "we", "the", "and", "but", "for", "are", "was", "you", "all",
        "can", "had", "her", "his", "how", "its", "may", "new", "now", "old",
        "our", "out", "she", "too", "use", "way", "who", "any", "did", "get",
        "has", "him", "let", "not", "one", "put", "say", "see", "two", "own",
        "off", "top",
    ]

    /// Splits audio longer than `maxSamples` into pieces that each fit one encoder
    /// window, cutting at the quietest 100 ms of the last 5 s before each limit.
    /// Release tails can exceed the largest window (quiet speech the live loop
    /// won't cut in, or the last chunk re-decoded with a near-silent tail).
    public static func split(_ samples: [Float], maxSamples: Int) -> [[Float]] {
        var pieces: [[Float]] = []
        var start = 0
        while samples.count - start > maxSamples {
            let limit = start + maxSamples
            let searchStart = max(start + maxSamples / 2, limit - 5 * 16_000)
            let energies = frameEnergies(Array(samples[searchStart..<limit]))
            let window = 10
            var cut = limit
            var quietestSum = Float.greatestFiniteMagnitude
            var i = 0
            while i + window <= energies.count {
                let sum = energies[i..<(i + window)].reduce(0, +)
                if sum < quietestSum {
                    quietestSum = sum
                    cut = searchStart + (i + window / 2) * frame
                }
                i += 1
            }
            pieces.append(Array(samples[start..<cut]))
            start = cut
        }
        pieces.append(Array(samples[start...]))
        return pieces
    }

    /// Joins chunk transcripts. A chunk boundary sits in a pause, which the model often
    /// reads as a sentence start; when the previous chunk didn't end a sentence and the
    /// next starts with a capitalized common word ("And", "The"), lowercase it back.
    /// Likewise a chunk ending in "." followed by one starting lowercase ("so it stops."
    /// + "changing…") is one sentence, so the period goes.
    public static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            var text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if result.hasSuffix("."), text.first?.isLowercase == true,
               let lastWord = result.split(separator: " ").last, lastWord.filter({ $0 == "." }).count == 1 {
                result.removeLast()
            }
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

    /// A 10 ms frame counts as pause when its RMS is below this, given the clip's
    /// 90th-percentile frame.
    static func pauseThreshold(loud: Float) -> Float {
        max(1.5e-3, loud * 0.08)
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
