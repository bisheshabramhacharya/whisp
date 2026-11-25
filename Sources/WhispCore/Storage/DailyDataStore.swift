import Foundation

/// Local record store and account-free transport. The wire format is documented in docs/daily-data-sync.md.
public final class DailyDataStore: @unchecked Sendable {
    public struct Record: Codable, Sendable, Equatable {
        public let kind: String
        public let id: String
        public let revision: Int64
        public let operation: String
        public let deleted: Bool
        public let value: String
        public let detail: String
    }

    public struct Change {
        public let kind: String
        public let id: String
        public let value: String
        public let detail: String
        public let deleted: Bool

        public init(_ kind: String, _ id: String, _ value: String = "", detail: String = "", deleted: Bool = false) {
            self.kind = kind
            self.id = id
            self.value = value
            self.detail = detail
            self.deleted = deleted
        }
    }

    private struct Snapshot: Codable {
        let version: Int
        let records: [Record]
    }

    private struct Envelope: Codable {
        let version: Int
        let record: Record
    }

    private struct Key: Hashable {
        let kind: String
        let id: String
        init(_ kind: String, _ id: String) { self.kind = kind; self.id = id }
    }

    private let file: URL
    private let lock = NSLock()
    private let syncLock = NSLock()
    private var state: [Key: Record]?
    private var seenFiles = Set<String>()
    private var syncPath: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(file: URL) { self.file = file }

    public static func newID() -> String { UUID().uuidString.lowercased() }

    public func records(_ kind: String, includingDeleted: Bool = false) throws -> [Record] {
        try lock.withLock {
            try load().values.filter { $0.kind == kind && (includingDeleted || !$0.deleted) }
                .sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
        }
    }

    /// Seed existing data only when there is no recorded revision, even if the latest revision is a tombstone.
    public func seed(_ changes: [Change]) throws {
        try update(changes, onlyMissing: true)
    }

    public func update(_ changes: [Change]) throws {
        try update(changes, onlyMissing: false)
    }

    private func update(_ changes: [Change], onlyMissing: Bool) throws {
        try lock.withLock {
            let old = try load()
            var next = old
            for change in changes {
                let key = Key(change.kind, change.id)
                let existing = next[key]
                if onlyMissing, existing != nil { continue }
                let value = change.deleted ? "" : change.value
                let detail = change.deleted ? "" : change.detail
                if let existing, existing.value == value, existing.detail == detail,
                   existing.deleted == change.deleted { continue }
                let revision = existing?.revision ?? 0
                guard revision < Int64.max else { throw CocoaError(.fileWriteUnknown) }
                next[key] = Record(kind: key.kind, id: key.id, revision: onlyMissing ? 0 : revision + 1,
                                   operation: Self.newID(), deleted: change.deleted, value: value, detail: detail)
            }
            if old != next { try save(next) }
        }
    }

    /// Merge then exchange winning records. Invalid files are left alone and retried next time.
    @discardableResult
    public func sync(with folder: URL) throws -> Int {
        try syncLock.withLock {
            let root = folder.appendingPathComponent("Whisp Sync v1", isDirectory: true)
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CocoaError(.fileNoSuchFile)
            }
            let fm = FileManager.default
            do { try fm.createDirectory(at: root, withIntermediateDirectories: false) }
            catch let error as CocoaError where error.code == .fileWriteFileExists {}
            let attributes = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if syncPath != root { seenFiles.removeAll(); syncPath = root }
            var accepted = Set<String>()
            var validFiles: [String: Record] = [:]
            var unreadable = 0
            for file in files {
                let name = file.lastPathComponent
                let operation = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "json", Self.valid(operation) else { continue }
                accepted.insert(name)
                if seenFiles.contains(name) { continue }
                guard let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      properties.isRegularFile == true, properties.isSymbolicLink != true,
                      let bytes = try? Data(contentsOf: file),
                      let envelope = try? JSONDecoder().decode(Envelope.self, from: bytes),
                      envelope.version == 1, envelope.record.operation == operation,
                      Self.portable(envelope.record.kind), Self.valid(envelope.record) else {
                    unreadable += 1
                    continue
                }
                validFiles[name] = envelope.record
            }
            let winners = try lock.withLock {
                let old = try load()
                var next = old
                for record in validFiles.values { Self.merge(record, into: &next) }
                if old != next { try save(next) }
                return next.values.filter { Self.portable($0.kind) }
            }
            // Do not cache arrival until its merged state is safely saved.
            seenFiles.formIntersection(accepted)
            seenFiles.formUnion(validFiles.keys)
            let wireEncoder = JSONEncoder()
            for record in winners {
                let name = record.operation + ".json"
                if accepted.contains(name) { continue }
                let destination = root.appendingPathComponent(name)
                try wireEncoder.encode(Envelope(version: 1, record: record)).write(to: destination, options: .atomic)
                seenFiles.insert(name)
            }
            return unreadable
        }
    }

    private func load() throws -> [Key: Record] {
        if let state { return state }
        var next: [Key: Record] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: file))
            guard snapshot.version == 1, snapshot.records.allSatisfy(Self.valid) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for record in snapshot.records { Self.merge(record, into: &next) }
        }
        state = next
        return next
    }

    private func save(_ next: [Key: Record]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Snapshot(version: 1, records: Array(next.values))).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        state = next
    }

    private static func merge(_ record: Record, into state: inout [Key: Record]) {
        let key = Key(record.kind, record.id)
        if let old = state[key] {
            if old.revision > record.revision { return }
            if old.revision == record.revision {
                if old.deleted != record.deleted {
                    if old.deleted { return }
                } else if old.operation >= record.operation { return }
            }
        }
        state[key] = record
    }

    private static func portable(_ kind: String) -> Bool { kind == "history" || kind == "dictionary" }

    private static func valid(_ operation: String) -> Bool {
        UUID(uuidString: operation)?.uuidString.lowercased() == operation
    }

    private static func valid(_ record: Record) -> Bool {
        guard !record.kind.isEmpty, !record.id.isEmpty, record.revision >= 0, valid(record.operation) else { return false }
        if record.deleted { return record.value.isEmpty && record.detail.isEmpty }
        switch record.kind {
        case "history":
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entry = try? decoder.decode(HistoryEntry.self, from: Data(record.value.utf8))
            return entry?.id == record.id && record.detail.isEmpty
        case "dictionary":
            return !record.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }
}
