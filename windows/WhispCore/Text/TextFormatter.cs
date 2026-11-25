using System.Globalization;
using System.Text;
using Token = Whisp.Core.Text.FillerCleaner.Token;

namespace Whisp.Core.Text;

/// Rules-only formatting after cleanup. Port of Sources/WhispCore/Text/TextFormatter.swift.
public sealed class TextFormatter
{
    public string Format(string text)
    {
        var tokens = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(Token.Parse).ToList();
        if (tokens.Count == 0) return "";
        JoinPaths(tokens);
        WriteNumbers(tokens);
        Punctuate(tokens);
        return string.Join(" ", tokens.Select(token => token.Text));
    }

    private static readonly HashSet<string> PathEndings =
    [
        "swift", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "java", "kt", "c", "h",
        "cc", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "bash", "zsh", "json", "yaml",
        "yml", "toml", "xml", "html", "htm", "css", "scss", "sass", "md", "txt", "rtf",
        "csv", "tsv", "sql", "log", "lock", "env", "plist", "pdf", "png", "jpg", "jpeg",
        "gif", "svg", "webp", "wav", "mp3", "mp4", "mov", "zip", "gz", "tar", "dmg",
        "ipa", "apk", "xlsx", "docx", "pptx", "key", "pages",
        "com", "org", "net", "io", "dev", "app", "co", "ai",
    ];

    private static readonly HashSet<string> NotPathWords =
    [
        "i", "i'm", "i'll", "i've", "i'd", "we", "you", "they", "he", "she", "it",
        "the", "a", "an", "this", "that", "these", "those", "our", "my", "your", "their",
        "his", "her", "its", "is", "are", "was", "were", "be", "been", "being", "am",
        "do", "does", "did", "done", "can", "could", "will", "would", "should", "shall",
        "may", "might", "must", "not", "no", "yes", "ok", "okay", "and", "or", "but",
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "as", "if", "then",
        "than", "so", "just", "like", "about", "into", "onto", "over", "under", "after",
        "before", "up", "down", "out", "off", "all", "any", "some", "every", "each",
        "there", "here", "what", "which", "who", "whom", "whose", "when", "where", "why",
        "how", "also", "very", "really", "more", "most", "less", "least", "only", "same",
        "other", "another", "both", "few", "many", "much",
    ];

    private static readonly HashSet<string> SeparatorWords = ["slash", "backslash", "dot", "underscore", "forward"];

    private static bool IsPathWord(Token token)
    {
        if (token.Leading.Length != 0 || token.Core.Length == 0 || SeparatorWords.Contains(token.Word))
            return false;
        foreach (var character in token.Core.EnumerateRunes())
            if (!Rune.IsLetterOrDigit(character) && !Rune.IsNumber(character)
                && Rune.GetUnicodeCategory(character) is not (UnicodeCategory.NonSpacingMark or
                    UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark)
                && character.Value is not ('-' or '_' or '.'))
                return false;
        return token.Trailing.Length == 0 || token.Trailing.AsSpan().ContainsAny(".?!,;:");
    }

    private static (string Text, bool IsSlash, int Length)? Separator(List<Token> tokens, int index)
    {
        if (index >= tokens.Count || tokens[index].Leading.Length != 0 || tokens[index].Trailing.Length != 0)
            return null;
        return tokens[index].Word switch
        {
            "slash" or "backslash" => ("/", true, 1),
            "dot" => (".", false, 1),
            "underscore" => ("_", false, 1),
            "forward" when index + 1 < tokens.Count && tokens[index + 1].Word == "slash"
                && tokens[index + 1].Leading.Length == 0 && tokens[index + 1].Trailing.Length == 0 => ("/", true, 2),
            _ => null,
        };
    }

    private static (int End, int LastPart)? PathRun(List<Token> tokens, int start)
    {
        if (start > 0 && Separator(tokens, start - 1) != null) return null;
        var lastPart = start;
        var separators = 0;
        var hasSlash = false;
        var startsWithSeparator = false;
        string? wordBeforeFirstSeparator = null;
        if (Separator(tokens, start) is { } first)
        {
            var part = start + first.Length;
            if ((start != 0 && !tokens[start - 1].EndsSentence) || first.Text != "." || part >= tokens.Count
                || !IsPathWord(tokens[part]) || !PathEndings.Contains(tokens[part].Word))
                return null;
            startsWithSeparator = true;
            separators = 1;
            lastPart = part;
        }
        else if (!IsPathWord(tokens[start]) || tokens[start].Trailing.Length != 0)
        {
            return null;
        }

        var cursor = lastPart + 1;
        while (Separator(tokens, cursor) is { } separator)
        {
            var part = cursor + separator.Length;
            if (part >= tokens.Count || !IsPathWord(tokens[part])) break;
            if (separators == 0) wordBeforeFirstSeparator = tokens[cursor - 1].Word;
            separators++;
            hasSlash |= separator.IsSlash;
            lastPart = part;
            cursor = part + 1;
            if (tokens[part].Trailing.Length != 0) break;
        }
        if (separators < 2 && !hasSlash && !startsWithSeparator) return null;
        if (wordBeforeFirstSeparator != null && NotPathWords.Contains(wordBeforeFirstSeparator)) return null;
        if (!startsWithSeparator)
        {
            for (var i = start; i < cursor; i++)
                if (Separator(tokens, i) == null && NotPathWords.Contains(tokens[i].Word))
                    return null;
        }
        return (cursor, lastPart);
    }

