using Whisp.Core;

namespace Whisp;

internal sealed class DailyDataForm : Form
{
    private readonly DailyDataSession _data;
    private readonly MicRecorder _recorder;
    private readonly Action<string> _copy;
    private readonly ListBox _history = new() { Dock = DockStyle.Fill, IntegralHeight = false };
    private readonly TextBox _historyQuery = new() { Dock = DockStyle.Top, PlaceholderText = "Search dictations", AccessibleName = "Search dictations" };
    private readonly TextBox _text = new() { Dock = DockStyle.Fill, Multiline = true, ScrollBars = ScrollBars.Vertical, AccessibleName = "Dictation text" };
    private readonly ListBox _dictionary = new() { Dock = DockStyle.Fill, IntegralHeight = false };
    private readonly TextBox _dictionaryQuery = new() { Dock = DockStyle.Top, PlaceholderText = "Search words and replacements", AccessibleName = "Search words and replacements" };
    private readonly TextBox _heard = new() { Width = 280, PlaceholderText = "Word or heard phrase", AccessibleName = "Word or heard phrase" };
    private readonly TextBox _replacement = new() { Width = 280, PlaceholderText = "Replace with (optional)", AccessibleName = "Replace with (optional)" };
    private readonly ComboBox _inputs = new() { Width = 300, DropDownStyle = ComboBoxStyle.DropDownList, AccessibleName = "Input device" };
    private readonly Label _path = new() { AutoSize = true, MaximumSize = new Size(600, 0) };
    private readonly Label _status = new() { AutoSize = true, MaximumSize = new Size(600, 0) };
    private readonly Button _choose = new() { Text = "Choose Folder…", AutoSize = true };
    private readonly Button _sync = new() { Text = "Sync Now", AutoSize = true };
    private readonly Button _disconnect = new() { Text = "Disconnect", AutoSize = true };
    private sealed record Row<T>(T Value, string Label)
    {
        public override string ToString() => Label;
    }

    public DailyDataForm(DailyDataSession data, MicRecorder recorder, Action<string> copy, int page)
    {
        _data = data;
        _recorder = recorder;
        _copy = copy;
        Text = "Whisp Settings";
        Icon = AppIcon.Load();
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        MinimumSize = new Size(585, 400);
        ClientSize = new Size(680, 450);
        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(Page("History", HistoryTab()));
        tabs.TabPages.Add(Page("Dictionary", DictionaryTab()));
        tabs.TabPages.Add(Page("Microphone", MicrophoneTab()));
        tabs.TabPages.Add(Page("Sync", SyncTab()));
        tabs.SelectedIndex = page;
        Controls.Add(tabs);
        _data.Changed += RefreshSync;
        FormClosed += (_, _) => _data.Changed -= RefreshSync;
        Shown += (_, _) => Try(() => { ReloadHistory(); ReloadDictionary(); LoadInputs(); RefreshSync(); });
    }

    private static TabPage Page(string title, Control content)
    {
        var page = new TabPage(title) { Padding = new Padding(12) };
        page.Controls.Add(content);
        return page;
    }

    private static Button ActionButton(string label, Action action)
    {
        var button = new Button { Text = label, AutoSize = true };
        button.Click += (_, _) => action();
        return button;
    }

    private static FlowLayoutPanel Stack() => new()
    {
        Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true,
    };

