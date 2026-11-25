import Foundation

public struct DailyDictionary: Sendable {
    public static let kind = "dictionary"
    public let store: DailyDataStore

    public init(store: DailyDataStore) { self.store = store }

    public func records(matching search: String = "") throws -> [DailyDataStore.Record] {
        try store.records(Self.kind).filter {
            search.isEmpty || $0.value.localizedCaseInsensitiveContains(search)
                || $0.detail.localizedCaseInsensitiveContains(search)
        }.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }

    public func pairs() throws -> [(from: [String], to: String)] {
        try records().filter { !$0.detail.isEmpty }.map { ([$0.value], $0.detail) }
    }

    @discardableResult
    public func save(id: String? = nil, from: String, to: String = "") throws -> Bool {
        let from = Self.trim(from), to = Self.trim(to)
        guard !from.isEmpty else { return false }
        let current = try records()
        guard !current.contains(where: {
            $0.id != id && $0.value.caseInsensitiveCompare(from) == .orderedSame && $0.detail == to
        }) else { return false }
        let key = Self.key(from, to)
        let target = id ?? (current.contains(where: { $0.id == key }) ? DailyDataStore.newID() : key)
        try store.update([.init(Self.kind, target, from, detail: to)])
        return true
    }

    public func remove(id: String) throws {
        try store.update([.init(Self.kind, id, deleted: true)])
    }

    public func remove(from: String, to: String = "") throws {
        if let match = try records().first(where: {
            $0.value.caseInsensitiveCompare(Self.trim(from)) == .orderedSame && $0.detail == Self.trim(to)
        }) { try remove(id: match.id) }
    }

    public func importLegacy(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let dictionary = try JSONDecoder().decode(PersonalDictionary.File.self, from: Data(contentsOf: file))
        let words = (dictionary.terms ?? []).map { ($0, "") }
            + (dictionary.replacements ?? []).flatMap { pair in pair.from.map { ($0, pair.to) } }
        try store.seed(words.compactMap { from, to in
            let from = Self.trim(from), to = Self.trim(to)
            return from.isEmpty ? nil : .init(Self.kind, Self.key(from, to), from, detail: to)
        })
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func key(_ from: String, _ to: String) -> String {
        let source = from.lowercased()
        return "\(source.utf8.count):\(source)\(to)"
    }
}
