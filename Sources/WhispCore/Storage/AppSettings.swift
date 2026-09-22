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
        static let pillScale = "pillScale"
        static let pillOrigin = "pillOrigin"
        static let alwaysShowPill = "alwaysShowPill"
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

    /// Keep WAVs of every dictation next to history.jsonl (fine-tuning data).
    @Published public var keepRecordings: Bool {
        didSet { defaults.set(keepRecordings, forKey: Key.keepRecordings) }
    }

    /// Carbon/virtual key code for the push-to-talk key. Default 61 = Right Option.
    @Published public var hotkeyKeyCode: Int {
        didSet { defaults.set(hotkeyKeyCode, forKey: Key.hotkeyKeyCode) }
    }

    /// Recording pill size multiplier (1.0 = 200×52 pt).
    @Published public var pillScale: Double {
        didSet { defaults.set(pillScale, forKey: Key.pillScale) }
    }

    /// Where the user dragged the pill (bottom-left, global screen coords);
    /// nil = bottom-center of the screen with the mouse.
    @Published public var pillOrigin: CGPoint? {
        didSet {
            if let pillOrigin {
                defaults.set([pillOrigin.x, pillOrigin.y], forKey: Key.pillOrigin)
            } else {
                defaults.removeObject(forKey: Key.pillOrigin)
            }
        }
    }

    /// Keep a dimmed pill on screen while idle (so it can be dragged anytime).
    @Published public var alwaysShowPill: Bool {
        didSet { defaults.set(alwaysShowPill, forKey: Key.alwaysShowPill) }
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
            Key.pillScale: 0.75,
            Key.alwaysShowPill: false,
        ])
        self.sounds = defaults.bool(forKey: Key.sounds)
        self.autoMute = defaults.bool(forKey: Key.autoMute)
        self.keepRecordings = defaults.bool(forKey: Key.keepRecordings)
        self.hotkeyKeyCode = defaults.integer(forKey: Key.hotkeyKeyCode)
        self.pillScale = defaults.double(forKey: Key.pillScale)
        self.alwaysShowPill = defaults.bool(forKey: Key.alwaysShowPill)
        if let xy = defaults.array(forKey: Key.pillOrigin) as? [Double], xy.count == 2 {
            self.pillOrigin = CGPoint(x: xy[0], y: xy[1])
        } else {
            self.pillOrigin = nil
        }
    }
}
