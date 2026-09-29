import Foundation

/// Resolves the hidden `asrEngine` setting to a concrete `Transcribing` engine.
///
/// New engines: add one `case` here (name = the `defaults write` value) and keep
/// the default first. Engines are experimental A/B backends — "parakeet" is the
/// shipping engine and must stay the fallback for unknown names so a typo can
/// never silence dictation.
public enum ASREngine {
    /// Engine used when `asrEngine` is unset or unrecognized: today's engine.
    public static let defaultName = "parakeet"

    /// Every name `make(named:)` accepts. Kept in sync with the switch.
    public static let knownNames: [String] = ["parakeet", "short", "streaming", "par2", "fast", "fastall"]

    public static func isKnown(_ name: String) -> Bool {
        knownNames.contains(name)
    }

    /// Build the engine for `name`. Unknown names must not reach here —
    /// `AppSettings` already falls back to `defaultName`; this keeps the same
    /// contract for direct callers (whisp-bench `--compare`).
    public static func make(named name: String) -> Transcribing {
        switch name {
        case "parakeet":
            return ParakeetTranscriber()
        case "short":
            return ShortWindowEngine()
        case "streaming":
            return StreamingEngine()
        // "par2": second decode lane for mid-chunk releases (waits max(rem,tail)
        // instead of rem+tail). Costs ~600 MB for the extra model set — opt-in.
        case "par2":
            return ParakeetTranscriber(model: .unified, unifiedLanes: 2)
        // "fast"/"fastall": one wide-joint call per emitted token instead of the
        // ~120-step joint loop; byte-identical output. Hypothesis is ANE wins.
        case "fast":
            return FastRnnt(jointComputeUnits: .cpuOnly)
        case "fastall":
            return FastRnnt(jointComputeUnits: .all)
        default:
            return ParakeetTranscriber()
        }
    }
}