    private static void JoinPaths(List<Token> tokens)
    {
        for (var start = 0; start < tokens.Count; start++)
        {
            if (PathRun(tokens, start) is not { } run) continue;
            var path = new StringBuilder();
            for (var i = start; i < run.End;)
            {
                if (Separator(tokens, i) is { } separator)
                {
                    path.Append(separator.Text);
                    i += separator.Length;
                }
                else
                {
                    path.Append(tokens[i++].Core);
                }
            }
            ReplaceRun(tokens, start, run.End - start, path.ToString(), run.LastPart);
        }
    }

    private static readonly Dictionary<string, int> Ones = new()
    {
        ["zero"] = 0, ["one"] = 1, ["two"] = 2, ["three"] = 3, ["four"] = 4, ["five"] = 5, ["six"] = 6,
        ["seven"] = 7, ["eight"] = 8, ["nine"] = 9, ["ten"] = 10, ["eleven"] = 11, ["twelve"] = 12,
        ["thirteen"] = 13, ["fourteen"] = 14, ["fifteen"] = 15, ["sixteen"] = 16, ["seventeen"] = 17,
        ["eighteen"] = 18, ["nineteen"] = 19,
    };

    private static readonly Dictionary<string, int> Tens = new()
    {
        ["twenty"] = 20, ["thirty"] = 30, ["forty"] = 40, ["fifty"] = 50, ["sixty"] = 60, ["seventy"] = 70,
        ["eighty"] = 80, ["ninety"] = 90,
    };

    private static readonly Dictionary<string, int> Scales = new()
    {
        ["hundred"] = 100, ["thousand"] = 1000, ["million"] = 1_000_000, ["billion"] = 1_000_000_000,
    };

    private static readonly Dictionary<string, int> Ordinals = new()
    {
        ["first"] = 1, ["second"] = 2, ["third"] = 3, ["fourth"] = 4, ["fifth"] = 5, ["sixth"] = 6,
        ["seventh"] = 7, ["eighth"] = 8, ["ninth"] = 9, ["tenth"] = 10, ["eleventh"] = 11, ["twelfth"] = 12,
        ["thirteenth"] = 13, ["fourteenth"] = 14, ["fifteenth"] = 15, ["sixteenth"] = 16,
        ["seventeenth"] = 17, ["eighteenth"] = 18, ["nineteenth"] = 19, ["twentieth"] = 20,
        ["thirtieth"] = 30, ["fortieth"] = 40, ["fiftieth"] = 50, ["sixtieth"] = 60, ["seventieth"] = 70,
        ["eightieth"] = 80, ["ninetieth"] = 90, ["hundredth"] = 100, ["thousandth"] = 1000,
        ["millionth"] = 1_000_000,
    };

    private enum NumberKind { None, Unit, Tens, Scale, And }

    private readonly record struct NumberRun(long Value, int Count, bool Ordinal);

    private static NumberRun? ReadNumber(List<Token> tokens, int start)
    {
        long total = 0, current = 0;
        var count = 0;
        var last = NumberKind.None;
        var ordinal = false;
        while (start + count < tokens.Count)
        {
            var token = tokens[start + count];
            if (token.Leading.Length != 0) break;
            if (token.Word == "and" && last == NumberKind.Scale)
            {
                count++;
                last = NumberKind.And;
                continue;
            }
            NumberKind kind;
            if (Ones.TryGetValue(token.Word, out var value)) kind = NumberKind.Unit;
            else if (Tens.TryGetValue(token.Word, out value)) kind = NumberKind.Tens;
            else if (Scales.TryGetValue(token.Word, out value)) kind = NumberKind.Scale;
            else if (Ordinals.TryGetValue(token.Word, out value))
            {
                kind = value < 20 ? NumberKind.Unit : value < 100 ? NumberKind.Tens : NumberKind.Scale;
                ordinal = true;
            }
            else break;

            if (count > 0)
            {
                if (kind == NumberKind.Unit && last == NumberKind.Unit) break;
                if (kind == NumberKind.Unit && last == NumberKind.Tens && value >= 10) break;
                if (kind == NumberKind.Tens && last is NumberKind.Unit or NumberKind.Tens) break;
            }
            if (kind == NumberKind.Scale && value == 100)
            {
                if (current > long.MaxValue / value) return null;
                current = Math.Max(current, 1) * value;
            }
            else if (kind == NumberKind.Scale)
            {
                if (current > (long.MaxValue - total) / value || total > long.MaxValue - value) return null;
                total += Math.Max(current, 1) * value;
                current = 0;
            }
            else
            {
                if (current > long.MaxValue - value) return null;
                current += value;
            }

            count++;
            last = kind;
            if (ordinal) break;
        }
        return count > 0 && total <= long.MaxValue - current ? new NumberRun(total + current, count, ordinal) : null;
    }

