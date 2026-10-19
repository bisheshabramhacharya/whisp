namespace Whisp.Core.Input;

public enum HotkeyEvent
{
    /// Begin recording (key pressed, or hands-free mode entered).
    Start,
    /// Finish recording and transcribe (key released, or hands-free mode ended).
    Stop,
    /// Abort without transcribing (Esc, or the key used as part of another shortcut).
    Cancel,
    /// A second short tap released into hands-free recording.
    HandsFree,
}

public enum HotkeyInput
{
    KeyDown,
    KeyUp,
    /// Any non-modifier key press.
    CharacterKey,
    /// A modifier press other than the monitored key.
    OtherKey,
    Escape,
}

/// <summary>
/// Pure state machine deciding which HotkeyEvent (if any) a stream of key transitions
/// produces. Port of Sources/WhispCore/Input/HotkeyStateMachine.swift — timestamps are
/// injected (monotonic seconds) so the whole thing is unit-testable.
///
///   - Key down alone                                  -> Start immediately.
///   - Key up after a hold >= HoldThreshold (0.25 s)   -> Stop.
///   - Key up after a hold <  HoldThreshold (a tap)    -> Cancel.
///   - A second press within DoubleTapWindow (0.4 s) of a tap release -> Start;
///     releasing that second press quickly stays recording — hands-free lock
///     (HandsFree). The next key press then ends hands-free: Stop, and its release
///     is swallowed.
///   - Another modifier pressed within ChordGrace (0.3 s) of a non-hands-free hold
///     start -> Cancel (the user is doing Alt+Ctrl+X, not dictating).
///   - A character key pressed within CharacterGrace (1 s) of a hold start -> Cancel:
///     an Alt+char chord. Later it's a stray key during a real dictation and is ignored.
///   - Esc while recording -> Cancel. Esc while not recording -> Cancel too; the
///     controller uses it to drop a dictation that is still transcribing.
/// </summary>
public sealed class HotkeyStateMachine
{
    private enum Mode { Idle, Holding, SecondHold, HandsFree, IgnoringRelease }

    private Mode _mode = Mode.Idle;
    private double _since;
    /// When the last tap (short hold) was released; drives the double-tap window.
    private double _lastTapRelease = double.NegativeInfinity;

    public double HoldThreshold { get; set; } = 0.25;
    public double DoubleTapWindow { get; set; } = 0.4;
    public double ChordGrace { get; set; } = 0.3;
    public double CharacterGrace { get; set; } = 1.0;

    /// Whether recording is conceptually active.
    public bool IsRecording => _mode is Mode.Holding or Mode.SecondHold or Mode.HandsFree;

    /// Whether the monitored key is physically held as part of a dictation.
    public bool IsHolding => _mode is Mode.Holding or Mode.SecondHold;

    /// Feed one input; returns the event to deliver (if any).
    public HotkeyEvent? Handle(HotkeyInput input, double now)
    {
        switch (_mode, input)
        {
            // Presses
            case (Mode.Idle, HotkeyInput.KeyDown):
                _mode = now - _lastTapRelease <= DoubleTapWindow ? Mode.SecondHold : Mode.Holding;
                _since = now;
                return HotkeyEvent.Start;

            case (Mode.HandsFree, HotkeyInput.KeyDown):
                // The "next press" that ends hands-free; its release is swallowed.
                _mode = Mode.IgnoringRelease;
                return HotkeyEvent.Stop;

            // Releases
            case (Mode.Holding, HotkeyInput.KeyUp):
                _mode = Mode.Idle;
                if (now - _since < HoldThreshold)
                {
                    _lastTapRelease = now;
                    return HotkeyEvent.Cancel;
                }
                return HotkeyEvent.Stop;

            case (Mode.SecondHold, HotkeyInput.KeyUp):
                if (now - _since < HoldThreshold)
                {
                    // Quick release of the second press: lock into hands-free.
                    _mode = Mode.HandsFree;
                    return HotkeyEvent.HandsFree;
                }
                _mode = Mode.Idle;
                return HotkeyEvent.Stop;

            case (Mode.IgnoringRelease, HotkeyInput.KeyUp):
                _mode = Mode.Idle;
                return null;

            // Other keys (Alt+X chord detection)
            case (Mode.Holding or Mode.SecondHold, HotkeyInput.CharacterKey):
                if (now - _since >= CharacterGrace) return null;
                _mode = Mode.Idle;
                return HotkeyEvent.Cancel;

            // A modifier press only cancels inside ChordGrace; later it's ignored
            // because the user is dictating.
            case (Mode.Holding or Mode.SecondHold, HotkeyInput.OtherKey):
                if (now - _since >= ChordGrace) return null;
                _mode = Mode.Idle;
                return HotkeyEvent.Cancel;

            // Escape — always aborts an active recording.
            case (Mode.Holding or Mode.SecondHold or Mode.HandsFree, HotkeyInput.Escape):
                _mode = Mode.Idle;
                return HotkeyEvent.Cancel;

            case (Mode.Idle or Mode.IgnoringRelease, HotkeyInput.Escape):
                return HotkeyEvent.Cancel;

            default:
                return null;
        }
    }
}
