using System.Diagnostics;
using System.Security.Cryptography;
using SherpaOnnx;
using Whisp.Core;
using Whisp.Core.ASR;

namespace Whisp;

/// One downloadable model file, pinned by size and SHA-256.
internal sealed record ModelFile(string Name, long Size, string Sha256);

internal enum ModelKind { NemoTransducer, CohereTranscribe }

/// A speech model Whisp can run, and where to fetch it.
internal sealed record ModelSpec(string Id, string DisplayName, string MenuLabel, ModelKind Kind, string BaseUrl, ModelFile[] Files)
{
    /// NVIDIA Parakeet Unified English 0.6B — the model the Mac app uses — exported to
    /// ONNX by the sherpa-onnx project and int8-quantized. The default: about 2.7× faster
    /// than Cohere on a desktop CPU, nearly as accurate on audiobook speech and better on
    /// dictation-style tech words and times (see windows/README.md).
    public static readonly ModelSpec ParakeetUnified = new(
        "parakeet-unified-en-0.6b-int8",
        "Parakeet Unified 0.6B",
        "Parakeet Unified — recommended (660 MB)",
        ModelKind.NemoTransducer,
        "https://huggingface.co/csukuangfj2/sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming/resolve/8c3a10fb13408c7a7054f6898958bf1c64a8d6c7/",
        new[]
        {
            new ModelFile("tokens.txt", 8_952, "dc0b4584ab2e4ddbf888425c076c61b736e7356a015250db7d307e6f1a8188ff"),
            new ModelFile("decoder.int8.onnx", 7_257_753, "a5e223392c90e75f8144cdb5eb95af7625db389e39edef2bd1a9c872b3298fe6"),
            new ModelFile("joiner.int8.onnx", 1_735_860, "869f43f7d24595c55581ad3bf249a935fb8a71389fbdaa7504b9f46f93140f8a"),
            new ModelFile("encoder.int8.onnx", 654_040_552, "6716910b7a0833997fec7a410494c995d70124001a0e9b66d6370d6aced577e0"),
        });

    /// Cohere Transcribe 2B (Apache 2.0), #1 on the Open ASR Leaderboard, int8 ONNX by
    /// sherpa-onnx. Fewest errors on LibriSpeech, at about 2.7× Parakeet's decode time
    /// and 3.7 GB of memory.
    public static readonly ModelSpec CohereTranscribe = new(
        "cohere-transcribe-2b-int8",
        "Cohere Transcribe 2B",
        "Cohere Transcribe 2B — slower (2.9 GB)",
        ModelKind.CohereTranscribe,
        "https://huggingface.co/csukuangfj2/sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01/resolve/156a470cf08eefe706a0004f3c52d9ee567ca7a0/",
        new[]
        {
            new ModelFile("tokens.txt", 207_437, "013ede043ae2480e3a9205cc34550d9686100cc682bacc90f702facdfbb93035"),
            new ModelFile("encoder.int8.onnx", 3_090_822, "cf704f8cfa90e3f0a76f9ffc05998bdf00ba9ae983192c14a85a3a5eb008b367"),
            new ModelFile("decoder.int8.onnx", 153_250_705, "8372ca6c8ff4db8b916ca3592f5c757a715e691b9edec751ba19b29fc854baf9"),
            new ModelFile("encoder.int8.onnx.data", 2_731_503_072, "bcf1b7148c8518ae52df1ad2d2fc2b4e89261ea23e6c874eef1d9f55bcbaa4a3"),
        });

    public static readonly ModelSpec[] All = { ParakeetUnified, CohereTranscribe };

    public static ModelSpec ById(string? id) => All.FirstOrDefault(m => m.Id == id) ?? ParakeetUnified;

    public long TotalSize => Files.Sum(f => f.Size);
}

/// <summary>
/// Downloads (once), loads and runs the speech model through sherpa-onnx on the CPU.
/// Input is 16 kHz mono float PCM; output is the raw punctuated transcript.
/// Decodes are serialized: the recognizer is shared, and the dictation pipeline never
/// needs two at once.
/// </summary>
internal sealed class SpeechEngine : IDisposable
{
    /// Longest audio handed to one decode; longer takes are split at their quietest points.
    private const int MaxDecodeSamples = 30 * SpeechSegmenter.SampleRate;

