import AppKit
import ApplicationServices
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
///   1. At key release, note the frontmost app and window, and start a background,
///      time-boxed Accessibility read of the character before the cursor (decides
///      whether a leading space is needed) plus a snapshot of the general pasteboard.
///      Both run while the model transcribes.
///   2. If a different app — or a different window of the same app — is frontmost by
///      paste time, leave the text on the clipboard instead of pasting into the
///      wrong place. An unknown window id never blocks the paste.
///   3. Reuse the key-release snapshot when the pasteboard hasn't changed since.
///   4. Write the text, marked `org.nspasteboard.TransientType`/`ConcealedType` so
///      clipboard managers don't record it.
///   5. Post Cmd+V as a real HID event (`.cghidEventTap`).
///   6. Restore the original clipboard once Accessibility shows the focused element
///      took the text. Reading the pasteboard does not change `changeCount`, so a
///      fixed timer cannot tell a slow target (Electron, a busy browser, a remote
///      desktop) from one that already pasted. When the insertion can't be confirmed,
///      wait `restoreDelay` (long enough for those targets) and still refuse to
///      overwrite a pasteboard someone else wrote in the meantime.
@MainActor
public final class Paster: TextPasting {

    /// How long dictated text stays on the clipboard when the focused element
    /// can't be shown to contain it. A confirmed insertion restores sooner.
    /// Must outlast targets that read the pasteboard late; 300 ms did not.
    public var restoreDelay: TimeInterval = 2

    /// How often to re-read the focused element while waiting out `restoreDelay`.
    private static let confirmPollNanos: UInt64 = 50_000_000

    /// Hard cap on every Accessibility query so a hung target app can't stall pasting.
    private nonisolated static let axTimeout: Float = 0.02 // 20 ms

    /// Selections longer than this are not read back; the length check still works.
    private nonisolated static let maxSelectedRead = 2000

    /// NSPasteboard marker types that tell clipboard managers to ignore this write.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard: NSPasteboard
    private let postPaste: @MainActor () -> Void

    /// The user's clipboard and the scheduled restore, while one is pending. A paste
    /// that lands before the restore reuses this snapshot instead of capturing our
    /// own previous dictation as "the user's clipboard" — unless the user copied
    /// something since (`changeCount` moved), which then becomes the clipboard to restore.
    private var pendingRestore: (snapshot: [[NSPasteboard.PasteboardType: Data]], changeCount: Int,
                                 task: Task<Void, Never>)?

    /// Bumped at the start of every paste so a restore scheduled for the previous
    /// one can't write over the new dictation.
    private var restoreGeneration = 0

    /// Frontmost app. Tests substitute this.
    public var frontmostProcessID: @MainActor () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Frontmost on-screen window of `pid`, or nil when it can't be determined.
    /// A nil result never blocks a paste. Tests substitute this.
    public var frontmostWindowID: @MainActor (pid_t) -> UInt32? = { pid in
        Paster.systemFrontmostWindowID(pid: pid)
    }

    /// When set, replaces the Accessibility read that decides whether the target
    /// has taken the paste. Return true to restore on the next poll, false to keep
    /// waiting, nil when the insertion can't be confirmed. Production leaves this nil.
    public var confirmInsertion: (@MainActor (_ text: String) -> Bool?)?

    public init(pasteboard: NSPasteboard = .general, postPaste: (@MainActor () -> Void)? = nil) {
        self.pasteboard = pasteboard
        self.postPaste = postPaste ?? { Self.postCommandV() }
    }

    // MARK: - TextPasting

    /// Called on the pasted path with the focused element context and the text
    /// actually inserted (including any leading space added here) plus the pid
    /// of the app it landed in. Used by the auto-learn watcher to remember the
    /// pasted span. Never on the hot path: fires after Cmd+V is posted, before
    /// the clipboard restore.
    public var onInserted: (@MainActor (FocusedContext, String, pid_t?) -> Void)?

