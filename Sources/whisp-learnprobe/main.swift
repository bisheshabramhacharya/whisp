import AppKit
import ApplicationServices
import Foundation
import WhispCore

// Live probe for the auto-learn path: does a correction the owner types after
// Whisp pasted something reach dictionary.json?
//
//   swift run -c release whisp-learnprobe
//
// It opens one real text view, records a paste into it through `EditWatcher`,
// edits the wrong word, and triggers the review the app triggers at the next
// dictation. Prints one line per stage and exits 0 only when the rule landed.
// Synthetic text only: it never reads or writes the owner's dictations.
//
// The window has to be on screen for Accessibility to publish its text area,
// so this takes focus for about a second. Nothing else uses the speech model.

let landing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("whisp-learnprobe-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
let dictionary = landing.appendingPathComponent("dictionary.json")
try "{\n  \"terms\": [],\n  \"replacements\": []\n}".write(to: dictionary, atomically: true, encoding: .utf8)

// The app's own oracle.
let learner = CorrectionLearner { word in
    NSSpellChecker.shared.checkSpelling(
        of: word, startingAt: 0, language: "en", wrap: false,
        inSpellDocumentWithTag: 0, wordCount: nil
    ).location == NSNotFound
}

let pasted = "Ship the knockout today."     // "knockout" is a word, "nelko" is not
let anchor = "Note: "
let fixed = anchor + "Ship the nelko today."

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 520, height: 200),
                      styleMask: [.titled], backing: .buffered, defer: false)
let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
window.contentView = textView
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(textView)
app.activate(ignoringOtherApps: true)

var liveWatcher: EditWatcher?

func axString(_ element: AXUIElement, _ name: String) -> String? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? String
}

func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: landing)
    exit(code)
}

// Nothing here may hang a terminal: a probe is not a test suite.
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("learnprobe: timeout waiting for the review")
    finish(9)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
    textView.string = anchor
    textView.setSelectedRange(NSRange(location: anchor.utf16.count, length: 0))

    let watcher = EditWatcher(learner: learner, dictionaryFile: dictionary,
                              pendingFile: landing.appendingPathComponent("corrections-pending.json"),
                              isEnabled: { true })
    watcher.onDictionarySaved = { message in
        print("learnprobe: app would announce \"\(message)\"")
    }
    // Strong reference for the whole probe: the review hops back to the main
    // actor, and a released watcher would drop it silently.
    liveWatcher = watcher

    var focused: AnyObject?
    let appElement = AXUIElementCreateApplication(getpid())
    guard AXUIElementCopyAttributeValue(
        appElement, kAXFocusedUIElementAttribute as CFString, &focused
    ) == .success, let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
        print("learnprobe: no focused Accessibility element, so the review cannot be read back")
        finish(4)
    }
    let element = raw as! AXUIElement
    print("learnprobe: focused element is \(axString(element, kAXRoleAttribute) ?? "?")")

    watcher.record(FocusedContext(element: element,
                                  cursorLocation: anchor.utf16.count,
                                  preceding: " ", beforeText: anchor),
                   text: pasted, pid: getpid())
    print("learnprobe: recorded the paste, now the owner fixes the word")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        textView.string = fixed
        // What the app does when the next dictation starts.
        watcher.dictationStarting()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let written = (try? String(contentsOf: dictionary, encoding: .utf8)) ?? ""
            let hasFrom = written.contains("\"knockout\"")
            let hasTo = written.contains("\"nelko\"")
            print("learnprobe: dictionary.json has \"knockout\": \(hasFrom), \"nelko\": \(hasTo)")
            print("learnprobe: \(hasFrom && hasTo ? "PASS" : "FAIL")")
            finish(hasFrom && hasTo ? 0 : 5)
        }
    }
}

app.run()
