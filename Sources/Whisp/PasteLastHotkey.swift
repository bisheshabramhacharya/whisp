import CoreGraphics
import OSLog
import WhispCore

/// Global Cmd+Shift+V: pastes the last dictation at the cursor, so a dictation
/// that landed nowhere (no text field focused) can be recovered in one keystroke.
/// An active session event tap (same permissions as the dictation hotkey) swallows
/// the chord before the frontmost app sees it.
@MainActor
final class PasteLastHotkey {
    private let controller: DictationController
    private let history: HistoryStore
    private let paster: Paster
    private var tap: CFMachPort?
    private let logger = Logger(subsystem: "com.bishesha.whisp", category: "PasteLast")

    init(controller: DictationController, history: HistoryStore, paster: Paster) {
        self.controller = controller
        self.history = history
        self.paster = paster
    }

    /// Safe to call repeatedly; retried until Input Monitoring/Accessibility are granted.
    func start() {
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

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        let me = Unmanaged<PasteLastHotkey>.fromOpaque(userInfo!).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard event.getIntegerValueField(.keyboardEventKeycode) == 9, // kVK_ANSI_V
              flags == [.maskCommand, .maskShift] else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { MainActor.assumeIsolated { me.pasteLast() } }
        }
        return nil // swallow both down and up
    }

    private func pasteLast() {
        guard let text = controller.lastResult?.cleaned ?? history.loadLast(1).first?.cleaned else { return }
        logger.log("paste last (\(text.count) chars)")
        let target = paster.target()
        Task { _ = await paster.paste(text, into: target) }
    }
}
