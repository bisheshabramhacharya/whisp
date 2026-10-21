import AppKit
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

// MARK: - Setup and pill settings survive relaunch

await MainActor.run {
    let suite = "whisp-settings-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    expect(String(settings.onboardingCompleted), "false", "fresh install needs guided setup")
    expect(String(settings.alwaysShowPill), "true", "pill is visible between dictations")
    settings.pillOrigin = CGPoint(x: -640, y: 315)
    settings.onboardingCompleted = true
    let relaunched = AppSettings(defaults: defaults)
    expect(String(relaunched.onboardingCompleted), "true", "completed setup survives relaunch")
    expect(String(Double(relaunched.pillOrigin?.x ?? 0)), "-640.0", "pill position survives relaunch on a left-hand monitor")
    expect(String(Double(relaunched.pillOrigin?.y ?? 0)), "315.0", "pill height survives relaunch")
    relaunched.pillOrigin = nil
    expect(AppSettings(defaults: defaults).pillOrigin == nil ? "reset" : "saved", "reset", "reset position clears the saved origin")
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
try! FileManager.default.removeItem(at: tmp)
expect(fileDict.apply("depop"), "Depop", "transiently missing file keeps last good")
try! #"{"terms": ["Grailed"], "replacements": [{"from": "depop", "to": "Depop App"}]}"#
    .write(to: tmp, atomically: true, encoding: .utf8)
expect(fileDict.apply("grailed"), "Grailed", "recovers after the file returns")

// MARK: - SpeechSegmenter

func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
    (0..<Int(seconds * 16_000)).map { amplitude * sinf(Float($0) * 0.2) }
}
let silence = { (seconds: Double) in [Float](repeating: 0, count: Int(seconds * 16_000)) }
let speech = tone(4) + silence(0.6) + tone(4)
let cut = SpeechSegmenter.nextCut(in: speech)
expect(cut.map { $0 >= 64_000 && $0 <= 73_600 ? "in pause" : "at \($0)" } ?? "nil", "in pause", "cut lands in the pause")
expect(SpeechSegmenter.nextCut(in: tone(3) + silence(0.6) + tone(1)).map(String.init) ?? "nil", "nil", "waits for minChunk")
expect(SpeechSegmenter.endsInPause(tone(2) + silence(0.5)).description, "true", "speech then pause")
expect(SpeechSegmenter.endsInPause(tone(2) + silence(0.1)).description, "false", "pause too short")
expect(SpeechSegmenter.endsInPause(silence(2)).description, "false", "no speech")
expect(SpeechSegmenter.nextCut(in: tone(4, amplitude: 0.002) + silence(0.6) + tone(4)).map(String.init) ?? "nil", "nil",
       "keeps near-silent chunk attached")
expect(SpeechSegmenter.nextCut(in: tone(8)).map(String.init) ?? "nil", "nil", "no pause, below forceChunk")
expect(SpeechSegmenter.nextCut(in: tone(15)) != nil ? "cut" : "nil", "cut", "forced cut")
expect(SpeechSegmenter.plan(tone(5) + silence(0.6) + tone(5) + silence(0.6) + tone(5)).count.description, "2", "plan")

// Long release tails are split to fit the largest encoder window instead of
// loading a second model set (a 30-75 s stall when Core ML recompiled it).
let window15 = 15 * 16_000
expect(SpeechSegmenter.split(tone(10), maxSamples: window15).count.description, "1", "short audio stays whole")
let longTake = tone(12) + silence(0.4) + tone(20)
let pieces = SpeechSegmenter.split(longTake, maxSamples: window15)
expect(pieces.allSatisfy { $0.count <= window15 } ? "fits" : "\(pieces.map(\.count))", "fits", "every piece fits the window")
expect(pieces.reduce(0) { $0 + $1.count }.description, longTake.count.description, "no audio lost")
expect(abs(pieces[0].count - 12 * 16_000 - 3_200) <= 3_200 ? "in pause" : "at \(pieces[0].count)", "in pause",
       "cuts in the quiet gap")
let pauseless = SpeechSegmenter.split(tone(40), maxSamples: window15)
expect(pauseless.count >= 3 && pauseless.allSatisfy { $0.count <= window15 } ? "fits" : "\(pauseless.map(\.count))",
       "fits", "pause-free speech still splits")
expect(SpeechSegmenter.join(["I went to", "The store and then.", "The end."]), "I went to the store and then. The end.")
expect(SpeechSegmenter.join(["Hello", "", "Bishesha said hi."]), "Hello Bishesha said hi.")
expect(SpeechSegmenter.join(["It stops.", "changing words."]), "It stops changing words.", "seam period dropped")
expect(SpeechSegmenter.join(["Meet at 5 p.m.", "tomorrow."]), "Meet at 5 p.m. tomorrow.", "abbreviation kept")

// MARK: - SpeechSegmenter.finish

