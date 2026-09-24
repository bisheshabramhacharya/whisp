import Foundation
import WhispCore

// Plain executable test runner (Command Line Tools ship without XCTest/Testing).
// Exits non-zero on any failure.

var failures = 0
var passes = 0

func expect(_ actual: String, _ expected: String, _ label: String = "", line: Int = #line) {
    if actual == expected {
        passes += 1
    } else {
        failures += 1
        print("FAIL line \(line) \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

// MARK: - FillerCleaner

let cleaner = FillerCleaner()
let cases: [(String, String)] = [
    // Hesitations
    ("Um, I think we should go.", "I think we should go."),
    ("Uh, so what's the plan?", "So what's the plan?"),
    ("I was, uh, going to call you.", "I was going to call you."),
    ("So, um, we should ship it.", "So, we should ship it."),
    ("I think, um.", "I think."),
    ("Um. I think it works.", "I think it works."),
    ("The um meeting is at 3 PM.", "The meeting is at 3 PM."),
    ("Hmm, let me check.", "Let me check."),
    ("Um.", ""),
    ("", ""),
    // Parenthetical fillers only when set off by commas
    ("It was, like, huge.", "It was huge."),
    ("Like, I don't know.", "I don't know."),
    ("I like pizza.", "I like pizza."),
    ("It looks like rain.", "It looks like rain."),
    ("It was great, you know.", "It was great."),
    ("You know, I think so.", "I think so."),
    ("Do you know where it is?", "Do you know where it is?"),
    ("It's, I mean, fine.", "It's fine."),
    ("I mean what I say.", "I mean what I say."),
    ("I like, you know, dogs.", "I like dogs."),
    // Stutters
    ("I I think so.", "I think so."),
    ("I, I think so.", "I think so."),
    ("The the report is done.", "The report is done."),
    ("We we we should go.", "We should go."),
    ("I know that that is true.", "I know that that is true."),
    ("She had had enough.", "She had had enough."),
    ("No no, that's wrong.", "No no, that's wrong."),
    ("It was very very good.", "It was very very good."),
    ("Go. Go.", "Go. Go."),
    // Restarted phrases
    ("Go to the go to desktop folder.", "Go to desktop folder."),
    ("I want to I want to go home.", "I want to go home."),
    ("Make sure you, make sure you open it.", "Make sure you open it."),
    ("Is it, is it working?", "Is it working?"),
    ("It is what it is.", "It is what it is."),
    ("How long did it take? How long did it take?", "How long did it take? How long did it take?"),
    ("No no no no.", "No no no no."),
    ("I can can make make it.", "I can make it."),
    ("Just do that Do that, but fast.", "Just do that, but fast."),
    // Never rewrites
    ("She went to the ER.", "She went to the ER."),
    ("It's 5 mm wide.", "It's 5 mm wide."),
    ("Send $4.2 million to Sarah by March 3rd.", "Send $4.2 million to Sarah by March 3rd."),
    ("Uh-huh, that works.", "Uh-huh, that works."),
    ("Honestly, it's basically done.", "Honestly, it's basically done."),
    ("Let's meet at 10:30 — okay?", "Let's meet at 10:30 — okay?"),
    // Real Parakeet output (whisp-bench on a `say` clip)
    ("Um, so I think we should, well, send $4.2 million to Sarah by March 3rd. And then, you know, update the vintage listing.",
     "So I think we should, well, send $4.2 million to Sarah by March 3rd. And then update the vintage listing."),
    // Clock times
    ("Send me the report by 5.30? Thanks.", "Send me the report by 5:30? Thanks."),
    ("Moved to Thursday at 2.45 p.m.", "Moved to Thursday at 2:45 p.m."),
    ("Call her 3.45 PM.", "Call her 3:45 PM."),
    ("We shipped version 2.4 on Tuesday.", "We shipped version 2.4 on Tuesday."),
    ("Upgrade to 2.45 today.", "Upgrade to 2.45 today."),
    ("It went from 1.25.3 to 1.26.", "It went from 1.25.3 to 1.26."),
    ("That costs $5.30 total.", "That costs $5.30 total."),
    ("Peak hit 1.2 gigabytes.", "Peak hit 1.2 gigabytes."),
]
for (input, output) in cases {
    expect(cleaner.clean(input), output, "clean(\"\(input)\")")
}

// MARK: - PersonalDictionary

let dict = PersonalDictionary(
    terms: ["Vinted", "Poshmark", "Whisp", "lowercase"],
    replacements: ["ChatGPT": ["chat gpt", "chat g p t"], "Bishesha": ["bee shesha"]]
)
let dictCleaner = FillerCleaner(dictionary: dict)
expect(dictCleaner.clean("I listed it on vinted and poshmark."), "I listed it on Vinted and Poshmark.")
expect(dictCleaner.clean("Ask chat  g p t, um, about it."), "Ask ChatGPT about it.")
expect(dictCleaner.clean("Chat GPT is useful."), "ChatGPT is useful.")
expect(dictCleaner.clean("Hi, I'm bee shesha."), "Hi, I'm Bishesha.")
expect(dictCleaner.clean("Invented things."), "Invented things.", "no partial-word match")
expect(dictCleaner.clean("whisper and whisp"), "whisper and Whisp")

// File-backed dictionary: live reload on edit, malformed edit keeps last good version.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-dict-\(UUID().uuidString).json")
defer { try? FileManager.default.removeItem(at: tmp) }
let fileDict = PersonalDictionary(fileURL: tmp)
expect(fileDict.apply("vinted"), "vinted", "missing file is empty")
try! #"{"terms": ["Vinted"], "replacements": [{"from": "posh mark", "to": "Poshmark"}]}"#
    .write(to: tmp, atomically: true, encoding: .utf8)
expect(fileDict.apply("vinted and posh mark"), "Vinted and Poshmark", "loads file")
try! #"{"terms": ["Depop"]}"#.write(to: tmp, atomically: true, encoding: .utf8)
try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: tmp.path)
expect(fileDict.apply("vinted on depop"), "vinted on Depop", "reloads on change")
try! #"{"terms": ["#.write(to: tmp, atomically: true, encoding: .utf8)
try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: tmp.path)
expect(fileDict.apply("depop"), "Depop", "malformed edit keeps last good")

// MARK: - SpeechSegmenter

func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
    (0..<Int(seconds * 16_000)).map { amplitude * sinf(Float($0) * 0.2) }
}
let silence = { (seconds: Double) in [Float](repeating: 0, count: Int(seconds * 16_000)) }
let speech = tone(4) + silence(0.6) + tone(4)
let cut = SpeechSegmenter.nextCut(in: speech)
expect(cut.map { $0 >= 64_000 && $0 <= 73_600 ? "in pause" : "at \($0)" } ?? "nil", "in pause", "cut lands in the pause")
expect(SpeechSegmenter.nextCut(in: tone(3) + silence(0.6) + tone(1)).map(String.init) ?? "nil", "nil", "waits for minChunk")
expect(SpeechSegmenter.nextCut(in: tone(4, amplitude: 0.002) + silence(0.6) + tone(4)).map(String.init) ?? "nil", "nil",
       "keeps near-silent chunk attached")
