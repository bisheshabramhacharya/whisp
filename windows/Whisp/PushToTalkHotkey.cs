using System.Diagnostics;
using System.Runtime.InteropServices;
using Whisp.Core.Input;

namespace Whisp;

/// <summary>
/// Global push-to-talk key via low-level keyboard and mouse hooks (the Windows
/// counterpart of the Mac's RightOptionHotkey event tap). Key transitions feed the shared
/// HotkeyStateMachine; events are raised on the UI thread that installed the hooks.
///
/// The key can be any keyboard key but Esc, or the middle or a side mouse button.
/// A modifier key (Alt, Ctrl, Shift, Windows) is never swallowed, so Right Alt keeps
/// working in shortcuts, and other keys pressed with it feed the chord detection. Any
/// other key or mouse button is swallowed while it's the push-to-talk key, so F13 or a
/// middle click doesn't also do its usual thing; then only Esc reaches the state machine.
///
/// Esc while the key is held for a dictation cancels, and is swallowed: passing it on would
/// make it Alt+Esc (send the window to the back) or Ctrl+Esc (open Start). Holding Alt or
/// Windows alone would normally open the focused app's menu bar (or Start) on release;
/// while dictating with one, Whisp taps an unassigned key (the trick AutoHotkey calls the
/// menu mask key) so the release is just a release.
/// </summary>
internal sealed class PushToTalkHotkey : IDisposable
{
    private readonly HotkeyStateMachine _machine = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    // Held so the GC can't collect the delegates while Windows still calls them.
    private readonly Native.LowLevelKeyboardProc _keyboardProc;
    private readonly Native.LowLevelKeyboardProc _mouseProc;
    private IntPtr _keyboardHook;
    private IntPtr _mouseHook;
    private SynchronizationContext? _context;
    private HotkeyBinding _key = HotkeyBinding.RightAlt;
    private bool _keyIsDown;
    private bool _swallowEscapeUp;
    private Action<HotkeyBinding>? _capture;

    public HotkeyBinding Key
    {
        get => _key;
        set
        {
            if (_key == value) return;
            _key = value;
            _keyIsDown = false;
        }
    }

    /// Raised on the UI thread.
    public event Action<HotkeyEvent>? Event;

    public bool IsRunning => _keyboardHook != IntPtr.Zero;

    public PushToTalkHotkey()
    {
        _keyboardProc = KeyboardProc;
        _mouseProc = MouseProc;
    }

