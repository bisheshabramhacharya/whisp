import Foundation

/// User-editable word list at `dictionary.json`:
///
///     {
///       "terms": ["Vinted", "Poshmark"],
///       "replacements": [{"from": ["chat gpt", "chat g p t"], "to": "ChatGPT"}]
///     }
///
/// - `terms` fix casing of whole-word matches ("vinted" -> "Vinted").
/// - `replacements` swap whole-word/phrase matches (case-insensitive) for `to`.
///
/// The file is re-read automatically when its modification date changes, so edits
/// apply to the next dictation without restarting. Thread-safe.
public final class PersonalDictionary: @unchecked Sendable {

    struct Replacement: Decodable {
        let from: [String]
        let to: String

        private enum CodingKeys: String, CodingKey { case from, to }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            to = try c.decode(String.self, forKey: .to)
            if let list = try? c.decode([String].self, forKey: .from) {
                from = list
            } else {
                from = [try c.decode(String.self, forKey: .from)]
            }
        }
    }

    struct File: Decodable {
        var terms: [String]?
        var replacements: [Replacement]?
    }

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var loadedModificationDate: Date?
    private var rules: [Rule] = []

    /// Loads from `fileURL`; a missing or malformed file is treated as empty.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// In-memory dictionary (tests).
    public init(terms: [String], replacements: [String: [String]] = [:]) {
        self.fileURL = nil
        let json: [String: Any] = [
            "terms": terms,
            "replacements": replacements.map { ["from": $0.value, "to": $0.key] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            load(data)
        }
    }

    /// Applies replacements, then term casing.
    public func apply(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        reloadIfNeeded()
        guard !rules.isEmpty, !text.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for rule in rules {
            rule.regex.replaceMatches(
                in: result, range: NSRange(location: 0, length: result.length),
                withTemplate: rule.template)
        }
        return result as String
    }

    /// Adds a "`from` -> `to`" replacement to the dictionary file (created if missing),
    /// joining an existing entry with the same `to`. Throws — without writing — when the
    /// file exists but isn't valid JSON, so a half-edited dictionary is never clobbered.
    public static func addReplacement(from: String, to: String, fileURL: URL) throws {
        let from = trim(from), to = trim(to)
        guard !from.isEmpty, !to.isEmpty else { return }
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            root = object
        }
        var replacements = root["replacements"] as? [[String: Any]] ?? []
        if let i = replacements.firstIndex(where: { ($0["to"] as? String) == to }) {
            var sources = replacements[i]["from"] as? [String] ?? (replacements[i]["from"] as? String).map { [$0] } ?? []
            guard !sources.contains(where: { $0.caseInsensitiveCompare(from) == .orderedSame }) else { return }
            sources.append(from)
            replacements[i]["from"] = sources
        } else {
            replacements.append(["from": [from], "to": to])
        }
        root["replacements"] = replacements
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Loading (call with lock held)

    private func reloadIfNeeded() {
        guard let fileURL else { return }
        let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        guard modified != loadedModificationDate else { return }
        loadedModificationDate = modified
        if let data = try? Data(contentsOf: fileURL) {
            load(data)
        } else {
            rules = []
        }
    }

    private func load(_ data: Data) {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            // Keep the last good version while the user is mid-edit.
            return
        }
        let cleanTerms = (file.terms ?? []).map(Self.trim).filter { !$0.isEmpty }
        let replacements = file.replacements ?? []

        var newRules: [Rule] = []
        // Longer phrases first so "chat g p t" wins over "chat".
        let pairs = replacements
            .flatMap { r in r.from.map { (Self.trim($0), r.to) } }
            .filter { !$0.0.isEmpty }
            .sorted { $0.0.count > $1.0.count }
        for (from, to) in pairs {
            if let rule = Self.rule(matching: from, replaceWith: to) { newRules.append(rule) }
        }
        // Casing fixes only matter for terms that aren't all-lowercase.
        for term in cleanTerms where term != term.lowercased() {
            if let rule = Self.rule(matching: term, replaceWith: term) { newRules.append(rule) }
        }
        rules = newRules
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whole-word, case-insensitive; internal spaces match any whitespace run.
    private static func rule(matching phrase: String, replaceWith replacement: String) -> Rule? {
        let words = phrase.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return Rule(regex: regex, template: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