expect(SpeechSegmenter.nextCut(in: tone(8)).map(String.init) ?? "nil", "nil", "no pause, below forceChunk")
expect(SpeechSegmenter.nextCut(in: tone(26)) != nil ? "cut" : "nil", "cut", "forced cut")
expect(SpeechSegmenter.plan(tone(5) + silence(0.6) + tone(5) + silence(0.6) + tone(5)).count.description, "2", "plan")
expect(SpeechSegmenter.join(["I went to", "The store and then.", "The end."]), "I went to the store and then. The end.")
expect(SpeechSegmenter.join(["Hello", "", "Bishesha said hi."]), "Hello Bishesha said hi.")

// MARK: - SpeechSegmenter.finish

/// Counts model calls; returns a fixed string per call.
final class CountingTranscriber: Transcribing {
    var calls: [Int] = []
    func prepare() async throws {}
    func transcribe(_ samples: [Float]) async throws -> String {
        calls.append(samples.count)
        return "tail"
    }
}

func finishCalls(tail: [Float]) async -> (String, [Int]) {
    let chunk = tone(7)
    let fake = CountingTranscriber()
    let text = try! await SpeechSegmenter.finish(
        chunk + tail, chunkStarts: [0], texts: ["Chunk one."], committed: chunk.count, transcriber: fake)
    return (text, fake.calls)
}
do {
    let (text, calls) = await finishCalls(tail: silence(1))
    expect(text, "Chunk one.", "silent tail reuses chunk text")
    expect(calls.description, "[]", "silent tail: no model call")
}
do {
    // A short quiet trailing word: the whole tail passes the near-silence gate, but the
    // word is loud enough that trimSilence would keep it — must still re-decode.
    let (text, calls) = await finishCalls(tail: silence(0.5) + tone(0.06, amplitude: 0.02) + silence(0.44))
    expect(text, "tail", "quiet word in tail re-decodes last chunk")
    expect(calls.description, "[\(7 * 16_000 + 16_000)]", "re-decode covers chunk + tail")
}
do {
    // Quieter than the speech threshold next to a loud chunk: the re-decode would trim
    // it away as silence anyway, so it's skipped.
    let (text, calls) = await finishCalls(tail: silence(0.5) + tone(0.3, amplitude: 0.008) + silence(0.2))
    expect(text, "Chunk one.", "sub-threshold tail reuses chunk text")
    expect(calls.description, "[]", "sub-threshold tail: no model call")
}
do {
    let (text, calls) = await finishCalls(tail: tone(2))
    expect(text, "Chunk one. tail", "speech tail decoded alone")
    expect(calls.description, "[32000]", "only the tail is decoded")
}

