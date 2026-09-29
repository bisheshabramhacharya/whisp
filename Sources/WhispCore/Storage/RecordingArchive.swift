import Foundation

/// Saves dictation audio as 16 kHz mono PCM16 WAVs in `recordings/`, all kept as
/// fine-tuning data. File name is `<HistoryEntry.id>.wav` so audio and history match up.
public final class RecordingArchive: Sendable {

    public let directory: URL
    public let sampleRate: Int
    /// Total size cap for `directory`. Once a save pushes the folder past it,
    /// the oldest WAVs are deleted first so recordings can't grow without
    /// bound. ~17.5 h of 16 kHz PCM16 by default.
    public let maxTotalBytes: UInt64

    public init(directory: URL = AppPaths.recordingsDir, sampleRate: Int = 16_000,
                maxTotalBytes: UInt64 = 2_000_000_000) {
        self.directory = directory
        self.sampleRate = sampleRate
        self.maxTotalBytes = maxTotalBytes
    }

    /// Writes a RIFF/WAVE PCM16 file. Returns the file URL.
    @discardableResult
    public func save(samples: [Float], id: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).wav")
        try wavData(samples).write(to: url, options: .atomic)
        AppPaths.makeUserOnly(url)
        prune(keeping: url)
        return url
    }

    /// Deletes oldest-first until the WAVs in `directory` fit `maxTotalBytes`.
    /// `keeping` is never deleted, even when it alone exceeds the cap.
    private func prune(keeping: URL) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        else { return }
        var total: UInt64 = 0
        var wavs: [(url: URL, size: Int, mtime: Date)] = []
        for url in urls where url.pathExtension == "wav" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize else { continue }
            total += UInt64(size)
            wavs.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        let kept = keeping.resolvingSymlinksInPath()
        for wav in wavs.sorted(by: { $0.mtime < $1.mtime }) {
            guard total > maxTotalBytes else { return }
            // contentsOfDirectory resolves symlinks (e.g. /var -> /private/var),
            // so compare resolved paths, not the original URLs.
            guard wav.url.resolvingSymlinksInPath() != kept else { continue }
            try? fm.removeItem(at: wav.url)
            total -= UInt64(wav.size)
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
