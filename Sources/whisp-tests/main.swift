import AppKit
import Foundation
import WhispCore

// Plain executable test runner (Command Line Tools ship without XCTest/Testing).
// Exits non-zero on any failure.

// Never touch the owner's real dictations: the suite writes a history line, a
// dictionary and a wav, so point AppPaths at a throwaway folder before the
// first use of it. AppPaths.root is a lazy `let`, so this must run first.
let testDataDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("whisp-tests-\(UUID().uuidString)", isDirectory: true)
setenv("WHISP_DATA_DIR", testDataDir.path, 1)

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
    ("I said dot dot dot and stopped.", "I said dot dot dot and stopped."),
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
    // A number inside a real stutter or restart still drops the words, not the digits.
    ("Go to 4 go to 4 now.", "Go to 4 now."),
    ("We we need room 404 404 today.", "We need room 404 404 today."),
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

// MARK: - TextFormatter
//
// Fixed rules, no model: the same words, written the way he would write them.
// Each case below is one rule; "must not fire" cases pin what has to be left alone.

let formatter = TextFormatter()
let formatCases: [(String, String, String)] = [
    // Numbers twenty and up are written in digits; anything smaller stays a word.
    ("Send twenty five dollars today.", "Send $25 today.", "number and money"),
    ("Two hundred fifty units shipped.", "250 units shipped.", "hundreds"),
    ("We need one hundred and five of them.", "We need 105 of them.", "and inside a number"),
    ("It costs fifty bucks.", "It costs $50.", "slang money"),
    ("That is twenty five percent off.", "That is 25% off.", "percentage"),
    ("Wait twenty minutes.", "Wait 20 minutes.", "tens alone"),
    ("Three hundred thousand records.", "300000 records.", "thousand"),
    ("The twenty fifth of May.", "The 25th of May.", "ordinal"),
    ("I have five apples.", "I have five apples.", "must not fire: small count"),
    ("One thing at a time.", "One thing at a time.", "must not fire: one thing"),
    ("I have told you a hundred times.", "I have told you a hundred times.", "must not fire: a hundred times"),
    ("It costs five dollars.", "It costs five dollars.", "must not fire: small money stays words"),
    ("The five of us are here.", "The five of us are here.", "must not fire: five of us"),
    // A year or a price said the way people say it is not one number: half a
    // reading would write a wrong number, so all of it stays words.
    ("We met in twenty nineteen.", "We met in twenty nineteen.", "must not fire: spoken year"),
    ("I said twenty ten.", "I said twenty ten.", "must not fire: spoken year"),
    ("Twenty twelve was a good year.", "Twenty twelve was a good year.", "must not fire: spoken year"),
    ("In twenty twenty four we shipped it.", "In twenty twenty four we shipped it.",
     "must not fire: spoken year"),
    ("Flight twenty five twenty.", "Flight twenty five twenty.", "must not fire: number read in pairs"),
    ("That costs two fifty.", "That costs two fifty.", "must not fire: price read in pairs"),
    ("Three ninety nine for the shirt.", "Three ninety nine for the shirt.",
     "must not fire: price read in pairs"),
    ("I said dot dot dot and stopped.", "I said dot dot dot and stopped.", "must not fire: spoken ellipsis"),
    // Spoken clock times, only after a time word and only with a minute.
    ("Meet me at five thirty.", "Meet me at 5:30.", "clock time"),
    ("The call is at ten fifteen tomorrow.", "The call is at 10:15 tomorrow.", "clock time, teens"),
    ("Let us meet at five oh five.", "Let us meet at 5:05.", "clock time, leading zero"),
    ("Meet me at five.", "Meet me at five.", "must not fire: bare hour"),
    ("At one point we agreed.", "At one point we agreed.", "must not fire: at one point"),
    // Spoken file paths.
    ("Open src slash main dot swift.", "Open src/main.swift.", "path"),
    ("Open src slash components.", "Open src/components.", "single slash"),
    ("Go to www dot example dot com.", "Go to www.example.com.", "web address"),
    ("Dot env is the config file.", ".env is the config file.", "dot file at a sentence start"),
    ("Edit dot env first.", "Edit dot env first.", "must not fire: one spoken dot alone"),
    ("Check the package dot json file.", "Check the package dot json file.",
     "must not fire: one spoken dot alone"),
    ("We slash prices today.", "We slash prices today.", "must not fire: slash as a verb"),
    ("We slash prices slash costs today.", "We slash prices slash costs today.",
     "must not fire: two verbs, not a path"),
    ("Put a dot of paint on it.", "Put a dot of paint on it.", "must not fire: a dot of paint"),
    // Sentences: capital, closing stop, question mark, opener comma.
    ("we should ship it", "We should ship it.", "closing stop and capital"),
    ("is it working", "Is it working?", "question"),
    ("do you want coffee", "Do you want coffee?", "question"),
    ("where is the file", "Where is the file?", "question with wh-"),
    ("it's fine, right.", "It's fine, right?", "tag question"),
    ("what is done is done.", "What is done is done.", "must not fire: not a question"),
    ("do not do that.", "Do not do that.", "must not fire: not a question"),
    ("yes I think so.", "Yes, I think so.", "opener comma"),
    ("no it isn't.", "No, it isn't.", "opener comma"),
    ("okay let's go.", "Okay, let's go.", "opener comma"),
    ("no no, that's wrong.", "No no, that's wrong.", "must not fire: doubled no"),
    ("so we went home.", "So we went home.", "must not fire: no comma after so"),
    ("we ship today. then we rest.", "We ship today. Then we rest.", "second sentence"),
]
for (input, expected, rule) in formatCases {
    expect(formatter.format(input), expected, "format(\(input)) - \(rule)")
}

// A formatting pass may rewrite how a word is written, never drop one. The only
// words it may remove are a number's money or percentage word, a spoken path
// separator, and the "and" inside a spelled number.
let absorbedWords: Set<String> = [
    "dollars", "dollar", "bucks", "buck", "cents", "cent", "percent", "per", "slash",
    "dot", "underscore", "backslash", "forward", "and",
]

// Spelled numbers become digits, so their words are allowed to disappear; every
// other word has to survive.
let numberWords: Set<String> = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
    "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty",
    "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion", "oh",
    "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
    "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth",
    "seventeenth", "eighteenth", "nineteenth", "twentieth", "thirtieth", "fortieth",
    "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth", "hundredth",
    "thousandth", "millionth",
]

func testWords(_ text: String) -> [String] {
    var out: [String] = []
    var current = ""
    for ch in text.lowercased() {
        if ch.isLetter || ch.isNumber {
            current.append(ch)
        } else if !current.isEmpty {
            out.append(current)
            current = ""
        }
    }
    if !current.isEmpty { out.append(current) }
    return out
}

for (input, _, rule) in formatCases {
    // The real output, not the table's expectation: a wrong value written in digits
    // is caught by the equality check above, and this one is for a lost word.
    let actual = formatter.format(input)
    var have: [String: Int] = [:]
    for word in testWords(actual) { have[word, default: 0] += 1 }
    for word in testWords(input) {
        if word.contains(where: \.isNumber) || absorbedWords.contains(word) { continue }
        if numberWords.contains(word) { continue }
        if let count = have[word], count > 0 {
            have[word] = count - 1
        } else {
            failures += 1
            print("FAIL format lost a word: \(word) in \(rule): \(input) -> \(actual)")
        }
    }
}

// Real takes in his fast, casual style, through the whole pipeline in order:
// clean first, then format. Printed so the before and after can be read side by side.
let pipelineCases: [(String, String)] = [
    ("um so I I was thinking we should, like, ship it today",
     "So I was thinking we should ship it today."),
    ("the the build takes twenty five minutes and it's, uh, at five thirty",
     "The build takes 25 minutes and it's at 5:30."),
    ("open src slash main dot swift and change the timeout to twenty five percent",
     "Open src/main.swift and change the timeout to 25%."),
    ("it costs two hundred fifty dollars, right",
     "It costs $250, right?"),
    ("is it working yet or do we need, you know, to restart it",
     "Is it working yet or do we need to restart it?"),
]
print("before and after, fast casual dictation:")
for (raw, expected) in pipelineCases {
    let after = formatter.format(cleaner.clean(raw))
    print("  before: \(raw)")
    print("  after:  \(after)")
    expect(after, expected, "pipeline(clean then format) \(raw)")
}