/// Counts model calls; returns a fixed string per call.
final class CountingTranscriber: Transcribing {
    var calls: [Int] = []
    func prepare() async throws {}
    func transcribe(_ samples: [Float]) async throws -> String {
        calls.append(samples.count)
        return "Tail."
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
    // word is loud enough that trimSpeech would keep it — must still re-decode.
    let (text, calls) = await finishCalls(tail: silence(0.5) + tone(0.06, amplitude: 0.02) + silence(0.44))
    expect(text, "Tail.", "quiet word in tail re-decodes last chunk")
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
    // Speculation covers the tail and only silence followed: no model call.
    let chunk = tone(7), fake = CountingTranscriber()
    let samples = chunk + tone(2) + silence(1)
    let text = try! await SpeechSegmenter.finish(
        samples, chunkStarts: [0], texts: ["Chunk one."], committed: chunk.count,
        speculation: (chunk.count + 2 * 16_000 + 8_000, "Spec."), transcriber: fake)
    expect(text, "Chunk one. Spec.", "speculation reused")
    expect(fake.calls.description, "[]", "speculation: no model call")
    // Speech after the speculation: decode the tail instead.
    let resumed = try! await SpeechSegmenter.finish(
        samples + tone(1), chunkStarts: [0], texts: ["Chunk one."], committed: chunk.count,
        speculation: (chunk.count + 2 * 16_000 + 8_000, "Spec."), transcriber: fake)
    expect(resumed, "Chunk one. Tail.", "stale speculation ignored")
}
do {
    let (text, calls) = await finishCalls(tail: tone(2))
    expect(text, "Chunk one. Tail.", "speech tail decoded alone")
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
           "start cancel start handsFree stop -", "double-tap locks hands-free; next press stops, release swallowed")
    expect(run([(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.3), (.keyUp, 0.4), (.otherKey, 1), (.characterKey, 2)]),
           "start cancel start handsFree - -", "hands-free event is emitted only when entering the mode")
    expect(run([(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.3), (.keyUp, 2)]),
           "start cancel start stop", "tap then hold is a normal hold")
    expect(run([(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.9), (.keyUp, 1.0)]),
           "start cancel start cancel", "second tap outside window is just a tap")
    expect(run([(.keyDown, 0), (.otherKey, 0.1), (.keyUp, 0.5)]), "start cancel -", "chord within grace cancels")
    expect(run([(.keyDown, 0), (.otherKey, 1), (.keyUp, 2)]), "start - stop", "other key after grace ignored")
    expect(run([(.keyDown, 0), (.escape, 1), (.keyUp, 2)]), "start cancel -", "Esc cancels a hold")
    expect(run([(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.3), (.keyUp, 0.4), (.escape, 3)]),
           "start cancel start handsFree cancel", "Esc cancels hands-free")
    expect(run([(.keyDown, 0), (.keyUp, 1), (.escape, 1.1)]), "start stop cancel", "Esc after release reaches the controller")
    // A release injected by the missed-key-up watchdog is just a .keyUp — it
    // finishes a hold like a real one, and can never do anything in hands-free.
    expect(run([(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.3), (.keyUp, 0.4), (.keyUp, 5)]),
           "start cancel start handsFree -", "a stray key-up in hands-free produces nothing")
}

// keyExpectedDown gates the watchdog: armed exactly while a hold physically
// holds the key — never in hands-free, where the key is up by definition.
do {
    var m = HotkeyStateMachine()
    func down(_ input: HotkeyStateMachine.Input, now: Double) -> String {
        _ = m.handle(input, now: now)
        return m.keyExpectedDown ? "armed" : "safe"
    }
    expect(down(.keyDown, now: 0), "armed", "watchdog arms on hold")
    expect(down(.keyUp, now: 1), "safe", "watchdog disarms on release")
    expect(down(.keyDown, now: 1.2), "armed", "tap start arms")
    expect(down(.keyUp, now: 1.3), "safe", "tap end disarms")
    expect(down(.keyDown, now: 1.6), "armed", "second hold arms")
    expect(down(.keyUp, now: 1.7), "safe", "hands-free never arms the watchdog")
    expect(down(.keyDown, now: 3), "safe", "hands-free ending press doesn't arm")
    expect(down(.keyUp, now: 3.1), "safe", "swallowed release stays unarmed")
}

// MARK: - KeyUpWatchdog

// While armed, a key that is physically up means the real key-up was lost:
// fire one synthetic release and disarm. Never polls unarmed.
do {
    var physical = true
    var releases = 0
    let watchdog = KeyUpWatchdog(isKeyDown: { physical })
    watchdog.onMissedRelease = { releases += 1 }
    watchdog.checkNow()
    expect(releases.description, "0", "unarmed watchdog never polls")
    watchdog.arm()
    expect((watchdog.armed && releases == 0).description, "true", "held key keeps it armed")
    watchdog.checkNow()
    expect(releases.description, "0", "still held: nothing fires")
    physical = false
    watchdog.checkNow()
    expect((!watchdog.armed && releases == 1).description, "true", "physically up fires one release")
    watchdog.checkNow()
    expect(releases.description, "1", "missed release fires once")
    physical = true
    watchdog.arm()
    watchdog.disarm()
    physical = false
    watchdog.checkNow()
    expect(releases.description, "1", "disarmed watchdog is inert")
}

// MARK: - DictationController pipeline (fakes)

