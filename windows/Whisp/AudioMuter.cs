using System.Text.Json;
using NAudio.CoreAudioApi;
using Whisp.Core;

namespace Whisp;

/// <summary>
/// Mutes the default speakers while dictating, so the model hears you rather than a
/// video playing. A sentinel file records the mute; if Whisp crashes or is killed
/// while muted, the next launch puts the sound back (RepairAfterCrash).
/// </summary>
internal sealed class AudioMuter
{
    private sealed record Sentinel(string DeviceId, bool WasMuted);

    private readonly string _sentinelPath;
    private Sentinel? _active;

    public AudioMuter(string sentinelPath)
    {
        _sentinelPath = sentinelPath;
    }

    public void Mute()
    {
        if (_active != null) return;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            var volume = device.AudioEndpointVolume;
            _active = new Sentinel(device.ID, volume.Mute);
            AtomicFile.WriteAllText(_sentinelPath, JsonSerializer.Serialize(_active));
            if (!_active.WasMuted) volume.Mute = true;
        }
        catch (Exception e)
        {
            Log.Write($"mute failed: {e.Message}");
            _active = null;
        }
    }

    public void Restore()
    {
        if (_active == null) return;
        Apply(_active);
        _active = null;
        TryDelete(_sentinelPath);
    }

    /// Replays a mute left behind by a crash, then removes the sentinel.
    public static void RepairAfterCrash(string sentinelPath)
    {
        if (!File.Exists(sentinelPath)) return;
        try
        {
            if (JsonSerializer.Deserialize<Sentinel>(File.ReadAllText(sentinelPath)) is { } sentinel) Apply(sentinel);
        }
        catch (Exception e)
        {
            Log.Write($"mute repair failed: {e.Message}");
        }
        TryDelete(sentinelPath);
    }

    private static void Apply(Sentinel sentinel)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDevice(sentinel.DeviceId);
            device.AudioEndpointVolume.Mute = sentinel.WasMuted;
        }
        catch (Exception e)
        {
            Log.Write($"unmute failed: {e.Message}");
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (IOException) { }
    }
}
