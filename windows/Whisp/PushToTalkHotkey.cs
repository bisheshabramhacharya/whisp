using System.Diagnostics;
using System.Runtime.InteropServices;
using Whisp.Core;
using Whisp.Core.Input;

namespace Whisp;

/// <summary>
/// Global push-to-talk key via a low-level keyboard hook (the Windows counterpart of the
/// Mac's RightOptionHotkey event tap). Key transitions feed the shared
/// HotkeyStateMachine; events are raised on the UI thread that installed the hook.
///
/// Keys are never swallowed, so Right Alt keeps working in shortcuts — except Esc while
/// the key is held for a dictation: it cancels, and passing it on would make it Alt+Esc
/// (send the window to the back) or Ctrl+Esc (open Start). Holding Alt alone
/// would normally open the focused app's menu bar on release; while dictating with
/// Right Alt, Whisp taps an unassigned key (the trick AutoHotkey calls the menu mask
/// key) so the release is just a release.
/// </summary>
internal sealed class PushToTalkHotkey : IDisposable
{
    private readonly HotkeyStateMachine _machine = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    // Held so the GC can't collect the delegate while Windows still calls it.
    private readonly Native.LowLevelKeyboardProc _proc;
    private IntPtr _hook;
    private SynchronizationContext? _context;
    private bool _keyIsDown;
    private bool _swallowEscapeUp;

    public PushToTalkKey Key { get; set; } = PushToTalkKey.RightAlt;

    /// Raised on the UI thread.
    public event Action<HotkeyEvent>? Event;

    public bool IsRunning => _hook != IntPtr.Zero;

    public PushToTalkHotkey()
    {
        _proc = HookProc;
    }

    public void Start()
    {
        if (_hook != IntPtr.Zero) return;
        _context = SynchronizationContext.Current;
        _hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _proc, Native.GetModuleHandle(null), 0);
        if (_hook == IntPtr.Zero)
            throw new InvalidOperationException($"SetWindowsHookEx failed ({Marshal.GetLastWin32Error()})");
    }

    public void Stop()
    {
        if (_hook == IntPtr.Zero) return;
        Native.UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
        _keyIsDown = false;
    }

    public void Dispose() => Stop();

    private int MonitoredVk => Key == PushToTalkKey.RightCtrl ? Native.VK_RCONTROL : Native.VK_RMENU;

    private static bool IsModifier(int vk) => vk is Native.VK_LSHIFT or Native.VK_RSHIFT or Native.VK_LCONTROL
        or Native.VK_RCONTROL or Native.VK_LMENU or Native.VK_RMENU or Native.VK_LWIN or Native.VK_RWIN
        or Native.VK_SHIFT or Native.VK_CONTROL or Native.VK_MENU;

    private IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
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
                Handle(vk, info.scanCode, down, up);
                if (swallow) return 1;
            }
        }
        return Native.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private void Handle(int vk, uint scanCode, bool down, bool up)
    {
        // AltGr layouts send a phantom Left Ctrl (scan code 0x21D) with Right Alt.
        if (vk == Native.VK_LCONTROL && scanCode == 0x21D) return;
        var now = _clock.Elapsed.TotalSeconds;
        HotkeyInput? input = null;
        if (vk == MonitoredVk)
        {
            if (down && !_keyIsDown)
            {
                _keyIsDown = true;
                input = HotkeyInput.KeyDown;
            }
            else if (up && _keyIsDown)
            {
                _keyIsDown = false;
                input = HotkeyInput.KeyUp;
            }
            // Auto-repeat downs while held are ignored.
        }
        else if (down)
        {
            input = vk == Native.VK_ESCAPE ? HotkeyInput.Escape
                : IsModifier(vk) ? HotkeyInput.OtherKey
                : HotkeyInput.CharacterKey;
        }
        if (input is not HotkeyInput i) return;
        var evt = _machine.Handle(i, now);
        // Work happens after the hook returns: Windows drops hooks that answer slowly.
        var context = _context;
        if (i == HotkeyInput.KeyDown && Key == PushToTalkKey.RightAlt)
        {
            // Mask the Alt release so the focused app doesn't open its menu bar.
            context?.Post(_ => MaskAltRelease(), null);
        }
        if (evt is HotkeyEvent e) context?.Post(_ => Event?.Invoke(e), null);
    }

    private static void MaskAltRelease()
    {
        Native.Send(Native.Key(Native.VK_MENU_MASK, up: false), Native.Key(Native.VK_MENU_MASK, up: true));
    }
}
