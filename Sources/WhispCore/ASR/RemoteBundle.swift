import CryptoKit
import Foundation

/// A compiled Core ML bundle published as a zip (a GitHub release asset),
/// fetched once into the model cache and verified by SHA-256 before use.
public struct RemoteBundle: Sendable {
    /// Directory name of the unpacked bundle, e.g. `…_w5000_int8.mlmodelc`.
    public let name: String
    public let url: URL
    /// Lowercase hex SHA-256 of the zip.
    public let sha256: String

    public init(name: String, url: URL, sha256: String) {
        self.name = name
        self.url = url
        self.sha256 = sha256
    }

    public enum FetchError: Error, LocalizedError {
        case badStatus(Int)
        case checksumMismatch
        case unpackFailed

        public var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "download failed (HTTP \(code))"
            case .checksumMismatch: return "download didn't match the expected checksum"
            case .unpackFailed: return "couldn't unpack the model"
            }
        }
    }

    /// Downloads, verifies and unpacks into `dir/name`; returns the bundle URL.
    public func fetch(into dir: URL) async throws -> URL {
        let (zip, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: zip) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.badStatus(http.statusCode)
        }
        return try install(zip: zip, into: dir)
    }

    /// Verifies `zip` and unpacks it to `dir/name`. The bundle only appears
    /// under its final name once complete, so a crash mid-unpack leaves
    /// nothing the engine would try to load.
    public func install(zip: URL, into dir: URL) throws -> URL {
        guard try Self.sha256Hex(of: zip) == sha256.lowercased() else { throw FetchError.checksumMismatch }
        let fm = FileManager.default
        let staging = dir.appendingPathComponent(".\(name).partial-\(UUID().uuidString)", isDirectory: true)
        let unpacked = staging.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              fm.fileExists(atPath: unpacked.appendingPathComponent("coremldata.bin").path)
        else { throw FetchError.unpackFailed }
        // Zips made on a Mac can carry AppleDouble "._" files at the root.
        for entry in (try? fm.contentsOfDirectory(atPath: unpacked.path)) ?? [] where entry.hasPrefix("._") {
            try? fm.removeItem(at: unpacked.appendingPathComponent(entry))
        }

        let final = dir.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: unpacked, to: final)
        return final
    }

    public static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
