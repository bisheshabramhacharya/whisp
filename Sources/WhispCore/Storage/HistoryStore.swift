import Foundation

/// One completed dictation, persisted as a JSONL line.
public struct HistoryEntry: Codable, Sendable, Identifiable {
    /// UUID; also the basename of the optional WAV in recordings/.
    public var id: String
    /// When the recording started.
    public var date: Date
    public var durationSec: Double
    /// Raw model output before cleanup.
    public var raw: String
    /// Text that was pasted.
    public var cleaned: String
    /// Key release -> paste finished, in milliseconds.
    public var latencyMs: Int

    public init(id: String, date: Date, durationSec: Double, raw: String, cleaned: String, latencyMs: Int) {
        self.id = id
        self.date = date
        self.durationSec = durationSec
        self.raw = raw
        self.cleaned = cleaned
        self.latencyMs = latencyMs
    }
}

/// Append-only JSONL history at AppPaths.historyFile.
/// Appends run on one serial queue (DictationController's persistence queue); reads
/// run on the main thread. They share no mutable state — the encoder is only used by
/// appends, the decoder only by reads — and a read racing an append just drops the
/// half-written last line.
public final class HistoryStore: @unchecked Sendable {

    public let fileURL: URL

    /// How far back from EOF `loadLast` reads. ~512 KB covers thousands of entries.
    private let tailReadLimit: UInt64 = 512 * 1024

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(fileURL: URL = AppPaths.historyFile) {
        self.fileURL = fileURL
    }

    /// Appends one entry as a single JSON line. Creates the file if needed.
    public func append(_ entry: HistoryEntry) throws {
        var line = try encoder.encode(entry)
        line.append(0x0A) // \n

        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: fileURL, options: .atomic)
            return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// Returns the most recent `count` entries, newest first.
    /// Reads only the tail of the file, so it stays fast as history grows.
    public func loadLast(_ count: Int) -> [HistoryEntry] {
        guard count > 0,
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return [] }
        let readSize = min(fileSize, tailReadLimit)
        let offset = fileSize - readSize

        guard let _ = try? handle.seek(toOffset: offset),
              let data = try? handle.readToEnd() else { return [] }

        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let nl = text.firstIndex(of: "\n") {
            // First line is likely truncated by the tail read — drop it.
            text = String(text[text.index(after: nl)...])
        }

        let lines = text.split(separator: "\n").suffix(count)
        return lines.reversed().compactMap { line in
            try? decoder.decode(HistoryEntry.self, from: Data(line.utf8))
        }
    }
}
