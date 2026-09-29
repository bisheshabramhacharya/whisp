import Foundation

/// All on-disk locations for Whisp data.
///
/// Default root: `~/Library/Application Support/Whisp/`
/// Override with the `WHISP_DATA_DIR` env var (useful for dev runs and tests).
public enum AppPaths {

    /// ~/Library/Application Support/Whisp
    public static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["WHISP_DATA_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("Whisp", isDirectory: true)
    }()

    /// root/history.jsonl — append-only transcription history.
    public static var historyFile: URL {
        root.appendingPathComponent("history.jsonl")
    }

    /// root/recordings/ — optional 16 kHz mono WAVs, keyed by entry id.
    public static var recordingsDir: URL {
        root.appendingPathComponent("recordings", isDirectory: true)
    }

    /// root/dictionary.json — personal dictionary for the cleaner.
    public static var dictionaryFile: URL {
        root.appendingPathComponent("dictionary.json")
    }

    /// Creates root + recordings dir if missing, and locks the whole data dir
    /// down to the current user: transcripts and voice recordings are private,
    /// but `~/Library/Application Support` is world-readable by default.
    /// Tightens permissions on existing installs too.
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordingsDir.path)
        for file in [historyFile, dictionaryFile] where fm.fileExists(atPath: file.path) {
            makeUserOnly(file)
        }
    }

    /// Makes `url` readable/writable only by the current user (0600). Best-effort.
    public static func makeUserOnly(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Creates dictionary.json with an empty template if it does not exist yet.
    /// Format: `{"terms": [...], "replacements": [{"from": [...], "to": "..."}]}`
    @discardableResult
    public static func ensureDictionaryTemplate() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dictionaryFile.path) {
            let template = """
                {
                  "terms": [],
                  "replacements": []
                }
                """
            try? template.write(to: dictionaryFile, atomically: true, encoding: .utf8)
        }
        makeUserOnly(dictionaryFile)
        return dictionaryFile
    }
}
