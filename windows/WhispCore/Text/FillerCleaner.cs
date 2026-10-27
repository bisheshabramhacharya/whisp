using System.Text.RegularExpressions;

namespace Whisp.Core.Text;

/// <summary>
/// Subtractive, rules-only cleanup. Port of Sources/WhispCore/Text/FillerCleaner.swift.
/// It never rephrases: it only removes
///
/// - hesitation sounds anywhere ("um", "uh", "erm", "hmm"),
/// - "like" / "you know" / "I mean" when set off by commas ("It was, like, huge"),
/// - immediate stutters ("I I think", "the, the") except intentional doubles
///   ("that that", "had had", "no no", "very very") and repeated numbers ("4 4", "404 404"),
/// - restarted phrases: the abandoned first try in "go to the go to desktop" or
///   "I want to, I want to go", but not a repeated run of numbers ("1 2 1 2 5"),
///
/// then repairs the punctuation/capitalization it disturbed, writes clock times with a
/// colon ("at 5.30" -> "at 5:30"), and applies the personal dictionary.
/// </summary>
public sealed class FillerCleaner
{
    private readonly PersonalDictionary? _dictionary;

    public FillerCleaner(PersonalDictionary? dictionary = null)
    {
        _dictionary = dictionary;
    }

    public string Clean(string raw)
    {
        var tokens = raw.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(Token.Parse).ToList();
        RemoveHesitations(tokens);
        RemoveParentheticalFillers(tokens);
        RemoveStutters(tokens);
        RemoveRestarts(tokens);
        var text = FixClockTimes(string.Join(" ", tokens.Select(t => t.Text)));
        return _dictionary?.Apply(text) ?? text;
    }

    /// Parakeet writes "five thirty" as "5.30". Use a colon when the context says it's a
    /// clock time: followed by am/pm, or after at/by/until/… A number followed by a
    /// measurement unit is a quantity, never a time ("at 3.14 percent", "version 2.45"
    /// are untouched).
    private static readonly (Regex Regex, string Template)[] ClockTimeRules = BuildClockTimeRules();

    private static (Regex, string)[] BuildClockTimeRules()
    {
        const string units = @"(?:percent|per cent|%|points?|kilo(?:s|grams?)?|kg|pounds?|lbs?|dollars?|bucks|euros?|cents|meters?|metres?|miles?|degrees?|millions?|billions?|thousands?|gigabytes?|gb|megabytes?|mb|kilobytes?|kb|terabytes?|tb|inches|inch|feet|foot|cm|mm|millimeters?|millimetres?|seconds?|secs?|mins?|minutes?|hours?|hrs?|days?|weeks?|months?|years?|volts?|watts?|amps?|ohms?|hertz|khz|mhz|ghz|liters?|litres?|gallons?|ounces?|oz|grams?|milligrams?|mg|acres?|hectares?|pixels?|px|dpi|fps|kph|mph|rpm|bpm|decibels?|db|times|x|stars?|floors|stor(?:e|)ys|episodes?|chapters?|versions?|levels?|laps?|pages?|verses?|steps?|reps?|sets?|calories?)";
        const string time = @"(1[0-2]|0?[1-9])\.([0-5]\d)";
        const string timeRef = @"(?:1[0-2]|0?[1-9])\.[0-5]\d";
        var rules = new (string, string)[]
        {
            (@"(?<![\d.])" + time + @"(?=\s*[ap]\.?m\b)", "$1:$2"),
            // Ranges: "from 9.00 to 5.30", "between 8.30 and 6.00", "at 5.30 or 6.00", "at 5.30-6.00".
            (@"\b(from|between|at|by|until|till|around|before|after) " + time + @"(\s*(?:to|or|and|-|–|—)\s*)" + time
                + @"(?!\.?\d|\s*" + units + @"\b)", "$1 $2:$3$4$5:$6"),
            (@"\b(at|by|until|till|around|from|before|after) " + time + @"(?!\.?\d|\s*" + units
                + @"\b|\s*(?:to|or|and|-|–|—)\s*" + timeRef + @"\s*" + units + @"\b)", "$1 $2:$3"),
        };
        return rules
            .Select(r => (new Regex(r.Item1, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), r.Item2))
            .ToArray();
    }

    private static string FixClockTimes(string text)
    {
        if (!text.Contains('.')) return text;
        foreach (var (regex, template) in ClockTimeRules)
        {
            text = regex.Replace(text, template);
        }
        return text;
    }

    // Word lists

    private static readonly HashSet<string> Hesitations = new()
    {
        "um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "erm", "hmm", "hmmm", "hm", "mmm",
    };

    // "er" and "mm" are left out on purpose: "the ER", "5 mm".

    /// Removed only when fenced by commas / sentence boundaries.
    private static readonly string[][] Parentheticals = { new[] { "you", "know" }, new[] { "i", "mean" }, new[] { "like" } };