    public func target() -> PasteTarget {
        let pid = frontmostProcessID()
        let windowID = pid.flatMap { frontmostWindowID($0) }
        let axWindow: Task<AXWindowToken?, Never>?
        if let pid, windowID == nil {
            // Window list couldn't see one (no on-screen window, or the list is
            // empty without screen recording). Accessibility is already required
            // for the hotkey, so remember the focused window and compare it later.
            axWindow = Task.detached(priority: .userInitiated) {
                guard let element = Self.focusedWindow(pid: pid) else { return nil }
                return AXWindowToken(element)
            }
        } else {
            axWindow = nil
        }
        let lookup = Task.detached(priority: .userInitiated) { () -> FocusedContext? in
            guard AXIsProcessTrusted() else { return nil }
            return Self.focusedContext()
        }
        let board = pasteboard
        let clipboard = Task.detached(priority: .userInitiated) {
            ClipboardCapture(items: Self.snapshot(board), changeCount: board.changeCount)
        }
        return PasteTarget(pid: pid, focused: lookup, clipboard: clipboard,
                           windowID: windowID, axWindow: axWindow)
    }

    public func paste(_ text: String, into target: PasteTarget) async -> PasteResult {
        guard !text.isEmpty else { return .pasted }
        restoreGeneration += 1
        let generation = restoreGeneration
        pendingRestore?.task.cancel()

        var text = text
        if let first = text.first, first.isLetter || first.isNumber,
           let previous = await target.precedingCharacter.value,
           Self.needsSpace(after: previous) {
            text = " " + text
        }

        let pasteboard = self.pasteboard
        if await focusLeft(target) {
            pendingRestore?.task.cancel()
            pendingRestore = nil
            pasteboard.clearContents()
            pasteboard.setString(text.trimmingCharacters(in: .whitespaces), forType: .string)
            return .copiedAppChanged
        }

        let snapshot: [[NSPasteboard.PasteboardType: Data]]
        if let pending = pendingRestore {
            pending.task.cancel()
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
        // would fire Cmd+V into the wrong window. Rewrite without the transient
        // markers so a manual ⌘V still works and clipboard history keeps it.
        if await focusLeft(target) {
            pendingRestore?.task.cancel()
            pendingRestore = nil
            pasteboard.clearContents()
            pasteboard.setString(text.trimmingCharacters(in: .whitespaces), forType: .string)
            return .copiedAppChanged
        }

        postPaste()

        // The focused lookup already resolved above (preceding awaited it), so
        // this never adds an AX round-trip to the paste.
        let context = await target.focused.value
        if let context, let onInserted {
            onInserted(context, text, target.pid)
        }

        scheduleRestore(snapshot: snapshot, expectedChangeCount: expectedChangeCount,
                        generation: generation, text: text, context: context)
        return .pasted
    }

    /// Dictation is appended to a word/sentence (so needs a separating space) unless the
    /// cursor follows whitespace or an opening bracket/quote/slash: "foo(" + "bar" -> "foo(bar".
    public nonisolated static func needsSpace(after previous: Character) -> Bool {
        !previous.isWhitespace && !"([{/\\\u{201C}\u{2018}".contains(previous)
    }

    /// True when the dictation should stay on the clipboard instead of being pasted.
    /// A nil window on either side means that side couldn't see a window; that alone
    /// never blocks the paste (the pid check still runs). `axWindowDiffers` is only
    /// consulted when the numeric ids can't be compared, and nil means the
    /// accessibility window couldn't be read either.
    public nonisolated static func focusLeftTarget(
        releasePID: pid_t?, currentPID: pid_t?,
        releaseWindow: UInt32?, currentWindow: UInt32?,
        axWindowDiffers: Bool?
    ) -> Bool {
        if let releasePID, currentPID != releasePID { return true }
        if let releaseWindow, let currentWindow {
            return releaseWindow != currentWindow
        }
        return axWindowDiffers ?? false
    }

    /// Whether the focused element now shows `needle` as a new insertion.
    /// nil means it couldn't be proved (wait and retry, or fall back to the long
    /// delay). false means the readable value is not the dictation yet.
    ///
    /// A matching slice is not enough: the characters after the caret may already
    /// have been `needle`. The document length has to move by the insertion, and a
    /// selection that was already exactly `needle` is treated as unprovable because
    /// replacing it with itself doesn't change the value.
    public nonisolated static func insertionConfirmed(
        needle: String,
        slice: String?,
        characterCountBefore: Int?,
        characterCountAfter: Int?,
        selectionLength: Int,
        selectedText: String?
    ) -> Bool? {
        guard let slice else { return nil }
        guard slice == needle else { return false }
        if selectionLength > 0, let selectedText, selectedText == needle { return nil }
        // Same length as the needle but we never read the selection: the slice can
        // match either the old selection or the paste. Don't guess.
        if selectionLength > 0, selectedText == nil, selectionLength == needle.utf16.count {
            return nil
        }
        if let before = characterCountBefore {
            guard let after = characterCountAfter else { return nil }
            let expected = before - selectionLength + needle.utf16.count
            return after == expected
        }
        // No length. A fully read selection that was different text is still proof:
        // that range changing to the needle means the value changed.
        if selectionLength > 0, let selectedText, selectedText != needle { return true }
        return nil
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

    // MARK: - Which window

    /// Pid changed, or the same app's frontmost window changed. Unknown windows
    /// fail open so a flaky window list can't stop a paste that would have landed.
    private func focusLeft(_ target: PasteTarget) async -> Bool {
        let currentPID = frontmostProcessID()
        if Self.focusLeftTarget(releasePID: target.pid, currentPID: currentPID,
                                releaseWindow: nil, currentWindow: nil, axWindowDiffers: nil) {
            return true
        }
        guard let pid = target.pid, currentPID == pid else { return false }
        let currentWindow = frontmostWindowID(pid)
        if target.windowID != nil, currentWindow != nil {
            return Self.focusLeftTarget(releasePID: target.pid, currentPID: currentPID,
                                        releaseWindow: target.windowID, currentWindow: currentWindow,
                                        axWindowDiffers: nil)
        }
        // Numeric ids unavailable on at least one side. Compare focused windows
        // when both reads succeeded; otherwise keep the pid-only behavior.
        var axDiffers: Bool?
        if let release = await target.axWindow?.value,
           let current = Self.focusedWindow(pid: pid) {
            axDiffers = !CFEqual(release.element as CFType, current as CFType)
        }
        return Self.focusLeftTarget(releasePID: target.pid, currentPID: currentPID,
                                    releaseWindow: target.windowID, currentWindow: currentWindow,
                                    axWindowDiffers: axDiffers)
    }

    /// First on-screen, layer-0 window owned by `pid` in z-order. Nil when the
    /// list doesn't include that app (no window, or the ids aren't visible).
    private nonisolated static func systemFrontmostWindowID(pid: pid_t) -> UInt32? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard Self.intValue(info, kCGWindowOwnerPID) == Int(pid) else { continue }
            guard Self.intValue(info, kCGWindowLayer) ?? 0 == 0 else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? Double)
                ?? (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
                ?? 1
            guard alpha > 0 else { continue }
            if let number = Self.intValue(info, kCGWindowNumber),
               let id = UInt32(exactly: number), id != 0 {
                return id
            }
        }
        return nil
    }

