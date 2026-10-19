namespace Whisp.Core;

/// <summary>
/// Where Whisp keeps its files on Windows. The data folder mirrors the Mac's
/// ~/Library/Application Support/Whisp, file for file:
///
///   %APPDATA%\Whisp\dictionary.json    your words (same format as on the Mac)
///   %APPDATA%\Whisp\history.jsonl      past dictations (same format as on the Mac)
///   %APPDATA%\Whisp\recordings\        WAVs, if "Keep recordings" is on
///   %APPDATA%\Whisp\settings.json      menu settings
///   %LOCALAPPDATA%\Whisp\Models\       speech model (~660 MB, not roamed)
///
/// WHISP_HOME / WHISP_MODELS override the two roots (tests, portable installs).
/// </summary>
public sealed class AppPaths
{
    public string Root { get; }
    public string ModelsRoot { get; }

    public AppPaths(string root, string modelsRoot)
    {
        Root = root;
        ModelsRoot = modelsRoot;
    }

    public static AppPaths Default { get; } = new(
        Environment.GetEnvironmentVariable("WHISP_HOME") is { Length: > 0 } home
            ? home
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Whisp"),
        Environment.GetEnvironmentVariable("WHISP_MODELS") is { Length: > 0 } models
            ? models
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Whisp", "Models"));

    public string HistoryFile => Path.Combine(Root, "history.jsonl");
    public string RecordingsDirectory => Path.Combine(Root, "recordings");
    public string DictionaryFile => Path.Combine(Root, "dictionary.json");
    public string SettingsFile => Path.Combine(Root, "settings.json");
    /// Written while system audio is muted, so a crash can't leave it muted.
    public string MutedSentinel => Path.Combine(Root, "muted-device.json");
    public string LogFile => Path.Combine(Root, "whisp.log");

    public void EnsureCreated()
    {
        Directory.CreateDirectory(Root);
        Directory.CreateDirectory(ModelsRoot);
    }
}