// Formatting twice must give the same text: the app may clean a take it already
// formatted when a recovered take is re-read.
for (_, expected, _) in formatCases {
    expect(formatter.format(expected), expected, "format is idempotent: \(expected)")
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

// MARK: - Coding word pack

// Built in and always on: none of this needs a dictionary.json rule. Each row is
// a sentence in fast casual dictation, then what has to reach the screen.
let packCases: [(String, String)] = [
    // File names, both spoken shapes
    ("put the rules in agents dot md", "put the rules in AGENTS.md"),
    ("update agents MD before you ship", "update AGENTS.md before you ship"),
    ("read claude dot md first", "read CLAUDE.md first"),
    ("put the rules in claude md", "put the rules in CLAUDE.md"),
    ("the soul dot md is the personality", "the SOUL.md is the personality"),
    ("add it to the readme", "add it to the README.md"),
    ("copy the dot env and fill it in", "copy the .env and fill it in"),
    ("bump package json and push", "bump package.json and push"),
    ("the ts config needs another alias", "the tsconfig.json needs another alias"),
    ("docker compose dot yaml has the ports", "docker-compose.yml has the ports"),
    ("put node modules in git ignore", "put node modules in .gitignore"),
    ("the make file has three targets", "the Makefile has three targets"),
    // Harnesses and AI tools
    ("claude code keeps rewriting my comments", "Claude Code keeps rewriting my comments"),
    ("ask chat gpt to check it", "ask ChatGPT to check it"),
    ("co-pilot wrote a worse version", "Copilot wrote a worse version"),
    ("open cursor and run the tests", "open Cursor and run the tests"),
    ("hermes is still running", "Hermes is still running"),
    ("push it to github", "push it to GitHub"),
    ("vs code is already open", "VS Code is already open"),
    ("the windsurf tab is lagging", "the Windsurf tab is lagging"),
    // Everyday words
    ("the pr on git hub is red", "the PR on GitHub is red"),
    ("put it in the jason file", "put it in the JSON file"),
    ("parse the jason and print it", "parse the JSON and print it"),
    ("run n p m install", "run npm install"),
    ("it only works on local host", "it only works on localhost"),
    ("use ssh to get in", "use SSH to get in"),
    ("the sub agent blew up", "the sub-agent blew up"),
    ("the mcp server is down", "the MCP server is down"),
    ("ask grok about the llm", "ask Grok about the LLM"),
    ("the gpu is pegged", "the GPU is pegged"),
    ("the api key is missing", "the API key is missing"),
    ("check the cli help", "check the CLI help"),
    ("fix the json output", "fix the JSON output"),
    ("it is a yaml thing", "it is a YAML thing"),
    ("post gres keeps dropping it", "Postgres keeps dropping it"),
    ("deploy it to vercel", "deploy it to Vercel"),
    ("the supabase keys are in the vault", "the Supabase keys are in the vault"),
    ("kube control rollout status", "kubectl rollout status"),
    ("swift ui is fine here", "SwiftUI is fine here"),
    ("it is core ml under the hood", "it is CoreML under the hood"),
    ("it works on mac os but not i os", "it works on macOS but not iOS"),
    ("typescript is fine, java script is not", "TypeScript is fine, JavaScript is not"),
    ("the cli is written in rust", "the CLI is written in Rust"),
    ("the cli is written in go", "the CLI is written in Go"),
    ("write a python script for it", "write a Python script for it"),
    ("open zed and paste it", "open Zed and paste it"),
    ("join the slack channel", "join the Slack channel"),
    ("the linear issue is stale", "the Linear issue is stale"),
    ("the notion page is empty", "the Notion page is empty"),
    ("figma has the new icons", "Figma has the new icons"),
    ("docker is not running", "Docker is not running"),
    ("ask capy to do it", "ask Capy to do it"),
    ("the codync agent is stuck", "the Codync agent is stuck"),
]
for (input, output) in packCases {
    expect(cleaner.clean(input), output, "pack: \"\(input)\"")
}

// The other half of the table: an English word that is also a product or language
// name must stay English, and a file name already spelled out must not grow a
// second extension.
let packUntouched: [String] = [
    "Jason called about the invoice.",
    "Jason's car is outside.",
    "I asked Jason to review the deploy.",
    "move the cursor to the end of the line.",
    "the cursor is blinking.",
    "make file copies of everything.",
    "a linear function of time.",
    "linear regression is boring.",
    "the notion of fairness matters.",
    "there is slack in the rope.",
    "the python was three meters long.",
    "rust on the car door.",
    "go to the store and get milk.",
    "swift delivery at noon.",
    "I bought yarn and a bun.",
    "the letter zed sounds like zee.",
    "we merged the commit and rebased the branch.",
    "the apiary is full of bees.",
    "she asked about Claude Monet.",
    "README.md is the entry point.",
    "the .gitignore file is fine.",
    "the AGENTS.md file has the rules.",
    "the package.json already has it.",
    // Nothing inside a path, a URL, an email, a branch name or an identifier.
    "open src/api/handler.ts and tell me what it says.",
    "check https://api.example.com/v1 before you deploy.",
    "send the invite to bob@api.com today.",
    "the branch is feat/api-cleanup on origin.",
    "rename api_key_for_user in the env file.",
    // Ordinary English that only looks like a product name.
    "we moved with swift action.",
    "the calls came in swift succession.",
    "coat it with rust protection.",
    "read Jason the letter when it lands.",
    "write Jason a note about it.",
    "I need to go code for a while.",
    "the wind surf was rough yesterday.",
    "the local host of the party left early.",
]
for input in packUntouched {
    expect(cleaner.clean(input), input, "pack leaves alone: \"\(input)\"")
}

// A hand-written rule still wins: the pack runs first, the dictionary last, so a
// rule is written against the spelling Whisp shows you.
let overrideDict = PersonalDictionary(terms: [], replacements: ["GitHub Enterprise": ["github"]])
expect(FillerCleaner(dictionary: overrideDict).clean("push it to git hub"), "push it to GitHub Enterprise",
       "dictionary beats the pack")

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
expect(SpeechSegmenter.nextCut(in: tone(4, amplitude: 0.002) + silence(0.6) + tone(4, amplitude: 0.3))
       .map(String.init) ?? "nil", "nil",
       "keeps near-silent chunk attached to louder speech")
expect(SpeechSegmenter.nextCut(in: tone(8)).map(String.init) ?? "nil", "nil", "no pause, below forceChunk")
expect(SpeechSegmenter.nextCut(in: tone(15)) != nil ? "cut" : "nil", "cut", "forced cut")
expect(SpeechSegmenter.plan(tone(5) + silence(0.6) + tone(5) + silence(0.6) + tone(5)).count.description, "2", "plan")

// A quiet chunk stays attached while the pending span is short — that is what keeps
// quietly recorded words (under the absolute near-silence limits) alive.
expect(SpeechSegmenter.nextCut(in: tone(15, amplitude: 0.002)).map(String.init) ?? "nil", "nil",
       "quiet chunk stays attached below the limit")
// Past a minute of uncut audio the guard gives way: leaving it pending is what a
// release then decodes in 15 s windows. One real 9 1/2 minute take never cut at all,
// so its release decoded 536 s and took 6103 ms.
expect(SpeechSegmenter.nextCut(in: tone(70, amplitude: 0.002)) != nil ? "cut" : "nil", "cut",
       "a minute of quiet pending is cut anyway")
expect(SpeechSegmenter.nextCut(in: tone(4, amplitude: 0.002) + silence(0.6) + tone(58, amplitude: 0.3))
       != nil ? "cut" : "nil", "cut", "a minute of pending cuts even next to loud speech")

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

// reset() ends a hold like stop() does, so the watchdog must not outlive it:
// a poll after reset fires nothing even with the key physically up.
do {
    var physical = true
    var releases = 0
    let hotkey = RightOptionHotkey()
    hotkey.isRightOptionDown = { physical }
    hotkey.keyUpWatchdogForTesting.onMissedRelease = { releases += 1 }
    hotkey.keyUpWatchdogForTesting.arm()
    expect(hotkey.keyUpWatchdogForTesting.armed.description, "true", "watchdog watches a hold")
    physical = false
    hotkey.reset()
    hotkey.keyUpWatchdogForTesting.checkNow()
    expect((releases == 0 && !hotkey.keyUpWatchdogForTesting.armed).description, "true",
           "reset disarms: the post-reset poll fires no release")
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
    var resets = 0
    func start() throws {}
    func stop() {}
    func reset() { resets += 1 }
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
    var copied: [String] = []
    var result = PasteResult.pasted
    var copyResult = PasteResult.copiedSessionInterrupt
    func target() -> PasteTarget { PasteTarget(pid: 1, precedingCharacter: Task { nil }) }
    func paste(_ text: String, into target: PasteTarget) async -> PasteResult {
        if result == .pasted { pasted.append(text) }
        return result
    }
    func copy(_ text: String) -> PasteResult {
        if copyResult == .copiedSessionInterrupt { copied.append(text) }
        return copyResult
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
    expect((controller.statusMessage?.contains("switched windows") ?? false).description, "true", "window change reported")
    paster.result = .pasted

    // Secure Event Input on: the take lands on the clipboard, never pasted,
    // and the user is told to ⌘V it themselves.
    paster.result = .copiedSecureInput
    dictate(seconds: 1)
    await settle()
    expect((controller.statusMessage?.contains("Secure typing") ?? false).description, "true",
           "secure input tells the user to paste")
    paster.result = .pasted

    // History and recordings are written off the pipeline, and in order.
    controller.flushPersistence()
    let saved = history.loadLast(10).map(\.cleaned)
    expect(saved.description, "[\"Clip 1.\", \"Clip 1.\", \"Clip 2.\", \"Clip 1.\", \"Clip 3.\", \"Clip 0.\"]",
           "history persisted in order (cancelled clip skipped)")
    let wavs = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("recordings").path)) ?? []
    expect(wavs.count.description, "6", "one WAV per pasted dictation")

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

// MARK: - 10-minute cap

// The hard cap ends the take like a key-up: everything said still pastes and
// the menu says why it stopped. Same path in push-to-talk and hands-free.
@MainActor
func capTests() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-cap-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = FakeRecorder(), hotkey = FakeHotkey(), paster = FakePaster()
    let transcriber = SlowTranscriber(), sounds = CountingSounds()
    let settings = AppSettings(defaults: UserDefaults(suiteName: "whisp-tests-\(UUID().uuidString)")!)
    settings.autoMute = false
    settings.keepRecordings = false
    let history = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
    let controller = DictationController(
        transcriber: transcriber, recorder: recorder, hotkey: hotkey, paster: paster,
        cleaner: FillerCleaner(), muter: NoMuter(), sounds: sounds, settings: settings,
        history: history, recordings: RecordingArchive(directory: dir.appendingPathComponent("recordings")))
    try! controller.startHotkey()
    func settle() async {
        for _ in 0..<200 where controller.state != .idle { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // Push-to-talk: shrink the cap; the take ends on its own, still pastes,
    // and a real release afterwards is a no-op.
    controller.maximumDuration = 0.1
    recorder.next = [Float](repeating: 0.1, count: 32_000)
    hotkey.onEvent?(.start)
    await settle()
    expect(paster.pasted.description, "[\"Clip 2.\"]", "capped take still pastes")
    expect((controller.statusMessage?.contains("cap") ?? false).description, "true",
           "cap tells the user why it stopped")
    hotkey.onEvent?(.stop)
    await settle()
    expect(paster.pasted.description, "[\"Clip 2.\"]", "release after the cap does nothing")

    // Hands-free: same cap path, hands-free flag cleared with the take.
    recorder.next = [Float](repeating: 0.1, count: 16_000)
    hotkey.onEvent?(.start)
    hotkey.onEvent?(.handsFree)
    await settle()
    expect(paster.pasted.description, "[\"Clip 2.\", \"Clip 1.\"]", "hands-free cap still pastes")
    expect(controller.isHandsFree.description, "false", "cap ends hands-free too")
}
await capTests()

// MARK: - Crash mid-transcription

// A take in flight has its audio in pending/ — deleted when it lands. A file
// left at launch means a crash took the process down mid-transcription:
// recoverPendingTakes() decodes it, keeps it in history, copies the text
// (its target app is long gone), and always deletes the file.
@MainActor
func crashRecoveryTests() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-crash-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let pendDir = dir.appendingPathComponent("pending")
    let pendTakes = PendingTakes(directory: pendDir)

    // WAV round-trip: what save writes is what load decodes.
    let samples: [Float] = [0, 0.5, -0.5, 1, -1]
    let wavURL = pendTakes.fileURL(takeID: "t-1")
    try! pendTakes.save(samples: samples, to: wavURL)
    expect(pendTakes.list().count.description, "1", "pending file listed")
    let loaded = pendTakes.load(wavURL)!
    expect((loaded.count == samples.count && abs(loaded[1] - 0.5) < 0.001).description,
           "true", "pending WAV decodes to the same samples")
    let junk = pendDir.appendingPathComponent("junk.wav")
    try! "not a wav".write(to: junk, atomically: true, encoding: .utf8)
    expect((pendTakes.load(junk) == nil).description, "true", "corrupt pending file reads nil")
    pendTakes.remove(wavURL)
    pendTakes.remove(junk)
    expect(pendTakes.list().count.description, "0", "round-trip cleaned up")

    // In-flight lifecycle: a normal take writes pending/ then deletes it.
    let recorder = FakeRecorder(), hotkey = FakeHotkey(), paster = FakePaster()
    let transcriber = SlowTranscriber(), sounds = CountingSounds()
    let settings = AppSettings(defaults: UserDefaults(suiteName: "whisp-tests-\(UUID().uuidString)")!)
    settings.autoMute = false
    settings.keepRecordings = false
    let history = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
    let controller = DictationController(
        transcriber: transcriber, recorder: recorder, hotkey: hotkey, paster: paster,
        cleaner: FillerCleaner(), muter: NoMuter(), sounds: sounds, settings: settings,
        history: history, recordings: RecordingArchive(directory: dir.appendingPathComponent("recordings")),
        pendingTakes: pendTakes)
    var copied: [String] = []
    controller.clipboardSink = { copied.append($0) }
    controller.clipboardOccupied = { false }
    try! controller.startHotkey()
    func settle() async {
        for _ in 0..<200 where controller.state != .idle { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    recorder.next = [Float](repeating: 0.1, count: 32_000)
    // While the transcription is still in flight the take's WAV sits in pending/.
    transcriber.delays[2] = 400_000_000
    hotkey.onEvent?(.start)
    hotkey.onEvent?(.stop)
    controller.flushPersistence()
    expect(pendTakes.list().count.description, "1", "in-flight take has a pending WAV")
    await settle()
    controller.flushPersistence()
    expect(pendTakes.list().count.description, "0", "finished take deletes its pending WAV")

    // A cancelled take finishes too — its pending file is removed, not recovered.
    recorder.next = [Float](repeating: 0.1, count: 32_000)
    hotkey.onEvent?(.start)
    hotkey.onEvent?(.stop)
    hotkey.onEvent?(.cancel)
    await settle()
    controller.flushPersistence()
    expect(pendTakes.list().count.description, "0", "cancelled take deletes its pending WAV")

    // Crash leftovers: two takes plus a corrupt file — both recover, in order;
    // only the first lands on the clipboard; every file is gone after.
    try! pendTakes.save(samples: [Float](repeating: 0.1, count: 32_000),
                        to: pendTakes.fileURL(takeID: "clip-1-aaaa"))
    try! await Task.sleep(nanoseconds: 20_000_000)
    try! pendTakes.save(samples: [Float](repeating: 0.1, count: 48_000),
                        to: pendTakes.fileURL(takeID: "clip-2-bbbb"))
    try! "garbage".write(to: pendDir.appendingPathComponent("clip-3-bad.wav"),
                         atomically: true, encoding: .utf8)
    await controller.recoverPendingTakes()
    controller.flushPersistence()
    expect(pendTakes.list().count.description, "0", "all pending files consumed")
    expect(copied.description, "[\"Clip 2.\", \"Clip 3.\"]", "recovered takes land on the clipboard in order")
    // loadLast returns newest-first.
    expect(history.loadLast(10).map(\.cleaned).description,
           "[\"Clip 3.\", \"Clip 2.\", \"Clip 2.\"]", "both recovered takes land in history in order")
    expect((controller.statusMessage?.contains("Recovered") ?? false).description, "true",
           "menu says a take was recovered")

    // Clipboard already holding user content: recovered text stays in History only.
    copied = []
    controller.clipboardOccupied = { true }
    try! pendTakes.save(samples: [Float](repeating: 0.1, count: 16_000),
                        to: pendTakes.fileURL(takeID: "clip-4-cccc"))
    await controller.recoverPendingTakes()
    controller.flushPersistence()
    expect(copied.description, "[]", "occupied clipboard is not clobbered")
    expect(history.loadLast(1).first?.cleaned ?? "?", "Clip 1.", "take still lands in history")
    expect((controller.statusMessage?.contains("History") ?? false).description, "true",
           "menu points at History instead")

    // An empty transcript leftover is deleted without touching anything.
    transcriber.text = ""
    try! pendTakes.save(samples: [Float](repeating: 0.1, count: 16_000),
                        to: pendTakes.fileURL(takeID: "clip-5-dddd"))
    let before = history.loadLast(10).count
    await controller.recoverPendingTakes()
    controller.flushPersistence()
    expect(pendTakes.list().count.description, "0", "empty leftover deleted")
    expect(history.loadLast(10).count.description, before.description, "empty take adds no history")
    expect(copied.description, "[]", "empty take copies nothing")

    // A write failure inside the pass outranks the "recovered" text: a take that
    // reached the clipboard but could not be written down must not be reported
    // as saved. Same read-only history file as the full-disk test, so the
    // persist inside the loop fails; a second leftover drops out, which is what
    // leaves the recovered text as the other candidate for the menu.
    transcriber.text = nil
    copied = []
    controller.clipboardOccupied = { false }
    try! FileManager.default.setAttributes([.posixPermissions: 0o444],
                                           ofItemAtPath: history.fileURL.path)
    try! pendTakes.save(samples: [Float](repeating: 0.1, count: 16_000),
                        to: pendTakes.fileURL(takeID: "clip-6-eeee"))
    try! "garbage".write(to: pendDir.appendingPathComponent("clip-7-ffff.wav"),
                         atomically: true, encoding: .utf8)
    await controller.recoverPendingTakes()
    controller.flushPersistence()
    expect(copied.description, "[\"Clip 1.\"]", "a take that can't be saved still reaches the clipboard")
    expect(controller.statusMessage ?? "nil", DictationController.persistFailedMessage,
           "a failed write outranks the recovered text")
    try! FileManager.default.setAttributes([.posixPermissions: 0o644],
                                           ofItemAtPath: history.fileURL.path)
}
await crashRecoveryTests()

// MARK: - Session interrupt (sleep/lock/user-switch)

// The Mac sleeping, locking, or switching users mid-take: capture stops like a
// key-up, the take still transcribes and lands in history — but it copies to
// the clipboard instead of pasting (the target session is gone), and the
// held-key state is reset so a key still down can't look stuck.
@MainActor
func sessionInterruptTests() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-susp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = FakeRecorder(), hotkey = FakeHotkey(), paster = FakePaster()
    let transcriber = SlowTranscriber(), sounds = CountingSounds()
    let settings = AppSettings(defaults: UserDefaults(suiteName: "whisp-tests-\(UUID().uuidString)")!)
    settings.autoMute = false
    settings.keepRecordings = false
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
    }

    // Baseline: a normal take pastes.
    dictate(seconds: 1)
    await settle()
    expect(paster.pasted.description, "[\"Clip 1.\"]", "baseline take pastes")

    // Suspended while recording: the take transcribes, copies, and says why.
    recorder.next = [Float](repeating: 0.1, count: 32_000)
    hotkey.onEvent?(.start)
    controller.systemSuspending()
    await settle()
    expect(paster.copied.description, "[\"Clip 2.\"]", "suspended take copies, not pastes")
    expect(paster.pasted.description, "[\"Clip 1.\"]", "nothing pasted during suspension")
    expect(hotkey.resets.description, "1", "held-key state reset on suspend")
    expect((controller.statusMessage?.contains("slept or locked") ?? false).description, "true",
           "suspension tells the user to paste")

    // Suspended with two takes still transcribing: both copy.
    dictate(seconds: 1)
    dictate(seconds: 2)
    controller.systemSuspending()
    await settle()
    expect(paster.copied.description, "[\"Clip 2.\", \"Clip 1.\", \"Clip 2.\"]",
           "every queued take copies")
    expect(hotkey.resets.description, "2", "second suspend resets again")

    // After waking, the next take pastes normally again.
    dictate(seconds: 3)
    await settle()
    expect(paster.pasted.description, "[\"Clip 1.\", \"Clip 3.\"]", "post-suspension take pastes")

    // Suspending while idle resets the key state but touches nothing else.
    controller.systemSuspending()
    expect(hotkey.resets.description, "3", "idle suspend still resets")
    expect(paster.copied.description, "[\"Clip 2.\", \"Clip 1.\", \"Clip 2.\"]",
           "idle suspend copies nothing")

    // Copied takes are still in history.
    controller.flushPersistence()
    let saved = history.loadLast(10).map(\.cleaned)
    expect(saved.count.description, "5", "copied takes still land in history")
}
await sessionInterruptTests()

// MARK: - Lead storage

// Dictation data is private: the data dir and every file in it must be
// readable only by the owner (~/Library/Application Support is world-readable).
do {
    // AppPaths.root is already pointed at the suite's throwaway folder at the
    // top of this file.
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

// The data folder the app reads must be the one the owner edits: the first
// installs lived in ~/whisp-data, and a double-clicked app has no environment
// to say so.
// Decided against real folders, because the rule asks the filesystem.
do {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("whisp-home-\(UUID().uuidString)",
                                                            isDirectory: true)
    let legacy = home.appendingPathComponent("whisp-data", isDirectory: true)
    let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    let firstInstall = support.appendingPathComponent("Whisp", isDirectory: true)
    defer { try? fm.removeItem(at: home) }
    func choose(_ override: String? = nil) -> URL {
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: legacy.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        return AppPaths.chooseRoot(override: override, legacy: legacy, legacyExists: exists,
                                   appSupport: support)
    }
    expect(choose().path, firstInstall.path, "no ~/whisp-data: a fresh install uses Application Support")
    expect(choose("/tmp/x").path, "/tmp/x", "WHISP_DATA_DIR wins over everything")
    expect(choose("").path, firstInstall.path, "an empty WHISP_DATA_DIR is not an override")
    try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
    expect(choose().path, legacy.path, "an empty ~/whisp-data is still the data root")
    try #"{"terms":["Vinted"],"replacements":[]}"#.write(
        to: legacy.appendingPathComponent("dictionary.json"), atomically: true, encoding: .utf8)
    expect(choose().path, legacy.path, "~/whisp-data holding a dictionary is the data root")
    try fm.createDirectory(at: firstInstall, withIntermediateDirectories: true)
    try #"{"terms":["Sol"],"replacements":[]}"#.write(
        to: firstInstall.appendingPathComponent("dictionary.json"), atomically: true, encoding: .utf8)
    expect(choose().path, legacy.path, "both folders present: the owner's data wins")
    // The rule reads no file, so an unreadable dictionary inside must not move
    // the root, and opening it must not take the reader down with it.
    try "not json {{{".write(to: legacy.appendingPathComponent("dictionary.json"),
                             atomically: true, encoding: .utf8)
    expect(choose().path, legacy.path, "an unreadable dictionary inside does not move the root")
    expect(PersonalDictionary(fileURL: legacy.appendingPathComponent("dictionary.json"))
            .apply("We sell on vinted."),
           "We sell on vinted.", "an unreadable dictionary applies nothing and does not crash")
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

// MARK: - Capture drain (last word at release)

// At key-up one IO buffer is always in flight holding the end of the last
// word. finish() must wait for it — returning early when it lands, never
// past the ~30 ms cap. Driven without audio hardware: finish() runs on a
// background thread; once isDraining reports the wait armed, the tap-thread
// append lands and must end it promptly (no timer to flake on slow runners).
do {
    let cap = CaptureBuffer()
    cap.begin()
    let head: [Float] = [1, 2, 3]
    _ = head.withUnsafeBufferPointer { cap.append($0) }
    var outcome: (samples: [Float], drained: Bool)?
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        outcome = cap.finish()
        done.signal()
    }
    while !cap.isDraining {}
    let tail: [Float] = [4, 5]
    _ = tail.withUnsafeBufferPointer { cap.append($0) }
    let t0 = DispatchTime.now().uptimeNanoseconds
    done.wait()
    let waitMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    expect((outcome?.drained ?? false).description, "true", "drain catches the buffer in flight at release")
    expect((outcome?.samples ?? []).description, "[1.0, 2.0, 3.0, 4.0, 5.0]",
           "stop() keeps audio that arrives after key-up")
    expect(waitMs < 30 ? "early" : "capped", "early",
           "drain returns on the buffer, not the cap (\(Int(waitMs)) ms)")
}

