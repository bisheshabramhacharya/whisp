using System.Diagnostics;
using Whisp.Core;
using Whisp.Core.Text;

namespace Whisp;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        // whisp.exe --transcribe clip.wav [model-id]   prints the raw and cleaned transcript (16 kHz mono WAV)
        if (args.Length is 2 or 3 && args[0] == "--transcribe")
            return Transcribe(args[1], args.Length == 3 ? args[2] : null);

        using var single = new Mutex(true, @"Local\Whisp-6c1e0e6c", out var first);
        if (!first)
        {
            MessageBox.Show("Whisp is already running — look for its icon by the clock.", "Whisp",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }

        var paths = AppPaths.Default;
        paths.EnsureCreated();
        Log.Init(paths);
        Log.Write($"Whisp {Application.ProductVersion} starting");
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.ThreadException += (_, e) => Log.Write($"unhandled: {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"fatal: {e.ExceptionObject}");
        Application.Run(new TrayApp(paths));
        return 0;
    }

    private static int Transcribe(string wav, string? modelId)
    {
        Native.AttachConsole(-1); // ATTACH_PARENT_PROCESS: print to the calling terminal
        var paths = AppPaths.Default;
        paths.EnsureCreated();
        var spec = ModelSpec.ById(modelId ?? new AppSettings(paths.SettingsFile).SpeechModel);
        using var engine = new SpeechEngine(spec, paths.ModelsRoot);
        engine.Status += s => Console.Error.WriteLine(s);
        engine.PrepareAsync().GetAwaiter().GetResult();
        var samples = Wav.Read(wav);
        var sw = Stopwatch.StartNew();
        var raw = engine.TranscribeAsync(samples).GetAwaiter().GetResult();
        var ms = sw.ElapsedMilliseconds;
        var cleaned = new FillerCleaner(new PersonalDictionary(paths.DictionaryFile)).Clean(raw);
        Console.WriteLine($"raw:     {raw}");
        Console.WriteLine($"cleaned: {cleaned}");
        Console.WriteLine($"{samples.Length / 16000.0:F1}s audio in {ms} ms");
        return 0;
    }
}
