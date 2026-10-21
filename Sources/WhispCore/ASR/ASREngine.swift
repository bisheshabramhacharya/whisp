import Foundation

/// Resolves the hidden `asrEngine` setting to a concrete `Transcribing` engine.
///
/// New engines: add one `case` here (name = the `defaults write` value) and keep
/// the default first. Unknown names fall back to the default so a typo can
/// never silence dictation.
public enum ASREngine {
    /// Engine used when `asrEngine` is unset or unrecognized. On 433 of the
    /// owner's recordings it gave text identical to "parakeet" and halved the
    /// decode of clips under 5 s (98.9 -> 48.6 ms p50 on an 8 GB M1).
    public static let defaultName = "short"

    /// Every name `make(named:)` accepts. Kept in sync with the switch.
    public static let knownNames: [String] = ["short", "split", "parakeet", "streaming", "par2"]

    public static func isKnown(_ name: String) -> Bool {
        knownNames.contains(name)
    }

    /// Build the engine for `name`. Unknown names must not reach here —
    /// `AppSettings` already falls back to `defaultName`; this keeps the same
    /// contract for direct callers (whisp-bench `--compare`).
    public static func make(named name: String) -> Transcribing {
        switch name {
        // FluidAudio's own offline manager: always a 15 s encoder window.
        case "parakeet":
            return ParakeetTranscriber()
        // Streaming decode during capture. Opt-in: it drops or mishears the
        // last word in ~5% of releases (vs ~1% offline).
        case "streaming":
            return StreamingEngine()
        // "split": leftovers past the largest short encoder window decode as
        // <=5 s pieces on it instead of one 15 s pass. Opt-in; identical to
        // "short" until a short-window bundle is installed.
        case "split":
            return ShortWindowEngine(piecewise: true)
        // "par2": second decode lane for mid-chunk releases (waits max(rem,tail)
        // instead of rem+tail). Costs ~600 MB for the extra model set — opt-in.
        case "par2":
            return ParakeetTranscriber(model: .unified, unifiedLanes: 2)
        default:
            return ShortWindowEngine()
        }
    }
}
