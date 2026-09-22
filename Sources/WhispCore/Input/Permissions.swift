import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

/// TCC permission helpers for everything Whisp needs:
/// microphone (audio capture), Accessibility (paste via simulated Cmd+V + AX reads),
/// and Input Monitoring (the listen-only CGEvent tap).
public enum Permissions {

    /// System Settings panes we can deep-link to.
    public enum Pane {
        case microphone
        case accessibility
        case inputMonitoring

        var url: URL {
            let anchor: String
            switch self {
            case .microphone:      anchor = "Privacy_Microphone"
            case .accessibility:   anchor = "Privacy_Accessibility"
            case .inputMonitoring: anchor = "Privacy_ListenEvent"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    // MARK: - Microphone

    public static var microphoneGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Triggers the system prompt on first call; resolves with the user's choice.
    /// Returns immediately (no prompt) when permission was already decided.
    public static func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied:  return false
        default:       return await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: - Accessibility (paste events + focused-element reads)

    public static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Same check, but also shows the system "grant accessibility" prompt.
    /// Returns the current trust state; the grant itself is asynchronous
    /// (the user has to toggle it in Settings).
    @discardableResult
    public static func promptAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Input Monitoring (listen-only event tap)

    public static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Triggers the system prompt for Input Monitoring; returns the current state.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    // MARK: - Settings deep-links

    public static func openSettings(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}
