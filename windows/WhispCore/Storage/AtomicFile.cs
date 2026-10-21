using System.Text;

namespace Whisp.Core;

public static class AtomicFile
{
    /// Writes to a sibling temp file, then swaps it into place, so readers never see a
    /// half-written file.
    public static void WriteAllText(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var tmp = path + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(tmp, text, new UTF8Encoding(false));
        File.Move(tmp, path, overwrite: true);
    }
}
