import AVFoundation
import FluidAudio
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
    var streaming: String?
    var gap: Double = 0
    var ping: Double = 0
    var files: [String] = []
    // Track A speed tooling
    var profile = false
    var replay = false
    var compare: String?
    var engine = "parakeet"
    var engineSet = false
    var offsets = [0, 50, 100, 150, 200, 350, 600, 1000]
    var micDrop: Double = 0
    var idle: Double = 30
    var show = false
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
        case "--gap":
            i += 1
            if i < args.count, let g = Double(args[i]) { opts.gap = g }
        case "--ping":
            i += 1
            if i < args.count, let p = Double(args[i]) { opts.ping = p }
        case "--streaming":
            i += 1
            if i < args.count { opts.streaming = args[i] }
        case "--profile":
            opts.profile = true
        case "--replay":
            opts.replay = true
        case "--compare":
            i += 1
            if i < args.count { opts.compare = args[i] }
        case "--engine":
            i += 1
            if i < args.count {
                opts.engine = args[i]
                opts.engineSet = true
            }
        case "--offsets":
            i += 1
            if i < args.count {
                opts.offsets = args[i].split(separator: ",").compactMap { Int($0) }
            }
        case "--mic-drop":
            i += 1
            if i < args.count, let d = Double(args[i]) { opts.micDrop = d }
        case "--idle":
            i += 1
            if i < args.count, let s = Double(args[i]) { opts.idle = s }
        case "--show":
            opts.show = true
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
          --gap SECONDS  idle this long before each run, like the pause between real
                       dictations (decodes run ~60-120 ms slower after >0.1 s idle on M1)
          --ping SECONDS  with --gap, rewarm the model this long before each run, like the
                       app does at key press
          --streaming 320|640|1120  instead, replay each file through the streaming Unified
                       model in 100 ms buffers (the mic cadence) and time the release step.
          --profile    per-file stage profile (mel / encoder / joint / decoder ms, call
                       counts) of one <=15 s window via the profiled engine
          --replay     release replay: run the real chunk/speculate/finish loop over each
                       file and simulate key release at --offsets ms after the last word;
                       prints wait p50/p95/mean, no-wait share, last-word survival
          --offsets LIST  release offsets in ms (default 0,50,100,150,200,350,600,1000)
          --mic-drop MS   model MicRecorder dropping this much in-flight audio at stop
          --engine NAME   engine for --replay/--profile (parakeet|profiled|<asrEngine>)
          --compare A,B,…  interleaved A/B over files: --runs per file, WER, word
                       agreement vs first engine, warm and --idle+rewarm timing
          --idle S     idle seconds before the rewarm pass in --compare (default 30)
          --show       print per-file transcripts/details (default: aggregates only)
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
        // The live loop speculates at the last tick where the audio since the last cut
        // ended in a pause; decoded off the clock, as it happens before release.
        var speculation: (end: Int, text: String)?
        var specEnd: Int?
        var tick = start + (samples.count - start) / SpeechSegmenter.tick * SpeechSegmenter.tick
        while tick > start, specEnd == nil {
            if SpeechSegmenter.endsInPause(Array(samples[start..<tick])) { specEnd = tick }
            tick -= SpeechSegmenter.tick
        }
        if let specEnd {
            speculation = (specEnd, try await transcriber.transcribe(Array(samples[start..<specEnd])))
        }
        let t0 = Date()
        let joined = try await SpeechSegmenter.finish(
            samples, chunkStarts: [0] + cuts.dropLast(), texts: texts, committed: start,
            speculation: speculation, transcriber: transcriber)
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

// MARK: - Streaming replay

