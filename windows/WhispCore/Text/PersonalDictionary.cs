using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Whisp.Core.Text;

/// <summary>
/// User-editable word list at dictionary.json. Port of
/// Sources/WhispCore/Text/PersonalDictionary.swift; the file format is identical, so a
/// dictionary copied from a Mac works as-is:
///
///     {
///       "terms": ["Vinted", "Poshmark"],
///       "replacements": [{"from": ["chat gpt", "chat g p t"], "to": "ChatGPT"}]
///     }
///
/// - terms fix casing of whole-word matches ("vinted" -> "Vinted").
/// - replacements swap whole-word/phrase matches (case-insensitive) for "to".
///
/// The file is re-read automatically when its modification time changes, so edits
/// apply to the next dictation without restarting. Thread-safe.
/// </summary>
public sealed class PersonalDictionary
{
    private sealed record Rule(Regex Regex, string Replacement);

    private readonly string? _path;
    private readonly object _gate = new();
    private DateTime? _loadedStamp;
    private List<Rule> _rules = new();

    /// Loads from path; a missing or malformed file is treated as empty.
    public PersonalDictionary(string path)
    {
        _path = path;
    }

    /// In-memory dictionary (tests). replacements maps "to" -> its "from" phrases.
    public PersonalDictionary(IEnumerable<string> terms, IDictionary<string, string[]>? replacements = null)
    {
        var root = new JsonObject
        {
            ["terms"] = new JsonArray(terms.Select(t => (JsonNode?)t).ToArray()),
            ["replacements"] = new JsonArray((replacements ?? new Dictionary<string, string[]>())
                .Select(r => (JsonNode?)new JsonObject
                {
                    ["from"] = new JsonArray(r.Value.Select(f => (JsonNode?)f).ToArray()),
                    ["to"] = r.Key,
                }).ToArray()),
        };
        Load(root.ToJsonString());
    }

    /// Applies replacements, then term casing.
    public string Apply(string text)
    {
        lock (_gate)
        {
            ReloadIfNeeded();
            if (_rules.Count == 0 || text.Length == 0) return text;
            foreach (var rule in _rules)
            {
                text = rule.Regex.Replace(text, _ => rule.Replacement);
            }
            return text;
        }
    }

    /// Adds a "from -> to" replacement to the dictionary file (created if missing),
    /// joining an existing entry with the same "to". Throws — without writing — when the
    /// file exists but isn't valid JSON, so a half-edited dictionary is never clobbered.
    public static void AddReplacement(string from, string to, string path)
    {
        from = from.Trim();
        to = to.Trim();
        if (from.Length == 0 || to.Length == 0) return;
        var root = ReadRoot(path);
        var replacements = root["replacements"] as JsonArray ?? new JsonArray();
        var existing = replacements.OfType<JsonObject>().FirstOrDefault(r => StringValue(r["to"]) == to);
        if (existing != null)
        {
            var sources = Sources(existing);
            if (sources.Any(s => string.Equals(s, from, StringComparison.OrdinalIgnoreCase))) return;
            sources.Add(from);
            existing["from"] = new JsonArray(sources.Select(s => (JsonNode?)s).ToArray());
        }
        else
        {
            replacements.Add(new JsonObject { ["from"] = new JsonArray(from), ["to"] = to });
        }
        root["replacements"] = Detach(replacements);
        Write(root, path);
    }

    /// Adds term to "terms" (created if missing), deduplicated case-insensitively.
    /// Same never-clobber guarantee as AddReplacement.
    public static void AddTerm(string term, string path)
    {
        term = term.Trim();
        if (term.Length == 0) return;
        var root = ReadRoot(path);
        var terms = StringList(root["terms"]);
        if (terms.Any(t => string.Equals(t, term, StringComparison.OrdinalIgnoreCase))) return;
        terms.Add(term);
        root["terms"] = new JsonArray(terms.Select(t => (JsonNode?)t).ToArray());
        Write(root, path);
    }

    /// Removes term from "terms" (case-insensitive). Missing file or term is a no-op;
    /// an unparseable file is left alone.
    public static void RemoveTerm(string term, string path)
    {
        term = term.Trim();
        if (term.Length == 0 || !File.Exists(path)) return;
        var root = ReadRoot(path);
        var terms = StringList(root["terms"]);
        terms.RemoveAll(t => string.Equals(t, term, StringComparison.OrdinalIgnoreCase));
        root["terms"] = new JsonArray(terms.Select(t => (JsonNode?)t).ToArray());
        Write(root, path);
    }

    /// Removes "from" from the from-list of the rule mapping to "to"; when the list
    /// empties the whole rule is dropped. Same never-clobber guarantee.
    public static void RemoveReplacement(string from, string to, string path)
    {
        from = from.Trim();
        to = to.Trim();
        if (from.Length == 0 || to.Length == 0 || !File.Exists(path)) return;
        var root = ReadRoot(path);
        var replacements = root["replacements"] as JsonArray ?? new JsonArray();
        var existing = replacements.OfType<JsonObject>().FirstOrDefault(r => StringValue(r["to"]) == to);
        if (existing == null) return;
        var sources = Sources(existing);
        sources.RemoveAll(s => string.Equals(s, from, StringComparison.OrdinalIgnoreCase));
        if (sources.Count == 0)
            replacements.Remove(existing);
        else
            existing["from"] = new JsonArray(sources.Select(s => (JsonNode?)s).ToArray());
        root["replacements"] = Detach(replacements);
        Write(root, path);
    }