// A dead or silent input must not stall release->paste: the wait ends at the
// cap and keeps what was already captured.
do {
    let cap = CaptureBuffer()
    cap.begin()
    let head: [Float] = [7]
    _ = head.withUnsafeBufferPointer { cap.append($0) }
    let t0 = DispatchTime.now().uptimeNanoseconds
    let (got, drained) = cap.finish()
    let waitMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    expect(drained.description, "false", "drain gives up when nothing arrives")
    expect(got.description, "[7.0]", "cap timeout keeps what was captured")
    expect(waitMs >= 25 && waitMs < 200 ? "capped" : "\(Int(waitMs))", "capped",
           "drain is bounded near the 30 ms cap")
}

// stop() with no live take (already stopped, cancelled, or a start that never
// delivered) must not pay the drain wait.
do {
    let cap = CaptureBuffer()
    let t0 = DispatchTime.now().uptimeNanoseconds
    let (got, drained) = cap.finish()
    let waitMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    expect(waitMs < 5 ? "instant" : "\(Int(waitMs))ms", "instant",
           "finish() without a take never waits")
    expect(got.isEmpty && !drained ? "ok" : "?", "ok", "finish() without a take is empty")
}

// Cancel path: audio and the recording flag are dropped at once, late buffers
// are refused, and a new take starts clean (the double-tap second press).
do {
    let cap = CaptureBuffer()
    cap.begin()
    let head: [Float] = [1]
    _ = head.withUnsafeBufferPointer { cap.append($0) }
    cap.discard()
    let late: [Float] = [2]
    expect(late.withUnsafeBufferPointer { cap.append($0) }.description, "false",
           "buffers after cancel are dropped")
    expect(cap.tail(from: 0).isEmpty.description, "true", "cancel drops captured audio")
    expect(cap.isRecording.description, "false", "cancel ends the take")

    cap.begin()
    let next: [Float] = [9]
    _ = next.withUnsafeBufferPointer { cap.append($0) }
    expect(cap.tail(from: 0).description, "[9.0]", "a new take starts clean")
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

// MARK: - The hunt (disk full, racing writes, 10-min resource bound)

// Two writers racing history.jsonl: appends use O_APPEND so each line lands at
// the true EOF — no seek-to-end overwrite, no interleaved bytes.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-race-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("history.jsonl")
    let storeA = HistoryStore(fileURL: file), storeB = HistoryStore(fileURL: file)
    func entry(_ n: Int) -> HistoryEntry {
        HistoryEntry(id: "e\(n)", date: Date(), durationSec: 1, raw: "r\(n)", cleaned: "c\(n)", latencyMs: 0)
    }
    try! storeA.append(entry(0)) // pre-create: the race hits the append path
    let group = DispatchGroup()
    let q = DispatchQueue(label: "race", attributes: .concurrent)
    for i in 1...50 {
        group.enter(); q.async { try! storeA.append(entry(i)); group.leave() }
        group.enter(); q.async { try! storeB.append(entry(i + 50)); group.leave() }
    }
    group.wait()
    let lines = try! String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    expect(lines.count.description, "101", "racing appends keep every line")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decodable = lines.filter { line in
        (try? decoder.decode(HistoryEntry.self, from: Data(line.utf8))) != nil
    }
    expect(decodable.count.description, "101", "racing appends keep every line intact")
}