/// Feeds each file to the streaming Unified model in 100 ms buffers, decoding as audio
/// arrives like a live recording would, then times the release step two ways:
/// `finish()` (flush the held-back right context), and simply taking the partial.
func runStreaming(tier: String, files: [String]) async {
    let configs: [String: UnifiedConfig] = [
        "320": UnifiedConfig(leftFrames: 70, chunkFrames: 2, rightFrames: 2),
        "640": UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 1),
        "1120": UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7),
    ]
    guard let config = configs[tier] else {
        print("Unknown streaming tier '\(tier)'. Choices: 320, 640, 1120")
        exit(1)
    }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    func buffer(_ slice: ArraySlice<Float>) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(slice.count))!
        buf.frameLength = AVAudioFrameCount(slice.count)
        slice.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: slice.count) }
        return buf
    }

    let manager = StreamingUnifiedAsrManager(config: config)
    let loadStart = Date()
    do {
        try await manager.loadModels()
    } catch {
        print("streaming load failed: \(error.localizedDescription)")
        exit(2)
    }
    print(String(format: "Streaming %@ ms tier loaded in %.1f s  footprint: %@", tier,
                 Date().timeIntervalSince(loadStart), formatMB(physicalFootprint())))

    var totals = (files: 0, audioMs: 0.0, busyMs: 0.0, finishMs: 0.0, partialSame: 0)
    for (index, path) in files.enumerated() {
        guard let samples = try? loadSamples16kMono(path: path) else { continue }
        do {
            try await manager.reset()
            var busyMs = 0.0
            var start = 0
            while start < samples.count {
                let end = min(start + 1_600, samples.count)
                try await manager.appendAudio(buffer(samples[start..<end]))
                let t0 = Date()
                try await manager.processBufferedAudio()
                busyMs += Date().timeIntervalSince(t0) * 1000
                start = end
            }
            let partial = await manager.getPartialTranscript()
            let t0 = Date()
            let final = try await manager.finish()
            let finishMs = Date().timeIntervalSince(t0) * 1000
            let audioMs = Double(samples.count) / 16
            let same = normalizedWords(partial) == normalizedWords(final)
            print("=== \(URL(fileURLWithPath: path).lastPathComponent)  (\(String(format: "%.2f", audioMs / 1000)) s) ===")
            print(String(format: "  stream: busy %.0f ms (%.1f%% of audio)  finish %.0f ms  partial==final: %@",
                         busyMs, 100 * busyMs / audioMs, finishMs, same ? "yes" : "no"))
            print("  stream transcript: \(final)")
            if !same { print("  partial at release: \(partial)") }
            if index > 0 {  // first file includes one-time warm-up
                totals.files += 1
                totals.audioMs += audioMs
                totals.busyMs += busyMs
                totals.finishMs += finishMs
                totals.partialSame += same ? 1 : 0
            }
        } catch {
            print("\(path): streaming failed: \(error.localizedDescription)")
        }
    }
    let t = totals
    print(String(format: "Streaming summary: %d files  busy %.1f%% of audio  finish avg %.0f ms  partial==final %d/%d",
                 t.files, 100 * t.busyMs / max(t.audioMs, 1), t.finishMs / Double(max(t.files, 1)),
                 t.partialSame, t.files))
    print("Peak RSS: \(formatMB(peakRSSBytes()))  footprint: \(formatMB(physicalFootprint()))")
}

// MARK: - Main

let opts = parseArgs()
guard !opts.files.isEmpty else {
    printUsage()
    exit(1)
}
if let tier = opts.streaming {
    await runStreaming(tier: tier, files: opts.files)
    exit(0)
}

// Track A speed modes dispatch before the standard bench loop.
if opts.profile || opts.replay || opts.compare != nil {
    let files = loadFiles(opts.files)
    guard !files.isEmpty else { exit(1) }
    do {
        if opts.profile {
            // --profile defaults to the profiled engine; --engine overrides.
            let name = opts.engineSet ? opts.engine : "profiled"
            try await runProfile(engineName: name, runs: opts.runs, files: files, show: opts.show)
        }
        if opts.replay {
            try await runReplay(engineName: opts.engine, files: files,
                                offsets: opts.offsets, micDropMs: opts.micDrop, show: opts.show)
        }
        if let compare = opts.compare {
            let names = compare.split(separator: ",").map { String($0) }
            guard names.count >= 2 else {
                print("--compare needs >= 2 engine names (e.g. parakeet,profiled)")
                exit(1)
            }
            try await runCompare(names: names, runs: opts.runs, idleSeconds: opts.idle,
                                 files: files, show: opts.show)
        }
    } catch {
        print("bench failed: \(error.localizedDescription)")
        exit(2)
    }
    exit(0)
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
        if opts.gap > 0 {
            let lead = min(opts.ping, opts.gap)
            try? await Task.sleep(nanoseconds: UInt64((opts.gap - lead) * 1e9))
            if lead > 0 {
                await transcriber.rewarm()
                try? await Task.sleep(nanoseconds: UInt64(lead * 1e9))
            }
        }
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
