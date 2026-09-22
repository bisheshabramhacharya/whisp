import ApplicationServices
import CoreGraphics
import Foundation

/// Global listener for a single modifier key (Right Option by default) via a
/// listen-only, session-level CGEventTap. All `HotkeyEvent`s are delivered on the
/// main thread; event interpretation lives in `HotkeyStateMachine` (pure, tested
/// separately) — this file is only plumbing:
///
///   flagsChanged(ourKeyCode)  -> .keyDown / .keyUp  (edge-detected via device-dependent
///                                                  flag bits, so left and right are
///                                                  distinguishable)
///   flagsChanged(other mods)  -> .otherKey          (only when a modifier bit is *newly* set)
///   keyDown(keyCode 53)       -> .escape
///   keyDown(anything else)    -> .otherKey
///
/// The tap is re-enabled automatically if the system disables it for timeout/user
/// input. `start()` throws `HotkeyError.permissionDenied` when the tap cannot be
/// created (Input Monitoring / Accessibility not granted).
public final class RightOptionHotkey: HotkeyMonitoring {

    public var onEvent: ((HotkeyEvent) -> Void)?

    private let keyCode: UInt16
    private var machine = HotkeyStateMachine()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // State below is touched only on the main thread.
    private var isOurKeyDown = false
    private var previousFlags: UInt64 = 0

    /// Union of every modifier bit in CGEventFlags — device-independent masks
    /// (maskShift…maskSecondaryFn) AND the per-side device bits (NX_DEVICE*KEYMASK).
    /// The device bits matter: pressing Left Option while Right Option is held does
    /// not set a *new* device-independent bit (maskAlternate is already set), but it
    /// does set NX_DEVICELALTKEYMASK — and that should still count as a chord.
    private static let allModifierBits: UInt64 =
        CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskControl.rawValue |
        CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskCommand.rawValue |
        CGEventFlags.maskSecondaryFn.rawValue |
        CGEventFlags.maskAlphaShift.rawValue |
        0x0001 | 0x0002 | 0x0004 | 0x0008 | 0x0010 | 0x0020 | 0x0040 | 0x0080 | 0x2000

    /// `keyCode` 61 = Right Option (default), 58 = Left Option, 54/55 = R/L Command,
    /// 62/59 = R/L Control, 56/60 = L/R Shift, 63 = Fn/Globe.
    public init(keyCode: UInt16 = 61) {
        self.keyCode = keyCode
    }

    deinit { stop() }

    // MARK: - HotkeyMonitoring

    public func start() throws {
        guard tap == nil else { return }

        // The tap can be *created* without Input Monitoring — it just never
        // delivers events, which would falsely report a running monitor. Gate on
        // the TCC state first; Accessibility alone suffices on older macOS.
        guard CGPreflightListenEventAccess() || AXIsProcessTrusted() else {
            throw HotkeyError.permissionDenied
        }

        let eventsOfInterest: CGEventMask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.keyDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventsOfInterest,
            callback: RightOptionHotkey.tapCallback,
            userInfo: userInfo
        ) else {
            // nil tap => TCC denied (Input Monitoring, or Accessibility on older macOS).
            throw HotkeyError.permissionDenied
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
        machine = HotkeyStateMachine()
        isOurKeyDown = false
        previousFlags = 0
    }

    // MARK: - Event plumbing

    /// Called on whatever thread the event tap uses; keep it minimal — re-arm the tap
    /// here (time-critical), then hop to main for the state machine.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<RightOptionHotkey>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged || type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let now = ProcessInfo.processInfo.systemUptime

        DispatchQueue.main.async {
            monitor.route(type: type, keyCode: keyCode, flags: flags, now: now)
        }
        return Unmanaged.passUnretained(event)
    }

    /// Runs on the main thread. Translates CGEvents into `HotkeyStateMachine.Input`s.
    private func route(type: CGEventType, keyCode eventKeyCode: UInt16,
                       flags: CGEventFlags, now: TimeInterval) {
        // Drop events that were dispatched before stop() but run after it — the
        // machine was reset, so a stale keyDown would otherwise emit a bogus .start.
        guard tap != nil else { return }
        switch type {
        case .flagsChanged:
            // Modifier bits that became set since the last flagsChanged — lets us
            // catch "other modifier pressed" regardless of which physical key it was.
            let newlyPressed = flags.rawValue & ~previousFlags & Self.allModifierBits
            previousFlags = flags.rawValue

            if eventKeyCode == keyCode {
                let pressed = Self.isPressed(flags: flags, keyCode: eventKeyCode,
                                           newlyPressed: newlyPressed)
                if pressed && !isOurKeyDown {
                    isOurKeyDown = true
                    emit(machine.handle(.keyDown, now: now))
                } else if !pressed && isOurKeyDown {
                    isOurKeyDown = false
                    emit(machine.handle(.keyUp, now: now))
                }
            } else if newlyPressed != 0 {
                emit(machine.handle(.otherKey, now: now))
            }

        case .keyDown:
            if eventKeyCode == 53 { // kVK_Escape
                emit(machine.handle(.escape, now: now))
            } else {
                emit(machine.handle(.otherKey, now: now))
            }

        default:
            break
        }
    }

    private func emit(_ event: HotkeyEvent?) {
        guard let event else { return }
        onEvent?(event)
    }

    // MARK: - Press/release detection for the monitored key

    /// Device-dependent flag bit for a specific physical modifier key — this is how
    /// we tell Right Option (0x40) from Left Option (0x20), etc.
    /// Values are the NX_DEVICExxxKEYMASK bits from <IOKit/hidsystem/IOLLEvent.h>,
    /// which appear verbatim in `CGEventFlags.rawValue` for flagsChanged events.
    private static func deviceBit(for keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 61: return 0x0040 // NX_DEVICERALTKEYMASK   (Right Option)
        case 58: return 0x0020 // NX_DEVICERLALTKEYMASK  (Left Option)
        case 54: return 0x0010 // NX_DEVICERCMDKEYMASK   (Right Command)
        case 55: return 0x0008 // NX_DEVICERLCMDKEYMASK  (Left Command)
        case 62: return 0x2000 // NX_DEVICERCTLKEYMASK   (Right Control)
        case 59: return 0x0001 // NX_DEVICERLCTLKEYMASK  (Left Control)
        case 60: return 0x0004 // NX_DEVICERSHIFTKEYMASK (Right Shift)
        case 56: return 0x0002 // NX_DEVICERLSHIFTKEYMASK(Left Shift)
        default: return nil
        }
    }

    /// Device-independent mask for keys without a per-side bit (Fn/Globe) or as a
    /// fallback for unusual keyCodes.
    private static func genericMask(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 61, 58: return .maskAlternate
        case 54, 55: return .maskCommand
        case 62, 59: return .maskControl
        case 60, 56: return .maskShift
        case 63:     return .maskSecondaryFn
        default:     return nil
        }
    }

    private static func isPressed(flags: CGEventFlags, keyCode: UInt16,
                                  newlyPressed: UInt64) -> Bool {
        if let bit = deviceBit(for: keyCode) {
            return flags.rawValue & bit != 0
        }
        if let mask = genericMask(for: keyCode) {
            return flags.contains(mask)
        }
        // Unknown modifier keyCode: a flagsChanged that *set* bits is a press.
        return newlyPressed != 0
    }
}
