import Foundation

/// Saves dictation audio as 16 kHz mono PCM16 WAVs in `recordings/` and prunes
/// old ones. File name is `<HistoryEntry.id>.wav` so audio and history match up.
public final class RecordingArchive {

    public let directory: URL
    public let sampleRate: Int

    public init(directory: URL = AppPaths.recordingsDir, sampleRate: Int = 16_000) {
        self.directory = directory
        self.sampleRate = sampleRate
    }

    /// Writes a RIFF/WAVE PCM16 file. Returns the file URL.
    @discardableResult
    public func save(samples: [Float], id: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).wav")
        try wavData(samples).write(to: url, options: .atomic)
        return url
    }

    /// Deletes oldest WAVs beyond `keep` (by modification date).
    public func prune(keep: Int) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        let files = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "wav" }

        guard files.count > keep else { return }

        let newestFirst = try files.sorted { a, b in
            let da = try a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let db = try b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return da > db
        }
        for stale in newestFirst.dropFirst(keep) {
            try? fm.removeItem(at: stale)
        }
    }

    // MARK: - WAV encoding (PCM16, mono, little-endian)

    private func wavData(_ samples: [Float]) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(36) + dataSize)
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk: PCM, mono, sampleRate, 16-bit
        data.append(contentsOf: "fmt ".utf8)
        data.appendLE(UInt32(16))                       // fmt chunk size
        data.appendLE(UInt16(1))                        // audio format = PCM
        data.appendLE(UInt16(1))                        // channels
        data.appendLE(UInt32(sampleRate))               // sample rate
        data.appendLE(UInt32(sampleRate * 2))           // byte rate
        data.appendLE(UInt16(2))                        // block align
        data.appendLE(UInt16(16))                       // bits per sample

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.appendLE(dataSize)

        let pcm = samples.map { s -> Int16 in
            let clamped = max(-1.0, min(1.0, s))
            return Int16(clamped * Float(Int16.max))
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

private extension Data {
    mutating func appendLE<T>(_ value: T) {
        var v = value
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
