import AVFoundation
import Foundation
import WhispCore

// whisp-bench [--runs N] [--model NAME] <audio files...>
//
// Loads audio of any format via AVFoundation, converts to 16 kHz mono
// Float32, transcribes with ParakeetTranscriber, and prints model load time,
// per-file transcript, latency, RTF and peak RSS. If a sibling "<file>.txt"
// exists it is used as the reference transcript for a simple WER score.

struct Options {
    var runs = 3
    var model = ParakeetTranscriber().model.rawValue
    var itn = false
    var vocab: [String] = []
    var chunked = false
    var files: [String] = []
}

func parseArgs() -> Options {
    var opts = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--runs":
            i += 1
            if i < args.count, let n = Int(args[i]) { opts.runs = max(1, n) }
        case "--model":
            i += 1
            if i < args.count { opts.model = args[i] }
        case "--itn":
            i += 1
            if i < args.count { opts.itn = args[i] != "off" && args[i] != "0" }
        case "--vocab":
            i += 1
            if i < args.count {
                opts.vocab = args[i].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }
        case "--chunked":
            opts.chunked = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            opts.files.append(args[i])
        }
        i += 1
    }
    return opts
}

func printUsage() {
    print(
        """
        Usage: whisp-bench [--runs N] [--model NAME] <audio files...>
          --runs N     transcriptions per file (default 3, first is warm-up)
          --model NAME one of: \(ParakeetTranscriber.Model.allCases.map(\.rawValue).joined(separator: ", "))
                       (aliases: v2, v3, 110m, unified; default: transcriber default)
          --itn on|off inverse text normalization (default off)
          --vocab a,b,c  custom vocabulary terms (comma-separated; enables CTC rescoring)
          --chunked    also replay the app's transcribe-while-recording path: chunks cut at
                       pauses are decoded ahead, then only the tail is timed (release→text).
                       Reports word differences vs whole-clip decoding.
          If <file>.txt exists next to an audio file it is scored as the WER reference.
        """)
}

// MARK: - Audio loading (AVFoundation -> 16 kHz mono Float32)

enum BenchError: Error, LocalizedError {
    case cannotOpen(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let p): return "Cannot open audio file: \(p)"
        case .conversionFailed(let m): return "Audio conversion failed: \(m)"
        }
    }
}

func loadSamples16kMono(path: String) throws -> [Float] {
    let url = URL(fileURLWithPath: path)
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        throw BenchError.cannotOpen(path)
    }
    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0 else { throw BenchError.conversionFailed("empty file: \(path)") }

    guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
        throw BenchError.conversionFailed("no converter for \(file.processingFormat)")
    }
    let ratio = 16_000.0 / file.processingFormat.sampleRate
    let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio + 1024)
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)
    else { throw BenchError.conversionFailed("buffer alloc") }

    var consumed = false
    var error: NSError?
    converter.convert(to: outBuffer, error: &error) { _, status in
        if consumed {
            status.pointee = .endOfStream
            return nil
        }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        else {
            status.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: inBuf, frameCount: frameCount)
        } catch {
            status.pointee = .endOfStream
            return nil
        }
        consumed = true
        status.pointee = .haveData
        return inBuf
    }
    if let error { throw BenchError.conversionFailed(error.localizedDescription) }

    let n = Int(outBuffer.frameLength)
    guard n > 0, let ch = outBuffer.floatChannelData else {
        throw BenchError.conversionFailed("no samples decoded")
    }
    return Array(UnsafeBufferPointer(start: ch[0], count: n))
}

// MARK: - Metrics

func peakRSSBytes() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(usage.ru_maxrss)  // bytes on macOS
}

func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

