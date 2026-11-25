import Foundation

public enum DailyDataExport {
    public static func write(from store: DailyDataStore, to folder: URL) throws {
        let history = try store.records("history").map(\.value).joined(separator: "\n")
        let words = try store.records("dictionary")
        let dictionary: [String: Any] = [
            "terms": words.filter { $0.detail.isEmpty }.map(\.value),
            "replacements": words.filter { !$0.detail.isEmpty }.map { ["from": [$0.value], "to": $0.detail] },
        ]
        let file = folder.appendingPathComponent("history.jsonl")
        try Data((history.isEmpty ? history : history + "\n").utf8).write(to: file, options: .atomic)
        let dictionaryFile = folder.appendingPathComponent("dictionary.json")
        try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
            .write(to: dictionaryFile, options: .atomic)
        AppPaths.makeUserOnly(file)
        AppPaths.makeUserOnly(dictionaryFile)
    }
}