    /// Words people deliberately double.
    private static readonly HashSet<string> IntentionalDoubles = new()
    {
        "that", "had", "is", "no", "very", "really", "so", "bye", "yeah", "yes", "okay", "ok", "oh",
        "ha", "haha", "hey", "go", "well", "please", "more", "again", "too", "many", "much", "blah",
        "knock", "now", "wait", "come", "there", "far", "long", "over", "round", "up", "down", "wow",
        "tick", "tock", "cha", "boo", "choo", "yay", "hip", "bang", "night", "done", "fine", "sure",
        // Expressions, names and wordplay people say twice on purpose.
        "hear", "hush", "do", "test", "stop", "fifty", "twenty", "nineteen",
        "mahi", "bora", "walla", "pago", "sing", "chow", "yo", "mu", "bon",
        "na", "la", "goo", "ga", "woo", "yadda", "yada", "hee", "haw", "gee",
        "nudge", "wink", "tut", "tsk", "rah", "ring", "ding", "honk", "quack",
        "moo", "woof", "meow", "vroom", "bam", "pow", "dee", "dum", "poo", "wee",
        "si", "oui", "ja", "da", "ma", "pa", "oink", "buzz", "hiss", "tweet",
        "chirp", "ribbit", "snap", "beep", "bong", "zoom", "pip",
    };

    /// Codes and counts ("4", "404", "3.14"), which people repeat on purpose.
    /// A letter anywhere ("4th", "R2") keeps the token a word, so a real stutter of it still drops.
    private static bool IsNumericWord(string word)
    {
        var digit = false;
        foreach (var ch in word)
        {
            if (char.IsNumber(ch)) digit = true;
            else if (char.IsLetter(ch)) return false;
        }
        return digit;
    }

    /// Sentence-initial lead-ins whose comma survives when a following filler is removed ("So, um, we" -> "So, we").
    private static readonly HashSet<string> LeadIns = new()
    {
        "so", "well", "yes", "yeah", "no", "okay", "ok", "oh", "right", "now", "anyway", "actually",
        "also", "first", "second", "then", "hey", "hi", "hello", "alright", "honestly", "basically",
    };

    // Passes

    private static void RemoveHesitations(List<Token> tokens)
    {
        var i = 0;
        while (i < tokens.Count)
        {
            if (Hesitations.Contains(tokens[i].Word))
                Remove(tokens, i, i + 1, requireFence: false);
            else
                i++;
        }
    }

    private static void RemoveParentheticalFillers(List<Token> tokens)
    {
        var i = 0;
        while (i < tokens.Count)
        {
            var phrase = Parentheticals.FirstOrDefault(p => Matches(p, tokens, i));
            if (phrase == null)
            {
                i++;
                continue;
            }
            if (IsFenced(tokens, i, i + phrase.Length))
                Remove(tokens, i, i + phrase.Length, requireFence: true);
            else
                i++;
        }
    }

    private static void RemoveStutters(List<Token> tokens)
    {
        var i = 1;
        while (i < tokens.Count)
        {
            Token prev = tokens[i - 1], cur = tokens[i];
            var separable = prev.Trailing.Length == 0 || prev.Trailing == ",";
            if (separable && cur.Word.Length > 0 && cur.Leading.Length == 0 && prev.Leading.Length == 0
                && cur.Word == prev.Word && !IntentionalDoubles.Contains(cur.Word)
                && !IsNumericWord(cur.Word))
            {
                // Keep the second copy's punctuation, the first copy's casing.
                tokens[i] = new Token("", prev.Core, cur.Trailing);
                tokens.RemoveAt(i - 1);
            }
            else
            {
                i++;
            }
        }
    }

    /// Words a speaker may abandon between a phrase and its restart ("go to the go to").
    private static readonly HashSet<string> Abandonable = new()
    {
        "the", "a", "an", "to", "my", "our", "your", "his", "her", "their", "this", "its",
    };

    /// Drops the first copy of a 2–4 word phrase that is immediately repeated, optionally
    /// with one abandoned word in between: "go to the go to desktop" -> "go to desktop".
    /// Never crosses a sentence end, leaves chants made of intentional doubles alone,
    /// and leaves a phrase made only of numbers alone ("press 1 2 1 2 5" is a code).
    private static void RemoveRestarts(List<Token> tokens)
    {
        var i = 0;
        while (i < tokens.Count)
        {
            if (!TryRemoveRestartAt(tokens, i)) i++;
        }
    }