final class FakeRecorder: AudioRecording {
    var onLevel: ((Float) -> Void)?
    var lostInput = false
    var next: [Float] = []
    var cancels = 0
    func start() throws {}
    func samples(from start: Int) -> [Float] { [] }
    func stop() -> [Float] { next }
    func cancel() { cancels += 1 }
}
final class FakeHotkey: HotkeyMonitoring {
    var onEvent: ((HotkeyEvent) -> Void)?
    func start() throws {}
    func stop() {}
}
/// Returns "clip <seconds>" after a delay that is longer for longer clips' ids given.
final class SlowTranscriber: Transcribing {
    var delays: [Int: UInt64] = [:]
    /// When set, returned verbatim regardless of the clip length.
    var text: String?
    func prepare() async throws {}
    func transcribe(_ samples: [Float]) async throws -> String {
        let seconds = samples.count / 16_000
        try await Task.sleep(nanoseconds: delays[seconds] ?? 50_000_000)
        return text ?? "Clip \(seconds)."
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

    hotkey.onEvent?(.handsFree)
    expect(controller.isHandsFree.description, "false", "idle hands-free event does not show a lock")
    hotkey.onEvent?(.start)
    expect(controller.isHandsFree.description, "false", "ordinary hold does not show a lock")
    hotkey.onEvent?(.handsFree)
    expect(controller.isHandsFree.description, "true", "second short tap shows the hands-free lock")
    hotkey.onEvent?(.cancel)
    expect(controller.isHandsFree.description, "false", "cancel clears the hands-free lock")
    hotkey.onEvent?(.start)
    hotkey.onEvent?(.handsFree)
    hotkey.onEvent?(.stop)
    expect(controller.isHandsFree.description, "false", "release clears the lock before processing")

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

    // A3: a take that transcribes to nothing is surfaced, not silent.
    paster.pasted = []
    sounds.log = []
    transcriber.delays = [:]
    transcriber.text = ""
    dictate(seconds: 1)
    await settle()
    expect(paster.pasted.description, "[]", "empty transcript pastes nothing")
    expect((controller.statusMessage?.contains("speech") ?? false).description, "true", "empty transcript reported")
    expect(sounds.log.contains("error").description, "true", "empty transcript plays error")

    // A3: an all-filler take says what happened instead of vanishing.
    sounds.log = []
    transcriber.text = "um uh"
    dictate(seconds: 1)
    await settle()
    expect((controller.statusMessage?.contains("filler") ?? false).description, "true", "all-filler take reported")
    expect(sounds.log.contains("error").description, "true", "all-filler take plays error")

    // A3: the stale warning clears the moment the next take starts.
    transcriber.text = nil
    dictate(seconds: 1)
    await settle()
    expect((controller.statusMessage == nil).description, "true", "status message clears on next take")
    expect(paster.pasted.description, "[\"Clip 1.\"]", "next take still pastes")
}
await pipelineTests()

// MARK: - Lead storage

// Dictation data is private: the data dir and every file in it must be
// readable only by the owner (~/Library/Application Support is world-readable).
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    setenv("WHISP_DATA_DIR", dir.path, 1)
    func perm(_ url: URL) -> String {
        let attrs = try! FileManager.default.attributesOfItem(atPath: url.path)
        return String(format: "%o", attrs[.posixPermissions] as! Int)
    }
    try! AppPaths.ensureDirectories()
    expect(perm(AppPaths.root), "700", "data dir is user-only")
    expect(perm(AppPaths.recordingsDir), "700", "recordings dir is user-only")
    let permHistory = HistoryStore(fileURL: AppPaths.historyFile)
    try! permHistory.append(HistoryEntry(id: "t1", date: Date(), durationSec: 1, raw: "r", cleaned: "c", latencyMs: 1))
    expect(perm(AppPaths.historyFile), "600", "history file is user-only")
    AppPaths.ensureDictionaryTemplate()
    expect(perm(AppPaths.dictionaryFile), "600", "dictionary file is user-only")
    let permArchive = RecordingArchive(directory: AppPaths.recordingsDir)
    _ = try! permArchive.save(samples: [0.1, 0.2], id: "t1")
    expect(perm(AppPaths.recordingsDir.appendingPathComponent("t1.wav")), "600", "wav is user-only")
}

// MARK: - A2 Reliability

// The capture buffer must cover the 10-minute take cap and be grown on the
// caller's thread (start() calls reserveTakeCapacity() before touching the
// engine, which can't run on this VM), then shrink back after the take.
do {
    let rec = MicRecorder()
    expect(rec.reservedSampleCapacity < 16_000 * 600 ? "idle" : "full",
           "idle", "capture buffer starts at idle reserve")
    rec.reserveTakeCapacity()
    expect(rec.reservedSampleCapacity >= 16_000 * 600 ? "full" : "under",
           "full", "capture buffer covers 10-min cap")
    _ = rec.stop()
    expect(rec.reservedSampleCapacity < 16_000 * 600 ? "shrunk" : "held",
           "shrunk", "buffer releases take-size capacity after stop()")
}

// A character key early in a Right Option hold is an Option+char chord
// (@, Option+Backspace, ...) even after a dwell — cancel within characterGrace.
// Later it's a stray key during real dictation and must not discard the take.
do {
    func run(_ inputs: [(HotkeyStateMachine.Input, Double)]) -> String {
        var m = HotkeyStateMachine()
        return inputs.map { m.handle($0.0, now: $0.1).map { "\($0)" } ?? "-" }.joined(separator: " ")
    }
    expect(run([(.keyDown, 0), (.characterKey, 0.8), (.keyUp, 0.9)]), "start cancel -",
           "Option+char after a dwell cancels")
    expect(run([(.keyDown, 0), (.characterKey, 3), (.keyUp, 4)]), "start - stop",
           "stray key mid-dictation keeps the take")
    expect(run([(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.3), (.characterKey, 1.2), (.keyUp, 1.3)]),
           "start cancel start cancel -", "Option+char cancels a second hold")
    // Hands-free: our key is physically up — typed characters are just typing.
    expect(run([(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.3), (.keyUp, 0.4),
                (.characterKey, 2), (.characterKey, 2.1), (.keyDown, 3), (.keyUp, 3.1)]),
           "start cancel start handsFree - - stop -", "chars in hands-free are ignored")
    // Modifier presses keep the chordGrace semantics.
    expect(run([(.keyDown, 0), (.otherKey, 0.1), (.keyUp, 0.5)]), "start cancel -",
           "modifier within grace cancels")
    expect(run([(.keyDown, 0), (.otherKey, 1), (.keyUp, 2)]), "start - stop",
           "modifier after grace ignored")
}

