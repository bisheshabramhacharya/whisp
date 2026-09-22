import Foundation

/// Pure state machine deciding which `HotkeyEvent` (if any) a stream of key
/// transitions produces. No CGEvent/AppKit dependencies — timestamps are injected
/// (monotonic seconds) so the whole thing is unit-testable.
///
/// Semantics (Willow behaviour + hands-free improvement):
///
///   - Key down alone                       -> `.start` immediately.
///   - Key up after a hold >= `holdThreshold`          (0.25 s) -> `.stop`.
///   - Key up after a hold <  `holdThreshold` (a tap)           -> `.cancel`.
///   - A second press within `doubleTapWindow` (0.4 s) of a tap release -> `.start`;
///     releasing that second press quickly stays recording — hands-free lock
///     (no event). The next key press then ends hands-free: `.stop`, and its
///     release is swallowed.
///   - Another key/modifier pressed within `chordGrace` (0.3 s) of a non-hands-free
///     hold start -> `.cancel` (the user is doing Option+X, not dictating).
///     After the grace window other keys are ignored.
///   - Esc while recording (hold, second hold, or hands-free)   -> `.cancel`.
public struct HotkeyStateMachine {

    /// Inputs the plumbing layer extracts from CGEvents. "Key" always refers to the
    /// monitored key (e.g. Right Option); `otherKey` is any *press* of anything else.
    public enum Input: Sendable {
        case keyDown
        case keyUp
        case otherKey
        case escape
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Recording; key is physically held. `since` = press timestamp.
        case holding(since: TimeInterval)
        /// Recording; second press within the double-tap window, still held.
        case secondHold(since: TimeInterval)
        /// Recording locked on after the double-tap; key is physically up.
        case handsFree
        /// handsFree was ended by a key press (we emitted `.stop`); swallow that press's release.
        case ignoringRelease
    }

    public private(set) var state: State = .idle

    /// Whether recording is conceptually active (for UI state, tests, etc.).
    public var isRecording: Bool {
        switch state {
        case .holding, .secondHold, .handsFree: return true
        case .idle, .ignoringRelease: return false
        }
    }

    // Tunables (public so tests/UIs can inspect or adjust).
    public var holdThreshold: TimeInterval
    public var doubleTapWindow: TimeInterval
    public var chordGrace: TimeInterval

    /// When the last *tap* (short hold) was released; drives the double-tap window.
    private var lastTapRelease: TimeInterval = -.greatestFiniteMagnitude

    public init(holdThreshold: TimeInterval = 0.25,
                doubleTapWindow: TimeInterval = 0.4,
                chordGrace: TimeInterval = 0.3) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
        self.chordGrace = chordGrace
    }

    /// Feed one input; returns the event to deliver (if any).
    @discardableResult
    public mutating func handle(_ input: Input, now: TimeInterval) -> HotkeyEvent? {
        switch (state, input) {

        // MARK: Presses
        case (.idle, .keyDown):
            if now - lastTapRelease <= doubleTapWindow {
                state = .secondHold(since: now)
            } else {
                state = .holding(since: now)
            }
            return .start

        case (.handsFree, .keyDown):
            // The "next press" that ends hands-free; its release is swallowed.
            state = .ignoringRelease
            return .stop

        // MARK: Releases
        case (.holding(let since), .keyUp):
            state = .idle
            if now - since < holdThreshold {
                lastTapRelease = now
                return .cancel
            }
            return .stop

        case (.secondHold(let since), .keyUp):
            if now - since < holdThreshold {
                // Quick release of the second press: lock into hands-free.
                state = .handsFree
                return nil
            }
            state = .idle
            return .stop

        case (.ignoringRelease, .keyUp):
            state = .idle
            return nil

        // MARK: Other keys (Option+X chord detection)
        case (.holding(let since), .otherKey), (.secondHold(let since), .otherKey):
            guard now - since < chordGrace else { return nil }
            state = .idle
            return .cancel

        // MARK: Escape — always aborts an active recording.
        case (.holding, .escape), (.secondHold, .escape), (.handsFree, .escape):
            state = .idle
            return .cancel

        default:
            return nil
        }
    }
}