    private readonly string _modelsRoot;
    private readonly SemaphoreSlim _decodeLock = new(1, 1);
    private readonly SemaphoreSlim _prepareLock = new(1, 1);
    private ModelSpec _spec;
    private OfflineRecognizer? _recognizer;
    /// Cancelled when another model is picked, so a long download doesn't block the switch.
    private CancellationTokenSource _switch = new();

    /// Human-readable status ("Downloading speech model… 42%", "Ready"). Raised on any thread.
    public event Action<string>? Status;

    public bool IsReady => _recognizer != null;
    public ModelSpec Model => _spec;
    public string ModelName => _spec.DisplayName;

    private string ModelDirectory => Path.Combine(_modelsRoot, _spec.Id);

    public SpeechEngine(ModelSpec spec, string modelsRoot)
    {
        _spec = spec;
        _modelsRoot = modelsRoot;
    }

    public async Task PrepareAsync(CancellationToken cancellation = default)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, _switch.Token);
        cancellation = linked.Token;
        await _prepareLock.WaitAsync(cancellation);
        try
        {
            if (_recognizer != null) return;
            await DownloadAsync(cancellation);
            Status?.Invoke("Loading speech model…");
            var sw = Stopwatch.StartNew();
            var recognizer = await Task.Run(() => new OfflineRecognizer(Config()), cancellation);
            // One throwaway decode so the first real dictation doesn't pay for warm-up.
            await Task.Run(() => Decode(recognizer, new float[SpeechSegmenter.SampleRate]), cancellation);
            _recognizer = recognizer;
            Log.Write($"model loaded in {sw.ElapsedMilliseconds} ms ({_spec.Id}, {Threads} threads)");
            Status?.Invoke("Ready");
        }
        finally
        {
            _prepareLock.Release();
        }
    }

    /// Switches to another model: frees the current one, then downloads/loads the new one.
    public async Task UseModelAsync(ModelSpec spec)
    {
        if (spec == _spec && _recognizer != null) return;
        Interlocked.Exchange(ref _switch, new CancellationTokenSource()).Cancel();
        await _prepareLock.WaitAsync();
        await _decodeLock.WaitAsync();
        try
        {
            _recognizer?.Dispose();
            _recognizer = null;
            _spec = spec;
        }
        finally
        {
            _decodeLock.Release();
            _prepareLock.Release();
        }
        await PrepareAsync();
    }

    private static int Threads => Math.Clamp(Environment.ProcessorCount / 2, 2, 8);

    private OfflineRecognizerConfig Config()
    {
        var dir = ModelDirectory;
        var config = new OfflineRecognizerConfig();
        config.ModelConfig.Tokens = Path.Combine(dir, "tokens.txt");
        config.ModelConfig.NumThreads = Threads;
        config.ModelConfig.Provider = "cpu";
        config.DecodingMethod = "greedy_search";
        switch (_spec.Kind)
        {
            case ModelKind.NemoTransducer:
                config.ModelConfig.Transducer.Encoder = Path.Combine(dir, "encoder.int8.onnx");
                config.ModelConfig.Transducer.Decoder = Path.Combine(dir, "decoder.int8.onnx");
                config.ModelConfig.Transducer.Joiner = Path.Combine(dir, "joiner.int8.onnx");
                config.ModelConfig.ModelType = "nemo_transducer";
                break;
            case ModelKind.CohereTranscribe:
                config.ModelConfig.CohereTranscribe.Encoder = Path.Combine(dir, "encoder.int8.onnx");
                config.ModelConfig.CohereTranscribe.Decoder = Path.Combine(dir, "decoder.int8.onnx");
                config.ModelConfig.CohereTranscribe.Language = "en";
                config.ModelConfig.CohereTranscribe.UsePunct = 1;
                config.ModelConfig.CohereTranscribe.UseItn = 1;
                break;
        }
        return config;
    }
    /// Raw transcript of samples; "" for near-silence.
    public async Task<string> TranscribeAsync(float[] samples)
    {
        if (SpeechSegmenter.IsNearSilent(samples)) return "";
        var recognizer = _recognizer;
        if (recognizer == null)
        {
            await PrepareAsync();
            recognizer = _recognizer!;
        }
        await _decodeLock.WaitAsync();
        try
        {
            return await Task.Run(() =>
            {
                var pieces = SpeechSegmenter.Split(samples, MaxDecodeSamples);
                return SpeechSegmenter.Join(pieces.Select(p => Decode(recognizer, p)));
            });
        }
        finally
        {
            _decodeLock.Release();
        }
    }

    /// Silence added after the audio: with only a short pause after the last word (a
    /// decode started at a pause), the model leaves off the final period.
    private static readonly float[] TrailingPad = new float[SpeechSegmenter.SampleRate * 4 / 10];

    private static string Decode(OfflineRecognizer recognizer, float[] samples)
    {
        using var stream = recognizer.CreateStream();
        stream.AcceptWaveform(SpeechSegmenter.SampleRate, samples);
        stream.AcceptWaveform(SpeechSegmenter.SampleRate, TrailingPad);
        recognizer.Decode(stream);
        return stream.Result.Text.Trim();
    }

    // Download

    private async Task DownloadAsync(CancellationToken cancellation)
    {
        Directory.CreateDirectory(ModelDirectory);
        var missing = _spec.Files.Where(f => !IsValid(f)).ToList();
        if (missing.Count == 0) return;

        using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Whisp-Windows");
        long done = _spec.Files.Except(missing).Sum(f => f.Size);
        var total = _spec.TotalSize;
        var lastReport = -1;
        foreach (var file in missing)
        {
            var path = Path.Combine(ModelDirectory, file.Name);
            var partial = path + ".partial";
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    await DownloadFileAsync(http, _spec.BaseUrl + file.Name, partial, file, cancellation, bytes =>
                    {
                        var percent = (int)(100 * (done + bytes) / total);
                        if (percent == lastReport) return;
                        lastReport = percent;
                        Status?.Invoke($"Downloading speech model… {percent}%");
                    });
                    break;
                }
                catch (Exception e) when (e is HttpRequestException or IOException && attempt < 4 && !cancellation.IsCancellationRequested)
                {
                    Log.Write($"download {file.Name} attempt {attempt} failed: {e.Message}");
                    await Task.Delay(TimeSpan.FromSeconds(2 * attempt), cancellation);
                }
            }
            Status?.Invoke("Checking speech model…");
            var hash = await Task.Run(() => Sha256(partial), cancellation);
            if (hash != file.Sha256)
            {
                File.Delete(partial);
                throw new InvalidDataException($"{file.Name} failed its checksum — try again");
            }
            File.Move(partial, path, overwrite: true);
            MarkVerified(file);
            done += file.Size;
        }
    }

    private static async Task DownloadFileAsync(HttpClient http, string url, string partial, ModelFile file,
        CancellationToken cancellation, Action<long> progress)
    {
        // Resume a partial download left by a previous run.
        long existing = File.Exists(partial) ? new FileInfo(partial).Length : 0;
        if (existing > file.Size) { File.Delete(partial); existing = 0; }
        if (existing == file.Size) return;
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (existing > 0) request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(existing, null);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
        response.EnsureSuccessStatusCode();
        if (existing > 0 && response.StatusCode != System.Net.HttpStatusCode.PartialContent) existing = 0;
        await using var source = await response.Content.ReadAsStreamAsync(cancellation);
        await using var target = new FileStream(partial, existing > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write);
        var buffer = new byte[1 << 20];
        var written = existing;
        int read;
        while ((read = await source.ReadAsync(buffer, cancellation)) > 0)
        {
            await target.WriteAsync(buffer.AsMemory(0, read), cancellation);
            written += read;
            progress(written);
        }
    }

    private string MarkerPath(ModelFile file) => Path.Combine(ModelDirectory, file.Name + ".verified");

    /// A file counts as valid when it has the pinned size and either a marker from an
    /// earlier verification of this exact file, or a fresh hash match.
    private bool IsValid(ModelFile file)
    {
        var path = Path.Combine(ModelDirectory, file.Name);
        var info = new FileInfo(path);
        if (!info.Exists || info.Length != file.Size) return false;
        var stamp = $"{file.Sha256} {info.Length} {info.LastWriteTimeUtc.Ticks}";
        try
        {
            if (File.Exists(MarkerPath(file)) && File.ReadAllText(MarkerPath(file)) == stamp) return true;
        }
        catch (IOException)
        {
        }
        if (Sha256(path) != file.Sha256) return false;
        MarkVerified(file);
        return true;
    }

    private void MarkVerified(ModelFile file)
    {
        var info = new FileInfo(Path.Combine(ModelDirectory, file.Name));
        File.WriteAllText(MarkerPath(file), $"{file.Sha256} {info.Length} {info.LastWriteTimeUtc.Ticks}");
    }

    private static string Sha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    public void Dispose()
    {
        _recognizer?.Dispose();
        _recognizer = null;
    }
}
