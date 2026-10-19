namespace Whisp;

/// "Fix a Misheard Word…": teaches the dictionary that one phrase should be typed as another.
internal sealed class FixWordDialog : Form
{
    private readonly TextBox _heard = new() { Width = 360 };
    private readonly TextBox _meant = new() { Width = 360 };

    public string Heard => _heard.Text.Trim();
    public string Meant => _meant.Text.Trim();

    public FixWordDialog(string? lastDictation)
    {
        Text = "Fix a Misheard Word";
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
        if (!string.IsNullOrWhiteSpace(lastDictation))
        {
            Add(new Label { Text = "Last dictation:", AutoSize = true, ForeColor = SystemColors.GrayText });
            Add(new Label { Text = lastDictation.Length > 200 ? lastDictation[..200] + "…" : lastDictation, AutoSize = true, MaximumSize = new Size(360, 0), Margin = new Padding(3, 0, 3, 10) });
        }
        Add(new Label { Text = "Whisp typed:", AutoSize = true });
        Add(_heard);
        Add(new Label { Text = "It should be:", AutoSize = true, Margin = new Padding(3, 10, 3, 3) });
        Add(_meant);
        Add(new Label
        {
            Text = "Matching ignores case and only replaces whole words.",
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(3, 6, 3, 10),
        });
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        var ok = new Button { Text = "Learn It", DialogResult = DialogResult.OK, AutoSize = true };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true };
        buttons.Controls.Add(ok);
        buttons.Controls.Add(cancel);
        Add(buttons);
        Controls.Add(layout);
        AcceptButton = ok;
        CancelButton = cancel;
        ok.Enabled = false;
        EventHandler validate = (_, _) => ok.Enabled = Heard.Length > 0 && Meant.Length > 0 && Heard != Meant;
        _heard.TextChanged += validate;
        _meant.TextChanged += validate;
    }
}
