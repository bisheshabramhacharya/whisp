namespace Whisp.Core;

/// Audio for a released take, kept only until the take finishes or is cancelled.
public sealed class PendingTakes(string directory)
{
    public sealed record Take(string Id, DateTimeOffset Date);

    private string FilePath(string id) => Path.Combine(directory, id + ".wav");

    public void Save(string id, float[] samples, DateTimeOffset date)
    {
        Directory.CreateDirectory(directory);
        var file = FilePath(id);
        var partial = file + ".partial";
        try
        {
            using (var stream = new FileStream(partial, FileMode.Create))
                Wav.Write(stream, samples);
            File.SetLastWriteTimeUtc(partial, date.UtcDateTime);
            File.Move(partial, file);
        }
        finally
        {
            File.Delete(partial);
        }
    }

    public Take[] List()
    {
        if (!Directory.Exists(directory)) return [];
        return new DirectoryInfo(directory).EnumerateFiles("*.wav")
            .Select(file => new Take(Path.GetFileNameWithoutExtension(file.Name), file.LastWriteTimeUtc))
            .OrderBy(take => take.Date)
            .ThenBy(take => take.Id, StringComparer.Ordinal)
            .ToArray();
    }

    public void RemovePartials()
    {
        if (!Directory.Exists(directory)) return;
        foreach (var file in Directory.EnumerateFiles(directory, "*.wav.partial"))
            File.Delete(file);
    }

    public float[] Load(string id) => Wav.Read(FilePath(id));

    public void Remove(string id)
    {
        if (Directory.Exists(directory)) File.Delete(FilePath(id));
    }
}