// Disk-full writes must never clobber an existing dictionary: the atomic
// write throws before the file is touched.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-dictfull-\(UUID().uuidString)")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dict = dir.appendingPathComponent("dictionary.json")
    let before = #"{"terms": ["Vinted"], "replacements": []}"#
    try! before.write(to: dict, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    var threw = false
    do { try PersonalDictionary.addTerm("Depop", fileURL: dict) } catch { threw = true }
    expect(threw.description, "true", "dictionary write on a full disk throws")
    expect((try? String(contentsOf: dict, encoding: .utf8)) ?? "?", before,
           "failed dictionary write leaves the file alone")
}

// A recorder that yields audio progressively, like a real capture, and a
// process-resident-size probe for the resource-bounds check.
final class ServedRecorder: AudioRecording {
    var onLevel: ((Float) -> Void)?
    let lostInput = false
    private var served = 0
    let total: Int, serving: Int
    init(total: Int, serving: Int) { self.total = total; self.serving = serving }
    func start() throws {}
    func samples(from start: Int) -> [Float] {
        served = min(served + serving, total)
        return [Float](repeating: 0.1, count: max(0, served - start))
    }
    func stop() -> [Float] { [Float](repeating: 0.1, count: total) }
    func cancel() {}
}
// Peak resident-set-size watermark in bytes (macOS units for ru_maxrss).
func peakRssBytes() -> UInt64 {
    var r = rusage()
    getrusage(RUSAGE_SELF, &r)
    return UInt64(r.ru_maxrss)
}