func formatMB(_ bytes: UInt64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

// MARK: - WER (simple word-level Levenshtein on normalized words)

func normalizedWords(_ s: String) -> [String] {
    s.lowercased()
        .components(separatedBy: .alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

func wordEditDistance(_ ref: [String], _ hyp: [String]) -> Int {
    let (n, m) = (ref.count, hyp.count)
    if n == 0 { return m }
    if m == 0 { return n }
    var prev = Array(0...m)
    var curr = [Int](repeating: 0, count: m + 1)
    for i in 1...n {
        curr[0] = i
        for j in 1...m {
            curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1))
        }
        swap(&prev, &curr)
    }
    return prev[m]
}

// MARK: - Chunked replay

var chunkedTotals = (files: 0, fullMs: 0.0, tailMs: 0.0, diffWords: 0, words: 0)

@MainActor
func benchChunked(_ samples: [Float], full: String, fullMs: Double) async {
    let cuts = SpeechSegmenter.plan(samples)
    var texts: [String] = []
    var start = 0
    do {
        for cut in cuts {
            texts.append(try await transcriber.transcribe(Array(samples[start..<cut])))
            start = cut
        }
        let t0 = Date()
        let joined = try await SpeechSegmenter.finish(
            samples, chunkStarts: [0] + cuts.dropLast(), texts: texts, committed: start,
            transcriber: transcriber)
        let tailMs = Date().timeIntervalSince(t0) * 1000
        let ref = normalizedWords(full)
        let diff = wordEditDistance(ref, normalizedWords(joined))
        print(String(format: "  chunked: %d cuts  tail %.0f ms vs full %.0f ms  word diffs vs full: %d/%d",
                     cuts.count, tailMs, fullMs, diff, ref.count))
        if diff > 0 {
            print("  chunked transcript: \(joined)")
            let bounds = [0] + cuts + [samples.count]
            for (i, text) in texts.enumerated() where i + 1 < bounds.count {
                print(String(format: "    [%6.2f-%6.2f s] %@", Double(bounds[i]) / 16_000,
                             Double(bounds[i + 1]) / 16_000, text))
            }
        }
        chunkedTotals.files += 1
        chunkedTotals.fullMs += fullMs
        chunkedTotals.tailMs += tailMs
        chunkedTotals.diffWords += diff
        chunkedTotals.words += ref.count
    } catch {
        print("  chunked: failed: \(error.localizedDescription)")
    }
}

// MARK: - Main

let opts = parseArgs()
guard !opts.files.isEmpty else {
    printUsage()
    exit(1)
}

let modelAliases: [String: ParakeetTranscriber.Model] = [
    "v2": .tdtV2, "v3": .tdtV3, "110m": .tdtCtc110m, "unified": .unified,
]
guard let model = ParakeetTranscriber.Model(rawValue: opts.model) ?? modelAliases[opts.model]
else {
    print("Unknown model '\(opts.model)'. Choices: \(ParakeetTranscriber.Model.allCases.map(\.rawValue).joined(separator: ", "))")
    exit(1)
}

let transcriber = ParakeetTranscriber(model: model)
transcriber.inverseTextNormalization = opts.itn
transcriber.vocabulary = opts.vocab
transcriber.onStatus = { print("[status] \($0)") }

print("Model: \(model.rawValue)")

let loadStart = Date()
do {
    try await transcriber.prepare()
} catch {
    print("prepare() failed: \(error.localizedDescription)")
    exit(2)
}
let loadTime = Date().timeIntervalSince(loadStart)
print(String(format: "Load+prepare time: %.2f s (includes download/compile on first run)", loadTime))
print("Peak RSS after load: \(formatMB(peakRSSBytes()))  footprint: \(formatMB(physicalFootprint()))")
print("")

for path in opts.files {
    let samples: [Float]
    do {
        samples = try loadSamples16kMono(path: path)
    } catch {
        print("\(path): \(error.localizedDescription)")
        continue
    }
    let duration = Double(samples.count) / 16_000.0
    print("=== \(URL(fileURLWithPath: path).lastPathComponent)  (\(String(format: "%.2f", duration)) s) ===")

    // Optional reference transcript
    let refPath = path + ".txt"
    let reference = try? String(contentsOfFile: refPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    var latencies: [Double] = []
    var lastText = ""
    for run in 0..<opts.runs {
        let t0 = Date()
        do {
            lastText = try await transcriber.transcribe(samples)
        } catch {
            print("  run \(run + 1): transcribe failed: \(error.localizedDescription)")
            break
        }
        let dt = Date().timeIntervalSince(t0)
        latencies.append(dt)
        let label = run == 0 ? "warm-up " : "run \(run)  "
        print(String(format: "  %@ %.0f ms  RTF %.3f", label, dt * 1000, dt / duration))
    }

    if !latencies.isEmpty {
        let warm = latencies.dropFirst()
        if !warm.isEmpty {
            let avg = warm.reduce(0, +) / Double(warm.count)
            print(String(format: "  warm avg: %.0f ms  (min %.0f / max %.0f)",
                         avg * 1000, warm.min()! * 1000, warm.max()! * 1000))
        }
        print("  transcript: \(lastText)")
        if opts.chunked {
            await benchChunked(samples, full: lastText, fullMs: (latencies.dropFirst().min() ?? latencies[0]) * 1000)
        }
        if let reference, !reference.isEmpty {
            let ref = normalizedWords(reference)
            let hyp = normalizedWords(lastText)
            let dist = wordEditDistance(ref, hyp)
            let wer = ref.isEmpty ? 0 : Double(dist) / Double(ref.count)
            print(String(format: "  WER vs reference: %.1f%% (%d words)", wer * 100, ref.count))
        }
    }
    print("")
}

print("Peak RSS: \(formatMB(peakRSSBytes()))  footprint: \(formatMB(physicalFootprint()))")
if chunkedTotals.files > 0 {
    let t = chunkedTotals
    print(String(format: "Chunked summary: %d files  full %.0f ms total  tail %.0f ms total (%.0f%% faster)  word diffs %d/%d (%.2f%%)",
                 t.files, t.fullMs, t.tailMs, 100 * (1 - t.tailMs / max(t.fullMs, 1)),
                 t.diffWords, t.words, 100 * Double(t.diffWords) / Double(max(t.words, 1))))
}
