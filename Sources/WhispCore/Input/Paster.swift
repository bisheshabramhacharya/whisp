import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Inserts dictated text into the frontmost app at the cursor, without stealing focus:
///
///   1. Best-effort Accessibility read of the focused element to decide whether a
///      leading space is needed (hard time-boxed via AX messaging timeout).
///   2. Snapshot every item/type on the general pasteboard.
///   3. Write the text, marked `org.nspasteboard.TransientType`/`ConcealedType` so
///      clipboard managers don't record it.
///   4. Post Cmd+V as a real HID event (`.cghidEventTap`).
///   5. ~300 ms later, restore the original clipboard — but only if `changeCount`
///      shows nothing else wrote to the pasteboard in the meantime.
public final class Paster: TextPasting {

    /// How long to wait before restoring the user's clipboard (ms).
    public var restoreDelay: TimeInterval = 0.3

    /// Hard cap on every Accessibility query so a hung target app can't stall pasting.
    private static let axTimeout: Float = 0.02 // 20 ms

    /// NSPasteboard marker types that tell clipboard managers to ignore this write.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// The user's clipboard and the scheduled restore, while one is pending. A paste
    /// that lands before the restore reuses this snapshot instead of capturing our
    /// own previous dictation as "the user's clipboard". Main thread only.
    private var pendingRestore: (snapshot: [[NSPasteboard.PasteboardType: Data]], work: DispatchWorkItem)?

    public init() {}

    // MARK: - TextPasting

    /// Call on the main thread.
    public func paste(_ text: String) {
        guard !text.isEmpty else { return }

        var text = text
        if shouldPrependSpace(to: text) {
            text = " " + text
        }

        let pasteboard = NSPasteboard.general
        let snapshot: [[NSPasteboard.PasteboardType: Data]]
        if let pending = pendingRestore {
            pending.work.cancel()
            snapshot = pending.snapshot
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
        pendingRestore = (snapshot, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
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

    /// Prepend a space when the text starts with an alphanumeric character AND the
    /// character right before the cursor is non-whitespace (i.e. we're appending to
    /// a word/sentence rather than starting fresh). Everything is best-effort and
    /// time-boxed: any AX failure -> paste as-is.
    private func shouldPrependSpace(to text: String) -> Bool {
        guard let first = text.first, first.isLetter || first.isNumber else { return false }
        guard AXIsProcessTrusted() else { return false }
        guard let previous = focusedCharacterBeforeCursor() else { return false }
        return !previous.isWhitespace
    }

    /// The single character immediately before the focused element's insertion point.
    /// Prefers the parameterized "string for range" attribute (cheap — the target only
    /// serializes one character); falls back to reading the whole value.
    private func focusedCharacterBeforeCursor() -> Character? {
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

        // Fallback: read the whole value and index into it (still time-boxed).
        var wholeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &wholeValue
        ) == .success, let string = wholeValue as? String else { return nil }
        let index = string.index(string.startIndex, offsetBy: range.location - 1,
                                 limitedBy: string.endIndex)
        guard let index, index < string.endIndex else { return nil }
        return string[index]
    }
}