    private static bool TryRemoveRestartAt(List<Token> tokens, int i)
    {
        for (var n = 4; n >= 2; n--)
        {
            for (var gap = 0; gap <= 1; gap++)
            {
                var second = i + n + gap;
                if (second + n > tokens.Count) continue;
                if (gap == 1 && !Abandonable.Contains(tokens[i + n].Word)) continue;
                var ok = true;
                for (var k = i; k < second && ok; k++)
                    ok = !tokens[k].EndsSentence && tokens[k].Leading.Length == 0;
                for (var k = 0; k < n && ok; k++)
                    ok = tokens[i + k].Word == tokens[i + k + n + gap].Word;
                if (!ok) continue;
                // Chants of one intentional double ("no no no no") aren't restarts,
                // but a phrase merely made of protectable words still is ("do that do that").
                var chant = true;
                for (var k = i; k < i + n && chant; k++)
                {
                    var w = tokens[k].Word;
                    chant = (w == tokens[i].Word && IntentionalDoubles.Contains(w)) || w.Length == 0;
                }
                if (chant) continue;
                // A phrase of only numbers ("1 2 1 2 5", "5 5 5 5 now") is a code, not a restart.
                // A word phrase that merely contains a number still is ("go to 4 go to 4 now").
                var numeric = true;
                for (var k = i; k < i + n && numeric; k++)
                    numeric = IsNumericWord(tokens[k].Word);
                if (numeric) continue;
                // A repeat that runs to the end of the take ("Let's go let's go!") or
                // keeps alternating ("ran and ran and ran") is emphasis, not a restart.
                if (second + n >= tokens.Count || tokens[second + n].Word == tokens[i].Word) continue;
                // Keep the first copy's casing (sentence start stays capitalized).
                var firstCore = tokens[i].Core;
                tokens.RemoveRange(i, second - i);
                tokens[i].Core = firstCore;
                return true;
            }
        }
        return false;
    }

    // Removal with punctuation repair

    /// A phrase is fenced when it's bounded on the left by a comma or sentence start, and on
    /// the right by a comma, or by sentence end when the left side is a comma.
    private static bool IsFenced(List<Token> tokens, int lower, int upper)
    {
        for (var k = lower; k < upper - 1; k++)
            if (tokens[k].Trailing.Length > 0) return false;
        for (var k = lower; k < upper; k++)
            if (tokens[k].Leading.Length > 0) return false;
        var prev = lower > 0 ? tokens[lower - 1] : null;
        var last = tokens[upper - 1];
        var leftComma = prev?.Trailing == ",";
        var atStart = prev == null || prev.EndsSentence;
        if (last.Trailing == ",") return leftComma || atStart;
        if (last.EndsSentence) return leftComma;
        return false;
    }

    private static void Remove(List<Token> tokens, int lower, int upper, bool requireFence)
    {
        var last = tokens[upper - 1];
        int? prevIndex = lower > 0 ? lower - 1 : null;
        var atSentenceStart = prevIndex is int pi ? tokens[pi].EndsSentence : true;

        if (prevIndex is int p)
        {
            var prev = tokens[p];
            if (last.EndsSentence && !prev.EndsSentence)
            {
                // "I think, um." -> "I think."
                prev.Trailing = prev.Trailing.TrimStart(',') + last.Trailing;
            }
            else if (!last.EndsSentence && prev.Trailing == ","
                     && (last.Trailing == "," || requireFence)
                     && !(LeadIns.Contains(prev.Word) && (p == 0 || tokens[p - 1].EndsSentence)))
            {
                // "I was, uh, going" -> "I was going"
                prev.Trailing = "";
            }
        }

        tokens.RemoveRange(lower, upper - lower);

        if (atSentenceStart && lower < tokens.Count)
            tokens[lower].CapitalizeFirst();
    }

    private static bool Matches(string[] phrase, List<Token> tokens, int i)
    {
        if (i + phrase.Length > tokens.Count) return false;
        for (var k = 0; k < phrase.Length; k++)
            if (tokens[i + k].Word != phrase[k]) return false;
        return true;
    }

    /// A whitespace-delimited word split into leading punctuation, core, and trailing punctuation.
    private sealed class Token
    {
        private string _core = "";

        public string Leading;
        public string Trailing;
        /// Lowercased Core, cached instead of recomputed on every comparison.
        public string Word { get; private set; } = "";

        public string Core
        {
            get => _core;
            set
            {
                _core = value;
                Word = value.ToLowerInvariant();
            }
        }

        public Token(string leading, string core, string trailing)
        {
            Leading = leading;
            Core = core;
            Trailing = trailing;
        }

        public static Token Parse(string raw)
        {
            static bool IsWordChar(char c) => char.IsLetter(c) || char.IsNumber(c);
            var start = -1;
            for (var k = 0; k < raw.Length; k++)
                if (IsWordChar(raw[k])) { start = k; break; }
            if (start < 0) return new Token("", "", raw);
            var end = raw.Length - 1;
            while (!IsWordChar(raw[end])) end--;
            return new Token(raw[..start], raw[start..(end + 1)], raw[(end + 1)..]);
        }

        public string Text => Leading + Core + Trailing;
        public bool EndsSentence => Trailing.IndexOfAny(new[] { '.', '?', '!' }) >= 0;

        public void CapitalizeFirst()
        {
            if (Core.Length == 0 || !char.IsLower(Core[0])) return;
            Core = char.ToUpperInvariant(Core[0]) + Core[1..];
        }
    }
}
