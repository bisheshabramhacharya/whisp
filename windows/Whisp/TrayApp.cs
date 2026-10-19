using System.Diagnostics;
using Microsoft.Win32;
using Whisp.Core;
using Whisp.Core.Text;

namespace Whisp;

/// <summary>
/// The tray icon and its menu — the Windows counterpart of the Mac menu bar item —
/// plus composition of every service. Whisp has no main window.
/// </summary>
internal sealed class TrayApp : ApplicationContext
{
    private const int PasteLastHotkeyId = 1;

    private readonly AppPaths _paths;
    private readonly AppSettings _settings;
    private readonly HistoryStore _history;
    private readonly SpeechEngine _engine;
    private readonly MicRecorder _recorder;
    private readonly Paster _paster = new();
    private readonly Sounds _sounds = new();
    private readonly PushToTalkHotkey _hotkey = new();
    private readonly DictationController _controller;
    private readonly NotifyIcon _tray;
    private readonly ContextMenuStrip _menu = new();
    private readonly RecordingPill _pill;
    private readonly HotkeyWindow _hotkeyWindow;
    private string _modelStatus = "Starting…";

    public TrayApp(AppPaths paths)
    {
        _paths = paths;
        paths.EnsureCreated();
        _settings = new AppSettings(paths.SettingsFile);
        _history = new HistoryStore(paths.HistoryFile);
        _engine = new SpeechEngine(ModelSpec.ById(_settings.SpeechModel), paths.ModelsRoot);
        _recorder = new MicRecorder();
        AudioMuter.RepairAfterCrash(paths.MutedSentinel);
        var cleaner = new FillerCleaner(new PersonalDictionary(paths.DictionaryFile));
        cleaner.Clean("Warm up the cleaner, um, and the dictionary.");

        _controller = new DictationController(_engine, _recorder, _paster, cleaner, new AudioMuter(paths.MutedSentinel),
            _sounds, _settings, _history, new RecordingArchive(paths.RecordingsDirectory));

        _pill = new RecordingPill(_settings);
        _pill.ContextMenuRequested += p => _menu.Show(p);
        _pill.CreateControl();
        var handle = _pill.Handle; // create the layered window now
        _ = handle;

        _tray = new NotifyIcon
        {
            Icon = AppIcon.Load(),
            Text = "Whisp",
            ContextMenuStrip = _menu,
            Visible = true,
        };
        _menu.Opening += (_, _) => BuildMenu();
        _tray.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) ShowMenuAtCursor();
        };
        BuildMenu();

        var ui = SynchronizationContext.Current!;
        _engine.Status += status => ui.Post(_ =>
        {
            _modelStatus = status;
            UpdateIndicators();
        }, null);
        _controller.Changed += UpdateIndicators;
        _controller.Level += _pill.PushLevel;
        _hotkey.Event += _controller.Handle;
        _hotkey.Key = _settings.Hotkey;
        _settings.Changed += () => _hotkey.Key = _settings.Hotkey;

        _hotkeyWindow = new HotkeyWindow(PasteLastHotkeyId, PasteLast);
        if (!Native.RegisterHotKey(_hotkeyWindow.Handle, PasteLastHotkeyId,
                Native.MOD_CONTROL | Native.MOD_ALT | Native.MOD_NOREPEAT, (uint)Native.VK_V))
            Log.Write("Ctrl+Alt+V is taken by another app; Paste Last Dictation stays in the menu");

        try
        {
            _hotkey.Start();
        }
        catch (Exception e)
        {
            _controller.SetStatus($"Couldn't watch the keyboard: {e.Message}");
            Log.Write($"hotkey start failed: {e}");
        }

        ApplyLaunchAtLogin();
        UpdateIndicators();
        _ = PrepareModelAsync();

        if (!_settings.OnboardingCompleted)
        {
            ui.Post(_ => ShowWelcome(), null);
        }
    }

    private async Task PrepareModelAsync(ModelSpec? switchTo = null)
    {
        try
        {
            if (switchTo != null)
                await _engine.UseModelAsync(switchTo);
            else
                await _engine.PrepareAsync();
        }
        catch (OperationCanceledException)
        {
            // Another model was picked mid-download; that switch reports its own status.
        }
        catch (Exception e)
        {
            Log.Write($"model prepare failed: {e}");
            _modelStatus = $"Speech model failed: {e.Message}";
            UpdateIndicators();
            _tray.ShowBalloonTip(5000, "Whisp", $"Couldn't get the speech model ready: {e.Message}\nPick Retry Model Download in the menu.", ToolTipIcon.Error);
        }
    }

    private string HotkeyName => _settings.Hotkey == PushToTalkKey.RightCtrl ? "Right Ctrl" : "Right Alt";

    private string StatusLine()
    {
        if (_controller.StatusMessage is { } message) return message;
        if (!_engine.IsReady) return _modelStatus;
        return _controller.State switch
        {
            DictationState.Recording => _controller.IsHandsFree ? "Listening (hands-free) — press " + HotkeyName + " to finish" : "Listening…",
            DictationState.Transcribing => "Transcribing…",
            _ => $"Ready — hold {HotkeyName} and talk",
        };
    }

    private void UpdateIndicators()
    {
        var status = StatusLine();
        _tray.Text = Truncate("Whisp — " + status, 127);
        _pill.SetState(_controller.State, _controller.IsHandsFree, !_engine.IsReady);
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..(max - 1)] + "…";

    private void ShowMenuAtCursor()
    {
        // NotifyIcon only shows its menu on right-click; reuse its private helper for left-click.
        typeof(NotifyIcon).GetMethod("ShowContextMenu", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
            ?.Invoke(_tray, null);
    }

    // Menu

    private void BuildMenu()
    {
        _menu.Items.Clear();
        _menu.Items.Add(new ToolStripMenuItem(Truncate(StatusLine(), 80)) { Enabled = false });
        if (!_engine.IsReady && _modelStatus.StartsWith("Speech model failed", StringComparison.Ordinal))
            _menu.Items.Add("Retry Model Download", null, (_, _) => _ = PrepareModelAsync());
        _menu.Items.Add(new ToolStripSeparator());

        // From the menu, focus is on the taskbar, so copy; Ctrl+Alt+V pastes at the cursor.
        var copyLast = new ToolStripMenuItem("Copy Last Dictation", null, (_, _) =>
        {
            if (LastText() is { } text) _paster.Copy(text);
        })
        {
            ShortcutKeyDisplayString = "Ctrl+Alt+V pastes",
            Enabled = LastText() != null,
        };
        _menu.Items.Add(copyLast);

        var historyMenu = new ToolStripMenuItem("History");
        var recent = _history.LoadLast(15);
        if (recent.Count == 0)
        {
            historyMenu.DropDownItems.Add(new ToolStripMenuItem("No dictations yet") { Enabled = false });
        }
        else
        {
            historyMenu.DropDownItems.Add(new ToolStripMenuItem("Click one to copy it") { Enabled = false });
            foreach (var entry in recent.Where(e => e.Cleaned.Length > 0))
            {
                var label = Truncate(entry.Cleaned.ReplaceLineEndings(" "), 60);
                var item = new ToolStripMenuItem(label.Replace("&", "&&"), null, (_, _) => _paster.Copy(entry.Cleaned))
                {
                    ToolTipText = entry.Date.LocalDateTime.ToString("g"),
                };
                historyMenu.DropDownItems.Add(item);
            }
        }
        _menu.Items.Add(historyMenu);
        _menu.Items.Add(new ToolStripSeparator());

        _menu.Items.Add("Fix a Misheard Word…", null, (_, _) => FixWord());
        _menu.Items.Add("Edit Dictionary…", null, (_, _) => EditDictionary());
        _menu.Items.Add("Import from Mac…", null, (_, _) => ImportFromMac());
        _menu.Items.Add(new ToolStripSeparator());

        var pill = new ToolStripMenuItem("Recording Pill");
        foreach (var (label, scale) in new[] { ("Tiny", 0.5), ("Small", 0.75), ("Large", 1.0) })
        {
            pill.DropDownItems.Add(new ToolStripMenuItem(label, null, (_, _) => _settings.PillScale = scale)
            {
                Checked = Math.Abs(_settings.PillScale - scale) < 0.01,
            });
        }
        pill.DropDownItems.Add(new ToolStripSeparator());
        pill.DropDownItems.Add(Toggle("Always Show", _settings.AlwaysShowPill, v => _settings.AlwaysShowPill = v));
        pill.DropDownItems.Add("Reset Position", null, (_, _) => _settings.PillOrigin = null);
        _menu.Items.Add(pill);

        var key = new ToolStripMenuItem("Push-to-Talk Key");
        foreach (var (label, value) in new[] { ("Right Alt", PushToTalkKey.RightAlt), ("Right Ctrl", PushToTalkKey.RightCtrl) })
        {
            key.DropDownItems.Add(new ToolStripMenuItem(label, null, (_, _) => _settings.Hotkey = value)
            {
                Checked = _settings.Hotkey == value,
            });
        }
        _menu.Items.Add(key);

        var model = new ToolStripMenuItem("Speech Model");
        foreach (var spec in ModelSpec.All)
        {
            model.DropDownItems.Add(new ToolStripMenuItem(spec.MenuLabel, null, (_, _) => SwitchModel(spec))
            {
                Checked = _engine.Model == spec,
            });
        }
        _menu.Items.Add(model);

        _menu.Items.Add(Toggle("Sounds", _settings.Sounds, v => _settings.Sounds = v));
        _menu.Items.Add(Toggle("Mute Audio While Dictating", _settings.AutoMute, v => _settings.AutoMute = v));
        _menu.Items.Add(Toggle("Keep Recordings", _settings.KeepRecordings, v => _settings.KeepRecordings = v));
        _menu.Items.Add(Toggle("Launch at Login", _settings.LaunchAtLogin, v =>
        {
            _settings.LaunchAtLogin = v;
            ApplyLaunchAtLogin();
        }));
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("Open Setup…", null, (_, _) => ShowWelcome());
        _menu.Items.Add("Open Data Folder", null, (_, _) => Process.Start("explorer.exe", _paths.Root));
        _menu.Items.Add($"Whisp {Application.ProductVersion.Split('+')[0]} · {_engine.ModelName}").Enabled = false;
        _menu.Items.Add("Quit Whisp", null, (_, _) => Quit());
    }

    private static ToolStripMenuItem Toggle(string label, bool value, Action<bool> set) =>
        new(label, null, (_, _) => set(!value)) { Checked = value };

    // Actions

    private string? LastText()
    {
        var text = _controller.LastResult?.Cleaned ?? _history.LoadLast(1).FirstOrDefault()?.Cleaned;
        return string.IsNullOrWhiteSpace(text) ? null : text;
    }

    private void SwitchModel(ModelSpec spec)
    {
        if (_engine.Model == spec) return;
        _settings.SpeechModel = spec.Id;
        _modelStatus = $"Switching to {spec.DisplayName}…";
        UpdateIndicators();
        _ = PrepareModelAsync(spec);
    }

    private async void PasteLast()
    {
        if (LastText() is not { } text) return;
        try
        {
            await _paster.PasteAsync(text, _paster.Target());
        }
        catch (Exception e)
        {
            Log.Write($"paste last failed: {e.Message}");
        }
    }

    private void FixWord()
    {
        using var dialog = new FixWordDialog(LastText());
        if (dialog.ShowDialog() != DialogResult.OK) return;
        try
        {
            PersonalDictionary.AddReplacement(dialog.Heard, dialog.Meant, _paths.DictionaryFile);
            _tray.ShowBalloonTip(3000, "Whisp", $"Got it: \"{dialog.Heard}\" will be typed as \"{dialog.Meant}\".", ToolTipIcon.Info);
        }
        catch (Exception e)
        {
            MessageBox.Show($"Couldn't update dictionary.json: {e.Message}\n\nFix the file (Edit Dictionary…) and try again.",
                "Whisp", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void EditDictionary()
    {
        if (!File.Exists(_paths.DictionaryFile))
        {
            AtomicFile.WriteAllText(_paths.DictionaryFile, """
                {
                  "terms": [],
                  "replacements": []
                }

                """);
        }
        Process.Start(new ProcessStartInfo("notepad.exe", $"\"{_paths.DictionaryFile}\"") { UseShellExecute = true });
    }

    public void ImportFromMac(IWin32Window? owner = null)
    {
        using var dialog = new System.Windows.Forms.OpenFileDialog
        {
            Title = "Import Whisp data from a Mac",
            Filter = "Whisp export (*.zip)|*.zip|All files (*.*)|*.*",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\Downloads",
        };
        if (dialog.ShowDialog(owner) != DialogResult.OK) return;
        try
        {
            var report = MacImport.Import(dialog.FileName, _paths, _settings);
            ApplyLaunchAtLogin();
            Log.Write($"mac import: {report}");
            MessageBox.Show(owner, report.ToString(), "Whisp", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception e)
        {
            Log.Write($"mac import failed: {e}");
            MessageBox.Show(owner, $"Import failed: {e.Message}", "Whisp", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private WelcomeForm? _welcome;

    private void ShowWelcome()
    {
        if (_welcome is { IsDisposed: false })
        {
            _welcome.Activate();
            return;
        }
        _welcome = new WelcomeForm(_settings, _engine, () => _modelStatus, HotkeyName, owner => ImportFromMac(owner));
        _welcome.FormClosed += (_, _) =>
        {
            _settings.OnboardingCompleted = true;
            ApplyLaunchAtLogin();
        };
        _welcome.Show();
    }

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    private void ApplyLaunchAtLogin()
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (_settings.LaunchAtLogin)
                key.SetValue("Whisp", $"\"{Environment.ProcessPath}\"");
            else if (key.GetValue("Whisp") != null)
                key.DeleteValue("Whisp");
        }
        catch (Exception e)
        {
            Log.Write($"launch at login: {e.Message}");
        }
    }

    private void Quit()
    {
        _controller.Shutdown();
        _hotkey.Stop();
        _tray.Visible = false;
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _hotkey.Dispose();
            _tray.Dispose();
            _menu.Dispose();
            _pill.Dispose();
            _hotkeyWindow.DestroyHandle();
            _recorder.Dispose();
            _sounds.Dispose();
            _engine.Dispose();
        }
        base.Dispose(disposing);
    }

    /// Message-only window that receives WM_HOTKEY for the global paste-last shortcut.
    private sealed class HotkeyWindow : NativeWindow
    {
        private readonly int _id;
        private readonly Action _action;

        public HotkeyWindow(int id, Action action)
        {
            _id = id;
            _action = action;
            CreateHandle(new CreateParams { Parent = new IntPtr(-3) }); // HWND_MESSAGE
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_HOTKEY && m.WParam.ToInt32() == _id) _action();
            base.WndProc(ref m);
        }
    }
}
