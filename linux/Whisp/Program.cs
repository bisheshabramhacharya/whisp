using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Whisp.Core;
using Whisp.Core.Text;

[assembly: SupportedOSPlatform("linux")]

namespace Whisp;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            switch (args)
            {
                case [] or ["--help"]:
                    Console.WriteLine("Usage: whisp daemon | press | release | cancel | --transcribe FILE.wav");
                    return 0;
                case ["press" or "release" or "cancel"]:
                    using (var client = new Socket(AddressFamily.Unix, SocketType.Dgram, ProtocolType.Unspecified))
                        await client.SendToAsync(Encoding.ASCII.GetBytes(args[0]), SocketFlags.None, Endpoint());
                    return 0;
                case ["daemon"]:
                    await RunDaemonAsync();
                    return 0;
                case ["--transcribe", var file]:
                    var samples = Wav.Read(file);
                    var paths = GetPaths();
                    using (var engine = CreateEngine(paths))
                    {
                        await engine.PrepareAsync();
                        var raw = await engine.TranscribeAsync(samples);
                        Console.WriteLine($"raw:     {raw}");
                        Console.WriteLine($"cleaned: {MakeCleaner(paths).Clean(raw)}");
                    }
                    return 0;
                default:
                    Console.Error.WriteLine("Unknown command; see whisp --help.");
                    return 2;
            }
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"Whisp: {e.Message}");
            return 1;
        }
    }

    private static async Task RunDaemonAsync()
    {
        var endpoint = Endpoint();
        var dir = Path.GetDirectoryName(endpoint.ToString())!;
        Directory.CreateDirectory(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        using var serverLock = File.Open(Path.Combine(dir, "daemon.lock"), FileMode.OpenOrCreate, FileAccess.Write, FileShare.None);
        using var server = new Socket(AddressFamily.Unix, SocketType.Dgram, ProtocolType.Unspecified);
        File.Delete(endpoint.ToString());
        server.Bind(endpoint);
        try
        {
            using var stop = new CancellationTokenSource();
            using var interrupt = PosixSignalRegistration.Create(PosixSignal.SIGINT, ctx => { ctx.Cancel = true; stop.Cancel(); });
            using var terminate = PosixSignalRegistration.Create(PosixSignal.SIGTERM, ctx => { ctx.Cancel = true; stop.Cancel(); });
            var paths = GetPaths();
            using var engine = CreateEngine(paths);
            await new DictationService(engine, MakeCleaner(paths)).RunAsync(server, stop.Token);
        }
        finally
        {
            File.Delete(endpoint.ToString());
        }
    }

    private static UnixDomainSocketEndPoint Endpoint()
    {
        var runtime = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        if (string.IsNullOrEmpty(runtime) || !Path.IsPathFullyQualified(runtime) || !Directory.Exists(runtime))
            throw new InvalidOperationException("XDG_RUNTIME_DIR must point to your session's runtime directory.");
        return new UnixDomainSocketEndPoint(Path.Combine(runtime, "whisp", "control.sock"));
    }

    private static AppPaths GetPaths()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var data = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
        var root = Path.Combine(string.IsNullOrEmpty(data) ? Path.Combine(home, ".local", "share") : data, "whisp");
        var paths = new AppPaths(
            Environment.GetEnvironmentVariable("WHISP_HOME") is { Length: > 0 } app ? app : root,
            Environment.GetEnvironmentVariable("WHISP_MODELS") is { Length: > 0 } models ? models : Path.Combine(root, "models"));
        paths.EnsureCreated();
        Log.Init(paths);
        return paths;
    }

    private static SpeechEngine CreateEngine(AppPaths paths)
    {
        var engine = new SpeechEngine(ModelSpec.ParakeetUnified, paths.ModelsRoot);
        engine.Status += Console.Error.WriteLine;
        return engine;
    }

    private static FillerCleaner MakeCleaner(AppPaths paths) => new(new PersonalDictionary(paths.DictionaryFile));
}
