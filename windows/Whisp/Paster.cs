using System.Windows.Automation;
using System.Windows.Automation.Text;
using Whisp.Core.Text;

namespace Whisp;

/// Where a dictation should land, captured at key release.
internal sealed class PasteTarget
{
    public required IntPtr Window { get; init; }
    /// Process name of the window, for the diagnostics log.
    public string AppName { get; init; } = "?";
    /// Character before the cursor, looked up in the background while the model transcribes.
    public required Task<char?> Preceding { get; init; }
}

internal enum PasteResult
{
    Pasted,
    /// Focus moved to another window while transcribing; the text was left on the clipboard.
    CopiedAppChanged,
}

/// <summary>
/// Inserts dictated text into the focused app at the cursor, without stealing focus.
/// Port of Sources/WhispCore/Input/Paster.swift:
///
///   1. At key release, note the foreground window and start a time-boxed UI Automation
///      read of the character before the cursor (decides whether a leading space is needed).
///   2. If a different window is in front by paste time, leave the text on the clipboard
///      instead of pasting into the wrong place.
///   3. Snapshot the clipboard, put the text on it — flagged so clipboard history and
///      clipboard managers skip it — and send Ctrl+V.
///   4. ~300 ms later restore the user's clipboard, unless something else wrote to it since.
/// </summary>
internal sealed class Paster
{
    private const int RestoreDelayMs = 300;
    private static readonly TimeSpan LookupTimeout = TimeSpan.FromMilliseconds(250);

    /// The user's clipboard while a restore is pending, so back-to-back dictations don't
    /// capture Whisp's own previous text as "the user's clipboard".
    private (IDataObject? Snapshot, uint Sequence, CancellationTokenSource Cancel)? _pendingRestore;

    public PasteTarget Target()
    {
        var window = Native.GetForegroundWindow();
        var lookup = Task.Run(PrecedingCharacter);
        string app;
        try
        {
            Native.GetWindowThreadProcessId(window, out var pid);
            using var process = System.Diagnostics.Process.GetProcessById((int)pid);
            app = process.ProcessName;
        }
        catch (Exception)
        {
            app = "?";
        }
        return new PasteTarget
        {
            Window = window,
            AppName = app,
            Preceding = Task.WhenAny(lookup, Task.Delay(LookupTimeout))
                .ContinueWith(t => t.Result == lookup && lookup.Status == TaskStatus.RanToCompletion ? lookup.Result : null),
        };
    }

    /// Must run on the UI (STA) thread: the clipboard needs it.
    public async Task<PasteResult> PasteAsync(string text, PasteTarget target)
    {
        if (text.Length == 0) return PasteResult.Pasted;
        if (char.IsLetterOrDigit(text[0]) && await target.Preceding is char previous && Spacing.NeedsSpace(previous))
            text = " " + text;

        if (Native.GetForegroundWindow() != target.Window)
        {
            CancelPendingRestore();
            SetClipboard(text.Trim(), transient: false);
            return PasteResult.CopiedAppChanged;
        }

        IDataObject? snapshot;
        if (_pendingRestore is { } pending)
        {
            pending.Cancel.Cancel();
            snapshot = Native.GetClipboardSequenceNumber() == pending.Sequence ? pending.Snapshot : Snapshot();
        }
        else
        {
            snapshot = Snapshot();
        }
        _pendingRestore = null;

        SetClipboard(text, transient: true);
        var expected = Native.GetClipboardSequenceNumber();

        // Ctrl+V while a modifier is still physically down (e.g. Right Alt from ending
        // hands-free) would be Ctrl+Alt+V; wait for the keys to come up.
        for (var i = 0; i < 40 && ModifiersDown(); i++) await Task.Delay(25);

        Native.Send(
            Native.Key(Native.VK_LCONTROL, up: false), Native.Key(Native.VK_V, up: false),
            Native.Key(Native.VK_V, up: true), Native.Key(Native.VK_LCONTROL, up: true));

        var cancel = new CancellationTokenSource();
        _pendingRestore = (snapshot, expected, cancel);
        _ = RestoreLaterAsync(snapshot, expected, cancel.Token);
        return PasteResult.Pasted;
    }

    /// Copies text to the clipboard (paste-last fallback).
    public void Copy(string text)
    {
        CancelPendingRestore();
        SetClipboard(text, transient: false);
    }

    private void CancelPendingRestore()
    {
        _pendingRestore?.Cancel.Cancel();
        _pendingRestore = null;
    }

    private async Task RestoreLaterAsync(IDataObject? snapshot, uint expected, CancellationToken cancel)
    {
        try
        {
            await Task.Delay(RestoreDelayMs, cancel);
        }
        catch (TaskCanceledException)
        {
            return;
        }
        _pendingRestore = null;
        if (Native.GetClipboardSequenceNumber() != expected) return;
        try
        {
            if (snapshot == null)
                Clipboard.Clear();
            else
                Clipboard.SetDataObject(snapshot, copy: true, retryTimes: 10, retryDelay: 20);
        }
        catch (Exception e)
        {
            Log.Write($"clipboard restore failed: {e.Message}");
        }
    }

    private static bool ModifiersDown() =>
        Native.IsDown(Native.VK_MENU) || Native.IsDown(Native.VK_CONTROL) || Native.IsDown(Native.VK_SHIFT)
        || Native.IsDown(Native.VK_LWIN) || Native.IsDown(Native.VK_RWIN);

    /// Copies every format of the current clipboard that can be read; null when empty.
    private static IDataObject? Snapshot()
    {
        try
        {
            var current = Clipboard.GetDataObject();
            if (current == null) return null;
            var copy = new DataObject();
            var any = false;
            foreach (var format in current.GetFormats(autoConvert: false))
            {
                try
                {
                    if (current.GetData(format, autoConvert: false) is { } data)
                    {
                        copy.SetData(format, autoConvert: false, data);
                        any = true;
                    }
                }
                catch (Exception)
                {
                    // Some formats (delayed-rendered, private) can't be read back; skip them.
                }
            }
            return any ? copy : null;
        }
        catch (Exception e)
        {
            Log.Write($"clipboard snapshot failed: {e.Message}");
            return null;
        }
    }

    private static void SetClipboard(string text, bool transient)
    {
        var data = new DataObject();
        data.SetData(DataFormats.UnicodeText, text);
        if (transient)
        {
            // Keep dictations out of Win+V history, cloud clipboard and clipboard managers.
            data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[4]));
            data.SetData("CanIncludeInClipboardHistory", new MemoryStream(new byte[4]));
            data.SetData("CanUploadToCloudClipboard", new MemoryStream(new byte[4]));
        }
        Clipboard.SetDataObject(data, copy: true, retryTimes: 10, retryDelay: 20);
    }

    /// The character before the caret in the focused control, via UI Automation.
    /// Best-effort: any failure → null (paste as-is).
    private static char? PrecedingCharacter()
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused == null) return null;
            if (focused.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) && pattern is TextPattern text)
            {
                var selection = text.GetSelection();
                if (selection.Length == 0) return null;
                var range = selection[0].Clone();
                range.MoveEndpointByRange(TextPatternRangeEndpoint.End, range, TextPatternRangeEndpoint.Start);
                if (range.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -1) == 0)
                    return '\n'; // caret at the very start: no space needed
                var before = range.GetText(1);
                return before.Length > 0 ? before[^1] : null;
            }
            if (focused.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && value is ValuePattern v)
            {
                // No caret position here: only an empty field is certain to need no space.
                return v.Current.Value.Length == 0 ? '\n' : null;
            }
        }
        catch (Exception)
        {
        }
        return null;
    }
}
