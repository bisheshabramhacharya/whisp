import Combine
import CoreGraphics
import Foundation
import os
import OSLog

/// Global Cmd+Shift+V: pastes the last dictation at the cursor, so a dictation
/// that landed nowhere (no text field focused) can be recovered in one keystroke.
/// An active session event tap (same permissions as the dictation hotkey) swallows
/// the chord before the frontmost app sees it — but only once a dictation exists.
/// With an empty history the chord keeps its normal meaning (e.g. paste-and-match
/// in other apps).
@MainActor
public final class PasteLastHotkey {
    private let controller: DictationController
    private let history: HistoryStore
    private let paster: Paster
    private var tap: CFMachPort?
    private var cancellable: AnyCancellable?
    private let logger = Logger(subsystem: "com.bishesha.whisp", category: "PasteLast")

    /// Written on the main actor (init, sink, pasteLast); read on the tap thread.
    private let _hasLastDictation = OSAllocatedUnfairLock(initialState: false)

    /// Whether ⌘⇧V currently has a dictation to offer. Read on the tap thread.
    public nonisolated var hasLastDictation: Bool {
        _hasLastDictation.withLock { $0 }
    }

    private nonisolated func setHasLastDictation(_ value: Bool) {
        _hasLastDictation.withLock { $0 = value }
    }

    public init(controller: DictationController, history: HistoryStore, paster: Paster) {
        self.controller = controller
        self.history = history
        self.paster = paster
        setHasLastDictation(controller.lastResult != nil || history.loadLast(1).first != nil)
        cancellable = controller.$lastResult
            .sink { [weak self] last in
                if last != nil { self?.setHasLastDictation(true) }
            }
    }

    /// Safe to call repeatedly; retried until Input Monitoring/Accessibility are granted.
    public func start() {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("paste-last tap not created (permissions)")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// The ⌘⇧V chord itself: V with exactly Command+Shift held, no other modifier.
    public nonisolated static func isChord(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let mods = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        return keyCode == 9 && mods == [.maskCommand, .maskShift] // kVK_ANSI_V
    }

    /// Whether an event is swallowed: only the exact chord, and only while Whisp
    /// has a previous dictation to offer — otherwise the keystroke goes to the
    /// frontmost app unchanged.
    public nonisolated func shouldConsume(keyCode: Int64, flags: CGEventFlags) -> Bool {
        Self.isChord(keyCode: keyCode, flags: flags) && hasLastDictation
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        let me = Unmanaged<PasteLastHotkey>.fromOpaque(userInfo!).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            return Unmanaged.passUnretained(event)
        }
        guard me.shouldConsume(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                               flags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { MainActor.assumeIsolated { me.pasteLast() } }
        }
        return nil // swallow both down and up
    }

    private func pasteLast() {
        guard let text = controller.lastResult?.cleaned ?? history.loadLast(1).first?.cleaned else { return }
        setHasLastDictation(true)
        logger.log("paste last (\(text.count) chars)")
        let target = paster.target()
        Task { _ = await paster.paste(text, into: target) }
    }
}