    private static bool IsNumberWord(string word) =>
        Ones.ContainsKey(word) || Tens.ContainsKey(word) || Scales.ContainsKey(word) || Ordinals.ContainsKey(word);

    private static string OrdinalSuffix(long value) => (value % 100) switch
    {
        11 or 12 or 13 => "th",
        _ => (value % 10) switch { 1 => "st", 2 => "nd", 3 => "rd", _ => "th" },
    };

    private static string? Digits(NumberRun run)
    {
        if (run.Count == 1 && (run.Value < 20 || run.Value is 100 or 1000 or 1_000_000 or 1_000_000_000))
            return null;
        return run.Value.ToString(CultureInfo.InvariantCulture) + (run.Ordinal ? OrdinalSuffix(run.Value) : "");
    }

    private static (string Prefix, string Suffix, int Count) Absorbed(List<Token> tokens, int next)
    {
        if (next >= tokens.Count) return ("", "", 0);
        var token = tokens[next];
        if (token.Leading.Length == 0 && token.Word is "dollars" or "dollar" or "bucks" or "buck")
            return ("$", "", 1);
        if (token.Leading.Length == 0 && token.Word == "percent")
            return ("", "%", 1);
        if (token.Word == "per" && next + 1 < tokens.Count && tokens[next + 1].Word == "cent"
            && tokens[next + 1].Leading.Length == 0)
            return ("", "%", 2);
        return ("", "", 0);
    }

    private static readonly HashSet<string> ClockPrepositions =
    [
        "at", "by", "around", "from", "before", "after", "until", "till", "past", "about",
    ];

    private static readonly Dictionary<string, int> MinuteTens = new()
    {
        ["ten"] = 10, ["twenty"] = 20, ["thirty"] = 30, ["forty"] = 40, ["fifty"] = 50,
    };

    private static (string Text, int Count)? ClockTime(List<Token> tokens, int start)
    {
        if (start == 0 || start + 1 >= tokens.Count || tokens[start].Leading.Length != 0
            || !ClockPrepositions.Contains(tokens[start - 1].Word)
            || !Ones.TryGetValue(tokens[start].Word, out var hour) || hour is < 1 or > 12)
            return null;

        var minuteToken = tokens[start + 1];
        if (minuteToken.Leading.Length != 0) return null;
        var unitToken = start + 2 < tokens.Count ? tokens[start + 2] : null;
        var count = 1;
        int minute;
        if (minuteToken.Word == "oh" && unitToken != null && Ones.TryGetValue(unitToken.Word, out var unit) && unit < 10)
        {
            minute = unit;
            count = 2;
        }
        else if (MinuteTens.TryGetValue(minuteToken.Word, out minute))
        {
            if (unitToken?.Leading.Length == 0 && Ones.TryGetValue(unitToken.Word, out unit) && unit < 10)
            {
                minute += unit;
                count = 2;
            }
        }
        else if (!Ones.TryGetValue(minuteToken.Word, out minute) || minute < 10)
        {
            return null;
        }

        var after = start + 1 + count;
        if (after < tokens.Count)
        {
            var word = tokens[after].Word;
            if (Ones.ContainsKey(word) || Tens.ContainsKey(word) || Scales.ContainsKey(word)) return null;
        }
        return (string.Create(CultureInfo.InvariantCulture, $"{hour}:{minute:D2}"), 1 + count);
    }

    private static void WriteNumbers(List<Token> tokens)
    {
        for (var start = 0; start < tokens.Count; start++)
        {
            if (ClockTime(tokens, start) is { } clock)
            {
                ReplaceRun(tokens, start, clock.Count, clock.Text, start + clock.Count - 1);
                continue;
            }
            if (ReadNumber(tokens, start) is not { } run || Digits(run) is not { } written) continue;

            var next = start + run.Count;
            if ((start > 0 && IsNumberWord(tokens[start - 1].Word))
                || (next < tokens.Count && IsNumberWord(tokens[next].Word)))
                continue;

            var absorbed = Absorbed(tokens, next);
            var count = run.Count + absorbed.Count;
            ReplaceRun(tokens, start, count, absorbed.Prefix + written + absorbed.Suffix, start + count - 1);
        }
    }

