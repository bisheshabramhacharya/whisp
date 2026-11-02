using Whisp.Core.Input;

namespace Whisp;

/// "Other Key or Button…": the next key or mouse button pressed becomes the push-to-talk key.
internal sealed class HotkeyPickerDialog : Form
{
    private readonly PushToTalkHotkey _hotkey;
    private readonly Label _picked = new() { AutoSize = true, Font = new Font("Segoe UI", 12f, FontStyle.Bold), Margin = new Padding(3, 10, 3, 10) };
    private readonly Button _ok = new() { Text = "Use This Key", DialogResult = DialogResult.OK, AutoSize = true, Enabled = false };

    public HotkeyBinding? Picked { get; private set; }

    public HotkeyPickerDialog(PushToTalkHotkey hotkey, HotkeyBinding current)
    {
        _hotkey = hotkey;
        Text = "Push-to-Talk Key";
        Icon = AppIcon.Load();
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Font = new Font("Segoe UI", 9.75f);
        TopMost = true;

        var layout = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, Padding = new Padding(14), Dock = DockStyle.Fill };
        void Add(Control c) => layout.Controls.Add(c);
        Add(new Label { Text = "Press the key or mouse button you want to hold to talk.", AutoSize = true });
        Add(new Label
        {
            Text = "Any key works, plus the middle and side mouse buttons.\nEsc, left click and right click can't be used.",
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(3, 6, 3, 3),
        });
        _picked.Text = $"Now: {current.DisplayName}";
        Add(_picked);
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true };
        buttons.Controls.Add(_ok);
        buttons.Controls.Add(cancel);
        Add(buttons);
        Controls.Add(layout);
        // No AcceptButton: Enter is a key you might pick. Esc still cancels.
        CancelButton = cancel;
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Listen();
    }

    private void Listen() => _hotkey.CaptureNext(binding =>
    {
        if (IsDisposed) return;
        Picked = binding;
        _picked.Text = binding.DisplayName;
        _ok.Enabled = true;
        // Keep listening so a second press replaces the first.
        Listen();
    });

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _hotkey.CancelCapture();
        base.OnFormClosed(e);
    }
}
