using Whisp.Core;

namespace Whisp;

/// <summary>
/// First-run setup, the short Windows version of the Mac's guided setup. Windows needs
/// no Accessibility or Input Monitoring grants, so it's one page: how to dictate, the
/// speech model's download progress, launch at login, and Import from Mac.
/// </summary>
internal sealed class WelcomeForm : Form
{
    private readonly Label _model = new() { AutoSize = true, ForeColor = SystemColors.GrayText };
    private readonly System.Windows.Forms.Timer _poll = new() { Interval = 250 };

    public WelcomeForm(AppSettings settings, SpeechEngine engine, Func<string> modelStatus, string hotkey,
        Action<IWin32Window> importFromMac)
    {
        Text = "Welcome to Whisp";
        Icon = AppIcon.Load();
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Font = new Font("Segoe UI", 10f);

        var layout = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, Padding = new Padding(22, 18, 22, 16) };
        void Add(Control c) => layout.Controls.Add(c);
        Add(new Label { Text = "Your voice. A little less typing.", AutoSize = true, Font = new Font("Segoe UI Semibold", 15f), Margin = new Padding(3, 0, 3, 12) });
        Add(Paragraph($"Hold {hotkey}, say what you want to write, and let go. Your words are typed wherever the cursor is — any app."));
        Add(Paragraph($"• Double-tap {hotkey} for hands-free: talk as long as you like, press it again to finish.\n" +
                      "• Esc cancels, even right after you let go.\n" +
                      "• Ctrl+Alt+V types your last dictation again.\n" +
                      "• The tray icon (bottom-right, by the clock) has History, Fix a Misheard Word and settings."));
        Add(Paragraph("Everything runs on this PC. Your audio and text never leave it."));
        Add(_model);

        var login = new CheckBox { Text = "Start Whisp when I sign in", AutoSize = true, Checked = settings.OnboardingCompleted ? settings.LaunchAtLogin : true, Margin = new Padding(3, 12, 3, 3) };
        Add(login);

        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 14, 0, 0) };
        var done = new Button { Text = "Start Dictating", AutoSize = true, DialogResult = DialogResult.OK };
        var import = new Button { Text = "Import from Mac…", AutoSize = true };
        import.Click += (_, _) => importFromMac(this);
        buttons.Controls.Add(done);
        buttons.Controls.Add(import);
        Add(buttons);
        Controls.Add(layout);
        AcceptButton = done;
        done.Click += (_, _) => Close();
        FormClosing += (_, _) => settings.LaunchAtLogin = login.Checked;

        void Refresh() => _model.Text = engine.IsReady
            ? $"✓ Speech model ready ({engine.ModelName})."
            : modelStatus() + $" (about {engine.Model.TotalSize / 1_000_000:N0} MB, once). You can start as soon as it's ready.";
        _poll.Tick += (_, _) => Refresh();
        Refresh();
        _poll.Start();
        FormClosed += (_, _) => _poll.Dispose();
    }

    private static Label Paragraph(string text) =>
        new() { Text = text, AutoSize = true, MaximumSize = new Size(520, 0), Margin = new Padding(3, 0, 3, 10) };
}
