using Whisp.Core;
using Whisp.Core.Text;

static class DailyDataTests
{
    public static void Run(string root, Action<bool, string> expect)
    {
        var shared = Path.Combine(root, "shared");
        Directory.CreateDirectory(shared);
        try
        {
            var aFile = Path.Combine(root, "a.json");
            var a = new DailyDataStore(aFile);
            var b = new DailyDataStore(Path.Combine(root, "b.json"));
            var legacyFile = Path.Combine(root, "legacy.jsonl");
            var history = new HistoryStore(legacyFile, a);
            var remoteHistory = new HistoryStore(Path.Combine(root, "remote.jsonl"), b);
            var dictionary = new DailyDictionary(a);
            var remoteDictionary = new DailyDictionary(b);
            new HistoryStore(legacyFile).Append(new HistoryEntry("take", DateTimeOffset.FromUnixTimeSeconds(1700000000),
                1, "original phrase", "Original", 4));
            history.ImportLegacy();
            a.Update(new DailyDataStore.Change("local", "microphone", "A mic"));
            dictionary.Save("cube", "Kubernetes");
            a.Sync(shared);
            b.Sync(shared);
            expect(remoteHistory.Search("PHRASE").Count == 1, "search checks raw and ignores case");
            expect(b.Records("local").Length == 0, "mic selection isn't synced");
            history.Edit("take", "Edit A");
            remoteHistory.Edit("take", "Edit B");
            var expected = string.CompareOrdinal(a.Records("history")[0].Operation, b.Records("history")[0].Operation) > 0
                ? "Edit A" : "Edit B";
            var id = dictionary.Records()[0].Id;
            dictionary.Save("cube", "K8s", id);
            remoteDictionary.Remove(id);
            remoteDictionary.Save("pike", "Pyke");
            a.Sync(shared);
            b.Sync(shared);
            a.Sync(shared);
            expect(history.Search(expected).Count == 1 && remoteHistory.Search(expected).Count == 1, "concurrent history edits converge");
            expect(dictionary.Records().Select(r => r.Value).SequenceEqual(new[] { "pike" }),
                "concurrent delete wins and unrelated addition survives");
            expect(new PersonalDictionary(dictionary).Apply("Use pike") == "Use Pyke", "synced dictionary reaches cleaner");
            history.ImportLegacy();
            expect(history.Search(expected).Count == 1, "legacy seed doesn't overwrite edited text");
            expect(new DailyDataStore(aFile).Records("dictionary", true).Any(r => r.Id == id && r.Deleted),
                "tombstone survives relaunch");
            var folder = Path.Combine(shared, "Whisp Sync v1");
            const string operation = "ab91ac9a-6b9f-4958-bf20-a5ea51ee7210";
            var partial = Path.Combine(folder, operation + ".json");
            File.WriteAllText(partial, "{");
            File.WriteAllText(Path.Combine(folder, "ignored.tmp"), "{");
            expect(a.Sync(shared) == 1, "partial operation is reported without blocking other records");
            AtomicFile.WriteAllText(partial, $$$"""
                {"version":1,"record":{"kind":"dictionary","id":"fixture","revision":1,"operation":"{{{operation}}}","deleted":false,"value":"naïve","detail":"Naïve"}}
                """);
            expect(a.Sync(shared) == 0 && dictionary.Records("NAÏVE").Length == 1,
                "corrected file is retried with shared v1 envelope");
            var pike = dictionary.Records("pike")[0];
            dictionary.Save("pike", "New Pyke", pike.Id);
            dictionary.Save("pike", "Pyke");
            expect(dictionary.Records("pike").Length == 2, "re-adding the original rule preserves the edited record");
            history.Append(new HistoryEntry("new", DateTimeOffset.UtcNow, 2, "new", "New", 4));
            expect(new HistoryStore(legacyFile).LoadLast(1).FirstOrDefault()?.Id == "new",
                "legacy recording history still contains local dictations");
        }
        catch (Exception e) { expect(false, $"daily data test threw: {e}"); }
        finally { Directory.Delete(root, recursive: true); }
    }
}