    private static void ReplaceRun(List<Token> tokens, int start, int count, string core, int lastPart)
    {
        var token = tokens[start];
        token.Leading = "";
        token.Core = core;
        token.Trailing = tokens[lastPart].Trailing;
        tokens.RemoveRange(start + 1, count - 1);
    }

    private static readonly HashSet<string> CommasAfter =
    [
        "yes", "yeah", "yep", "nope", "no", "okay", "ok", "alright", "sure", "well", "hey",
        "hi", "hello", "thanks", "sorry", "actually", "honestly", "anyway", "basically",
    ];

    private static readonly HashSet<string> CommaBefore =
    [
        "i", "i'm", "i'll", "i've", "i'd", "we", "we're", "we'll", "you", "you're",
        "they", "they're", "he", "he's", "she", "she's", "it", "it's", "this", "that",
        "these", "those", "the", "a", "an", "my", "our", "your", "their", "his", "her",
        "its", "there", "let's", "here's", "everyone", "everybody",
    ];

    private static readonly HashSet<string> QuestionAuxiliaries =
    [
        "do", "does", "did", "is", "are", "was", "were", "can", "could", "would", "should",
        "will", "shall", "may", "might", "have", "has", "had", "am", "isn't", "aren't",
        "wasn't", "weren't", "don't", "doesn't", "didn't", "can't", "couldn't",
        "wouldn't", "shouldn't", "won't", "haven't", "hasn't", "hadn't",
    ];

    private static readonly HashSet<string> QuestionWh =
    [
        "what", "where", "when", "why", "how", "who", "whom", "which", "whose",
    ];

    private static readonly HashSet<string> QuestionSubjects =
    [
        "i", "i'm", "you", "you're", "we", "we're", "they", "they're", "he", "she", "it",
        "there", "this", "that", "these", "those", "the", "a", "an", "my", "our", "your",
        "their", "his", "her", "anyone", "someone", "anybody", "everybody", "everyone",
    ];

    private static readonly HashSet<string> TagWords = ["right", "okay", "ok", "correct", "yeah"];

    private static void Punctuate(List<Token> tokens)
    {
        AddClosingStop(tokens);
        for (var i = 0; i < tokens.Count; i++)
        {
            if ((i == 0 || tokens[i - 1].EndsSentence) && !tokens[i].Leading.EndsWith('.'))
                tokens[i].CapitalizeFirst();
        }
        for (var i = 0; i + 1 < tokens.Count; i++)
        {
            if (tokens[i].Trailing.Length == 0 && CommasAfter.Contains(tokens[i].Word)
                && (i == 0 || tokens[i - 1].EndsSentence)
                && tokens[i + 1].Leading.Length == 0 && CommaBefore.Contains(tokens[i + 1].Word))
                tokens[i].Trailing = ",";
        }
        var sentenceStart = 0;
        for (var i = 0; i < tokens.Count; i++)
        {
            if (!tokens[i].EndsSentence) continue;
            if (IsQuestion(tokens, sentenceStart, i))
                tokens[i].Trailing = tokens[i].Trailing[..^1] + "?";
            sentenceStart = i + 1;
        }
    }

    private static void AddClosingStop(List<Token> tokens)
    {
        var last = tokens[^1];
        if (tokens.Count < 3 || last.Core.Length == 0 || last.EndsSentence) return;
        var trailing = last.Trailing;
        if (trailing.Length > 0 && trailing[^1] is ',' or ':' or ';')
        {
            last.Trailing = trailing[..^1] + ".";
        }
        else
        {
            var closer = trailing.AsSpan().IndexOfAny(Token.Closers);
            last.Trailing = closer >= 0 ? trailing.Insert(closer, ".") : trailing + ".";
        }
    }

    private static bool IsQuestion(List<Token> tokens, int from, int to)
    {
        if (from > to || !tokens[to].Trailing.EndsWith('.')) return false;
        if (to > from && TagWords.Contains(tokens[to].Word) && tokens[to - 1].Trailing == ",") return true;
        var first = tokens[from].Word;
        var second = to > from ? tokens[from + 1].Word : "";
        var third = to > from + 1 ? tokens[from + 2].Word : "";
        return (QuestionAuxiliaries.Contains(first) && QuestionSubjects.Contains(second))
            || (QuestionWh.Contains(first) && QuestionAuxiliaries.Contains(second) && QuestionSubjects.Contains(third));
    }
}
