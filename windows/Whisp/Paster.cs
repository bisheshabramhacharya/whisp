using System.Windows.Automation;
using System.Windows.Automation.Text;
using Whisp.Core.Input;
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
    /// Caret snapshot from the same lookup, used to tell a real paste from text that was already there.
    public required Task<CaretSnapshot> Caret { get; init; }
}

/// <summary>
/// What was at the caret when the hotkey was released. <see cref="Tail"/> is null when it
/// couldn't be read; empty when the caret was at the start of the document.
/// </summary>
internal readonly struct CaretSnapshot
{
    public char? Preceding { get; init; }
    public string? Tail { get; init; }
    public string? Selected { get; init; }
    /// The selection was too long to read. A suffix match would not prove the paste landed.
    public bool BlockEarlyConfirm { get; init; }
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
///   4. Restore the user's clipboard once UI Automation shows the caret took the text.
///      A clipboard read does not change the sequence number, so a fixed 300 ms timer
///      restores too soon for Electron, a busy browser, or a remote desktop. When the
///      insertion can't be confirmed, wait <see cref="RestoreDelayMs"/> and still refuse
///      to overwrite a clipboard someone else wrote in the meantime.
/// </summary>
internal sealed class Paster
{
    /// Long enough that a target which reads the clipboard late still sees the dictation.
    /// A confirmed insertion restores sooner.
    private const int RestoreDelayMs = 2000;
    private const int ConfirmPollMs = 50;
    private const int ProbeTimeoutMs = 80;
    private const int SelectedCap = 512;
    private static readonly TimeSpan LookupTimeout = TimeSpan.FromMilliseconds(250);

    /// The user's clipboard while a restore is pending, so back-to-back dictations don't
    /// capture Whisp's own previous text as "the user's clipboard".
    private (IDataObject? Snapshot, uint Sequence, CancellationTokenSource Cancel)? _pendingRestore;

    public PasteTarget Target()
    {
        var window = Native.GetForegroundWindow();
        // Preceding is published before the extra UI Automation reads, so those
        // reads missing the 250 ms budget cannot drop the leading space.
        var lookup = CaretLookup.Start(LookupTimeout, ReadCaret);
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
            Preceding = lookup.Preceding,
            Caret = lookup.Snapshot,
        };
    }

    /// Must run on the UI (STA) thread: the clipboard needs it.
    public async Task<PasteResult> PasteAsync(string text, PasteTarget target)
    {
        if (text.Length == 0) return PasteResult.Pasted;
        // The delivered character, not the snapshot: a timed-out tail read leaves
        // the snapshot empty and would otherwise drop the leading space.
        var preceding = await target.Preceding;
        var caret = await target.Caret;
        if (char.IsLetterOrDigit(text[0]) && preceding is char previous && Spacing.NeedsSpace(previous))
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

        // The window can change during the snapshot or that wait. Leave a normal
        // (not transient) copy so Ctrl+V and clipboard history still see it.
        if (Native.GetForegroundWindow() != target.Window)
        {
            CancelPendingRestore();
            SetClipboard(text.Trim(), transient: false);
            return PasteResult.CopiedAppChanged;
        }

        Native.Send(
            Native.Key(Native.VK_LCONTROL, up: false), Native.Key(Native.VK_V, up: false),
            Native.Key(Native.VK_V, up: true), Native.Key(Native.VK_LCONTROL, up: true));

        var cancel = new CancellationTokenSource();
        _pendingRestore = (snapshot, expected, cancel);
        _ = RestoreLaterAsync(snapshot, expected, text, caret, cancel.Token);
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

    private async Task RestoreLaterAsync(IDataObject? snapshot, uint expected, string text, CaretSnapshot caret, CancellationToken cancel)
    {
        // No caret snapshot (or a selection we couldn't read, or one that was already
        // this exact text): UI Automation can't prove the paste. Wait the full delay.
        var watch = caret.Tail != null && !caret.BlockEarlyConfirm && caret.Selected != text
            && text.Length > 0 && text.Length <= 2000;
        try
        {
            if (!watch)
            {
                await Task.Delay(RestoreDelayMs, cancel);
                TryRestore(snapshot, expected);
                return;
            }

            var started = Environment.TickCount64;
            while (true)
            {
                await Task.Delay(ConfirmPollMs, cancel);
                if (Native.GetClipboardSequenceNumber() != expected)
                {
                    ClearPending(expected);
                    return;
                }
                var elapsed = Environment.TickCount64 - started;
                bool? confirmed = null;
                if (elapsed < RestoreDelayMs)
                    confirmed = await ProbeAsync(text, caret, cancel);
                if (cancel.IsCancellationRequested) return;
                if (Native.GetClipboardSequenceNumber() != expected)
                {
                    ClearPending(expected);
                    return;
                }
                if (confirmed == true || elapsed >= RestoreDelayMs)
                {
                    TryRestore(snapshot, expected);
                    return;
                }
            }
        }
        catch (OperationCanceledException)
        {
            // A newer paste or an explicit copy owns the clipboard now.
        }
    }

    private void TryRestore(IDataObject? snapshot, uint expected)
    {
        if (Native.GetClipboardSequenceNumber() != expected)
        {
            ClearPending(expected);
            return;
        }
        ClearPending(expected);
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

    private void ClearPending(uint expected)
    {
        if (_pendingRestore is { } pending && pending.Sequence == expected)
            _pendingRestore = null;
    }

    private static async Task<bool?> ProbeAsync(string text, CaretSnapshot caret, CancellationToken cancel)
    {
        var probe = Task.Run(() =>
        {
            try { return InsertionLanded(text, caret); }
            catch (Exception) { return (bool?)null; }
        });
        var finished = await Task.WhenAny(probe, Task.Delay(ProbeTimeoutMs, cancel));
        if (finished != probe) return null;
        try { return await probe; }
        catch (Exception) { return null; }
    }

    /// <summary>
    /// True when the caret now sits just after <paramref name="text"/> and that suffix
    /// wasn't already there at key release. False when the caret is readable but doesn't
    /// show it yet. Null when UI Automation can't answer.
    /// </summary>
    private static bool? InsertionLanded(string text, CaretSnapshot caret)
    {
        if (caret.Tail == null || caret.BlockEarlyConfirm) return null;
        if (caret.Selected != null && caret.Selected == text) return null;
        var focused = AutomationElement.FocusedElement;
        if (focused == null) return null;
        if (!focused.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) || pattern is not TextPattern textPattern)
            return null;
        var selection = textPattern.GetSelection();
        if (selection.Length == 0) return null;
        var end = selection[0].Clone();
        end.MoveEndpointByRange(TextPatternRangeEndpoint.Start, end, TextPatternRangeEndpoint.End);
        // The needle alone can already have been the suffix. tail+text is the proof.
        if (!BackwardEquals(end, text)) return false;
        if (!BackwardEquals(end, caret.Tail + text)) return false;
        return true;
    }

    /// The range is collapsed at the caret. Expand it backward and compare.
    private static bool BackwardEquals(TextPatternRange caretEnd, string expected)
    {
        if (expected.Length == 0) return true;
        var range = caretEnd.Clone();
        range.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -expected.Length);
        return range.GetText(expected.Length + 1) == expected;
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

    /// The character before the caret, plus the text a later read uses to prove the paste.
    /// Preceding-character rules match the previous implementation: failure → null (paste as-is),
    /// caret at the start → '\n' (no leading space).
    /// <paramref name="deliverPreceding"/> is called as soon as that character is known,
    /// before the selection and tail reads, which share the lookup budget.
    private static CaretSnapshot ReadCaret(Action<char?> deliverPreceding)
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused == null)
            {
                deliverPreceding(null);
                return default;
            }
            if (focused.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) && pattern is TextPattern text)
            {
                var selection = text.GetSelection();
                if (selection.Length == 0)
                {
                    deliverPreceding(null);
                    return default;
                }
                var range = selection[0].Clone();
                range.MoveEndpointByRange(TextPatternRangeEndpoint.End, range, TextPatternRangeEndpoint.Start);
                char? preceding;
                if (range.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -1) == 0)
                    preceding = '\n'; // caret at the very start: no space needed
                else
                {
                    var before = range.GetText(1);
                    preceding = before.Length > 0 ? before[^1] : null;
                }
                deliverPreceding(preceding);

                // These reads are not needed for the leading space. If they hang
                // or throw, the character above is already delivered.
                var block = false;
                string? selected = null;
                string? tail = null;
                try
                {
                    var selectedRaw = selection[0].GetText(SelectedCap);
                    block = selectedRaw.Length >= SelectedCap;
                    selected = !block && selectedRaw.Length > 0 ? selectedRaw : null;

                    var tailRange = selection[0].Clone();
                    tailRange.MoveEndpointByRange(TextPatternRangeEndpoint.End, tailRange, TextPatternRangeEndpoint.Start);
                    tailRange.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -80);
                    tail = tailRange.GetText(80);
                }
                catch (Exception)
                {
                }

                return new CaretSnapshot
                {
                    Preceding = preceding,
                    Tail = tail,
                    Selected = selected,
                    BlockEarlyConfirm = block,
                };
            }
            if (focused.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && value is ValuePattern v)
            {
                // No caret position here: only an empty field is certain to need no space.
                // Tail stays null, so the restore waits out the full delay.
                var preceding = v.Current.Value.Length == 0 ? '\n' : (char?)null;
                deliverPreceding(preceding);
                return new CaretSnapshot { Preceding = preceding };
            }
            deliverPreceding(null);
        }
        catch (Exception)
        {
            deliverPreceding(null);
        }
        return default;
    }
}