// MARK: - Paster spacing

expect(Paster.needsSpace(after: "d").description, "true", "after a word")
expect(Paster.needsSpace(after: ".").description, "true", "after a period")
expect(Paster.needsSpace(after: " ").description, "false", "after a space")
expect(Paster.needsSpace(after: "\n").description, "false", "after a newline")
expect(Paster.needsSpace(after: "(").description, "false", "after (")
expect(Paster.needsSpace(after: "/").description, "false", "after /")
expect(Paster.needsSpace(after: "\u{201C}").description, "false", "after an opening curly quote")

// MARK: - PersonalDictionary.addReplacement

do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-add-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try! PersonalDictionary.addReplacement(from: "Pychy", to: "pi CLI", fileURL: url)
    try! #"{"terms": ["Vinted"], "replacements": [{"from": "Py CLI", "to": "pi CLI"}]}"#
        .write(to: url, atomically: true, encoding: .utf8)
    try! PersonalDictionary.addReplacement(from: "Pychy", to: "pi CLI", fileURL: url)
    try! PersonalDictionary.addReplacement(from: "pychy", to: "pi CLI", fileURL: url)
    try! PersonalDictionary.addReplacement(from: "GPT-6 soul", to: "GPT-6 Sol", fileURL: url)
    let added = PersonalDictionary(fileURL: url)
    expect(added.apply("open Pychy and Py CLI on GPT-6 soul with vinted"),
           "open pi CLI and pi CLI on GPT-6 Sol with Vinted", "added replacements apply, terms kept")
    let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let reps = json["replacements"] as! [[String: Any]]
    expect("\(reps.count) \(reps[0]["from"] as! [String])", "2 [\"Py CLI\", \"Pychy\"]", "merges into same target, no dup")
    try! #"{"terms": ["#.write(to: url, atomically: true, encoding: .utf8)
    let refused = (try? PersonalDictionary.addReplacement(from: "a", to: "b", fileURL: url)) == nil
    expect("\(refused) \(try! String(contentsOf: url, encoding: .utf8))", "true {\"terms\": [", "malformed file untouched")
}

// MARK: - HotkeyStateMachine

do {
    func run(_ inputs: [(HotkeyStateMachine.Input, Double)]) -> String {
        var m = HotkeyStateMachine()
        return inputs.map { m.handle($0.0, now: $0.1).map { "\($0)" } ?? "-" }.joined(separator: " ")
    }
    expect(run([(.keyDown, 0), (.keyUp, 1)]), "start stop", "hold")
    expect(run([(.keyDown, 0), (.keyUp, 0.1)]), "start cancel", "tap cancels")
    expect(run([(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.3), (.keyUp, 0.4), (.keyDown, 5), (.keyUp, 5.1)]),
           "start cancel start - stop -", "double-tap locks hands-free; next press stops, release swallowed")
    expect(run([(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.3), (.keyUp, 2)]),
           "start cancel start stop", "tap then hold is a normal hold")
    expect(run([(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.9), (.keyUp, 1.0)]),
           "start cancel start cancel", "second tap outside window is just a tap")
    expect(run([(.keyDown, 0), (.otherKey, 0.1), (.keyUp, 0.5)]), "start cancel -", "chord within grace cancels")
    expect(run([(.keyDown, 0), (.otherKey, 1), (.keyUp, 2)]), "start - stop", "other key after grace ignored")
    expect(run([(.keyDown, 0), (.escape, 1), (.keyUp, 2)]), "start cancel -", "Esc cancels a hold")
    expect(run([(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.3), (.keyUp, 0.4), (.escape, 3)]),
           "start cancel start - cancel", "Esc cancels hands-free")
    expect(run([(.keyDown, 0), (.keyUp, 1), (.escape, 1.1)]), "start stop cancel", "Esc after release reaches the controller")
}

// MARK: - DictationController pipeline (fakes)

