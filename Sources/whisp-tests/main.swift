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

// MARK: - Speed

let long = String(repeating: "Um, so I I was, like, thinking we should, you know, ship the the thing. ", count: 40)
let t0 = Date()
for _ in 0..<50 { _ = dictCleaner.clean(long) }
let perCallMs = Date().timeIntervalSince(t0) * 1000 / 50
print(String(format: "clean() on %d chars: %.2f ms", long.count, perCallMs))
if perCallMs > 20 { failures += 1; print("FAIL clean() too slow") }

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
