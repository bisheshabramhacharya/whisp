import Foundation
import WhispCore

func checkDailyData(_ expect: (Bool, String) -> Void) {
    do {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(DailyDataStore.newID())
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let aFile = root.appendingPathComponent("a.json")
        let a = DailyDataStore(file: aFile)
        let b = DailyDataStore(file: root.appendingPathComponent("b.json"))
        let history = HistoryStore(fileURL: root.appendingPathComponent("legacy.jsonl"), daily: a)
        let remoteHistory = HistoryStore(fileURL: root.appendingPathComponent("remote.jsonl"), daily: b)
        let dictionary = DailyDictionary(store: a)
        let remoteDictionary = DailyDictionary(store: b)
        let legacy = HistoryStore(fileURL: history.fileURL)
        let entry = HistoryEntry(id: "take", date: Date(timeIntervalSince1970: 1_700_000_000),
                                 durationSec: 1, raw: "original phrase", cleaned: "Original", latencyMs: 4)
        try legacy.append(entry)
        try history.importLegacy()
        try a.update([.init("local", "microphone", "A mic")])
        try dictionary.save(from: "cube", to: "Kubernetes")
        try a.sync(with: shared)
        try b.sync(with: shared)
        expect(try remoteHistory.search("PHRASE").count == 1, "search checks raw and ignores case")
        expect(try b.records("local").isEmpty, "mic selection isn't synced")
        try history.edit(id: "take", text: "Edit A")
        try remoteHistory.edit(id: "take", text: "Edit B")
        let aEdit = try a.records("history")[0], bEdit = try b.records("history")[0]
        let expected = aEdit.operation > bEdit.operation ? "Edit A" : "Edit B"
        let id = try dictionary.records()[0].id
        try dictionary.save(id: id, from: "cube", to: "K8s")
        try remoteDictionary.remove(id: id)
        try remoteDictionary.save(from: "pike", to: "Pyke")
        try a.sync(with: shared)
        try b.sync(with: shared)
        try a.sync(with: shared)
        expect(try history.search(expected).count == 1 && remoteHistory.search(expected).count == 1, "concurrent history edits converge")
        expect(try dictionary.records().map(\.value) == ["pike"], "concurrent delete wins and unrelated addition survives")
        expect(PersonalDictionary(daily: dictionary).apply("Use pike") == "Use Pyke", "synced dictionary reaches cleaner")
        try history.importLegacy()
        expect(try history.search(expected).count == 1, "legacy seed doesn't overwrite edited text")
        let restarted = DailyDataStore(file: aFile)
        expect(try restarted.records("dictionary", includingDeleted: true).contains(where: { $0.id == id && $0.deleted }),
               "tombstone survives relaunch")
        let folder = shared.appendingPathComponent("Whisp Sync v1")
        let operation = "ab91ac9a-6b9f-4958-bf20-a5ea51ee7210"
        let partial = folder.appendingPathComponent(operation + ".json")
        try Data("{".utf8).write(to: partial)
        try Data("{".utf8).write(to: folder.appendingPathComponent("ignored.tmp"))
        expect(try a.sync(with: shared) == 1, "partial sync operation is reported without blocking other records")
        let envelope = """
        {"version":1,"record":{"kind":"dictionary","id":"fixture","revision":1,"operation":"\(operation)","deleted":false,"value":"naïve","detail":"Naïve"}}
        """
        try Data(envelope.utf8).write(to: partial, options: .atomic)
        expect(try a.sync(with: shared) == 0 && dictionary.records(matching: "NAÏVE").count == 1,
               "corrected file is retried with shared v1 envelope")
        let exported = root.appendingPathComponent("exported")
        try fm.createDirectory(at: exported, withIntermediateDirectories: false)
        try DailyDataExport.write(from: a, to: exported)
        let exportedHistory = HistoryStore(fileURL: exported.appendingPathComponent("history.jsonl"))
        let exportedDictionary = PersonalDictionary(fileURL: exported.appendingPathComponent("dictionary.json"))
        expect(exportedHistory.loadLast(1).first?.cleaned == expected, "Mac export contains edited history")
        expect(exportedDictionary.apply("pike cube") == "Pyke cube", "Mac export contains active dictionary only")
        let pike = try dictionary.records(matching: "pike")[0]
        try dictionary.save(id: pike.id, from: "pike", to: "New Pyke")
        try dictionary.save(from: "pike", to: "Pyke")
        expect(try dictionary.records(matching: "pike").count == 2, "re-adding the original rule preserves the edited record")
        try history.append(HistoryEntry(id: "new", date: Date(), durationSec: 2, raw: "new", cleaned: "New", latencyMs: 4))
        expect(legacy.loadLast(1).first?.id == "new", "recording analysis can still read original local dictations")
    } catch {
        expect(false, "daily data test threw: \(error)")
    }
}