    /// Window-list values arrive as Int or NSNumber depending on the bridge.
    private nonisolated static func intValue(_ info: [String: Any], _ key: CFString) -> Int? {
        let value = info[key as String]
        if let number = value as? Int { return number }
        if let number = value as? UInt32 { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// Time-boxed focused window of `pid`. Nil when Accessibility can't see one.
    private nonisolated static func focusedWindow(pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement) // safe: type ID checked above
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

    private static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
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

    /// Puts `snapshot` back after the target has had a chance to read the dictation.
    /// `changeCount` only moves when someone writes, so it cannot tell us the target
    /// read the pasteboard — only that we must not clobber a newer write.
    private func scheduleRestore(
        snapshot: [[NSPasteboard.PasteboardType: Data]],
        expectedChangeCount: Int,
        generation: Int,
        text: String,
        context: FocusedContext?
    ) {
        let pasteboard = self.pasteboard
        let fallback = restoreDelay
        let confirm = confirmInsertion
        let task = Task { @MainActor [weak self] in
            let start = DispatchTime.now().uptimeNanoseconds
            let fallbackNanos = UInt64(max(0, fallback) * 1_000_000_000)
            func elapsed() -> UInt64 { DispatchTime.now().uptimeNanoseconds &- start }
            // No focused element and no override: nothing to poll. One wait, then restore.
            let canWatch = confirm != nil || context != nil
            while true {
                guard let self, self.restoreGeneration == generation, !Task.isCancelled else { return }
                let soFar = elapsed()
                if soFar < fallbackNanos {
                    let remaining = fallbackNanos - soFar
                    let nap = canWatch ? min(Self.confirmPollNanos, remaining) : remaining
                    try? await Task.sleep(nanoseconds: max(nap, 1_000_000))
                }
                guard let self, self.restoreGeneration == generation, !Task.isCancelled else { return }
                if pasteboard.changeCount != expectedChangeCount {
                    if self.pendingRestore?.changeCount == expectedChangeCount { self.pendingRestore = nil }
                    return
                }
                var confirmed: Bool?
                if elapsed() < fallbackNanos {
                    if let confirm {
                        confirmed = confirm(text)
                    } else if let context {
                        let needle = text
                        confirmed = await Task.detached(priority: .userInitiated) {
                            Self.insertionVisible(in: context, text: needle)
                        }.value
                    }
                }
                guard let self, self.restoreGeneration == generation, !Task.isCancelled else { return }
                if pasteboard.changeCount != expectedChangeCount {
                    if self.pendingRestore?.changeCount == expectedChangeCount { self.pendingRestore = nil }
                    return
                }
                if confirmed == true || elapsed() >= fallbackNanos {
                    self.pendingRestore = nil
                    Self.restore(snapshot, to: pasteboard)
                    return
                }
            }
        }
        pendingRestore = (snapshot, expectedChangeCount, task)
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

        let selectionLength = max(0, range.length)
        var selectedText: String?
        if selectionLength > 0, selectionLength <= maxSelectedRead,
           let selected = stringForRange(element, location: range.location, length: selectionLength),
           selected.utf16.count == selectionLength {
            selectedText = selected
        }
        return FocusedContext(element: element, cursorLocation: range.location,
                              preceding: preceding, beforeText: beforeText,
                              selectionLength: selectionLength, characterCount: characterCount(element),
                              selectedText: selectedText)
    }

    /// true/false when the element can be read, nil when it can't (secure field,
    /// no value, timed out). A nil result keeps the clipboard until `restoreDelay`.
    private nonisolated static func insertionVisible(in context: FocusedContext, text: String) -> Bool? {
        let element = context.element
        AXUIElementSetMessagingTimeout(element, axTimeout)
        if isSecureField(element) { return nil }
        guard !text.isEmpty else { return true }
        let units = text.utf16.count
        let slice = stringForRange(element, location: context.cursorLocation, length: units)
            ?? wholeValue(element).flatMap {
                substring($0, utf16Location: context.cursorLocation, utf16Length: units)
            }
        return insertionConfirmed(
            needle: text, slice: slice,
            characterCountBefore: context.characterCount, characterCountAfter: characterCount(element),
            selectionLength: context.selectionLength, selectedText: context.selectedText)
    }

    private nonisolated static func isSecureField(_ element: AXUIElement) -> Bool {
        var subrole: AnyObject?
        return AXUIElementCopyAttributeValue(element, "AXSubrole" as CFString, &subrole) == .success
            && (subrole as? String) == "AXSecureTextField"
    }

    private nonisolated static func characterCount(_ element: AXUIElement) -> Int? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &value
        ) == .success else { return nil }
        return value as? Int
    }

    private nonisolated static func wholeValue(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private nonisolated static func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
        guard location >= 0, length > 0 else { return nil }
        var range = CFRange(location: location, length: length)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, param, &value
        ) == .success else { return nil }
        return value as? String
    }

    private nonisolated static func substring(_ string: String, utf16Location: Int, utf16Length: Int) -> String? {
        guard utf16Location >= 0, utf16Length >= 0 else { return nil }
        let utf16 = string.utf16
        guard let start = utf16.index(utf16.startIndex, offsetBy: utf16Location, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: utf16Length, limitedBy: utf16.endIndex),
              let lower = start.samePosition(in: string),
              let upper = end.samePosition(in: string) else { return nil }
        return String(string[lower..<upper])
    }
}
