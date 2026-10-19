namespace Whisp.Core.ASR;

/// <summary>
/// Finds safe places to cut a recording while the user is still talking, so finished
/// chunks can be transcribed in the background and release-to-paste only has to decode
/// the tail. Port of Sources/WhispCore/ASR/SpeechSegmenter.swift. Cuts land in the
/// middle of a pause, so no word is ever split — except the forced cut after ForceChunk
/// of pause-free speech, which picks the quietest spot.
///
/// Input is 16 kHz mono float PCM.
/// </summary>
public static class SpeechSegmenter
{
    public const int SampleRate = 16_000;
    /// How often the live loop looks for a cut or a pause to speculate in.
    public const int Tick = SampleRate / 10; // 100 ms
    /// Don't cut before this much new audio — short chunks give the model too little context.
    public const int MinChunk = 6 * SampleRate;
    /// With no pause found, cut anyway once this much audio is pending.
    public const int ForceChunk = 14 * SampleRate;
    /// A pause must be at least this long to cut in it (350 ms).
    private const int MinPauseFrames = 35;
    /// A pause this long is enough to decode ahead of release (180 ms).
    private const int SpeculatePauseFrames = 18;
    private const int Frame = 160; // 10 ms

    /// Where to cut samples (audio pending since the last cut), or null to wait for more.
    public static int? NextCut(ReadOnlySpan<float> samples)
    {
        if (samples.Length < MinChunk) return null;
        var energies = FrameEnergies(samples);
        var loud = Percentile(energies, 0.9);
        if (loud is not float l || l <= 0) return null;
        var threshold = PauseThreshold(l);
        var earliest = MinChunk / 2 / Frame;

        // Latest pause of >= MinPauseFrames that starts after `earliest`.
        int? best = null;
        var runEnd = energies.Length;
        for (var f = energies.Length - 1; f >= earliest; f--)
        {
            if (energies[f] < threshold)
            {
                if ((f == earliest || energies[f - 1] >= threshold) && runEnd - f >= MinPauseFrames)
                {
                    best = (f + runEnd) / 2;
                    break;
                }
            }
            else
            {
                runEnd = f;
            }
        }
        // A chunk the transcriber would drop as silence may still hold quiet speech;
        // keep it attached to what follows, as whole-clip decoding would.
        if (best is int b && !IsNearSilent(samples[..(b * Frame)])) return b * Frame;

        if (samples.Length < ForceChunk) return null;
        // Quietest 100 ms window in the last 5 s.
        const int window = 10;
        var searchStart = Math.Max(earliest, energies.Length - 500);
        var quietest = searchStart;
        var quietestSum = float.MaxValue;
        for (var i = searchStart; i + window <= energies.Length; i++)
        {
            var sum = 0f;
            for (var k = i; k < i + window; k++) sum += energies[k];
            if (sum < quietestSum)
            {
                quietestSum = sum;
                quietest = i;
            }
        }
        var cut = (quietest + window / 2) * Frame;
        return IsNearSilent(samples[..cut]) ? null : cut;
    }

    /// Whether samples (audio pending since the last cut) holds speech and ends in a
    /// pause: the user may be done, so its transcript is worth computing ahead of release.
    public static bool EndsInPause(ReadOnlySpan<float> samples)
    {
        if (samples.Length <= MinPauseFrames * Frame || IsNearSilent(samples)) return false;
        var energies = FrameEnergies(samples);
        var loud = Percentile(energies, 0.9);
        if (loud is not float l || l <= 0) return false;
        var threshold = PauseThreshold(l);
        for (var f = Math.Max(0, energies.Length - SpeculatePauseFrames); f < energies.Length; f++)
            if (energies[f] >= threshold) return false;
        return true;
    }

    /// Whether nothing from `end` on would be kept as speech next to samples[start..end],
    /// i.e. decoding samples[start..] would give the same text as samples[start..end].
    public static bool QuietAfter(ReadOnlySpan<float> samples, int start, int end)
    {
        if (end >= samples.Length) return true;
        var rest = samples[end..];
        if (!IsNearSilent(rest)) return false;
        var loud = Percentile(FrameEnergies(samples[start..]), 0.9) ?? 0;
        var restEnergies = FrameEnergies(rest);
        var max = restEnergies.Length == 0 ? 0 : restEnergies.Max();
        return max < SpeechThreshold(loud);
    }

    /// The transcriber's silence gate: whole-buffer RMS and peak both low.
    public static bool IsNearSilent(ReadOnlySpan<float> samples, float rmsThreshold = 0.004f)
    {
        if (samples.IsEmpty) return true;
        double sumSquares = 0;
        float peak = 0;
        foreach (var s in samples)
        {
            sumSquares += s * s;
            var a = Math.Abs(s);
            if (a > peak) peak = a;
        }
        var rms = (float)Math.Sqrt(sumSquares / samples.Length);
        return rms < rmsThreshold && peak < 0.05f;
    }

    /// Replays the live loop offline (tests): every Tick samples, look for a cut in the
    /// audio pending since the previous one. Returns absolute cut indices.
    public static List<int> Plan(float[] samples)
    {
        var cuts = new List<int>();
        var committed = 0;
        for (var available = Tick; available <= samples.Length; available += Tick)
        {
            if (NextCut(samples.AsSpan(committed, available - committed)) is int cut)
            {
                committed += cut;
                cuts.Add(committed);
            }
        }
        return cuts;
    }

