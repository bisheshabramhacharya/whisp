using System.Text.Json;
using System.Text.Json.Serialization;

namespace Whisp.Core;

public sealed class DailyDataStore(string file)
{
    public sealed record Record(
        [property: JsonRequired] string Kind,
        [property: JsonRequired] string Id,
        [property: JsonRequired] long Revision,
        [property: JsonRequired] string Operation,
        [property: JsonRequired] bool Deleted,
        [property: JsonRequired] string Value,
        [property: JsonRequired] string Detail);

    public sealed record Change(string Kind, string Id, string Value = "", string Detail = "", bool Deleted = false);

    private sealed record Snapshot([property: JsonRequired] int Version, [property: JsonRequired] Record[] Records);
    private sealed record Envelope([property: JsonRequired] int Version, [property: JsonRequired] Record Record);

    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private readonly object _gate = new();
    private readonly object _syncGate = new();
    private Dictionary<(string Kind, string Id), Record>? _state;
    private readonly HashSet<string> _seenFiles = new(StringComparer.Ordinal);
    private string? _syncPath;

    public static string NewId() => Guid.NewGuid().ToString("D");

    public Record[] Records(string kind, bool includingDeleted = false)
    {
        lock (_gate)
            return Load().Values.Where(r => r.Kind == kind && (includingDeleted || !r.Deleted))
                .OrderBy(r => r.Id, StringComparer.Ordinal).ToArray();
    }

    public void Seed(IEnumerable<Change> changes) => Update(changes, true);
    public void Update(params Change[] changes) => Update(changes, false);

    private void Update(IEnumerable<Change> changes, bool onlyMissing)
    {
        lock (_gate)
        {
            var next = new Dictionary<(string Kind, string Id), Record>(Load());
            var changed = false;
            foreach (var c in changes)
            {
                var key = (c.Kind, c.Id);
                next.TryGetValue(key, out var old);
                if (onlyMissing && old != null) continue;
                var value = c.Deleted ? "" : c.Value;
                var detail = c.Deleted ? "" : c.Detail;
                if (old != null && old.Value == value && old.Detail == detail && old.Deleted == c.Deleted) continue;
                var revision = onlyMissing ? 0 : checked((old?.Revision ?? 0) + 1);
                next[key] = new Record(c.Kind, c.Id, revision, NewId(), c.Deleted, value, detail);
                changed = true;
            }
            if (changed) Save(next);
        }
    }

    public int Sync(string folder)
    {
        lock (_syncGate)
        {
            if (!Directory.Exists(folder)) throw new DirectoryNotFoundException(folder);
            var root = Path.Combine(Path.GetFullPath(folder), "Whisp Sync v1");
            Directory.CreateDirectory(root);
            if (new DirectoryInfo(root).LinkTarget != null)
                throw new IOException("Sync data directory is a link.");
            if (_syncPath != root)
            {
                _seenFiles.Clear();
                _syncPath = root;
            }
            var accepted = new HashSet<string>(StringComparer.Ordinal);
            var valid = new Dictionary<string, Record>(StringComparer.Ordinal);
            var unreadable = 0;
            foreach (var path in Directory.EnumerateFiles(root, "*.json"))
            {
                if (Path.GetExtension(path) != ".json") continue;
                var operation = Path.GetFileNameWithoutExtension(path);
                if (!ValidOperation(operation)) continue;
                accepted.Add(operation);
                if (_seenFiles.Contains(operation)) continue;
                try
                {
                    if (new FileInfo(path).LinkTarget != null)
                        throw new IOException("Sync record is a link.");
                    var envelope = JsonSerializer.Deserialize<Envelope>(File.ReadAllText(path), Json);
                    if (envelope is not { Version: 1, Record: { } r } || r.Operation != operation ||
                        !Portable(r.Kind) || !Valid(r))
                        throw new JsonException("Invalid sync record.");
                    valid.Add(operation, r);
                }
                catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
                {
                    unreadable++;
                }
            }
            Record[] winners;
            lock (_gate)
            {
                var next = new Dictionary<(string Kind, string Id), Record>(Load());
                var changed = false;
                foreach (var r in valid.Values) changed |= Merge(r, next);
                if (changed) Save(next);
                winners = next.Values.Where(r => Portable(r.Kind)).ToArray();
            }
            _seenFiles.IntersectWith(accepted);
            _seenFiles.UnionWith(valid.Keys);
            foreach (var r in winners)
            {
                if (accepted.Contains(r.Operation)) continue;
                AtomicFile.WriteAllText(Path.Combine(root, r.Operation + ".json"),
                    JsonSerializer.Serialize(new Envelope(1, r), Json));
                _seenFiles.Add(r.Operation);
            }
            return unreadable;
        }
    }

    private Dictionary<(string Kind, string Id), Record> Load()
    {
        if (_state != null) return _state;
        var next = new Dictionary<(string Kind, string Id), Record>();
        if (File.Exists(file))
        {
            var snapshot = JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(file), Json);
            if (snapshot is not { Version: 1, Records: { } records } || records.Any(r => !Valid(r)))
                throw new InvalidDataException("Invalid Whisp daily data.");
            foreach (var r in records) Merge(r, next);
        }
        return _state = next;
    }

    private void Save(Dictionary<(string Kind, string Id), Record> next)
    {
        AtomicFile.WriteAllText(file, JsonSerializer.Serialize(new Snapshot(1, next.Values.ToArray()), Json));
        _state = next;
    }

    private static bool Merge(Record r, Dictionary<(string Kind, string Id), Record> into)
    {
        var key = (r.Kind, r.Id);
        if (into.TryGetValue(key, out var old))
        {
            if (old.Revision > r.Revision) return false;
            if (old.Revision == r.Revision &&
                (old.Deleted != r.Deleted ? old.Deleted : string.CompareOrdinal(old.Operation, r.Operation) >= 0))
                return false;
        }
        into[key] = r;
        return true;
    }

    private static bool Portable(string kind) => kind is "history" or "dictionary";

    private static bool ValidOperation(string value) =>
        Guid.TryParseExact(value, "D", out var id) && id.ToString("D") == value;

    private static bool Valid(Record? r)
    {
        if (r is not { Kind.Length: > 0, Id.Length: > 0, Value: not null, Detail: not null } ||
            r.Revision < 0 || !ValidOperation(r.Operation)) return false;
        if (r.Deleted) return r.Value == "" && r.Detail == "";
        return r.Kind switch
        {
            "history" => r.Detail == "" && HistoryStore.Decode(r.Value)?.Id == r.Id,
            "dictionary" => !string.IsNullOrWhiteSpace(r.Value),
            _ => true,
        };
    }
}
