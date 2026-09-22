import AppKit
import Foundation

/// Subtle audio feedback for dictation lifecycle events, using preloaded NSSounds
/// from /System/Library/Sounds. All play functions are non-blocking (NSSound.play()
/// returns immediately) and are no-ops when `enabled` is false.
public enum Sounds {

    /// Master switch — the UI/settings layer can flip this at any time.
    public static var enabled = true

    private enum Kind: CaseIterable {
        case start, stop, cancel, error

        /// Quiet, low-latency choices (willow-style "tick" feedback, not alarms).
        /// Names resolve via NSSound(named:), which searches /System/Library/Sounds.
        var soundName: String {
            switch self {
            case .start:  return "Tink"
            case .stop:   return "Pop"
            case .cancel: return "Bottle"
            case .error:  return "Basso"
            }
        }

        var volume: Float {
            switch self {
            case .start, .stop: return 0.45
            case .cancel: return 0.35
            case .error:  return 0.5
            }
        }
    }

    /// Eagerly built on first access (any play* call or `preload()`), so the first
    /// audible event does not hit the disk.
    private static let library: [Kind: NSSound] = {
        var sounds: [Kind: NSSound] = [:]
        for kind in Kind.allCases {
            // NSSound(named:) searches ~/Library/Sounds, /Library/Sounds and
            // /System/Library/Sounds; fall back to the explicit system path.
            let sound = NSSound(named: NSSound.Name(kind.soundName))
                ?? NSSound(contentsOfFile: "/System/Library/Sounds/\(kind.soundName).aiff",
                           byReference: false)
            guard let sound else { continue }
            sound.volume = kind.volume
            sounds[kind] = sound
        }
        return sounds
    }()

    /// Optional: call once at app launch so the first `playStart()` is disk-warm.
    public static func preload() {
        _ = library
    }

    public static func playStart()  { play(.start) }
    public static func playStop()   { play(.stop) }
    public static func playCancel() { play(.cancel) }
    public static func playError()  { play(.error) }

    private static func play(_ kind: Kind) {
        guard enabled, let sound = library[kind] else { return }
        if sound.isPlaying { sound.stop() } // retrigger cleanly on rapid presses
        sound.play()
    }
}