    /// Release step: transcribe the tail and join it to the chunk transcripts.
    /// chunkStarts[i] is where the audio behind texts[i] began; the tail starts at
    /// committed. speculation is a transcript of samples[committed..End] made during a
    /// pause; it is the tail's text when nothing audible came after it.
    /// A near-silent tail may still hold quiet trailing words the silence gate would
    /// drop, so the last chunk is then re-decoded together with it — unless no tail
    /// frame reaches the level a trim would keep as speech next to that chunk.
    public static async Task<string> FinishAsync(
        float[] samples, IReadOnlyList<int> chunkStarts, IReadOnlyList<string> texts, int committed,
        (int End, string Text)? speculation, Func<float[], Task<string>> transcribe)
    {
        if (speculation is { } spec && QuietAfter(samples, committed, spec.End))
            return Join(texts.Append(spec.Text));
        var parts = texts.ToList();
        var tailStart = committed;
        if (tailStart < samples.Length && chunkStarts.Count > 0 && parts.Count > 0
            && chunkStarts[^1] < committed && IsNearSilent(samples.AsSpan(tailStart)))
        {
            var last = chunkStarts[^1];
            if (QuietAfter(samples, last, committed)) return Join(parts);
            parts.RemoveAt(parts.Count - 1);
            tailStart = last;
        }
        var tail = samples[tailStart..];
        parts.Add(tail.Length == 0 ? "" : await transcribe(tail));
        return Join(parts);
    }

    /// Splits audio longer than maxSamples into pieces that each fit one decode, cutting
    /// at the quietest 100 ms of the last 5 s before each limit.
    public static List<float[]> Split(float[] samples, int maxSamples)
    {
        var pieces = new List<float[]>();
        var start = 0;
        while (samples.Length - start > maxSamples)
        {
            var limit = start + maxSamples;
            var searchStart = Math.Max(start + maxSamples / 2, limit - 5 * SampleRate);
            var energies = FrameEnergies(samples.AsSpan(searchStart, limit - searchStart));
            const int window = 10;
            var cut = limit;
            var quietestSum = float.MaxValue;
            for (var i = 0; i + window <= energies.Length; i++)
            {
                var sum = 0f;
                for (var k = i; k < i + window; k++) sum += energies[k];
                if (sum < quietestSum)
                {
                    quietestSum = sum;
                    cut = searchStart + (i + window / 2) * Frame;
                }
            }
            pieces.Add(samples[start..cut]);
            start = cut;
        }
        pieces.Add(samples[start..]);
        return pieces;
    }

    /// Joins chunk transcripts. A chunk boundary sits in a pause, which the model often
    /// reads as a sentence start; when the previous chunk didn't end a sentence and the
    /// next starts with a capitalized common word ("And", "The"), lowercase it back.
    /// Likewise a chunk ending in "." followed by one starting lowercase is one
    /// sentence, so the period goes.
    public static string Join(IEnumerable<string> parts)
    {
        var result = "";
        foreach (var part in parts)
        {
            var text = part.Trim();
            if (text.Length == 0) continue;
            if (result.EndsWith('.') && char.IsLower(text[0]))
            {
                var lastWord = result.Split(' ').Last();
                if (lastWord.Count(c => c == '.') == 1) result = result[..^1];
            }
            if (result.Length > 0)
            {
                var endsSentence = ".?!".Contains(result[^1]);
                var firstWordLength = 0;
                while (firstWordLength < text.Length && char.IsLetter(text[firstWordLength])) firstWordLength++;
                var firstWord = text[..firstWordLength];
                if (!endsSentence && Lowercaseable.Contains(firstWord.ToLowerInvariant()))
                    text = firstWord.ToLowerInvariant() + text[firstWordLength..];
                result += " ";
            }
            result += text;
        }
        return result;
    }

    private static readonly HashSet<string> Lowercaseable = new()
    {
        "and", "but", "or", "so", "because", "then", "the", "a", "an", "to", "of", "in", "on",
        "at", "for", "with", "that", "this", "it", "is", "was", "if", "like", "just", "we",
        "you", "they", "he", "she", "my", "your", "our", "their", "what", "which", "when",
    };

    // Helpers

    /// A 10 ms frame counts as speech when its RMS exceeds this, given the loudest frame.
    private static float SpeechThreshold(float peak) => Math.Max(1.5e-3f, peak * 0.06f);

    /// A 10 ms frame counts as pause when its RMS is below this, given the clip's
    /// 90th-percentile frame.
    private static float PauseThreshold(float loud) => Math.Max(1.5e-3f, loud * 0.08f);

    private static float[] FrameEnergies(ReadOnlySpan<float> samples)
    {
        var count = samples.Length / Frame;
        var energies = new float[count];
        for (var f = 0; f < count; f++)
        {
            double sum = 0;
            var frame = samples.Slice(f * Frame, Frame);
            foreach (var s in frame) sum += s * s;
            energies[f] = (float)Math.Sqrt(sum / Frame);
        }
        return energies;
    }

    private static float? Percentile(float[] values, double p)
    {
        if (values.Length == 0) return null;
        var sorted = (float[])values.Clone();
        Array.Sort(sorted);
        return sorted[Math.Min(sorted.Length - 1, (int)(sorted.Length * p))];
    }
}
