import Foundation
import Combine
import ServiceManagement
import os

/// UserDefaults-backed settings. `launchAtLogin` additionally drives SMAppService.
@MainActor
public final class AppSettings: ObservableObject {

    private enum Key {
        static let sounds = "sounds"
        static let autoMute = "autoMute"
        static let keepRecordings = "keepRecordings"
        static let launchAtLoginDesired = "launchAtLoginDesired"
        static let hotkeyKeyCode = "hotkeyKeyCode"
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.bishesha.whisp", category: "Settings")

    @Published public var sounds: Bool {
        didSet { defaults.set(sounds, forKey: Key.sounds) }
    }

    /// Duck system audio while recording.
    @Published public var autoMute: Bool {
        didSet { defaults.set(autoMute, forKey: Key.autoMute) }
    }

    /// Keep WAVs of past dictations (newest 200) next to history.jsonl.
    @Published public var keepRecordings: Bool {
        didSet { defaults.set(keepRecordings, forKey: Key.keepRecordings) }
    }

    /// Carbon/virtual key code for the push-to-talk key. Default 61 = Right Option.
    @Published public var hotkeyKeyCode: Int {
        didSet { defaults.set(hotkeyKeyCode, forKey: Key.hotkeyKeyCode) }
    }

    /// SMAppService-backed login item. Reads actual registration status when the
    /// app is bundled; falls back to the stored intent when running as a bare
    /// SwiftPM executable (SMAppService.mainApp requires a .app bundle).
    public var launchAtLogin: Bool {
        get {
            if Self.isBundledApp {
                return SMAppService.mainApp.status == .enabled
            }
            return defaults.bool(forKey: Key.launchAtLoginDesired)
        }
        set {
            defaults.set(newValue, forKey: Key.launchAtLoginDesired)
            guard Self.isBundledApp else { return }
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                logger.error("SMAppService \(newValue ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
            }
            objectWillChange.send()
        }
    }

    /// True when running from inside a .app bundle (SMAppService needs one).
    public static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.sounds: true,
            Key.autoMute: true,
            Key.keepRecordings: true,
            Key.launchAtLoginDesired: false,
            Key.hotkeyKeyCode: 61, // Right Option
        ])
        self.sounds = defaults.bool(forKey: Key.sounds)
        self.autoMute = defaults.bool(forKey: Key.autoMute)
        self.keepRecordings = defaults.bool(forKey: Key.keepRecordings)
        self.hotkeyKeyCode = defaults.integer(forKey: Key.hotkeyKeyCode)
    }
}
