import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// The general pasteboard's contents and its `changeCount`, captured off the
/// main thread.
public struct ClipboardCapture: Sendable {
    public let items: [[NSPasteboard.PasteboardType: Data]]
    public let changeCount: Int
}

/// Inserts dictated text into the frontmost app at the cursor, without stealing focus:
///
///   1. At key release, note the frontmost app and start background, time-boxed
///      Accessibility read of the character before the cursor (decides whether a
///      leading space is needed) plus a snapshot of the general pasteboard.
///      Both run while the model transcribes.
///   2. If a different app is frontmost by paste time, leave the text on the clipboard
///      instead of pasting into the wrong window.
///   3. Reuse the key-release snapshot when the pasteboard hasn't changed since.
///   4. Write the text, marked `org.nspasteboard.TransientType`/`ConcealedType` so
///      clipboard managers don't record it.
///   5. Post Cmd+V as a real HID event (`.cghidEventTap`).
///   6. ~300 ms later, restore the original clipboard — but only if `changeCount`
///      shows nothing else wrote to the pasteboard in the meantime.
@MainActor
public final class Paster: TextPasting {

    /// How long to wait before restoring the user's clipboard (ms).
    public var restoreDelay: TimeInterval = 0.3

    /// Whether Secure Event Input is on at paste time — injectable for tests.
    /// While a secure field holds focus (password prompts, etc.), synthetic
    /// keystrokes are swallowed or land nowhere, so paste must copy instead.
    public var secureEventInput: () -> Bool = { IsSecureEventInputEnabled() }

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

    /// Called on the pasted path with the focused element context and the text
    /// actually inserted (including any leading space added here) plus the pid
    /// of the app it landed in. Used by the auto-learn watcher to remember the
    /// pasted span. Never on the hot path: fires after Cmd+V is posted, before
    /// the clipboard restore.
    public var onInserted: (@MainActor (FocusedContext, String, pid_t?) -> Void)?

    public func target() -> PasteTarget {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let lookup = Task.detached(priority: .userInitiated) { () -> FocusedContext? in
            guard AXIsProcessTrusted() else { return nil }
            return Self.focusedContext()
        }
        let clipboard = Task.detached(priority: .userInitiated) {
            let pasteboard = NSPasteboard.general
            return ClipboardCapture(items: Self.snapshot(pasteboard),
                                    changeCount: pasteboard.changeCount)
        }
        return PasteTarget(pid: pid, focused: lookup, clipboard: clipboard)
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
        // Secure Event Input means a secure field holds focus somewhere and
        // would swallow the synthetic Cmd+V — copy instead of pasting, and
        // leave the text for the user's own Cmd+V (no restore either).
        if secureEventInput() {
            pendingRestore?.work.cancel()
            pendingRestore = nil
            pasteboard.clearContents()
            pasteboard.setString(text.trimmingCharacters(in: .whitespaces), forType: .string)
            return .copiedSecureInput
        }
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
            snapshot = pasteboard.changeCount == pending.changeCount
                ? pending.snapshot
                : await Self.capturedOrFresh(target, pasteboard)
        } else {
            snapshot = await Self.capturedOrFresh(target, pasteboard)
        }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        item.setData(Data(), forType: Self.concealedType)
        pasteboard.writeObjects([item])
        let expectedChangeCount = pasteboard.changeCount

        // The check above ran before the snapshot await; a switch since then
        // would fire Cmd+V into the wrong window. The text stays on the
        // pasteboard either way, so bail to the same copied-for-⌘V path.
        if let pid = target.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            pendingRestore = nil
            return .copiedAppChanged
        }

        Self.postCommandV()

        // The focused lookup already resolved above (preceding awaited it), so
        // this never adds an AX round-trip to the paste.
        if let context = await target.focused.value, let onInserted {
            onInserted(context, text, target.pid)
        }

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

    /// The key-release snapshot when the pasteboard hasn't changed since it was
    /// taken; otherwise a fresh one taken now.
    private nonisolated static func capturedOrFresh(_ target: PasteTarget, _ pasteboard: NSPasteboard) async
        -> [[NSPasteboard.PasteboardType: Data]]
    {
        guard let captured = await target.clipboard?.value,
              captured.changeCount == pasteboard.changeCount else {
            return Self.snapshot(pasteboard)
        }
        return captured.items
    }

    /// Copies every data type of every existing pasteboard item, in order.
    /// Read-only, thread-safe — also used by the key-release capture task.
    private nonisolated static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
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

    /// The focused element plus cursor position, the character before it, and
    /// up to 40 UTF-16 chars of text before it — one lookup serving both the
    /// leading-space heuristic and the auto-learn pasted span. Prefers the
    /// parameterized "string for range" attribute (cheap — the target only
    /// serializes the requested slice); falls back to reading the whole value.
    /// Best-effort and time-boxed: any AX failure -> nil (paste as-is). Thread-safe.
    private nonisolated static func focusedContext() -> FocusedContext? {
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
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }

        var preceding: Character?
        var beforeText = ""
        if range.location > 0 {
            // Preferred: ask for just the slice before the cursor.
            var sliceRange = CFRange(location: max(0, range.location - 40), length: min(40, range.location))
            if let param = AXValueCreate(.cfRange, &sliceRange) {
                var stringValue: AnyObject?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString,
                    param, &stringValue
                ) == .success, let string = stringValue as? String {
                    beforeText = string
                    preceding = string.last
                }
            }
        }
        if preceding == nil {
            // Fallback: read the whole value and index into it (still time-boxed).
            // AX ranges count UTF-16 code units, so index the UTF-16 view.
            var wholeValue: AnyObject?
            if AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &wholeValue
            ) == .success, let string = wholeValue as? String {
                let utf16 = string.utf16
                if let cut = utf16.index(utf16.startIndex, offsetBy: range.location, limitedBy: utf16.endIndex) {
                    let head = string.prefix(upTo: cut.samePosition(in: string) ?? string.startIndex)
                    beforeText = String(head.suffix(40))
                    preceding = head.last
                }
            }
        }
        return FocusedContext(element: element, cursorLocation: range.location,
                              preceding: preceding, beforeText: beforeText)
    }
}