@MainActor
func huntTests() async {
    // Hands-free 10-minute take: 9.6M samples (38 MB) served progressively.
    // Memory may spike for buffers but stays a small multiple of the audio,
    // and the take lands intact with its real duration.
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-hunt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let hotkey = FakeHotkey(), paster = FakePaster()
        let recorder = ServedRecorder(total: 9_600_000, serving: 1_600_000)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "whisp-tests-\(UUID().uuidString)")!)
        settings.autoMute = false
        settings.keepRecordings = false
        let history = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
        let controller = DictationController(
            transcriber: SlowTranscriber(), recorder: recorder, hotkey: hotkey, paster: paster,
            cleaner: FillerCleaner(), muter: NoMuter(), sounds: CountingSounds(), settings: settings,
            history: history, recordings: RecordingArchive(directory: dir.appendingPathComponent("rec")))
        try! controller.startHotkey()
        let baseline = peakRssBytes()
        hotkey.onEvent?(.start)
        hotkey.onEvent?(.handsFree)
        // 100 ms polls × ~1.2 s serves all 10 simulated minutes to the chunk loop.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        hotkey.onEvent?(.stop)
        for _ in 0..<400 where controller.state != .idle { try? await Task.sleep(nanoseconds: 10_000_000) }
        controller.flushPersistence()
        let peakDelta = Double(Int64(peakRssBytes()) - Int64(baseline)) / 1e6
        print(String(format: "10-min fake take: peak RSS watermark +%.0f MB", peakDelta))
        expect(paster.pasted.count.description, "1", "10-min hands-free take lands as one paste")
        expect(paster.pasted.first?.hasPrefix("Clip ") ?? false ? "yes" : "no", "yes",
               "10-min take pastes the transcribed audio")
        expect(history.loadLast(1).first?.durationSec.description ?? "?", "600.0",
               "10-min take records its real duration")
        expect((peakDelta < 400).description, "true", "10-min take peak memory stays bounded (<400 MB)")
    }

    // Disk full: a history append that can't write still pastes the take and
    // says so in the menu instead of losing it silently.
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisp-full-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let historyFile = dir.appendingPathComponent("history.jsonl")
        try! " ".write(to: historyFile, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: historyFile.path)
        let recorder = FakeRecorder(), hotkey = FakeHotkey(), paster = FakePaster()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "whisp-tests-\(UUID().uuidString)")!)
        settings.autoMute = false
        settings.keepRecordings = false
        let history = HistoryStore(fileURL: historyFile)
        let controller = DictationController(
            transcriber: SlowTranscriber(), recorder: recorder, hotkey: hotkey, paster: paster,
            cleaner: FillerCleaner(), muter: NoMuter(), sounds: CountingSounds(), settings: settings,
            history: history, recordings: RecordingArchive(directory: dir.appendingPathComponent("rec")))
        try! controller.startHotkey()
        recorder.next = [Float](repeating: 0.1, count: 16_000)
        hotkey.onEvent?(.start)
        hotkey.onEvent?(.stop)
        for _ in 0..<200 where controller.state != .idle { try? await Task.sleep(nanoseconds: 10_000_000) }
        controller.flushPersistence()
        try? await Task.sleep(nanoseconds: 50_000_000)
        expect(paster.pasted.description, "[\"Clip 1.\"]", "full disk still pastes the take")
        expect((controller.statusMessage?.contains("Couldn't save") ?? false).description, "true",
               "full disk surfaces a menu warning")
    }
}
await huntTests()

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
    try? await Task.sleep(nanoseconds: 550_000_000)
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
    let settle = UInt64((paster.restoreDelay + 0.5) * 1_000_000_000)

    board.clearContents()
    board.setString(marker, forType: .string)
    let t = paster.target()
    _ = await paster.paste("dictated words", into: t)
    expect(board.string(forType: .string) ?? "?", "dictated words", "paste writes text")
    try? await Task.sleep(nanoseconds: settle)
    expect(board.string(forType: .string) ?? "?", marker, "clipboard restored after paste")

    // The user copies between key release and paste -> the newer clipboard wins.
    let t2 = paster.target()
    _ = await t2.clipboard?.value // let the key-release capture see `marker` first
    board.clearContents()
    board.setString("user copy", forType: .string)
    _ = await paster.paste("more words", into: t2)
    try? await Task.sleep(nanoseconds: settle)
    expect(board.string(forType: .string) ?? "?", "user copy", "newer clipboard restored")

    // Secure Event Input on: no Cmd+V is posted, the text stays on the
    // clipboard, and the user's old clipboard is not restored over it.
    board.clearContents()
    board.setString(marker, forType: .string)
    let defaultSecureCheck = paster.secureEventInput
    paster.secureEventInput = { true }
    let secureOutcome = await paster.paste("secret words", into: paster.target())
    paster.secureEventInput = defaultSecureCheck
    expect(secureOutcome == .copiedSecureInput ? "copied" : "\(secureOutcome)", "copied",
           "secure input copies instead of pasting")
    try? await Task.sleep(nanoseconds: 450_000_000)
    expect(board.string(forType: .string) ?? "?", "secret words",
           "secure copy stays on the clipboard (no restore)")

    // copy() (the sleep/lock/user-switch path): the text lands on the
    // clipboard for the user's own Cmd+V and nothing restores over it.
    board.clearContents()
    board.setString(marker, forType: .string)
    let copyOutcome = paster.copy(" wake words ")
    expect(copyOutcome == .copiedSessionInterrupt ? "copied" : "\(copyOutcome)", "copied",
           "session-interrupt copy returns the copied result")
    try? await Task.sleep(nanoseconds: 450_000_000)
    expect(board.string(forType: .string) ?? "?", "wake words",
           "copy leaves trimmed text on the clipboard")
}

// A target that doesn't paste on the Cmd+V — it reads the clipboard later.
// Change count does not move on a read, which is the bug: restoring on a
// timer alone can put the old clipboard back before this read.
@MainActor
final class LateClipboardReader {
    private let pasteboard: NSPasteboard
    private let delay: TimeInterval
    private var task: Task<Void, Never>?
    private(set) var pasted: String?

    init(pasteboard: NSPasteboard, delay: TimeInterval) {
        self.pasteboard = pasteboard
        self.delay = delay
    }

    func arm() {
        let board = pasteboard
        let delay = delay
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            pasted = board.string(forType: .string)
        }
    }

    func wait() async { await task?.value }
}

@MainActor
func pasterReliabilityTests() async {
    // Focus decision: pid, then window id, then the accessibility window.
    // A missing window id must not block the paste by itself.
    expect(Paster.focusLeftTarget(releasePID: 1, currentPID: 2, releaseWindow: 9, currentWindow: 9, axWindowDiffers: false) ? "hold" : "paste",
           "hold", "different app holds the paste")
    expect(Paster.focusLeftTarget(releasePID: 1, currentPID: 1, releaseWindow: 9, currentWindow: 10, axWindowDiffers: false) ? "hold" : "paste",
           "hold", "same app, different window holds the paste")
    expect(Paster.focusLeftTarget(releasePID: 1, currentPID: 1, releaseWindow: 9, currentWindow: 9, axWindowDiffers: true) ? "hold" : "paste",
           "paste", "matching window ids win over the accessibility element")
    expect(Paster.focusLeftTarget(releasePID: 1, currentPID: 1, releaseWindow: nil, currentWindow: nil, axWindowDiffers: true) ? "hold" : "paste",
           "hold", "accessibility window change holds the paste when ids are unknown")
    expect(Paster.focusLeftTarget(releasePID: 1, currentPID: 1, releaseWindow: nil, currentWindow: 4, axWindowDiffers: nil) ? "hold" : "paste",
           "paste", "unknown window does not block the paste")
    expect(Paster.focusLeftTarget(releasePID: nil, currentPID: 3, releaseWindow: nil, currentWindow: nil, axWindowDiffers: nil) ? "hold" : "paste",
           "paste", "no release pid does not block the paste")

    // Insertion proof. A slice that merely matches is not enough when that text
    // could already have been in the field.
    expect(Paster.insertionConfirmed(needle: "hello", slice: nil, characterCountBefore: 0, characterCountAfter: 5, selectionLength: 0, selectedText: nil) == nil ? "unsure" : "sure",
           "unsure", "unreadable element is not confirmation")
    expect(Paster.insertionConfirmed(needle: "hello", slice: "world", characterCountBefore: 5, characterCountAfter: 10, selectionLength: 0, selectedText: nil) == false ? "no" : "yes",
           "no", "different text is not the dictation")
    expect(Paster.insertionConfirmed(needle: "hello", slice: "hello", characterCountBefore: 4, characterCountAfter: 9, selectionLength: 0, selectedText: nil) == true ? "yes" : "no",
           "yes", "length grew by the insertion")
    expect(Paster.insertionConfirmed(needle: "hello", slice: "hello", characterCountBefore: 9, characterCountAfter: 9, selectionLength: 0, selectedText: nil) == false ? "no" : "yes",
           "no", "matching slice whose length didn't change is not a paste")
    expect(Paster.insertionConfirmed(needle: "hello", slice: "hello", characterCountBefore: nil, characterCountAfter: nil, selectionLength: 0, selectedText: nil) == nil ? "unsure" : "sure",
           "unsure", "collapsed caret without a length can't be proved")
    expect(Paster.insertionConfirmed(needle: "hello", slice: "hello", characterCountBefore: 5, characterCountAfter: 5, selectionLength: 5, selectedText: "hello") == nil ? "unsure" : "sure",
           "unsure", "selection that was already the dictation is not proof")
    expect(Paster.insertionConfirmed(needle: "hello", slice: "hello", characterCountBefore: nil, characterCountAfter: nil, selectionLength: 3, selectedText: "old") == true ? "yes" : "no",
           "yes", "a different selection replaced by the needle is proof")
    expect(Paster.insertionConfirmed(needle: "hello", slice: "hello", characterCountBefore: nil, characterCountAfter: nil, selectionLength: 5, selectedText: nil) == nil ? "unsure" : "sure",
           "unsure", "unread same-length selection is not proof")

    let noop: @MainActor () -> Void = {}

    // Slow target: reads 500 ms after the paste. The old 300 ms restore would
    // hand it the previous clipboard. Nothing here confirms an insertion, so
    // the text has to stay put until restoreDelay.
    do {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let marker = "user-clipboard-\(UUID().uuidString)"
        let dictated = "dictated-\(UUID().uuidString)"
        board.clearContents()
        board.setString(marker, forType: .string)
        let paster = Paster(pasteboard: board, postPaste: noop)
        paster.frontmostProcessID = { 4242 }
        paster.frontmostWindowID = { _ in 7 }
        // No focused element, so nothing can confirm the paste early — and no
        // real Accessibility read, so a nearby text field can't add a leading space.
        paster.confirmInsertion = { _ in nil }
        expect(paster.restoreDelay > 0.5 ? "holds" : "short", "holds", "fallback outlasts a 500 ms reader")
        let target = PasteTarget(pid: 4242, precedingCharacter: Task { nil }, windowID: 7)
        let result = await paster.paste(dictated, into: target)
        expect(String(describing: result), String(describing: PasteResult.pasted), "late target is still a paste")
        expect(board.string(forType: .string) ?? "?", dictated, "dictation is on the clipboard for the target")
        let reader = LateClipboardReader(pasteboard: board, delay: 0.5)
        reader.arm()
        await reader.wait()
        expect(reader.pasted ?? "?", dictated, "500 ms reader gets the dictation, not the old clipboard")
        try? await Task.sleep(nanoseconds: UInt64(paster.restoreDelay * 1_000_000_000))
        expect(board.string(forType: .string) ?? "?", marker, "old clipboard returns after the fallback")
    }

    // Once the insertion is confirmed, restore without waiting out the fallback.
    do {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let marker = "user-clipboard-\(UUID().uuidString)"
        board.clearContents()
        board.setString(marker, forType: .string)
        let paster = Paster(pasteboard: board, postPaste: noop)
        paster.frontmostProcessID = { 4242 }
        paster.frontmostWindowID = { _ in 7 }
        paster.restoreDelay = 30
        paster.confirmInsertion = { _ in true }
        let started = Date()
        _ = await paster.paste("dictated-\(UUID().uuidString)",
                               into: PasteTarget(pid: 4242, precedingCharacter: Task { nil }, windowID: 7))
        var restored = false
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if board.string(forType: .string) == marker { restored = true; break }
        }
        expect(restored ? "yes" : "no", "yes", "confirmed insertion restores the clipboard")
        expect(Date().timeIntervalSince(started) < 5 ? "soon" : "waited", "soon", "confirm does not wait out the fallback")
    }

    // A write after ours wins, even if we would otherwise restore.
    do {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        let paster = Paster(pasteboard: board, postPaste: noop)
        paster.frontmostProcessID = { 4242 }
        paster.frontmostWindowID = { _ in 7 }
        paster.restoreDelay = 0.3
        paster.confirmInsertion = { _ in nil }
        _ = await paster.paste("dictated", into: PasteTarget(pid: 4242, precedingCharacter: Task { nil }, windowID: 7))
        board.clearContents()
        board.setString("user copy", forType: .string)
        try? await Task.sleep(nanoseconds: 600_000_000)
        expect(board.string(forType: .string) ?? "?", "user copy", "a newer clipboard write is left alone")
    }

    // Same app, another window: don't paste into it. The text stays available
    // and the user's previous clipboard is not what gets restored over it.
    do {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        let paster = Paster(pasteboard: board, postPaste: noop)
        var window: UInt32 = 1
        paster.frontmostProcessID = { 4242 }
        paster.frontmostWindowID = { _ in window }
        paster.restoreDelay = 0.2
        paster.confirmInsertion = { _ in true }
        let target = PasteTarget(pid: 4242, precedingCharacter: Task { nil }, windowID: 1)
        window = 2
        let result = await paster.paste("dictated words", into: target)
        expect(String(describing: result), String(describing: PasteResult.copiedAppChanged), "same app, other window is not pasted")
        try? await Task.sleep(nanoseconds: 500_000_000)
        expect(board.string(forType: .string) ?? "?", "dictated words", "dictation stays on the clipboard for a manual paste")
    }

    // Different process, same as before.
    do {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        let paster = Paster(pasteboard: board, postPaste: noop)
        var pid: pid_t = 1
        paster.frontmostProcessID = { pid }
        paster.frontmostWindowID = { _ in 5 }
        let target = PasteTarget(pid: 1, precedingCharacter: Task { nil }, windowID: 5)
        pid = 2
        let result = await paster.paste("dictated words", into: target)
        expect(String(describing: result), String(describing: PasteResult.copiedAppChanged), "different app is not pasted")
        expect(board.string(forType: .string) ?? "?", "dictated words", "dictation left on the clipboard when the app changed")
    }
}
// Private pasteboard and no key events: always safe to run.
await pasterReliabilityTests()