// A crash or force-quit while muted must not leave system audio dead: mute()
// leaves a JSON sentinel, restore() deletes it, and the next launch's
// repairAfterCrash() replays it. Verified here for the file lifecycle and the
// decode+apply path (against a bogus device ID — no audio device on this VM);
// device-side restore is verified on hardware.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-mute-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let sentinel = dir.appendingPathComponent("muted-device.json")
    let fm = FileManager.default

    // No sentinel -> nothing to do.
    SystemAudioMuter.repairAfterCrash(sentinelURL: sentinel)
    expect(fm.fileExists(atPath: sentinel.path).description, "false", "no sentinel is a no-op")

    // Corrupt sentinel -> consumed, no crash, no write to any device.
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try! "not json".write(to: sentinel, atomically: true, encoding: .utf8)
    SystemAudioMuter.repairAfterCrash(sentinelURL: sentinel)
    expect(fm.fileExists(atPath: sentinel.path).description, "false", "corrupt sentinel removed")

    // Well-formed sentinels (both paths) -> decoded, applied (device dead here:
    // apply is a no-op), file removed.
    try! #"{"deviceID":999999,"method":{"mute":{"wasMuted":false}}}"#
        .write(to: sentinel, atomically: true, encoding: .utf8)
    SystemAudioMuter.repairAfterCrash(sentinelURL: sentinel)
    expect(fm.fileExists(atPath: sentinel.path).description, "false", "mute sentinel repaired + removed")
    try! #"{"deviceID":999999,"method":{"volumes":{"_0":[{"element":0,"previous":0.5}]}}}"#
        .write(to: sentinel, atomically: true, encoding: .utf8)
    SystemAudioMuter.repairAfterCrash(sentinelURL: sentinel)
    expect(fm.fileExists(atPath: sentinel.path).description, "false", "volumes sentinel repaired + removed")
}

// HotkeyPermissionTracker replaces the old 5 s polling timer: activation
// events feed it the current grant/running state and it emits stop/start
// decisions with the same semantics (stop once on loss, restart once on regain).
do {
    var t = HotkeyPermissionTracker()
    expect("\(t.check(hotkeyPermissionsGranted: true, hotkeyRunning: true))",
           "none", "healthy: nothing to do")
    expect("\(t.check(hotkeyPermissionsGranted: false, hotkeyRunning: true))",
           "stopHotkey", "grant lost while running")
    expect("\(t.check(hotkeyPermissionsGranted: false, hotkeyRunning: false))",
           "none", "loss reported once")
    expect("\(t.check(hotkeyPermissionsGranted: true, hotkeyRunning: false))",
           "startHotkey", "grants returned")
    expect("\(t.check(hotkeyPermissionsGranted: true, hotkeyRunning: true))",
           "none", "settled: no repeat start")

    var t2 = HotkeyPermissionTracker()
    expect("\(t2.check(hotkeyPermissionsGranted: false, hotkeyRunning: false))",
           "none", "lost while not running: nothing to stop")
    expect("\(t2.check(hotkeyPermissionsGranted: true, hotkeyRunning: false))",
           "none", "regain without a stop doesn't start")
}

@MainActor
func a2RaceTests() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-a2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = FakeRecorder(), hotkey = FakeHotkey(), paster = FakePaster()
    let transcriber = SlowTranscriber(), sounds = CountingSounds()
    let settings = AppSettings(defaults: UserDefaults(suiteName: "whisp-tests-\(UUID().uuidString)")!)
    settings.autoMute = false
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

    // Esc while recording: capture is cancelled, nothing is transcribed or pasted.
    paster.pasted = []
    hotkey.onEvent?(.start)
    hotkey.onEvent?(.cancel)
    await settle()
    expect(recorder.cancels.description, "1", "Esc mid-recording cancels capture")
    expect(paster.pasted.description, "[]", "Esc mid-recording: nothing pasted")

    // Rapid press/release (empty capture): discarded under minimumDuration, clean state.
    dictate(seconds: 0)
    await settle()
    expect(paster.pasted.description, "[]", "instant release discards, no paste")
    expect(controller.state.rawValue, "idle", "state settles to idle")

    // Quit (shutdown) while a clip is transcribing: the pending paste is dropped.
    paster.pasted = []
    transcriber.delays = [2: 300_000_000]
    dictate(seconds: 2)
    controller.shutdown()
    await settle()
    expect(paster.pasted.description, "[]", "shutdown drops the in-flight paste")
    expect(controller.state.rawValue, "idle", "idle after shutdown")
}
await a2RaceTests()