    public void Start()
    {
        if (_keyboardHook != IntPtr.Zero) return;
        _context = SynchronizationContext.Current;
        var module = Native.GetModuleHandle(null);
        _keyboardHook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _keyboardProc, module, 0);
        if (_keyboardHook == IntPtr.Zero)
            throw new InvalidOperationException($"SetWindowsHookEx failed ({Marshal.GetLastWin32Error()})");
        _mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, _mouseProc, module, 0);
        if (_mouseHook == IntPtr.Zero)
            Log.Write($"mouse hook failed ({Marshal.GetLastWin32Error()}); mouse buttons can't be the push-to-talk key");
    }

    public void Stop()
    {
        if (_keyboardHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_keyboardHook);
        if (_mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_mouseHook);
        _keyboardHook = _mouseHook = IntPtr.Zero;
        _keyIsDown = false;
    }

    public void Dispose() => Stop();

    /// The next key or mouse button pressed (except Esc, left and right click) goes to
    /// <paramref name="picked"/> on the UI thread instead of dictating, and is swallowed.
    public void CaptureNext(Action<HotkeyBinding> picked) => _capture = picked;

    public void CancelCapture() => _capture = null;

    private IntPtr KeyboardProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var info = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
            if (info.dwExtraInfo != Native.InjectedMarker)
            {
                var msg = (int)wParam;
                var down = msg is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN;
                var up = msg is Native.WM_KEYUP or Native.WM_SYSKEYUP;
                var vk = (int)info.vkCode;
                // AltGr layouts send a phantom Left Ctrl (scan code 0x21D) with Right Alt.
                var phantom = vk == Native.VK_LCONTROL && info.scanCode == 0x21D;
                if (_capture != null && !phantom && vk != Native.VK_ESCAPE)
                {
                    if (down) Picked(HotkeyBinding.Key(vk));
                    return 1;
                }
                var swallow = false;
                if (vk == Native.VK_ESCAPE)
                {
                    // Auto-repeat downs of a swallowed Esc are swallowed too.
                    if (down && (_swallowEscapeUp || (_keyIsDown && _machine.IsHolding)))
                    {
                        swallow = true;
                        _swallowEscapeUp = true;
                    }
                    else if (up && _swallowEscapeUp)
                    {
                        _swallowEscapeUp = false;
                        return 1;
                    }
                }
                if (!phantom)
                {
                    var isKey = !_key.IsMouse && vk == _key.Code;
                    if (isKey)
                        Transition(down, up);
                    else if (down)
                        OtherKey(vk);
                    // A non-modifier push-to-talk key (and its auto-repeat) never reaches apps.
                    if (isKey && !_key.IsModifier) swallow = true;
                }
                if (swallow) return 1;
            }
        }
        return Native.CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
    }

    private IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var msg = (int)wParam;
            HotkeyMouseButton? button = null;
            if (msg is Native.WM_MBUTTONDOWN or Native.WM_MBUTTONUP or Native.WM_MBUTTONDBLCLK)
            {
                button = HotkeyMouseButton.Middle;
            }
            else if (msg is Native.WM_XBUTTONDOWN or Native.WM_XBUTTONUP or Native.WM_XBUTTONDBLCLK)
            {
                var info = Marshal.PtrToStructure<Native.MSLLHOOKSTRUCT>(lParam);
                button = (info.mouseData >> 16) == Native.XBUTTON2 ? HotkeyMouseButton.Forward : HotkeyMouseButton.Back;
            }
            if (button is HotkeyMouseButton b)
            {
                var down = msg is Native.WM_MBUTTONDOWN or Native.WM_XBUTTONDOWN or Native.WM_MBUTTONDBLCLK or Native.WM_XBUTTONDBLCLK;
                var binding = HotkeyBinding.Mouse(b);
                if (_capture != null)
                {
                    if (down) Picked(binding);
                    return 1;
                }
                if (binding == _key)
                {
                    Transition(down, !down);
                    return 1;
                }
            }
        }
        return Native.CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    private void Picked(HotkeyBinding binding)
    {
        var picked = _capture;
        _capture = null;
        _context?.Post(_ => picked?.Invoke(binding), null);
    }

    private void Transition(bool down, bool up)
    {
        if (down && !_keyIsDown)
        {
            _keyIsDown = true;
            Feed(HotkeyInput.KeyDown);
        }
        else if (up && _keyIsDown)
        {
            _keyIsDown = false;
            Feed(HotkeyInput.KeyUp);
        }
        // Auto-repeat downs while held are ignored.
    }

    private void OtherKey(int vk)
    {
        if (vk == Native.VK_ESCAPE)
            Feed(HotkeyInput.Escape);
        // Chord detection only makes sense for a modifier: nobody presses F13+C as a shortcut.
        else if (_key.IsModifier)
            Feed(HotkeyBinding.IsModifierVk(vk) ? HotkeyInput.OtherKey : HotkeyInput.CharacterKey);
    }

    private void Feed(HotkeyInput input)
    {
        var evt = _machine.Handle(input, _clock.Elapsed.TotalSeconds);
        // Work happens after the hook returns: Windows drops hooks that answer slowly.
        var context = _context;
        if (input == HotkeyInput.KeyDown && _key.MasksRelease)
        {
            // Mask the Alt / Windows release so the focused app doesn't open its menu bar or Start.
            context?.Post(_ => MaskAltRelease(), null);
        }
        if (evt is HotkeyEvent e) context?.Post(_ => Event?.Invoke(e), null);
    }

    private static void MaskAltRelease()
    {
        Native.Send(Native.Key(Native.VK_MENU_MASK, up: false), Native.Key(Native.VK_MENU_MASK, up: true));
    }
}