// Opt-in: it overwrites the real clipboard and posts a real ⌘V into the frontmost app.
if ProcessInfo.processInfo.environment["WHISP_TEST_PASTEBOARD"] == "1" {
    await pasterTests()
} else {
    print("skipped Paster tests (real clipboard + ⌘V); set WHISP_TEST_PASTEBOARD=1 to run")
}

// MARK: - Auto-learn

// The learner's "real word" oracle comes from the app itself, through the same
// factory Composition calls. No stub and no copy, because either one can make a
// rule look right on a word the real checker already knows.
let learner = SpellCheckOracle.learner()

func checkLearn(_ pasted: String, _ current: String,
                _ expected: [CorrectionLearner.Decision],
                rules: [(from: [String], to: String)] = [],
                _ label: String, line: Int = #line) {
    let decisions = learner.decide(pasted: pasted, current: current, existingRules: rules)
    expect((decisions == expected).description, "true",
           "\(label) — got \(decisions)", line: line)
}

// The required table from the brief. Expectations below are what the app's own
// NSSpellChecker oracle produces; the words it happens to know decide the gate.
// A real word fixed to something the checker does not know is the owner naming
// a thing, so one sighting is saved.
checkLearn("Help me set up tail skill.", "Help me set up tailscale.",
           [.replacement(from: "tail skill", to: "tailscale")],
           "known words fixed to a name save at once")
checkLearn("Ship it to the knockout.", "Ship it to the nelko.",
           [.replacement(from: "knockout", to: "nelko")],
           "a product name the checker never saw saves at once")
checkLearn("Open the agents MD now.", "Open the AGENTS.md now.",
           [.replacement(from: "agents MD", to: "AGENTS.md")],
           "an abbreviation the checker never saw saves at once")
// The checker knows "Sol" and "Claude", so these two are not naming a new word:
// they still wait for a second sighting. Kept as rows precisely because the
// PR first claimed the opposite.
checkLearn("I use the soul model.", "I use the Sol model.",
           [.pending(from: "soul", to: "Sol", kind: .replacement)],
           "soul→Sol: the checker knows Sol, so it waits")
checkLearn("Open cloud code now.", "Open Claude Code now.",
           [.pending(from: "cloud code", to: "Claude Code", kind: .replacement)],
           "cloud code→Claude Code: the checker knows Claude, so it waits")
checkLearn("Open Pychy now.", "Open pi CLI now.",
           [.replacement(from: "Pychy", to: "pi CLI")], "junk from learns right away")
checkLearn("Meet Priya today.", "Meet Anil today.", [],
           "priya→anil is not a mishearing, so nothing is learned")
checkLearn("Meet priya today.", "Meet Priya today.",
           [.term("Priya")], "casing an unknown name still learns")
checkLearn("We sell on vinted.", "We sell on Vinted.",
           [.term("Vinted")], "casing a name the checker does not know saves at once")
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
            .term("Vinted")], "two fixes in one take")

// Review edge cases for the mishearing gate (PR #52).
// "gonna" and "2nd" are unknown to this oracle and fail the gate, so they
// wait for a second sighting instead of being dropped.
checkLearn("Meet Priya today.", "Meet today.", [], "deleting an unknown name learns nothing")
checkLearn("We gonna ship it.", "We will ship it.", [],
           "rewording slang is not a mishearing, so nothing is learned")
checkLearn("Use 2nd copy.", "Use 3rd copy.",
           [.pending(from: "2nd", to: "3rd", kind: .replacement)],
           "digit-led words with no Soundex key do not match")
checkLearn("Open Pychy.", "Open pi CLI. Thanks", [.replacement(from: "Pychy", to: "pi CLI")],
           "gate still passes the trailing-cut fix")
checkLearn("Email Filip today.", "Email Phillip today.",
           [.pending(from: "Filip", to: "Phillip", kind: .replacement)],
           "Filip→Phillip first sighting is pending")
checkLearn("Email Katie today.", "Email Caty today.",
           [.replacement(from: "Katie", to: "Caty")],
           "Katie→Caty is close enough to the sound to save at once")
checkLearn("Email Ellem today.", "Email LLM today.",
           [.pending(from: "Ellem", to: "LLM", kind: .replacement)],
           "Ellem→LLM first sighting is pending")

// Hostile learning: wrong fixes the owner didn't mean.
// An edit that looks like app autocorrect is indistinguishable from a user fix —
// junk sources learn instantly, so a bad "Pychy -> Pitchy" lands in one edit.
checkLearn("Open Pychy now.", "Open Pitchy now.",
           [.replacement(from: "Pychy", to: "Pitchy")],
           "autocorrect-looking junk fix learns right away")
// Two adjacent changed words merge into one diff block; a stoplisted word in
// the block kills the whole substitution, so the junk fix is lost too —
// protective, but it means an autocorrect run touching "Pychy now" teaches zero.
checkLearn("Open Pychy now.", "Open Pitchy Now.", [],
           "merged block with a stoplist word learns nothing")
// The same two fixes in separate sentence blocks each learn on their own.
checkLearn("Open Pychy now. Meet tuesday.", "Open Pitchy now. Meet Tuesday.",
           [.replacement(from: "Pychy", to: "Pitchy"),
            .term("Tuesday")],
           "two fixes in separate blocks both learn")
// Three real fixes in one take: the per-paste cap learns only the first two.
checkLearn("I use the soul model. Open Pychy now. We sell on vinted.",
           "I use the Sol model. Open Pitchy now. We sell on Vinted.",
           [.pending(from: "soul", to: "Sol", kind: .replacement),
            .replacement(from: "Pychy", to: "Pitchy")],
           "third fix in a take is dropped by the 2-fix cap")
// A rewrite of most of the take teaches nothing (same guard, smaller take).
checkLearn("We sell on vinted today.", "Ship it tomorrow instead.", [],
           "rewrite of the whole take learns nothing")

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
    // Whole-value fallback window: offsets are UTF-16, the tail clamps, and a
    // cursor past the end reads nothing.
    expect(EditWatcher.slice("abcdef", location: 2, length: 3) ?? "nil", "cde",
           "fallback window slice")
    expect(EditWatcher.slice("abcdef", location: 4, length: 99) ?? "nil", "ef",
           "fallback window slice clamps at the end")
    expect(EditWatcher.slice("abcdef", location: 6, length: 3) == nil ? "nil" : "text", "nil",
           "fallback window slice past the end reads nothing")
    expect(EditWatcher.slice("éclair 🤖 done", location: 10, length: 4) ?? "nil", "done",
           "fallback slice counts UTF-16 units like the AX range")
    // The fallback as one function: the ranged read wins when the editor gives
    // one, else the same span of its whole value. It takes no selected range,
    // only the location and length recorded at paste time, which is what keeps
    // review working in an editor that publishes a value and no selection.
    expect(EditWatcher.windowText(ranged: "cde", whole: "ignored", location: 2, length: 3) ?? "nil",
           "cde", "ranged read wins over the whole value")
    expect(EditWatcher.windowText(ranged: nil, whole: "abcdef", location: 2, length: 3) ?? "nil",
           "cde", "whole value and no selected range falls back to the slice")
    expect(EditWatcher.windowText(ranged: nil, whole: "abcdef", location: 99, length: 3) == nil
             ? "nil" : "text", "nil", "whole value with the cursor past its end reads nothing")
    expect(EditWatcher.windowText(ranged: nil, whole: nil, location: 0, length: 3) == nil
             ? "nil" : "text", "nil", "neither answer reads nothing and does not crash")
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
var saveNotices: [String] = []
var lastBatch: EditWatcher.LearnedBatch?
watcher.onDictionarySaved = { batch in
    lastBatch = batch
    saveNotices.append(batch.entries.map { "\($0.from) → \($0.to)" }.joined(separator: ", "))
}

func dictHas(_ needle: String) -> Bool {
    (try? String(contentsOf: dictFile, encoding: .utf8).contains(needle)) ?? false
}

// A real word fixed to a name the checker does not know saves on the first
// sighting: the owner is naming something, and that name is what the
// dictionary is for.
watcher.apply(learner.decide(pasted: "Help me set up tail skill.",
                                   current: "Help me set up tailscale.", existingRules: []))
