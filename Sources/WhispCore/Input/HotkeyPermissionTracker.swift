import Foundation

/// Decides what an observed TCC permission state should do to the dictation
/// hotkey. Pure value type — the app feeds it the current grant/running state
/// on each activation event and performs the returned action. This replaces an
/// unconditional 5 s poll with identical semantics and zero idle wakeups.
public struct HotkeyPermissionTracker {

    public enum Action: Equatable, Sendable {
        /// Nothing changed — do nothing.
        case none
        /// Grants were lost while the hotkey was live: stop it.
        case stopHotkey
        /// Grants returned after we stopped the hotkey: start it again.
        case startHotkey
    }

    /// Whether we already told the app to stop the hotkey for a lost grant.
    public private(set) var stoppedForPermission = false

    public init() {}

    /// Feed the current state; returns what to do about the hotkey.
    public mutating func check(hotkeyPermissionsGranted: Bool,
                               hotkeyRunning: Bool) -> Action {
        if hotkeyPermissionsGranted {
            defer { stoppedForPermission = false }
            return stoppedForPermission ? .startHotkey : .none
        }
        if hotkeyRunning {
            stoppedForPermission = true
            return .stopHotkey
        }
        return .none
    }
}