// While recording, each live tick tells the engine how much audio a release
// decode would get, so an engine with several encoder sizes can wake that one.
final class GrowingRecorder: AudioRecording {
    var onLevel: ((Float) -> Void)?
    let lostInput = false
    private var startedNs: UInt64 = 0
    func start() throws { startedNs = DispatchTime.now().uptimeNanoseconds }
    func samples(from start: Int) -> [Float] {
        let heard = Int((DispatchTime.now().uptimeNanoseconds - startedNs) / 62_500)
        return start < heard ? [Float](repeating: 0.1, count: heard - start) : []
    }
    func stop() -> [Float] { samples(from: 0) }
    func cancel() {}
}
final class PrewarmLog: Transcribing {
    private let lock = NSLock()
    private var logged: [Int] = []
    var sizes: [Int] { lock.withLock { logged } }
    func prepare() async throws {}
    func transcribe(_ samples: [Float]) async throws -> String { "Done." }
    func prewarm(forSamples samples: Int) async { lock.withLock { logged.append(samples) } }
}
@MainActor
func prewarmTests() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-prewarm-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let hotkey = FakeHotkey(), engine = PrewarmLog()
    let settings = AppSettings(defaults: UserDefaults(suiteName: "whisp-tests-\(UUID().uuidString)")!)
    settings.autoMute = false
    settings.sounds = false
    settings.keepRecordings = false
    let controller = DictationController(
        transcriber: engine, recorder: GrowingRecorder(), hotkey: hotkey, paster: FakePaster(),
        cleaner: FillerCleaner(), muter: NoMuter(), sounds: CountingSounds(), settings: settings,
        history: HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl")),
        recordings: RecordingArchive(directory: dir.appendingPathComponent("recordings")))
    controller.startHotkey()
    hotkey.onEvent?(.start)
    try? await Task.sleep(nanoseconds: 450_000_000)
    hotkey.onEvent?(.stop)
    try? await Task.sleep(nanoseconds: 100_000_000)
    let sizes = engine.sizes
    expect(sizes.count >= 2 ? "every tick" : "\(sizes)", "every tick", "prewarm runs on live ticks")
    expect(sizes == sizes.sorted() && (sizes.last ?? 0) >= 3 * SpeechSegmenter.tick ? "growing" : "\(sizes)",
           "growing", "prewarm gets the audio heard so far")
}
await prewarmTests()

// MARK: - A1 Speed

// trimSpeech: a loud mid-clip noise must not set the bar for quiet edge words.
do {
    let quiet = { (s: Double) in tone(s, amplitude: 0.02) }
    let coughy = silence(0.5) + quiet(0.5) + silence(0.5) + tone(0.3, amplitude: 0.9) + silence(0.5) + quiet(0.5) + silence(0.5)
    // With a max-based threshold (6% of the 0.9 cough) the quiet words fall below it
    // and trim keeps only ~0.9 s around the cough. A p90 reference keeps them.
    expect(SpeechSegmenter.trimSpeech(coughy).count > 2 * 16_000 ? "kept edges" : "\(SpeechSegmenter.trimSpeech(coughy).count)",
           "kept edges", "trim keeps quiet words next to a cough")
    // Ordinary loud speech trims exactly as before: speech plus the 150 ms margins.
    let clean = silence(0.5) + tone(2) + silence(0.5)
    let kept = SpeechSegmenter.trimSpeech(clean).count
    expect(abs(kept - 36_800) <= 320 ? "in margin" : "\(kept)", "in margin", "loud speech keeps 150 ms margins")
    expect(SpeechSegmenter.trimSpeech(silence(2)).isEmpty.description, "true", "all silence trims to empty")
    expect(SpeechSegmenter.trimSpeech(tone(0.01)).count.description, "160", "sub-frame clip untouched")

    // finish() must judge a quiet trailing word by the same p90 rule: a cough in
    // the last chunk must not make it skip the re-decode and drop the word.
    let chunk = quiet(6.7) + tone(0.3, amplitude: 0.9)
    let tail = silence(0.5) + quiet(0.06) + silence(0.44)
    let fake = CountingTranscriber()
    _ = try! await SpeechSegmenter.finish(
        chunk + tail, chunkStarts: [0], texts: ["Chunk one."], committed: chunk.count, transcriber: fake)
    expect(fake.calls.description, "[\(chunk.count + tail.count)]", "cough in chunk: quiet tail word re-decodes")
}

// Paster: the restore snapshot is captured at target() and the user's
// clipboard comes back after ⌘V. Runs against the real general pasteboard.
@MainActor
func pasterTests() async {
    let board = NSPasteboard.general
    let paster = Paster()
    let marker = "whisp-test-marker-\(UUID().uuidString.prefix(6))"

    board.clearContents()
    board.setString(marker, forType: .string)
    let t = paster.target()
    _ = await paster.paste("dictated words", into: t)
    expect(board.string(forType: .string) ?? "?", "dictated words", "paste writes text")
    try? await Task.sleep(nanoseconds: 450_000_000)
    expect(board.string(forType: .string) ?? "?", marker, "clipboard restored after paste")

    // The user copies between key release and paste -> the newer clipboard wins.
    let t2 = paster.target()
    _ = await t2.clipboard?.value // let the key-release capture see `marker` first
    board.clearContents()
    board.setString("user copy", forType: .string)
    _ = await paster.paste("more words", into: t2)
    try? await Task.sleep(nanoseconds: 450_000_000)
    expect(board.string(forType: .string) ?? "?", "user copy", "newer clipboard restored")
}
// Opt-in: it overwrites the real clipboard and posts a real ⌘V into the frontmost app.
if ProcessInfo.processInfo.environment["WHISP_TEST_PASTEBOARD"] == "1" {
    await pasterTests()
} else {
    print("skipped Paster tests (real clipboard + ⌘V); set WHISP_TEST_PASTEBOARD=1 to run")
}

// MARK: - Auto-learn

// The learner's "real word" oracle is a set here; "Pychy" is the only unknown
// (model-junk) word in the fixtures.
let knownWords: Set<String> = [
    "soul", "use", "the", "model", "open", "now", "we", "sell", "on", "vinted",
    "meet", "tuesday", "monday", "should", "ship", "it", "send", "to", "him",
    "hello", "there", "with", "and", "more", "typed", "after", "pi", "cli",
    "fully", "rewritten", "this", "is", "a", "different", "story", "today", "i",
]
let learner = CorrectionLearner(isKnownWord: { knownWords.contains($0.lowercased()) })