expect(dictHas("tail skill").description, "true", "a name fix writes on the first sighting")
expect(dictHas("tailscale").description, "true", "rule maps to tailscale")
expect(watcher.lastSummary?.contains("tail skill → tailscale") ?? false ? "shown" : "hidden",
       "shown", "menu shows Learned: tail skill → tailscale")
expect(saveNotices.last ?? "", "tail skill → tailscale", "alert follows the dictionary write")
// Saved now, used by the next dictation: the same file loads the rule back.
expect(PersonalDictionary(fileURL: dictFile).apply("Help me set up tail skill."),
       "Help me set up tailscale.", "the next dictation uses the learned rule")

// Junk fix writes immediately.
watcher.apply(learner.decide(pasted: "Open Pychy now.",
                                   current: "Open pi CLI now.", existingRules: []))
expect(dictHas("Pychy").description, "true", "junk fix writes at once")
expect(dictHas("pi CLI").description, "true", "junk fix target saved")
expect(saveNotices.last ?? "", "Pychy → pi CLI", "junk fix alerts after the write")

// The same fix again changes nothing, so it does not announce another save.
let noticesAfterPychy = saveNotices.count
watcher.apply(learner.decide(pasted: "Open Pychy now.",
                                   current: "Open pi CLI now.", existingRules: []))
expect(String(saveNotices.count), String(noticesAfterPychy), "duplicate rule is not announced again")

// A fix the checker can see through but does not consider a mishearing waits
// for a second sighting, then is written.
watcher.apply(learner.decide(pasted: "Email Filip today.",
                                   current: "Email Phillip today.", existingRules: []))
expect(dictHas("Filip").description, "false", "Filip→Phillip is not written the first time")
expect(dictHas("Phillip").description, "false", "Phillip is not written the first time")
expect(String(saveNotices.count), String(noticesAfterPychy), "Filip→Phillip shows no save alert")
watcher.apply(learner.decide(pasted: "Email Filip today.",
                                   current: "Email Phillip today.", existingRules: []))
expect(dictHas("Filip").description, "true", "second sighting writes the name swap")
expect(saveNotices.last ?? "", "Filip → Phillip", "name swap alerts on the second sighting")

// Undo of the learned batch restores the pre-learn state.
watcher.undoLast()
expect(dictHas("Filip").description, "false", "undo removes the promoted name swap")
expect(dictHas("Pychy").description, "true", "undo leaves earlier saves alone")
expect(String(saveNotices.count), String(noticesAfterPychy + 1), "undo shows no save alert")

// Undo: owner corrects a pasted Sol back to soul — the rule loses that source.
try PersonalDictionary.addReplacement(from: "soul", to: "Sol", fileURL: dictFile)
watcher.apply(learner.decide(pasted: "I use the Sol model.",
                                   current: "I use the soul model.",
                                   existingRules: PersonalDictionary.loadPairs(fileURL: dictFile)))
expect(dictHas("soul").description, "false", "undone rule loses its from")
expect(String(saveNotices.count), String(noticesAfterPychy + 1), "unlearning shows no save alert")

// Casing an unknown name is a real dictionary write, so it does announce.
watcher.apply(learner.decide(pasted: "Meet priya today.",
                                   current: "Meet Priya today.", existingRules: []))
expect(dictHas("Priya").description, "true", "unknown-name casing is saved")
expect(saveNotices.last ?? "", "priya → Priya", "term save alerts after the write")

// Fixes the gate can't see are pending once, then written the second time.
@MainActor
func learnTwice(_ pasted: String, _ current: String, _ from: String, _ to: String, _ label: String) {
    let before = saveNotices.count
    watcher.apply(learner.decide(pasted: pasted, current: current, existingRules: []))
    expect(dictHas(from).description, "false", "\(label) first sighting not saved")
    expect(String(saveNotices.count), String(before), "\(label) first sighting shows no alert")
    watcher.apply(learner.decide(pasted: pasted, current: current, existingRules: []))
    expect(dictHas(from).description, "true", "\(label) second sighting saved")
    expect(dictHas(to).description, "true", "\(label) target saved")
    expect(saveNotices.last ?? "", "\(from) → \(to)", "\(label) alerts after the second write")
}
learnTwice("Email Ellem today.", "Email LLM today.", "Ellem", "LLM", "Ellem→LLM")

// Undo on the confirmation card reverses exactly the batch it announced.
let noticesBeforeCardUndo = saveNotices.count
watcher.apply(learner.decide(pasted: "Meet chamath today.",
                                   current: "Meet Chamath today.", existingRules: []))
expect(dictHas("Chamath").description, "true", "a card batch is announced for the new term")
lastBatch?.undo()
expect(dictHas("Chamath").description, "false", "card undo removes the announced term")
expect(dictHas("Pychy").description, "true", "card undo leaves earlier saves alone")
expect(String(saveNotices.count), String(noticesBeforeCardUndo + 1), "card undo shows no save alert")

// Malformed dictionary.json: no write, no crash, no alert.
let noticesBeforeFailure = saveNotices.count
try "not json at all {{{".write(to: dictFile, atomically: true, encoding: .utf8)
watcher.apply(learner.decide(pasted: "Open Pychy now.",
                                   current: "Open pi CLI now.", existingRules: []))
expect((try? String(contentsOf: dictFile, encoding: .utf8)) ?? "", "not json at all {{{",
       "malformed dictionary never clobbered")
expect(String(saveNotices.count), String(noticesBeforeFailure), "failed write shows no save alert")

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
        // Repeated numbers are a code or a count. The old "Press 1 2 1 2." row stayed
        // only because the repeat ran to the end of the take.
        ("code 4 4 7.", "code 4 4 7."),
        ("press 1 2 1 2 5.", "press 1 2 1 2 5."),
        ("call 5 5 5 1 2 1 2.", "call 5 5 5 1 2 1 2."),
        ("call 5 5 5 5 now.", "call 5 5 5 5 now."),
        ("The code is 4, 4, 7.", "The code is 4, 4, 7."),
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

// Hostile sentences from the backlog: each case pins what the cleaner does
// today. Rows marked DOCUMENTED are current behavior kept on purpose —
// they're listed as open questions in the PR.
do {
    let hostile: [(String, String)] = [
        // Fillers hiding inside real words — never removed
        ("The umbrella is red.", "The umbrella is red."),
        ("Uhura gave the order.", "Uhura gave the order."),
        ("I likely agree.", "I likely agree."),
        ("It's, likely, true.", "It's, likely, true."),
        ("Um-huh, that's right.", "Um-huh, that's right."),
        ("The likelihood is high.", "The likelihood is high."),
        ("Sum the values.", "Sum the values."),
        // Numbers — words are never rewritten to digits, non-clock decimals stay
        ("two hundred and twenty two.", "two hundred and twenty two."),
        ("Pi is about 3.14.", "Pi is about 3.14."),
        ("Room 5.30 is free.", "Room 5.30 is free."),
        ("Meet at 13.30.", "Meet at 13.30."),
        ("Call at 0.30 PM.", "Call at 0.30 PM."),
        // Money — units guard keeps bare decimals alone
        ("I owe you 5.30 bucks.", "I owe you 5.30 bucks."),
        ("About 5.30 dollars today.", "About 5.30 dollars today."),
        ("It costs around 5.30 dollars.", "It costs around 5.30 dollars."),
        // DOCUMENTED (ambiguous): bare "at X.YZ" converts even when the user
        // meant a price or a ratio — the trigger word can't tell them apart.
        ("The total is at 5.30.", "The total is at 5:30."),
        ("The ratio is at 3.14.", "The ratio is at 3:14."),
        ("It costs around 5.30.", "It costs around 5:30."),
        // DOCUMENTED: "half past" isn't a trigger word, so this stays dotted.
        ("The train left half past 5.30.", "The train left half past 5.30."),
        // Clock times that convert
        ("It starts at 5.30.", "It starts at 5:30."),
        ("5.30pm works.", "5:30pm works."),
        ("by 5.30 or so.", "by 5:30 or so."),
        // End-of-take punctuation
        ("Really um?", "Really?"),
        ("Um um um.", ""),
        ("Wait, um...", "Wait..."),
        ("It was, like.", "It was."),
        ("I guess, you know?", "I guess?"),
        // Sentence-initial filler stripped: first word capitalizes as a take
        // start — right at a line start, debatable pasted mid-sentence.
        ("um, then we should go.", "Then we should go."),
        ("the rest of the sentence.", "the rest of the sentence."),
        // Abbreviation + comma ("e.g.,") is not a sentence end: the next word
        // must not capitalize after a filler is removed.
        ("For example, e.g., um, this thing.", "For example, e.g., this thing."),
        // But a quote closing a sentence still counts as its end.
        ("She said \"go.\" um, he left.", "She said \"go.\" He left."),
    ]
    for (input, output) in hostile {
        expect(cleaner.clean(input), output, "hostile(\"\(input)\")")
    }

    // Overlapping dictionary rules: longest `from` wins.
    let overlapDict = PersonalDictionary(terms: [], replacements: [
        "ChatGPT": ["chat g p t"], "GPT": ["g p t"],
        "NYC": ["new york"], "York City": ["york city"],
    ])
    expect(overlapDict.apply("ask g p t today."), "ask GPT today.", "shorter phrase still matches alone")
    expect(overlapDict.apply("ask chat g p t today."), "ask ChatGPT today.", "longest match wins")
    // DOCUMENTED: longest `from` applies first ("york city" beats "new york"),
    // but "new york" then re-matches inside the replacement's own output
    // ("new York") — suffix-overlapping rules can both fire on one span.
    expect(overlapDict.apply("meet in new york city."), "meet in NYC City.",
           "overlapping phrases: shorter rule re-matches the longer output")
}

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
// MARK: - Encoder windows (5 s, 10 s, stock 15 s)