    private static FlowLayoutPanel Buttons(params Control[] buttons)
    {
        var flow = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Bottom, WrapContents = false };
        flow.Controls.AddRange(buttons);
        return flow;
    }

    private static SplitContainer Split(Control list, Control search, Control editor)
    {
        var split = new SplitContainer { Dock = DockStyle.Fill, Size = new Size(630, 400), SplitterDistance = 255 };
        split.Panel1.Controls.Add(list);
        split.Panel1.Controls.Add(search);
        split.Panel2.Controls.Add(editor);
        return split;
    }

    private Control HistoryTab()
    {
        var save = ActionButton("Save", () => Try(() =>
        {
            if (_history.SelectedItem is Row<HistoryEntry> row) _data.History.Edit(row.Value.Id, _text.Text);
            ReloadHistory();
        }));
        var copy = ActionButton("Copy", () => Try(() => _copy(_text.Text)));
        _historyQuery.TextChanged += (_, _) => Try(ReloadHistory);
        _history.SelectedIndexChanged += (_, _) =>
        {
            var row = _history.SelectedItem as Row<HistoryEntry>;
            _text.Text = row?.Value.Cleaned ?? "";
            _text.Enabled = save.Enabled = copy.Enabled = row != null;
        };
        _text.Enabled = save.Enabled = copy.Enabled = false;
        var editor = new Panel { Dock = DockStyle.Fill };
        editor.Controls.Add(_text);
        editor.Controls.Add(Buttons(save, copy));
        return Split(_history, _historyQuery, editor);
    }

    private Control DictionaryTab()
    {
        var remove = ActionButton("Remove", () => Try(() =>
        {
            if (_dictionary.SelectedItem is Row<DailyDataStore.Record> row &&
                MessageBox.Show(this, "Remove this dictionary entry?", "Whisp",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
            {
                _data.Dictionary.Remove(row.Value.Id);
                ReloadDictionary();
            }
        }));
        var save = ActionButton("Add", () => Try(() =>
        {
            var id = (_dictionary.SelectedItem as Row<DailyDataStore.Record>)?.Value.Id;
            if (!_data.Dictionary.Save(_heard.Text, _replacement.Text, id))
                throw new InvalidOperationException("Enter a word or phrase not already in the dictionary.");
            ReloadDictionary();
            if (id == null) _heard.Text = _replacement.Text = "";
        }));
        var add = ActionButton("New", () =>
        {
            _dictionary.ClearSelected();
            _heard.Text = _replacement.Text = "";
            _heard.Focus();
        });
        _dictionaryQuery.TextChanged += (_, _) => Try(ReloadDictionary);
        _dictionary.SelectedIndexChanged += (_, _) =>
        {
            var row = _dictionary.SelectedItem as Row<DailyDataStore.Record>;
            _heard.Text = row?.Value.Value ?? "";
            _replacement.Text = row?.Value.Detail ?? "";
            remove.Enabled = row != null;
            save.Text = row == null ? "Add" : "Save";
        };
        remove.Enabled = false;
        var editor = Stack();
        editor.Controls.AddRange(new Control[]
        {
            _heard, _replacement,
            new Label { Text = "Leave replacement blank to preserve a word's capitalization.", MaximumSize = new Size(300, 0), AutoSize = true },
            Buttons(add, save, remove),
        });
        return Split(_dictionary, _dictionaryQuery, editor);
    }

    private Control MicrophoneTab()
    {
        var panel = Stack();
        _inputs.SelectionChangeCommitted += (_, _) => Try(() =>
        {
            if (_inputs.SelectedItem is Row<string> row)
            {
                _data.SelectMicrophone(row.Value);
                _recorder.PreferredInput = row.Value;
            }
        });
        panel.Controls.AddRange(new Control[]
        {
            new Label { Text = "Input device", AutoSize = true },
            _inputs, ActionButton("Refresh Devices", () => Try(LoadInputs)),
            new Label { Text = "Applies to the next dictation. If the selected microphone is unplugged, Whisp uses the system default. Your choice stays on this PC.",
                AutoSize = true, MaximumSize = new Size(540, 0) },
        });
        return panel;
    }

    private Control SyncTab()
    {
        var panel = Stack();
        _choose.Click += async (_, _) =>
        {
            using var dialog = new FolderBrowserDialog { Description = "Choose a Whisp sync folder", UseDescriptionForTitle = true, SelectedPath = _data.Folder };
            if (dialog.ShowDialog(this) == DialogResult.OK) await TryAsync(() => _data.SelectFolder(dialog.SelectedPath));
        };
        _sync.Click += async (_, _) => await TryAsync(_data.Sync);
        _disconnect.Click += async (_, _) => await TryAsync(() => _data.SelectFolder(""));
        panel.Controls.AddRange(new Control[]
        {
            new Label
            {
                Text = "Choose the same synced folder on each device. Whisp syncs dictation text and dictionary entries without a Whisp account. Audio recordings and microphone choices stay on this device. The folder contains readable dictation text — only choose one you trust.",
                AutoSize = true, MaximumSize = new Size(540, 0),
            },
            _path, Buttons(_choose, _sync, _disconnect), _status,
        });
        return panel;
    }

    private void LoadInputs()
    {
        _inputs.Items.Clear();
        _inputs.Items.Add(new Row<string>("", "System Default"));
        _inputs.Items.AddRange(MicRecorder.Inputs().Select(i => new Row<string>(i.Id, i.Name)).ToArray());
        var selected = _inputs.Items.Cast<Row<string>>().FirstOrDefault(i => i.Value == _data.Microphone);
        if (selected == null)
        {
            selected = new Row<string>(_data.Microphone, "Selected microphone (unavailable)");
            _inputs.Items.Add(selected);
        }
        _inputs.SelectedItem = selected;
    }

    private void ReloadHistory()
    {
        var selected = (_history.SelectedItem as Row<HistoryEntry>)?.Value.Id;
        var rows = _data.History.Search(_historyQuery.Text)
            .Select(e => new Row<HistoryEntry>(e, $"{e.Date.LocalDateTime:g}  {(e.Cleaned.Length == 0 ? e.Raw : e.Cleaned).ReplaceLineEndings(" ")}")).ToArray();
        _history.Items.Clear();
        _history.Items.AddRange(rows);
        if (selected != null) _history.SelectedItem = rows.FirstOrDefault(r => r.Value.Id == selected);
    }

    private void ReloadDictionary()
    {
        var selected = (_dictionary.SelectedItem as Row<DailyDataStore.Record>)?.Value.Id;
        var rows = _data.Dictionary.Records(_dictionaryQuery.Text)
            .Select(r => new Row<DailyDataStore.Record>(r, r.Detail == "" ? r.Value : $"{r.Value} → {r.Detail}")).ToArray();
        _dictionary.Items.Clear();
        _dictionary.Items.AddRange(rows);
        if (selected != null) _dictionary.SelectedItem = rows.FirstOrDefault(r => r.Value.Id == selected);
    }

    private void RefreshSync()
    {
        _path.Text = _data.Folder.Length == 0 ? "Sync is off." : _data.Folder;
        _status.Text = _data.Working ? "Syncing…" : _data.Status;
        _choose.Enabled = !_data.Working;
        _sync.Enabled = _disconnect.Enabled = !_data.Working && _data.Folder.Length > 0;
        if (!_data.Working)
        {
            if (_history.SelectedIndex < 0) Try(ReloadHistory);
            if (_dictionary.SelectedIndex < 0 && _heard.Text.Length == 0) Try(ReloadDictionary);
        }
    }

    private void Try(Action action)
    {
        try { action(); }
        catch (Exception e) { ShowError(e); }
    }

    private async Task TryAsync(Func<Task> action)
    {
        try { await action(); }
        catch (Exception e) { if (!IsDisposed) ShowError(e); }
    }

    private void ShowError(Exception error) =>
        MessageBox.Show(this, error.Message, "Whisp", MessageBoxButtons.OK, MessageBoxIcon.Warning);
}
