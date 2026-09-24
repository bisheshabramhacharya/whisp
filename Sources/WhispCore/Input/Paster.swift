import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Inserts dictated text into the frontmost app at the cursor, without stealing focus:
///
///   1. At key release, note the frontmost app and start a background, time-boxed
///      Accessibility read of the character before the cursor (decides whether a
///      leading space is needed). It runs while the model transcribes.
///   2. If a different app is frontmost by paste time, leave the text on the clipboard
///      instead of pasting into the wrong window.
///   3. Snapshot every item/type on the general pasteboard.
///   4. Write the text, marked `org.nspasteboard.TransientType`/`ConcealedType` so
///      clipboard managers don't record it.
///   5. Post Cmd+V as a real HID event (`.cghidEventTap`).
///   6. ~300 ms later, restore the original clipboard — but only if `changeCount`
///      shows nothing else wrote to the pasteboard in the meantime.
@MainActor
public final class Paster: TextPasting {

    /// How long to wait before restoring the user's clipboard (ms).
    public var restoreDelay: TimeInterval = 0.3

    /// Hard cap on every Accessibility query so a hung target app can't stall pasting.
    private nonisolated static let axTimeout: Float = 0.02 // 20 ms

    /// NSPasteboard marker types that tell clipboard managers to ignore this write.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// The user's clipboard and the scheduled restore, while one is pending. A paste
    /// that lands before the restore reuses this snapshot instead of capturing our
    /// own previous dictation as "the user's clipboard" — unless the user copied
    /// something since (`changeCount` moved), which then becomes the clipboard to restore.
    private var pendingRestore: (snapshot: [[NSPasteboard.PasteboardType: Data]], changeCount: Int,
                                 work: DispatchWorkItem)?

    public init() {}

    // MARK: - TextPasting

    public func target() -> PasteTarget {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let lookup = Task.detached(priority: .userInitiated) { () -> Character? in
            guard AXIsProcessTrusted() else { return nil }
            return Self.focusedCharacterBeforeCursor()
        }
        return PasteTarget(pid: pid, precedingCharacter: lookup)
    }

    public func paste(_ text: String, into target: PasteTarget) async -> PasteResult {
        guard !text.isEmpty else { return .pasted }

        var text = text
        if let first = text.first, first.isLetter || first.isNumber,
           let previous = await target.precedingCharacter.value,
           Self.needsSpace(after: previous) {
            text = " " + text
        }

        let pasteboard = NSPasteboard.general
        if let pid = target.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            pendingRestore?.work.cancel()
            pendingRestore = nil
            pasteboard.clearContents()
            pasteboard.setString(text.trimmingCharacters(in: .whitespaces), forType: .string)
            return .copiedAppChanged
        }

        let snapshot: [[NSPasteboard.PasteboardType: Data]]
        if let pending = pendingRestore {
            pending.work.cancel()
            snapshot = pasteboard.changeCount == pending.changeCount ? pending.snapshot : Self.snapshot(pasteboard)
        } else {
            snapshot = Self.snapshot(pasteboard)
        }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        item.setData(Data(), forType: Self.concealedType)
        pasteboard.writeObjects([item])
        let expectedChangeCount = pasteboard.changeCount

        Self.postCommandV()

        // Restore the user's clipboard once the target app has consumed Cmd+V —
        // unless somebody else wrote to the pasteboard in the meantime.
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRestore = nil
            guard pasteboard.changeCount == expectedChangeCount else { return }
            pasteboard.clearContents()
            let items = snapshot.map { types -> NSPasteboardItem in
                let restored = NSPasteboardItem()
                for (type, data) in types {
                    restored.setData(data, forType: type)
                }
                return restored
            }
            if !items.isEmpty {
                pasteboard.writeObjects(items)
            }
        }
        pendingRestore = (snapshot, expectedChangeCount, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
        return .pasted
    }

    /// Dictation is appended to a word/sentence (so needs a separating space) unless the
    /// cursor follows whitespace or an opening bracket/quote/slash: "foo(" + "bar" -> "foo(bar".
    public nonisolated static func needsSpace(after previous: Character) -> Bool {
        !previous.isWhitespace && !"([{/\\\u{201C}\u{2018}".contains(previous)
    }

    // MARK: - Cmd+V

    /// Posts a physical-looking Cmd+V to the HID event tap so even apps that ignore
    /// synthetic app-level events still paste.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        if let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Clipboard snapshot

    /// Copies every data type of every existing pasteboard item, in order.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    types[type] = data
                }
            }
            return types
        }
    }

    // MARK: - Smart spacing

    /// The single character immediately before the focused element's insertion point.
    /// Prefers the parameterized "string for range" attribute (cheap — the target only
    /// serializes one character); falls back to reading the whole value.
    /// Best-effort and time-boxed: any AX failure -> nil (paste as-is). Thread-safe.
    private nonisolated static func focusedCharacterBeforeCursor() -> Character? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.axTimeout)

        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue
        ) == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = focusedValue as! AXUIElement // safe: type ID checked above
        AXUIElementSetMessagingTimeout(element, Self.axTimeout)

        // Where is the cursor?
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        ) == .success, let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
              range.location > 0 else { return nil } // cursor at position 0 -> never a space

        // Preferred: ask for just the preceding character.
        var charRange = CFRange(location: range.location - 1, length: 1)
        if let param = AXValueCreate(.cfRange, &charRange) {
            var stringValue: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString,
                param, &stringValue
            ) == .success, let string = stringValue as? String, let ch = string.first {
                return ch
            }
        }

        // Fallback: read the whole value and index into it (still time-boxed). AX ranges
        // count UTF-16 code units, so index the UTF-16 view, not Characters.
        var wholeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &wholeValue
        ) == .success, let string = wholeValue as? String else { return nil }
        let utf16 = string.utf16
        guard range.location <= utf16.count,
              let end = utf16.index(utf16.startIndex, offsetBy: range.location, limitedBy: utf16.endIndex),
              let endIndex = end.samePosition(in: string.unicodeScalars),
              endIndex > string.unicodeScalars.startIndex else { return nil }
        let scalar = string.unicodeScalars[string.unicodeScalars.index(before: endIndex)]
        return Character(scalar)
    }
}
