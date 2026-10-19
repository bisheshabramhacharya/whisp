namespace Whisp.Core;

/// Saves dictation audio as 16 kHz mono 16-bit WAVs in recordings\, named by history id.
public sealed class RecordingArchive
{
    public string Directory { get; }

    public RecordingArchive(string directory)
    {
        Directory = directory;
    }

    public void Save(float[] samples, string id)
    {
        System.IO.Directory.CreateDirectory(Directory);
        using var stream = new FileStream(Path.Combine(Directory, id + ".wav"), FileMode.Create);
        Wav.Write(stream, samples);
    }
}

public static class Wav
{
    public const int SampleRate = 16_000;

    public static void Write(Stream stream, float[] samples)
    {
        using var w = new BinaryWriter(stream, System.Text.Encoding.ASCII, leaveOpen: true);
        var dataBytes = samples.Length * 2;
        w.Write("RIFF"u8);
        w.Write(36 + dataBytes);
        w.Write("WAVE"u8);
        w.Write("fmt "u8);
        w.Write(16);
        w.Write((short)1); // PCM
        w.Write((short)1); // mono
        w.Write(SampleRate);
        w.Write(SampleRate * 2);
        w.Write((short)2);
        w.Write((short)16);
        w.Write("data"u8);
        w.Write(dataBytes);
        foreach (var s in samples)
        {
            w.Write((short)Math.Clamp(MathF.Round(s * 32767f), short.MinValue, short.MaxValue));
        }
    }

    /// Reads a 16 kHz mono 16-bit PCM WAV (what Whisp writes, and what `--transcribe`
    /// accepts). Throws on other formats.
    public static float[] Read(string path)
    {
        using var r = new BinaryReader(File.OpenRead(path));
        if (new string(r.ReadChars(4)) != "RIFF") throw new InvalidDataException("not a RIFF file");
        r.ReadInt32();
        if (new string(r.ReadChars(4)) != "WAVE") throw new InvalidDataException("not a WAVE file");
        short channels = 0, bits = 0;
        var rate = 0;
        while (r.BaseStream.Position < r.BaseStream.Length)
        {
            var id = new string(r.ReadChars(4));
            var size = r.ReadInt32();
            if (id == "fmt ")
            {
                var format = r.ReadInt16();
                channels = r.ReadInt16();
                rate = r.ReadInt32();
                r.ReadInt32();
                r.ReadInt16();
                bits = r.ReadInt16();
                r.BaseStream.Seek(size - 16, SeekOrigin.Current);
                if (format != 1) throw new InvalidDataException("WAV must be PCM");
            }
            else if (id == "data")
            {
                if (channels != 1 || bits != 16 || rate != SampleRate)
                    throw new InvalidDataException($"WAV must be 16 kHz mono 16-bit (got {rate} Hz, {channels} ch, {bits}-bit)");
                var samples = new float[size / 2];
                for (var i = 0; i < samples.Length; i++) samples[i] = r.ReadInt16() / 32768f;
                return samples;
            }
            else
            {
                r.BaseStream.Seek(size + (size & 1), SeekOrigin.Current);
            }
        }
        throw new InvalidDataException("no data chunk");
    }
}