func checkLearn(_ pasted: String, _ current: String,
                _ expected: [CorrectionLearner.Decision],
                rules: [(from: [String], to: String)] = [],
                _ label: String, line: Int = #line) {
    let decisions = learner.decide(pasted: pasted, current: current, existingRules: rules)
    expect((decisions == expected).description, "true",
           "\(label) — got \(decisions)", line: line)
}

// The required table from the brief.
checkLearn("I use the soul model.", "I use the Sol model.",
           [.pending(from: "soul", to: "Sol", kind: .replacement)], "soul→Sol: pending")
checkLearn("Open Pychy now.", "Open pi CLI now.",
           [.replacement(from: "Pychy", to: "pi CLI")], "junk from learns right away")
checkLearn("We sell on vinted.", "We sell on Vinted.",
           [.pending(from: "vinted", to: "Vinted", kind: .term)], "case-only pending")
checkLearn("Meet on Tuesday.", "Meet on Monday.", [], "Tuesday→Monday never")
checkLearn("We should ship it.", "We should not ship it.", [], "insertion ignored")
checkLearn("Send it to him.", "Send it too him.", [], "stoplist ignored")
checkLearn("Hello there.", "Hello there!", [], "punctuation-only ignored")
checkLearn("We should ship it today.", "A fully rewritten different story.", [],
           "rewrite learns nothing")
checkLearn("Open Pychy now.", "Open pi CLI now. And more typed after.",
           [.replacement(from: "Pychy", to: "pi CLI")], "typed-after still learns")
// The last pasted word fixed, then more typed (or already there) after it:
// only the fix is learned, never the words that follow it.
checkLearn("Open Pychy.", "Open pi CLI. Thanks", [.replacement(from: "Pychy", to: "pi CLI")],
           "edited last word + typed after learns only the fix")
checkLearn("Open Pychy.", "Open pi CLI. Text that was already after the cursor.",
           [.replacement(from: "Pychy", to: "pi CLI")], "edited last word + existing text after")
checkLearn("Open Pychy", "Open pi CLI Thanks", [], "unpunctuated last word + text after: end unknown")
checkLearn("Open Pychy now.", "", [], "deletion learns nothing")
checkLearn("I use the Sol model.", "I use the soul model.",
           [.removed(from: "soul", to: "Sol")],
           rules: [(["soul"], "Sol")], "undo removes the rule")
checkLearn("Open Pychy now with vinted.", "Open pi CLI now with Vinted.",
           [.replacement(from: "Pychy", to: "pi CLI"),
            .pending(from: "vinted", to: "Vinted", kind: .term)], "two fixes in one take")

// Long takes: one fix in the middle of ~3000 words learns just that fix, and
// the diff stays cheap because only the changed middle is compared.
do {
    let filler = Array(repeating: "we sell on the model and more", count: 215).joined(separator: " ")
    let pasted = filler + " Open Pychy now. " + filler + "."
    let current = filler + " Open pi CLI now. " + filler + ". And more typed after."
    let start = DispatchTime.now()
    checkLearn(pasted, current, [.replacement(from: "Pychy", to: "pi CLI")], "one fix in a 3000-word take")
    checkLearn(pasted, pasted + " And more typed after.", [], "3000-word take, only typed after")
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    print(String(format: "learner on 2 x 3000-word takes: %.2f ms", ms))
}

// Anchor search with shifted offsets: the owner typed before the pasted span,
// so the anchor sits at a different position in the re-read window — the span
// is still found exactly once.
do {
    let window = "The owner added a sentence first. I use the soul model. Trailing."
    let shifted = window.replacingOccurrences(of: "The owner added", with: "The owner really added")
    let r1 = EditWatcher.singleOccurrence(of: "I use the ", in: window)
    let r2 = EditWatcher.singleOccurrence(of: "I use the ", in: shifted)
    expect(r1 != nil && r2 != nil ? "found" : "nil", "found", "anchor found at shifted offset")
    if let r2 {
        expect(String(shifted[r2.upperBound...]), "soul model. Trailing.", "text after shifted anchor")
    }
    // An anchor that occurs twice in the window is ambiguous: learn nothing.
    let repeatWindow = "I use the soul model. Again I use the Sol model."
    expect(EditWatcher.singleOccurrence(of: "I use the ", in: repeatWindow) == nil ? "nil" : "found",
           "nil", "ambiguous anchor learns nothing")
    // Paste at document start: empty anchor pins to the window start.
    let empty = EditWatcher.singleOccurrence(of: "", in: "Sol model.")
    expect(empty != nil && String("Sol model."[empty!.upperBound...]) == "Sol model." ? "ok" : "bad",
           "ok", "empty anchor = document start")
}

