import Foundation

/// Saves dictation audio as 16 kHz mono PCM16 WAVs in `recordings/`, all kept as
/// fine-tuning data. File name is `<HistoryEntry.id>.wav` so audio and history match up.
public final class RecordingArchive: Sendable {

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
        try WAVEncoder.pcm16Data(samples, sampleRate: sampleRate).write(to: url, options: .atomic)
        AppPaths.makeUserOnly(url)
        return url
    }
}
