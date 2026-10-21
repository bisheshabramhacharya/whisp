using NAudio.Wave;

namespace Whisp;

/// <summary>
/// Microphone capture at 16 kHz mono float, the format the speech model wants. Windows
/// converts from the device's native format. Levels are raised on the UI thread
/// (~25 Hz) for the recording pill.
/// </summary>
internal sealed class MicRecorder : IDisposable
{
    public const int SampleRate = 16_000;

    private readonly object _gate = new();
    private readonly SynchronizationContext? _context;
    private WaveInEvent? _device;
    private float[] _buffer = new float[SampleRate * 30];
    private int _count;
    private bool _recording;

    /// Normalized input level 0...1.
    public event Action<float>? Level;

    /// True when the input device failed mid-recording; the last Stop() returned only
    /// the audio from before the failure.
    public bool LostInput { get; private set; }

    public MicRecorder()
    {
        _context = SynchronizationContext.Current;
    }

    public void Start()
    {
        lock (_gate)
        {
            _count = 0;
            LostInput = false;
        }
        if (Environment.GetEnvironmentVariable("WHISP_TEST_MIC") is { Length: > 0 } testClip)
        {
            StartTestClip(testClip);
            return;
        }
        if (WaveInEvent.DeviceCount == 0)
            throw new InvalidOperationException("No microphone found");
        var device = new WaveInEvent
        {
            DeviceNumber = -1, // WAVE_MAPPER: follows the Windows default input device
            WaveFormat = new WaveFormat(SampleRate, 16, 1),
            BufferMilliseconds = 40,
            NumberOfBuffers = 3,
        };
        device.DataAvailable += OnData;
        device.RecordingStopped += OnStopped;
        device.StartRecording();
        _device = device;
        _recording = true;
    }

    /// Copy of the audio captured so far, from sample `start` on.
    public float[] Samples(int start)
    {
        lock (_gate)
        {
            if (start >= _count) return Array.Empty<float>();
            return _buffer.AsSpan(start, _count - start).ToArray();
        }
    }

    /// Stops capture and returns everything recorded since Start().
    public float[] Stop()
    {
        StopDevice();
        lock (_gate)
        {
            var samples = _buffer.AsSpan(0, _count).ToArray();
            _count = 0;
            if (_buffer.Length > SampleRate * 30) _buffer = new float[SampleRate * 30];
            return samples;
        }
    }

    /// Stops capture and discards audio.
    public void Cancel() => Stop();

    private CancellationTokenSource? _testClip;
    private int _testTake;

    /// End-to-end tests (WHISP_TEST_MIC=a.wav;b.wav): plays a 16 kHz WAV into the recorder
    /// in real time, as if spoken into the microphone, then silence. Each take uses the
    /// next clip in the list.
    private void StartTestClip(string paths)
    {
        var list = paths.Split(';', StringSplitOptions.RemoveEmptyEntries);
        var clip = Whisp.Core.Wav.Read(list[_testTake++ % list.Length]);
        var cancel = new CancellationTokenSource();
        _testClip = cancel;
        _recording = true;
        _ = Task.Run(async () =>
        {
            const int chunk = SampleRate / 25;
            var bytes = new byte[chunk * 2];
            var clock = System.Diagnostics.Stopwatch.StartNew();
            for (var sent = 0; !cancel.IsCancellationRequested; sent += chunk)
            {
                for (var i = 0; i < chunk; i++)
                {
                    var s = sent + i < clip.Length ? clip[sent + i] : 0f;
                    BitConverter.TryWriteBytes(bytes.AsSpan(i * 2), (short)(s * 32767));
                }
                OnData(this, new WaveInEventArgs(bytes, bytes.Length));
                var due = (sent + chunk) * 1000L / SampleRate - clock.ElapsedMilliseconds;
                if (due > 0) await Task.Delay((int)due);
            }
        });
    }

    private void StopDevice()
    {
        _recording = false;
        _testClip?.Cancel();
        _testClip = null;
        var device = _device;
        _device = null;
        if (device == null) return;
        // The capture thread delivers the buffers still in flight before it reports
        // stopped; wait for them so the last syllable isn't cut off.
        var stopped = new ManualResetEventSlim();
        device.RecordingStopped += (_, _) => stopped.Set();
        try
        {
            device.StopRecording();
            stopped.Wait(TimeSpan.FromMilliseconds(300));
        }
        catch (NAudio.MmException)
        {
            // Device already gone.
        }
        device.DataAvailable -= OnData;
        device.RecordingStopped -= OnStopped;
        device.Dispose();
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        var n = e.BytesRecorded / 2;
        double sumSquares = 0;
        lock (_gate)
        {
            if (_count + n > _buffer.Length) Array.Resize(ref _buffer, Math.Max(_buffer.Length * 2, _count + n));
            for (var i = 0; i < n; i++)
            {
                var s = BitConverter.ToInt16(e.Buffer, i * 2) / 32768f;
                _buffer[_count + i] = s;
                sumSquares += s * s;
            }
            _count += n;
        }
        if (n == 0) return;
        var rms = Math.Sqrt(sumSquares / n);
        // Speech RMS sits around 0.01–0.2; map it onto a perceptual 0...1 scale.
        var level = (float)Math.Clamp((20 * Math.Log10(rms + 1e-9) + 55) / 40, 0, 1);
        if (_context != null) _context.Post(_ => Level?.Invoke(level), null);
        else Level?.Invoke(level);
    }

    private void OnStopped(object? sender, StoppedEventArgs e)
    {
        if (_recording && e.Exception != null) LostInput = true;
    }

    public void Dispose() => StopDevice();
}
