// Apple's on-device speech transcriber, used as the second reference model for
// BIS-20. Reference only: the app must never link this, ship it, or need it.
//
//   scripts/speed/apple-stt.swift is compiled on first use by
//   scripts/speed/reference.py, which then calls it with audio file paths.
//
// Prints one JSON object per line on stdout: {"file": "<name>", "text": "..."}
// On a file it cannot transcribe it prints {"file": "<name>", "error": "..."}.
//
// The audio is read in place and never copied. macOS 26 or newer only.

import AVFoundation
import Foundation
import Speech

let arguments = Array(CommandLine.arguments.dropFirst())
guard let locale = Locale(identifier: "en-US") as Locale? else { exit(2) }

func transcribe(_ url: URL) async throws -> String {
    let transcriber = SpeechTranscriber(
        locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    // The on-device models are a system asset, not part of the OS image, so a
    // fresh Mac has to fetch them once. No prompt and no GUI: it is a download.
    if await AssetInventory.status(forModules: [transcriber]) != .installed {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            throw AppleSTTError.notInstalled
        }
        try await request.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let audio = try AVAudioFile(forReading: url)
    let collector = Task { () -> String in
        var text = ""
        for try await result in transcriber.results {
            text += String(result.text.characters)
        }
        return text
    }
    try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
    return try await collector.value
}

enum AppleSTTError: Error, CustomStringConvertible {
    case unsupported, notInstalled
    var description: String {
        switch self {
        case .unsupported: return "apple: locale unsupported on this Mac"
        case .notInstalled: return "apple: speech assets not installed"
        }
    }
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          var line = String(data: data, encoding: .utf8) else { return }
    line = line.replacingOccurrences(of: "\n", with: " ")
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

for path in arguments {
    let url = URL(fileURLWithPath: path)
    let name = url.deletingPathExtension().lastPathComponent
    do {
        let text = try await transcribe(url)
        emit(["file": name, "text": text])
    } catch {
        emit(["file": name, "error": "\(error)"])
    }
}