do {
    let w5 = ShortWindowEngine.fastWindowSeconds * 16_000
    let w10 = ShortWindowEngine.middleWindowSeconds * 16_000
    let w15 = ShortWindowEngine.maxWindowSamples
    let windows = [w15, w5, w10]  // unsorted: the picker sorts

    expect(ShortWindowEngine.middleBundle.name, "parakeet_unified_encoder_w10000_int8.mlmodelc",
           "10s bundle name")
    expect(String(w10), "160000", "10s window is 160000 samples")
    expect(ShortWindowEngine.fittingWindowSamples(w5, windows: windows).map(String.init) ?? "nil",
           String(w5), "5.0s audio uses the 5s window")
    expect(ShortWindowEngine.fittingWindowSamples(w5 + 1, windows: windows).map(String.init) ?? "nil",
           String(w10), "just over 5s uses the 10s window")
    expect(ShortWindowEngine.fittingWindowSamples(7 * 16_000, windows: windows).map(String.init) ?? "nil",
           String(w10), "7s audio uses the 10s window")
    expect(ShortWindowEngine.fittingWindowSamples(w10, windows: windows).map(String.init) ?? "nil",
           String(w10), "exactly 10s uses the 10s window")
    expect(ShortWindowEngine.fittingWindowSamples(w10 + 1, windows: windows).map(String.init) ?? "nil",
           String(w15), "just over 10s uses the 15s window")
    expect(ShortWindowEngine.fittingWindowSamples(w15 + 1, windows: windows).map(String.init) ?? "nil",
           "nil", "over 15s fits no single window")
    expect(ShortWindowEngine.fittingWindowSamples(3 * 16_000, windows: [w15, w5]).map(String.init) ?? "nil",
           String(w5), "without a 10s bundle, short audio still uses 5s")
    expect(ShortWindowEngine.fittingWindowSamples(7 * 16_000, windows: [w15, w5]).map(String.init) ?? "nil",
           String(w15), "without a 10s bundle, a 7s tail still uses 15s")

    let unpublished = RemoteBundle(
        name: ShortWindowEngine.middleBundle.name, url: ShortWindowEngine.middleBundle.url, sha256: "")
    let published = RemoteBundle(
        name: ShortWindowEngine.middleBundle.name, url: ShortWindowEngine.middleBundle.url,
        sha256: String(repeating: "ab", count: 32))
    expect(ShortWindowEngine.bundlesToFetch([unpublished], presentNames: []).isEmpty.description,
           "true", "empty checksum is not downloaded")
    expect(ShortWindowEngine.bundlesToFetch([published], presentNames: []).map(\.name).joined(separator: ","),
           published.name, "published bundle is fetched when missing")
    expect(ShortWindowEngine.bundlesToFetch([published], presentNames: [published.name]).isEmpty.description,
           "true", "bundle already on disk is not fetched again")
    expect(
        ShortWindowEngine.bundlesToFetch(
            [ShortWindowEngine.fastBundle, published],
            presentNames: [ShortWindowEngine.fastBundle.name]
        ).map(\.name).joined(separator: ","),
        published.name, "a longer window still downloads when the 5s one is installed")

    let missing = ShortWindowEngine.bundlesToFetch(presentNames: [])
    // The 10 s checksum is empty on purpose: there is no published zip, and a
    // made-up hash must not land here. When models-v2 is published, replace ""
    // with that zip's SHA-256 and expect both bundle names below.
    expect(ShortWindowEngine.middleBundle.sha256, "",
           "10s checksum stays empty until the models-v2 zip is published")
    expect(missing.map(\.name).joined(separator: ","), ShortWindowEngine.fastBundle.name,
           "while the 10s checksum is empty, only the 5s bundle is downloaded")

    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("whisp-windows-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    for name in [
        "parakeet_unified_encoder_int8.mlmodelc",
        "parakeet_unified_encoder_w5000_int8.mlmodelc",
        "parakeet_unified_encoder_w10000.mlmodelc",
        "parakeet_unified_encoder_w10000_int8.mlmodelc",
        "parakeet_unified_encoder_w2000_int8.mlmodelc",
        "notes.mlmodelc",
    ] {
        try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let found = ShortWindowEngine.discoverVariants(in: dir)
    let desc = found.map {
        "\($0.windowSamples):\($0.int8 ? "int8" : "fp"):\($0.url.lastPathComponent)"
    }.joined(separator: ",")
    expect(desc,
           "32000:int8:parakeet_unified_encoder_w2000_int8.mlmodelc,80000:int8:parakeet_unified_encoder_w5000_int8.mlmodelc,160000:int8:parakeet_unified_encoder_w10000_int8.mlmodelc,240000:int8:parakeet_unified_encoder_int8.mlmodelc",
           "discover prefers int8 and sorts shortest first")
}

expect(ASREngine.defaultName, "short", "default engine is the short-window one")
expect(String(describing: type(of: ASREngine.make(named: "typo"))), "ShortWindowEngine", "unknown engine name falls back")

// MARK: - Decode counters cost nothing when nothing listens

// The RNNT loop reads the clock twice per Core ML call to feed the bench's
// --stages split. That has to cost the shipping path nothing: only the bench
// attaches an observer, so the app decodes with collection off. Decode the same
// window both ways: same tokens, and the silent run recorded nothing while the
// collecting one counted every call it made.
do {
    if let probe = try await ShortWindowEngine.decodeStatsProbe() {
        expect(probe.identical ? "same" : "different", "same",
               "counters on and off emit identical tokens")
        expect("\(probe.jointCalls)", "\(probe.frames)",
               "collecting counts one joint call per encoder frame")
        expect("\(probe.decoderCalls >= 1)", "true", "collecting counts the decoder steps")
        expect(probe.silentStatsAreZero ? "zero" : "non-zero", "zero",
               "collection off records no timings and no call counts")
        if probe.tokenCount == 0 {
            // Synthetic features never make the joint emit: only real encoder
            // output does. The 40 decisions above are still compared, one per
            // frame, and both runs agree on every one.
            print("note: probe window emits no symbols (the joint answers blank on synthetic features)")
        }
    } else {
        print("skip: decode-stats probe needs the joint and decoder bundles")
    }
} catch {
    failures += 1
    print("FAIL decode-stats probe threw: \(error)")
}

// MARK: - Speed

// The formatting step has a 5 ms per-dictation budget. Two corpora: ordinary
// sentences, and sentences full of the words the coding pack rewrites.
let plainDictations = [
    "so I think we should ship it today and see what happens with the rest of the batch",
    "the meeting moved to three thirty and nobody told the other team about it",
    "can you send me the numbers from last week when you get a second",
]
let codingDictations = [
    "so I told claude code to fix the agents dot md file and it broke the jason config again",
    "the pr on git hub is red so post gres and vercel both need another look before we ship it",
    "open cursor and run n p m install, then check the linear issue and put the notes in notion",
]
func medianMs(_ texts: [String], _ iterations: Int) -> Double {
    var samples: [Double] = []
    for _ in 0..<iterations {
        let start = Date()
        for text in texts { _ = cleaner.clean(text) }
        samples.append(Date().timeIntervalSince(start) * 1000 / Double(texts.count))
    }
    return samples.sorted()[samples.count / 2]
}
// The longest real dictation on this machine is 8,815 characters, and 23 of 2,445
// are over 2,880, so the budget has to hold at the long end too. Two long texts:
// one shaped like his real dictation (ordinary talk with a coding word every few
// sentences, which is what the budget is measured on), and one that is nothing but
// coding words, printed for the worst case and not asserted.
let longestLength = 8_815
func repeated(_ sentence: String, to length: Int) -> String {
    var text = ""
    while text.count < length { text += sentence }
    return String(text.prefix(length))
}
let longestDictation = repeated("so I think we should ship it today and see what happens with the rest of the batch and then we can look at the numbers from last week and tell me what you think about the whole thing ", to: longestLength)
let codingHeavy = repeated("so I told claude code to fix the agents dot md file and check the jason config on local host again ", to: longestLength)
let longestMs = medianMs([longestDictation], 20)
let codingHeavyMs = medianMs([codingHeavy], 20)
let plainMs = medianMs(plainDictations, 200)
let codingMs = medianMs(codingDictations, 200)
print(String(format: "formatting step: %.3f ms ordinary, %.3f ms coding, %.3f ms at %d chars (budget 5 ms)",
             plainMs, codingMs, longestMs, longestDictation.count))
print(String(format: "  worst case at %d chars of nothing but coding words: %.3f ms (printed, not asserted)",
             codingHeavy.count, codingHeavyMs))
if Swift.max(plainMs, codingMs, longestMs) > 5 { failures += 1; print("FAIL formatting step over the 5 ms budget") }

let long = String(repeating: "Um, so I I was, like, thinking we should, you know, ship the the thing. ", count: 40)
let t0 = Date()
for _ in 0..<50 { _ = dictCleaner.clean(long) }
let perCallMs = Date().timeIntervalSince(t0) * 1000 / 50
print(String(format: "clean() on %d chars: %.2f ms", long.count, perCallMs))
if perCallMs > 20 { failures += 1; print("FAIL clean() too slow") }

// The format step's budget is 5 ms for a long take: five minutes of dictation is
// about 750 words, so measure on more than that, including the parts that make the
// rules work hardest (numbers, spoken paths, sentence ends).
let longDictation = String(
    repeating: "um so I I was thinking we should, like, ship the the build to src slash main dot swift at five thirty and it costs twenty five dollars. ",
    count: 32)
let longWords = longDictation.split(whereSeparator: \.isWhitespace).count
// One take, both text steps, so the numbers line up: clean alone is where the
// text step stood before the formatter existed, clean+format is where it stands
// now, and format alone is what the new step costs.
let t1 = Date()
for _ in 0..<50 { _ = dictCleaner.clean(longDictation) }
let beforeMs = Date().timeIntervalSince(t1) * 1000 / 50
let t2 = Date()
for _ in 0..<50 { _ = formatter.format(dictCleaner.clean(longDictation)) }
let afterMs = Date().timeIntervalSince(t2) * 1000 / 50
let longCleaned = dictCleaner.clean(longDictation)
let t3 = Date()
for _ in 0..<50 { _ = formatter.format(longCleaned) }
let perFormatMs = Date().timeIntervalSince(t3) * 1000 / 50
print(String(format: "text step on %d words / %d chars (%.0f s of speech): clean %.3f ms -> clean+format %.3f ms (format %.3f ms)",
             longWords, longDictation.count, Double(longWords) / 2.5, beforeMs, afterMs, perFormatMs))
if perFormatMs > 5 {
    failures += 1
    print("FAIL format() over the 5 ms budget")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
