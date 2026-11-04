import Foundation

/// Push-to-talk safety net: macOS occasionally drops the flagsChanged release
/// of a held modifier (sleep mid-hold, tap hiccups, focus grabs), which leaves
/// Whisp recording forever. While a hold is armed, the physical key state is
/// polled every `interval` (~250 ms); a physically-up key while logically held
/// means the key-up was missed, so `onMissedRelease` fires once. Never armed
/// in hands-free — the arming decision is the caller's, driven off
/// `HotkeyStateMachine.keyExpectedDown`.
///
/// Main-thread only (it is driven from the hotkey's main-thread event routing
/// and polls via a main-runloop Timer).
public final class KeyUpWatchdog {

    /// Physical "is the monitored key down right now" — injectable for tests.
    public var isKeyDown: () -> Bool
    /// Seconds between polls while armed.
    public var interval: TimeInterval
    /// Fires once when a missed key-up is detected; the watchdog then disarms.
    public var onMissedRelease: (() -> Void)?

    private var timer: Timer?
    public private(set) var armed = false

    public init(isKeyDown: @escaping () -> Bool, interval: TimeInterval = 0.25) {
        self.isKeyDown = isKeyDown
        self.interval = interval
    }

    deinit { disarm() }

    /// A hold state started — begin polling. Safe to call again while armed.
    /// Catches a key-up lost before the first tick at once.
    public func arm() {
        guard !armed else { return }
        armed = true
        checkNow()
        guard armed else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
    }

    /// The hold ended for any reason (release, cancel, reset, stop).
    public func disarm() {
        armed = false
        timer?.invalidate()
        timer = nil
    }

    /// One poll — also the test hook.
    public func checkNow() {
        guard armed, !isKeyDown() else { return }
        disarm()
        onMissedRelease?()
    }
}