    /// The dictionary's replacements flattened to (from-phrases, to) pairs — empty when
    /// the file is missing or unparseable. Read-only.
    public static List<(string[] From, string To)> LoadPairs(string path)
    {
        try
        {
            var file = Parse(File.ReadAllText(path));
            return file.Replacements;
        }
        catch (Exception)
        {
            return new();
        }
    }

    /// The dictionary's terms — empty when the file is missing or unparseable.
    public static List<string> LoadTerms(string path)
    {
        try
        {
            return Parse(File.ReadAllText(path)).Terms;
        }
        catch (Exception)
        {
            return new();
        }
    }

    /// Reads the JSON object at path; missing file -> empty root, unparseable ->
    /// throws so callers never clobber a half-edited file.
    private static JsonObject ReadRoot(string path)
    {
        if (!File.Exists(path)) return new JsonObject();
        return JsonNode.Parse(File.ReadAllText(path)) as JsonObject
            ?? throw new InvalidDataException($"{path} is not a JSON object");
    }

    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// Pretty-printed with sorted keys (like the Mac app) and written atomically.
    private static void Write(JsonObject root, string path)
    {
        var json = SortKeys(root)!.ToJsonString(WriteOptions);
        AtomicFile.WriteAllText(path, json + "\n");
    }

    private static JsonNode? SortKeys(JsonNode? node) => node switch
    {
        JsonObject o => new JsonObject(o.OrderBy(p => p.Key, StringComparer.Ordinal)
            .Select(p => KeyValuePair.Create(p.Key, SortKeys(p.Value)))),
        JsonArray a => new JsonArray(a.Select(SortKeys).ToArray()),
        null => null,
        _ => JsonNode.Parse(node.ToJsonString()),
    };

    private static JsonArray Detach(JsonArray array) =>
        new(array.Select(n => n == null ? null : JsonNode.Parse(n.ToJsonString())).ToArray());

    private static string? StringValue(JsonNode? node) =>
        node is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    private static List<string> StringList(JsonNode? node) => node switch
    {
        JsonArray a => a.Select(StringValue).OfType<string>().ToList(),
        JsonValue => StringValue(node) is string s ? new List<string> { s } : new List<string>(),
        _ => new List<string>(),
    };

    private static List<string> Sources(JsonObject replacement) => StringList(replacement["from"]);

    // Loading (call with the lock held)

    private void ReloadIfNeeded()
    {
        if (_path == null) return;
        DateTime? stamp = File.Exists(_path) ? File.GetLastWriteTimeUtc(_path) : null;
        if (stamp == _loadedStamp) return;
        // Stamp only after a readable, decodable file: one failed read (a mid-save
        // atomic swap, a half-written edit) must not consume this version and leave
        // the dictionary empty until the file changes again.
        string text;
        try
        {
            text = File.ReadAllText(_path);
        }
        catch (Exception)
        {
            return;
        }
        if (Load(text)) _loadedStamp = stamp;
    }

    private sealed record DictionaryFile(List<string> Terms, List<(string[] From, string To)> Replacements);

    /// Decodes the file the way the Mac's Codable model does: "terms" and
    /// "replacements" are optional, "from" may be a string or a list, and any other
    /// shape (e.g. a replacement without "to") rejects the whole file.
    private static DictionaryFile Parse(string json)
    {
        var root = JsonNode.Parse(json) as JsonObject ?? throw new InvalidDataException("not an object");
        var terms = new List<string>();
        switch (root["terms"])
        {
            case null: break;
            case JsonArray a:
                terms.AddRange(a.Select(n => StringValue(n) ?? throw new InvalidDataException("term")));
                break;
            default: throw new InvalidDataException("terms");
        }
        var replacements = new List<(string[], string)>();
        switch (root["replacements"])
        {
            case null: break;
            case JsonArray a:
                foreach (var node in a)
                {
                    if (node is not JsonObject r) throw new InvalidDataException("replacement");
                    var to = StringValue(r["to"]) ?? throw new InvalidDataException("to");
                    var from = r["from"] switch
                    {
                        JsonArray list => list.Select(n => StringValue(n) ?? throw new InvalidDataException("from")).ToArray(),
                        JsonValue v when StringValue(v) is string s => new[] { s },
                        _ => throw new InvalidDataException("from"),
                    };
                    replacements.Add((from, to));
                }
                break;
            default: throw new InvalidDataException("replacements");
        }
        return new DictionaryFile(terms, replacements);
    }

    private bool Load(string json)
    {
        DictionaryFile file;
        try
        {
            file = Parse(json);
        }
        catch (Exception)
        {
            // Keep the last good version while the user is mid-edit.
            return false;
        }
        var cleanTerms = file.Terms.Select(t => t.Trim()).Where(t => t.Length > 0);

        var rules = new List<Rule>();
        // Longer phrases first so "chat g p t" wins over "chat".
        var pairs = file.Replacements
            .SelectMany(r => r.From.Select(f => (From: f.Trim(), r.To)))
            .Where(p => p.From.Length > 0)
            .OrderByDescending(p => p.From.Length);
        foreach (var (from, to) in pairs)
        {
            rules.Add(MakeRule(from, to));
        }
        // Casing fixes only matter for terms that aren't all-lowercase.
        foreach (var term in cleanTerms.Where(t => t != t.ToLowerInvariant()))
        {
            rules.Add(MakeRule(term, term));
        }
        _rules = rules;
        return true;
    }

    /// Whole-word, case-insensitive; internal spaces match any whitespace run.
    private static Rule MakeRule(string phrase, string replacement)
    {
        var words = phrase.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Select(Regex.Escape);
        var pattern = @"(?<![\p{L}\p{N}])" + string.Join(@"\s+", words) + @"(?![\p{L}\p{N}])";
        return new Rule(new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), replacement);
    }
}
