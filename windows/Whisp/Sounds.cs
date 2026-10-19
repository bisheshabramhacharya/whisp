using System.Media;
using Whisp.Core;

namespace Whisp;

/// Short synthesized UI blips (start, stop, cancel, error), generated once at launch.
internal sealed class Sounds : IDisposable
{
    private readonly SoundPlayer _start = Make((660, 0.05), (990, 0.07));
    private readonly SoundPlayer _stop = Make((990, 0.05), (660, 0.07));
    private readonly SoundPlayer _cancel = Make((440, 0.09));
    private readonly SoundPlayer _error = Make((330, 0.08), (0, 0.04), (330, 0.08));

    public void PlayStart() => _start.Play();
    public void PlayStop() => _stop.Play();
    public void PlayCancel() => _cancel.Play();
    public void PlayError() => _error.Play();

    private static SoundPlayer Make(params (double Hz, double Seconds)[] notes)
    {
        var samples = new List<float>();
        foreach (var (hz, seconds) in notes)
        {
            var n = (int)(seconds * Wav.SampleRate);
            for (var i = 0; i < n; i++)
            {
                // Short fade in/out so the tones don't click.
                var envelope = Math.Min(1, Math.Min(i, n - i) / (0.008 * Wav.SampleRate));
                samples.Add((float)(0.18 * envelope * Math.Sin(2 * Math.PI * hz * i / Wav.SampleRate)));
            }
        }
        var stream = new MemoryStream();
        Wav.Write(stream, samples.ToArray());
        stream.Position = 0;
        var player = new SoundPlayer(stream);
        player.Load();
        return player;
    }

    public void Dispose()
    {
        _start.Dispose();
        _stop.Dispose();
        _cancel.Dispose();
        _error.Dispose();
    }
}
