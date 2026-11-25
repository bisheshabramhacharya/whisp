using System.Globalization;
using System.Text;
using Whisp.Core.Text;

namespace Whisp.Core;

public sealed class DailyDictionary(DailyDataStore store)
{
    private const string Kind = "dictionary";

    public DailyDataStore.Record[] Records(string query = "") => store.Records(Kind)
        .Where(r => r.Value.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                    r.Detail.Contains(query, StringComparison.OrdinalIgnoreCase))
        .OrderBy(r => r.Value, StringComparer.CurrentCultureIgnoreCase).ToArray();

    public bool Save(string from, string to = "", string? id = null)
    {
        from = from.Trim();
        to = to.Trim();
        var current = Records();
        if (from.Length == 0 || current.Any(r => r.Id != id &&
                r.Value.Equals(from, StringComparison.OrdinalIgnoreCase) && r.Detail == to)) return false;
        var key = Key(from, to);
        var target = id ?? (current.Any(r => r.Id == key) ? DailyDataStore.NewId() : key);
        store.Update(new DailyDataStore.Change(Kind, target, from, to));
        return true;
    }

    public void Remove(string id) => store.Update(new DailyDataStore.Change(Kind, id, Deleted: true));

    public void ImportLegacy(string path)
    {
        if (!File.Exists(path)) return;
        var words = PersonalDictionary.LoadTerms(path).Select(term => (From: term, To: ""))
            .Concat(PersonalDictionary.LoadPairs(path).SelectMany(p => p.From.Select(f => (From: f, p.To))));
        store.Seed(words.Select(p => (From: p.From.Trim(), To: p.To.Trim())).Where(p => p.From.Length != 0)
            .Select(p => new DailyDataStore.Change(Kind, Key(p.From, p.To), p.From, p.To)));
    }

    private static string Key(string from, string to)
    {
        var source = from.ToLowerInvariant();
        return Encoding.UTF8.GetByteCount(source).ToString(CultureInfo.InvariantCulture) + ":" + source + to;
    }
}
