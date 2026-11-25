using Whisp.Core;

namespace Whisp;

internal sealed class DailyDataSession
{
    private readonly AppPaths _paths;
    public DailyDataStore Store { get; }
    public HistoryStore History { get; }
    public DailyDictionary Dictionary { get; }
    public string Folder { get; private set; } = "";
    public string Microphone { get; private set; } = "";
    public string Status { get; private set; } = "";
    public bool Working { get; private set; }
    public event Action? Changed;

    public DailyDataSession(AppPaths paths)
    {
        _paths = paths;
        Store = new DailyDataStore(Path.Combine(paths.Root, "daily-data.json"));
        History = new HistoryStore(paths.HistoryFile, Store);
        Dictionary = new DailyDictionary(Store);
        try
        {
            ImportLegacy();
            Folder = Preference("folder");
            Microphone = Preference("microphone");
        }
        catch (Exception e) { Status = $"Couldn't load Whisp data: {e.Message}"; }
    }

    public void ImportLegacy()
    {
        History.ImportLegacy();
        Dictionary.ImportLegacy(_paths.DictionaryFile);
    }

    private string Preference(string id) => Store.Records("local").FirstOrDefault(r => r.Id == id)?.Value ?? "";

    public void SelectMicrophone(string id)
    {
        Store.Update(new DailyDataStore.Change("local", "microphone", id));
        Microphone = id;
    }

    public async Task SelectFolder(string path)
    {
        Store.Update(new DailyDataStore.Change("local", "folder", path));
        Folder = path;
        Status = "";
        Changed?.Invoke();
        await Sync();
    }

    public async Task Sync()
    {
        if (Working || Folder.Length == 0) return;
        Working = true;
        Changed?.Invoke();
        var folder = Folder;
        try
        {
            var unreadable = await Task.Run(() => Store.Sync(folder));
            Status = unreadable == 0 ? $"Last synced at {DateTime.Now:t}."
                : $"{unreadable} unreadable sync file(s). Whisp will retry.";
        }
        catch (Exception e) { Status = $"Couldn't sync: {e.Message}. Local data is still available."; }
        finally
        {
            Working = false;
            Changed?.Invoke();
        }
    }
}