// Apply path: pending file + dictionary.json in a temp dir.
let learnDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("whisp-learn-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: learnDir, withIntermediateDirectories: true)
let dictFile = learnDir.appendingPathComponent("dictionary.json")
let pendFile = learnDir.appendingPathComponent("corrections-pending.json")
try """
{
  "terms": [],
  "replacements": []
}
""".write(to: dictFile, atomically: true, encoding: .utf8)

let watcher = EditWatcher(learner: learner, dictionaryFile: dictFile,
                          pendingFile: pendFile, isEnabled: { true })

func dictHas(_ needle: String) -> Bool {
    (try? String(contentsOf: dictFile, encoding: .utf8).contains(needle)) ?? false
}

// 1st sighting of a real-word fix: pending only, dictionary untouched.
watcher.apply(learner.decide(pasted: "I use the soul model.",
                                   current: "I use the Sol model.", existingRules: []))
expect(dictHas("Sol").description, "false", "pending writes nothing to dictionary")
expect((try? String(contentsOf: pendFile, encoding: .utf8))?
        .contains("soul") == true ? "pending" : "empty", "pending", "fix counted in pending file")

// 2nd sighting: promoted into dictionary.json.
watcher.apply(learner.decide(pasted: "I use the soul model.",
                                   current: "I use the Sol model.", existingRules: []))
expect(dictHas("soul").description, "true", "second sighting writes the rule")
expect(dictHas("Sol").description, "true", "rule maps to Sol")
expect(watcher.lastSummary?.contains("soul → Sol") ?? false ? "shown" : "hidden",
       "shown", "menu shows Learned: soul → Sol")

// Junk fix writes immediately.
watcher.apply(learner.decide(pasted: "Open Pychy now.",
                                   current: "Open pi CLI now.", existingRules: []))
expect(dictHas("Pychy").description, "true", "junk fix writes at once")
expect(dictHas("pi CLI").description, "true", "junk fix target saved")

// Undo of the learned batch restores the pre-learn state.
watcher.undoLast()
expect(dictHas("Pychy").description, "false", "undo removes the junk fix")

// Undo: owner corrects a pasted Sol back to soul — the from is removed.
watcher.apply(learner.decide(pasted: "I use the Sol model.",
                                   current: "I use the soul model.",
                                   existingRules: PersonalDictionary.loadPairs(fileURL: dictFile)))
expect(dictHas("soul").description, "false", "undone rule loses its from")

// Malformed dictionary.json: no write, no crash.
try "not json at all {{{".write(to: dictFile, atomically: true, encoding: .utf8)
watcher.apply(learner.decide(pasted: "Open Pychy now.",
                                   current: "Open pi CLI now.", existingRules: []))
expect((try? String(contentsOf: dictFile, encoding: .utf8)) ?? "", "not json at all {{{",
       "malformed dictionary never clobbered")

// MARK: - A3 Text+UI

// Adversarial cleanup table — real sentences the cleaner must not damage.
// A deletion here is a trust bug: cleanup may only subtract fillers,
// stutters, and restarted phrases.
do {
    let adversarial: [(String, String)] = [
        // Words people say twice on purpose (names, expressions, onomatopoeia)
        ("Hear, hear!", "Hear, hear!"),
        ("Order the mahi mahi.", "Order the mahi mahi."),
        ("We're going to Bora Bora in June.", "We're going to Bora Bora in June."),
        ("Walla Walla onions are sweet.", "Walla Walla onions are sweet."),
        ("A yo yo rolled by.", "A yo yo rolled by."),
        ("The odds are fifty fifty.", "The odds are fifty fifty."),
        ("Keep the details hush hush.", "Keep the details hush hush."),
        ("I do do my best work at night.", "I do do my best work at night."),
        ("Test test, is this thing on?", "Test test, is this thing on?"),
        ("Stop, stop! That tickles.", "Stop, stop! That tickles."),
        ("He served time in Sing Sing.", "He served time in Sing Sing."),
        ("We flew to Pago Pago.", "We flew to Pago Pago."),
        ("She adopted a chow chow.", "She adopted a chow chow."),
        ("In twenty twenty we moved.", "In twenty twenty we moved."),
        ("It was nineteen nineteen.", "It was nineteen nineteen."),
        ("She sang na na na na.", "She sang na na na na."),
        ("The cow goes moo moo.", "The cow goes moo moo."),
        ("The duck said quack quack.", "The duck said quack quack."),
        ("Honk honk went the horn.", "Honk honk went the horn."),
        ("She wore a mu mu dress.", "She wore a mu mu dress."),
        ("I love a good bon bon.", "I love a good bon bon."),
        ("Ding ding, round two.", "Ding ding, round two."),
        ("Goo goo ga ga, said the baby.", "Goo goo ga ga, said the baby."),
        ("Woo woo, here we go.", "Woo woo, here we go."),
        ("The crowd went rah rah rah.", "The crowd went rah rah rah."),
        ("Yadda yadda yadda, whatever.", "Yadda yadda yadda, whatever."),
        ("Hee hee, that's funny.", "Hee hee, that's funny."),
        ("He laughed haw haw haw.", "He laughed haw haw haw."),
        ("Nudge nudge, wink wink.", "Nudge nudge, wink wink."),
        ("Tut tut, that's naughty.", "Tut tut, that's naughty."),
        ("Tsk tsk, not again.", "Tsk tsk, not again."),
        ("Ring ring, someone's calling.", "Ring ring, someone's calling."),
        ("Woof woof, said the dog.", "Woof woof, said the dog."),
        ("The cat goes meow meow.", "The cat goes meow meow."),
        ("Dum dum, went the beat.", "Dum dum, went the beat."),
        // Emphatic / sequential repeats that aren't restarts
        ("Let's go let's go!", "Let's go let's go!"),
        ("Wake up wake up!", "Wake up wake up!"),
        ("On off on off.", "On off on off."),
        ("Press 1 2 1 2.", "Press 1 2 1 2."),
        ("He ran and ran and ran.", "He ran and ran and ran."),
        ("Up down up down up.", "Up down up down up."),
        ("Thank you thank you.", "Thank you thank you."),
        // Capitalization repair after a sentence-initial removal
        ("I think. um, he agrees.", "I think. He agrees."),
        ("We won. uh, the crowd cheered.", "We won. The crowd cheered."),
        ("It's fine. you know, we should go.", "It's fine. We should go."),
        ("you know, we should go.", "We should go."),
        ("I agree. i mean, it works.", "I agree. It works."),
        // Clock times: quantities and versions aren't times
        ("The rate is at 3.14 percent.", "The rate is at 3.14 percent."),
        ("It grew by 2.45 percent.", "It grew by 2.45 percent."),
        ("We measured at 4.30 inches.", "We measured at 4.30 inches."),
        ("Down by 5.30 kilos.", "Down by 5.30 kilos."),
        ("Rates vary from 2.30 to 4.10 percent.", "Rates vary from 2.30 to 4.10 percent."),
        ("The score rose by 1.50 points.", "The score rose by 1.50 points."),
        ("It's priced at 9.99 dollars.", "It's priced at 9.99 dollars."),
        ("It costs at least 5.30 dollars.", "It costs at least 5.30 dollars."),
        // Clock times that SHOULD convert
        ("Meet me at 5.30.", "Meet me at 5:30."),
        ("See you around 6.15.", "See you around 6:15."),
        ("The meeting ends by 8.45.", "The meeting ends by 8:45."),
        ("Call her 3.45 PM.", "Call her 3:45 PM."),
        ("Meet from 9.00 to 5.30.", "Meet from 9:00 to 5:30."),
        ("The shop is open between 8.30 and 6.00.", "The shop is open between 8:30 and 6:00."),
        ("It runs at 5.30 or 6.00.", "It runs at 5:30 or 6:00."),
        ("Open from 8.30-5.30.", "Open from 8:30-5:30."),
        // Legit near-repeats and near-restarts that must not lose words
        ("We can, we can't.", "We can, we can't."),
        ("I did, I didn't.", "I did, I didn't."),
        ("Like father, like son.", "Like father, like son."),
        ("I like pizza and you know it.", "I like pizza and you know it."),
        ("It is what it is.", "It is what it is."),
        ("You know what, I agree.", "You know what, I agree."),
        ("I mean business.", "I mean business."),
        ("So, the plan is simple.", "So, the plan is simple."),
        ("What he is, is a mystery.", "What he is, is a mystery."),
        ("The reason is is that he left.", "The reason is is that he left."),
        ("Do it don't do it.", "Do it don't do it."),
        ("I had had enough by then.", "I had had enough by then."),
        ("Send it to the ER.", "Send it to the ER."),
        ("It's 5 mm wide.", "It's 5 mm wide."),
    ]
    for (input, output) in adversarial {
        expect(cleaner.clean(input), output, "adversarial(\"\(input)\")")
    }
}

// MARK: - Model download

// RemoteBundle.install: checksum first, and the bundle only appears under its
// final name once fully unpacked.
do {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("whisp-bundle-\(UUID().uuidString)")
    let src = work.appendingPathComponent("src"), cache = work.appendingPathComponent("cache")
    try fm.createDirectory(at: src.appendingPathComponent("weights"), withIntermediateDirectories: true)
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data("mil".utf8).write(to: src.appendingPathComponent("coremldata.bin"))
    try Data("w".utf8).write(to: src.appendingPathComponent("weights/weight.bin"))
    try Data("junk".utf8).write(to: src.appendingPathComponent("._metadata.json"))
    let zip = work.appendingPathComponent("b.zip")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", src.path, zip.path]
    try ditto.run(); ditto.waitUntilExit()
    let sum = try RemoteBundle.sha256Hex(of: zip)

    let name = "parakeet_unified_encoder_w5000_int8.mlmodelc"
    let bad = RemoteBundle(name: name, url: zip, sha256: String(repeating: "0", count: 64))
    expect((try? bad.install(zip: zip, into: cache)) == nil ? "rejected" : "installed",
           "rejected", "checksum mismatch installs nothing")
    expect(fm.fileExists(atPath: cache.appendingPathComponent(name).path) ? "present" : "absent",
           "absent", "no bundle after a bad checksum")

    let good = RemoteBundle(name: name, url: zip, sha256: sum)
    let installed = try await good.fetch(into: cache)  // file:// URL: same path as a real download
    expect(installed.lastPathComponent, name, "bundle installed under its final name")
    expect(fm.fileExists(atPath: installed.appendingPathComponent("weights/weight.bin").path) ? "ok" : "missing",
           "ok", "bundle contents unpacked")
    expect(fm.fileExists(atPath: installed.appendingPathComponent("._metadata.json").path) ? "kept" : "dropped",
           "dropped", "AppleDouble files dropped")
    let leftovers = try fm.contentsOfDirectory(atPath: cache.path).filter { $0 != name }
    expect(leftovers.joined(separator: ","), "", "no staging dirs left behind")
    try? fm.removeItem(at: work)
}
expect(ASREngine.defaultName, "short", "default engine is the short-window one")
expect(String(describing: type(of: ASREngine.make(named: "typo"))), "ShortWindowEngine", "unknown engine name falls back")

// MARK: - Speed

let long = String(repeating: "Um, so I I was, like, thinking we should, you know, ship the the thing. ", count: 40)
let t0 = Date()
for _ in 0..<50 { _ = dictCleaner.clean(long) }
let perCallMs = Date().timeIntervalSince(t0) * 1000 / 50
print(String(format: "clean() on %d chars: %.2f ms", long.count, perCallMs))
if perCallMs > 20 { failures += 1; print("FAIL clean() too slow") }

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
