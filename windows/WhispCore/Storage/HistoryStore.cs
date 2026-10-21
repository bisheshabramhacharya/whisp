using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Whisp.Core;

/// One completed dictation, persisted as a JSONL line. Same fields and date format as
/// the Mac's HistoryEntry, so history.jsonl moves between the two unchanged.
public sealed record HistoryEntry(
    /// UUID; also the basename of the optional WAV in recordings\.
    string Id,
    /// When the recording started.
    DateTimeOffset Date,
    double DurationSec,
    /// Raw model output before cleanup.
    string Raw,
    /// Text that was pasted.
    string Cleaned,
    /// Key release -> paste finished, in milliseconds.
    int LatencyMs);

/// Append-only JSONL history.
public sealed class HistoryStore
{
    private const long TailReadLimit = 512 * 1024;
    private readonly object _gate = new();

    public string FilePath { get; }

    public HistoryStore(string filePath)
    {
        FilePath = filePath;
    }

    private sealed class Line
    {
        [JsonPropertyName("id")] public string? Id { get; set; }
        [JsonPropertyName("date")] public string? Date { get; set; }
        [JsonPropertyName("durationSec")] public double DurationSec { get; set; }
        [JsonPropertyName("raw")] public string? Raw { get; set; }
        [JsonPropertyName("cleaned")] public string? Cleaned { get; set; }
        [JsonPropertyName("latencyMs")] public int LatencyMs { get; set; }
    }

    private static readonly JsonSerializerOptions Options = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static string Encode(HistoryEntry e) => JsonSerializer.Serialize(new Line
    {
        Id = e.Id,
        // ISO 8601 in UTC without fractional seconds, like Swift's .iso8601 strategy.
        Date = e.Date.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
        DurationSec = e.DurationSec,
        Raw = e.Raw,
        Cleaned = e.Cleaned,
        LatencyMs = e.LatencyMs,
    }, Options);

    public static HistoryEntry? Decode(string line)
    {
        try
        {
            var l = JsonSerializer.Deserialize<Line>(line, Options);
            if (l?.Id == null || l.Date == null || l.Raw == null || l.Cleaned == null) return null;
            if (!DateTimeOffset.TryParse(l.Date, CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var date)) return null;
            return new HistoryEntry(l.Id, date, l.DurationSec, l.Raw, l.Cleaned, l.LatencyMs);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// Appends one entry as a single JSON line. Creates the file if needed.
    public void Append(HistoryEntry entry)
    {
        lock (_gate)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.AppendAllText(FilePath, Encode(entry) + "\n", new UTF8Encoding(false));
        }
    }

    /// Returns the most recent count entries, newest first. Reads only the tail of
    /// the file, so it stays fast as history grows.
    public List<HistoryEntry> LoadLast(int count)
    {
        if (count <= 0) return new();
        string text;
        long offset;
        try
        {
            using var stream = new FileStream(FilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length == 0) return new();
            var readSize = Math.Min(stream.Length, TailReadLimit);
            offset = stream.Length - readSize;
            stream.Seek(offset, SeekOrigin.Begin);
            var buffer = new byte[readSize];
            stream.ReadExactly(buffer);
            text = Encoding.UTF8.GetString(buffer);
        }
        catch (IOException)
        {
            return new();
        }
        catch (UnauthorizedAccessException)
        {
            return new();
        }
        if (offset > 0 && text.IndexOf('\n') is var nl and >= 0)
        {
            // First line is likely truncated by the tail read — drop it.
            text = text[(nl + 1)..];
        }
        return text.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .TakeLast(count)
            .Reverse()
            .Select(Decode)
            .OfType<HistoryEntry>()
            .ToList();
    }

    /// Every entry, oldest first (import/merge).
    public List<HistoryEntry> LoadAll()
    {
        if (!File.Exists(FilePath)) return new();
        return File.ReadAllLines(FilePath).Select(Decode).OfType<HistoryEntry>().ToList();
    }

    /// Adds entries whose id isn't already present, keeping the file in date order.
    /// Returns how many were added.
    public int Merge(IEnumerable<HistoryEntry> incoming)
    {
        lock (_gate)
        {
            var existing = LoadAll();
            var ids = existing.Select(e => e.Id).ToHashSet();
            var added = incoming.Where(e => ids.Add(e.Id)).ToList();
            if (added.Count == 0) return 0;
            var merged = existing.Concat(added).OrderBy(e => e.Date).Select(Encode);
            AtomicFile.WriteAllText(FilePath, string.Join("\n", merged) + "\n");
            return added.Count;
        }
    }
}
