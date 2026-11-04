import Foundation

/// PCM16 WAV payload encode/decode shared by the recording archive and the
/// pending-take scratch files.
public enum WAVEncoder {

    /// 16 kHz mono PCM16 RIFF/WAVE bytes.
    public static func pcm16Data(_ samples: [Float], sampleRate: Int) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(36) + dataSize)
        data.append(contentsOf: "WAVE".utf8)

        data.append(contentsOf: "fmt ".utf8)
        data.appendLE(UInt32(16))                       // fmt chunk size
        data.appendLE(UInt16(1))                        // audio format = PCM
        data.appendLE(UInt16(1))                        // channels
        data.appendLE(UInt32(sampleRate))               // sample rate
        data.appendLE(UInt32(sampleRate * 2))           // byte rate
        data.appendLE(UInt16(2))                        // block align
        data.appendLE(UInt16(16))                       // bits per sample

        data.append(contentsOf: "data".utf8)
        data.appendLE(dataSize)

        let pcm = samples.map { s -> Int16 in
            let clamped = max(-1.0, min(1.0, s))
            return Int16(clamped * Float(Int16.max))
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Reads PCM16 mono samples back out of a WAV we wrote; nil when the file
    /// isn't a RIFF/WAVE or has no data chunk.
    public static func pcm16Samples(_ data: Data) -> [Float]? {
        guard data.count >= 44,
              data[0..<4] == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else { return nil }
        // Walk chunks until the "data" chunk — tolerates extra chunks we don't write.
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = data[offset..<(offset + 4)]
            let chunkSize = Int(data.subdata(in: (offset + 4)..<(offset + 8))
                .withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian)
            let payload = offset + 8
            if chunkID == Data("data".utf8) {
                guard payload + chunkSize <= data.count, chunkSize % 2 == 0 else { return nil }
                return data[payload..<(payload + chunkSize)].withUnsafeBytes { raw in
                    raw.bindMemory(to: Int16.self).map { Float($0) / Float(Int16.max) }
                }
            }
            offset = payload + chunkSize + (chunkSize % 2) // chunks are word-aligned
        }
        return nil
    }
}

/// Scratch WAVs for takes still in flight: `pending/` holds one file per
/// unfinished take — written when a take is queued, deleted when it lands.
/// Any file still here at launch is a take a crash or force-quit lost;
/// `DictationController.recoverPendingTakes()` transcribes it then.
public final class PendingTakes: Sendable {

    public let directory: URL
    public let sampleRate: Int

    public init(directory: URL = AppPaths.pendingDir, sampleRate: Int = 16_000) {
        self.directory = directory
        self.sampleRate = sampleRate
    }

    /// Where a take's pending WAV would live — the controller picks the name
    /// up front so it can delete the file later without another lookup.
    /// `clip-<takeID>-<random>.wav`: the random suffix keeps two crashed
    /// sessions' clip numbers from colliding.
    public func fileURL(takeID: String) -> URL {
        directory.appendingPathComponent("\(takeID).wav")
    }

    /// Writes the pending WAV at `url` (0700 dir, 0600 file).
    public func save(samples: [Float], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try WAVEncoder.pcm16Data(samples, sampleRate: sampleRate).write(to: url, options: .atomic)
        AppPaths.makeUserOnly(url)
    }

    /// All pending WAVs oldest-first (mtime), so recovery replays takes in order.
    public func list() -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.pathExtension == "wav" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return a < b
            }
    }

    /// Decodes a pending WAV back to samples; nil for a corrupt or foreign file.
    public func load(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return WAVEncoder.pcm16Samples(data)
    }

    /// The file's modification date — used as the recovered take's timestamp.
    public func fileDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()
    }

    public func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private extension Data {
    mutating func appendLE<T>(_ value: T) {
        var v = value
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
