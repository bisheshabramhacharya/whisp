using System.Globalization;
using Whisp.Core;

namespace Whisp;

/// Tiny append-only diagnostics log (whisp.log in the data folder), capped at 1 MB.
/// Holds timings and errors only — never transcripts.
internal static class Log
{
    private static readonly object Gate = new();
    private static string? _path;

    public static void Init(AppPaths paths)
    {
        _path = paths.LogFile;
        try
        {
            if (File.Exists(_path) && new FileInfo(_path).Length > 1024 * 1024)
                File.Move(_path, _path + ".old", overwrite: true);
        }
        catch (IOException)
        {
        }
    }

    public static void Write(string message)
    {
        var line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture) + " " + message;
        System.Diagnostics.Debug.WriteLine(line);
        if (_path == null) return;
        lock (Gate)
        {
            try
            {
                File.AppendAllText(_path, line + Environment.NewLine);
            }
            catch (IOException)
            {
            }
        }
    }
}
