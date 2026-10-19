using System.Text.Json;
using System.Text.Json.Serialization;

namespace Whisp.Core;

/// Push-to-talk key choices. Right Alt is the Windows counterpart of the Mac's Right Option.
public enum PushToTalkKey
{
    RightAlt,
    RightCtrl,
}

/// <summary>
/// Menu settings, persisted as settings.json in the data folder. Same names and
/// defaults as the Mac's UserDefaults-backed AppSettings, so a Mac import maps 1:1.
/// Every setter saves immediately.
/// </summary>
public sealed class AppSettings
{
    private sealed class Model
    {
        public bool Sounds { get; set; } = true;
        /// Mute system audio while recording.
        public bool AutoMute { get; set; } = true;
        /// Keep WAVs of every dictation next to history.jsonl.
        public bool KeepRecordings { get; set; } = true;
        public bool LaunchAtLogin { get; set; }
        [JsonConverter(typeof(JsonStringEnumConverter))]
        public PushToTalkKey Hotkey { get; set; } = PushToTalkKey.RightAlt;
        /// Recording pill size multiplier (1.0 = 180×50 px at 100% scaling).
        public double PillScale { get; set; } = 0.75;
        /// Where the user dragged the pill (top-left, virtual-screen pixels); null = bottom-center.
        public double[]? PillOrigin { get; set; }
        /// Keep a dimmed pill on screen while idle (so it can be dragged anytime).
        public bool AlwaysShowPill { get; set; } = true;
        public bool OnboardingCompleted { get; set; }
        /// Speech model id; null = the default model.
        public string? SpeechModel { get; set; }
    }

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly string _path;
    private readonly Model _model;

    public event Action? Changed;

    public AppSettings(string path)
    {
        _path = path;
        _model = TryLoad(path) ?? new Model();
    }

    private static Model? TryLoad(string path)
    {
        try
        {
            return File.Exists(path) ? JsonSerializer.Deserialize<Model>(File.ReadAllText(path), Options) : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private void Save()
    {
        try
        {
            AtomicFile.WriteAllText(_path, JsonSerializer.Serialize(_model, Options));
        }
        catch (IOException)
        {
            // Settings are best-effort; the next change retries.
        }
        Changed?.Invoke();
    }

    private void Set<T>(T current, T value, Action<T> assign)
    {
        if (EqualityComparer<T>.Default.Equals(current, value)) return;
        assign(value);
        Save();
    }

    public bool Sounds { get => _model.Sounds; set => Set(_model.Sounds, value, v => _model.Sounds = v); }
    public bool AutoMute { get => _model.AutoMute; set => Set(_model.AutoMute, value, v => _model.AutoMute = v); }
    public bool KeepRecordings { get => _model.KeepRecordings; set => Set(_model.KeepRecordings, value, v => _model.KeepRecordings = v); }
    public bool LaunchAtLogin { get => _model.LaunchAtLogin; set => Set(_model.LaunchAtLogin, value, v => _model.LaunchAtLogin = v); }
    public PushToTalkKey Hotkey { get => _model.Hotkey; set => Set(_model.Hotkey, value, v => _model.Hotkey = v); }
    public double PillScale { get => _model.PillScale; set => Set(_model.PillScale, value, v => _model.PillScale = v); }
    public bool AlwaysShowPill { get => _model.AlwaysShowPill; set => Set(_model.AlwaysShowPill, value, v => _model.AlwaysShowPill = v); }
    public bool OnboardingCompleted { get => _model.OnboardingCompleted; set => Set(_model.OnboardingCompleted, value, v => _model.OnboardingCompleted = v); }
    public string? SpeechModel { get => _model.SpeechModel; set => Set(_model.SpeechModel, value, v => _model.SpeechModel = v); }

    public (double X, double Y)? PillOrigin
    {
        get => _model.PillOrigin is { Length: 2 } xy ? (xy[0], xy[1]) : null;
        set
        {
            if (Nullable.Equals(PillOrigin, value)) return;
            _model.PillOrigin = value is { } v ? new[] { v.X, v.Y } : null;
            Save();
        }
    }
}