final class FakeRecorder: AudioRecording {
    var onLevel: ((Float) -> Void)?
    var lostInput = false
    var next: [Float] = []
    func start() throws {}
    func samples(from start: Int) -> [Float] { [] }
    func stop() -> [Float] { next }
    func cancel() {}
}
final class FakeHotkey: HotkeyMonitoring {
    var onEvent: ((HotkeyEvent) -> Void)?
    func start() throws {}
    func stop() {}
}
/// Returns "clip <seconds>" after a delay that is longer for longer clips' ids given.
final class SlowTranscriber: Transcribing {
    var delays: [Int: UInt64] = [:]
    func prepare() async throws {}
    func transcribe(_ samples: [Float]) async throws -> String {
        let seconds = samples.count / 16_000
        try await Task.sleep(nanoseconds: delays[seconds] ?? 50_000_000)
        return "Clip \(seconds)."
    }
}
@MainActor final class FakePaster: TextPasting {
    var pasted: [String] = []
    var result = PasteResult.pasted
    func target() -> PasteTarget { PasteTarget(pid: 1, precedingCharacter: Task { nil }) }
    func paste(_ text: String, into target: PasteTarget) async -> PasteResult {
        if result == .pasted { pasted.append(text) }
        return result
    }
}
final class NoMuter: AudioMuting { func mute() {}; func restore() {} }
final class CountingSounds: SoundPlaying {
    var log: [String] = []
    func playStart() { log.append("start") }
    func playStop() { log.append("stop") }
    func playCancel() { log.append("cancel") }
    func playError() { log.append("error") }
}

@MainActor
func pipelineTests() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-ctl-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = FakeRecorder(), hotkey = FakeHotkey(), paster = FakePaster()
    let transcriber = SlowTranscriber(), sounds = CountingSounds()
    let settings = AppSettings(defaults: UserDefaults(suiteName: "whisp-tests-\(UUID().uuidString)")!)
    settings.autoMute = false
    settings.keepRecordings = true
    let history = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
    let controller = DictationController(
        transcriber: transcriber, recorder: recorder, hotkey: hotkey, paster: paster,
        cleaner: FillerCleaner(), muter: NoMuter(), sounds: sounds, settings: settings,
        history: history, recordings: RecordingArchive(directory: dir.appendingPathComponent("recordings")))
    try! controller.startHotkey()

    func dictate(seconds: Double) {
        recorder.next = [Float](repeating: 0.1, count: Int(seconds * 16_000))
        hotkey.onEvent?(.start)
        hotkey.onEvent?(.stop)
    }
    func settle() async {
        for _ in 0..<200 where controller.state != .idle { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    // A 0.15 s word (under the old 0.3 s floor) is transcribed, not dropped.
    dictate(seconds: 0.15)
    await settle()
    expect(paster.pasted.description, "[\"Clip 0.\"]", "short clip is transcribed")

    // Pastes stay in release order even when the later clip transcribes faster.
    paster.pasted = []
    transcriber.delays = [3: 300_000_000, 1: 10_000_000]
    dictate(seconds: 3)
    dictate(seconds: 1)
    await settle()
    expect(paster.pasted.description, "[\"Clip 3.\", \"Clip 1.\"]", "pastes keep recording order")

    // Esc while transcribing: nothing is pasted, the cancel sound plays.
    paster.pasted = []
    sounds.log = []
    transcriber.delays = [2: 200_000_000]
    dictate(seconds: 2)
    hotkey.onEvent?(.cancel)
    await settle()
    expect(paster.pasted.description, "[]", "Esc after release drops the paste")
    expect(sounds.log.filter { $0 == "cancel" }.count.description, "1", "Esc after release plays cancel")

    // Esc with nothing pending does nothing; the next dictation still pastes.
    sounds.log = []
    hotkey.onEvent?(.cancel)
    dictate(seconds: 2)
    await settle()
    expect(paster.pasted.description, "[\"Clip 2.\"]", "later dictation unaffected by earlier Esc")
    expect(sounds.log.contains("cancel").description, "false", "idle Esc is silent")

    // Focus moved to another app: surfaced, not silently lost.
    paster.result = .copiedAppChanged
    dictate(seconds: 1)
    await settle()
    expect((controller.statusMessage?.contains("switched apps") ?? false).description, "true", "app change reported")
    paster.result = .pasted

    // History and recordings are written off the pipeline, and in order.
    controller.flushPersistence()
    let saved = history.loadLast(10).map(\.cleaned)
    expect(saved.description, "[\"Clip 1.\", \"Clip 2.\", \"Clip 1.\", \"Clip 3.\", \"Clip 0.\"]",
           "history persisted in order (cancelled clip skipped)")
    let wavs = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("recordings").path)) ?? []
    expect(wavs.count.description, "5", "one WAV per pasted dictation")
}
await pipelineTests()

// MARK: - Speed

let long = String(repeating: "Um, so I I was, like, thinking we should, you know, ship the the thing. ", count: 40)
let t0 = Date()
for _ in 0..<50 { _ = dictCleaner.clean(long) }
let perCallMs = Date().timeIntervalSince(t0) * 1000 / 50
print(String(format: "clean() on %d chars: %.2f ms", long.count, perCallMs))
if perCallMs > 20 { failures += 1; print("FAIL clean() too slow") }

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
