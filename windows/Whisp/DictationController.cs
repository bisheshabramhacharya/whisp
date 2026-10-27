using System.Diagnostics;
using Whisp.Core;
using Whisp.Core.ASR;
using Whisp.Core.Input;
using Whisp.Core.Text;

namespace Whisp;

internal enum DictationState { Idle, Recording, Transcribing }

/// <summary>
/// Orchestrates one push-to-talk dictation loop:
/// hotkey event -> sounds/mute -> record -> transcribe -> clean -> paste -> history.
/// Port of Sources/WhispCore/DictationController.swift.
///
/// Everything runs on the UI thread except decodes. While the key is held, finished
/// sentences are cut at pauses and transcribed in the background, so on release only
/// the tail is left to decode. Transcriptions run through a serial pipeline, so pastes
/// land in recording order even if a new dictation starts while one is still decoding.
/// </summary>
internal sealed class DictationController
{
    private readonly SpeechEngine _engine;
    private readonly MicRecorder _recorder;
    private readonly Paster _paster;
    private readonly FillerCleaner _cleaner;
    private readonly AudioMuter _muter;
    private readonly Sounds _sounds;
    private readonly AppSettings _settings;
    private readonly HistoryStore _history;
    private readonly RecordingArchive _recordings;

    private bool _isRecording;
    private bool _systemMuted;
    private int _pendingTranscriptions;
    private DateTimeOffset _recordingStartedAt;
    private CancellationTokenSource? _captureCancel;
    /// Every finished recording gets an increasing id; Esc after release drops the paste
    /// of every id up to _cancelledThrough.
    private int _lastClipId;
    private int _cancelledThrough;
    private Task _pipelineTail = Task.CompletedTask;
    private LiveChunks? _live;

    /// Hard safety cap so a stuck key can never record forever.
    public TimeSpan MaximumDuration { get; set; } = TimeSpan.FromMinutes(10);
    private const double MinimumDuration = 0.05;

    public DictationState State { get; private set; } = DictationState.Idle;
    public bool IsHandsFree { get; private set; }
    public HistoryEntry? LastResult { get; private set; }
    /// Last surfaced error/info message, shown in the tray menu.
    public string? StatusMessage { get; private set; }

    /// State, hands-free or status message changed.
    public event Action? Changed;
    public event Action<float>? Level;

    public DictationController(SpeechEngine engine, MicRecorder recorder, Paster paster, FillerCleaner cleaner,
        AudioMuter muter, Sounds sounds, AppSettings settings, HistoryStore history, RecordingArchive recordings)
    {
        _engine = engine;
        _recorder = recorder;
        _paster = paster;
        _cleaner = cleaner;
        _muter = muter;
        _sounds = sounds;
        _settings = settings;
        _history = history;
        _recordings = recordings;
        _recorder.Level += level => Level?.Invoke(level);
    }

    public void Handle(HotkeyEvent e)
    {
        switch (e)
        {
            case HotkeyEvent.Start: StartCapture(); break;
            case HotkeyEvent.Stop: StopCapture(); break;
            case HotkeyEvent.Cancel: CancelCapture(); break;
            case HotkeyEvent.HandsFree:
                if (_isRecording && !IsHandsFree)
                {
                    IsHandsFree = true;
                    Changed?.Invoke();
                }
                break;
        }
    }

    public void SetStatus(string? message)
    {
        StatusMessage = message;
        Changed?.Invoke();
    }

    /// Clean shutdown: queued dictations are not pasted.
    public void Shutdown()
    {
        _cancelledThrough = _lastClipId;
        if (_isRecording)
        {
            _isRecording = false;
            _captureCancel?.Cancel();
            _live = null;
            _recorder.Cancel();
            RestoreAudio();
        }
    }

    private void StartCapture()
    {
        if (_isRecording) return;
        StatusMessage = _engine.IsReady ? null
            : "Still loading the speech model — keep talking, your words are typed once it's ready";

        // Feedback first so the user hears the ack even if the mic fails.
        if (_settings.Sounds) _sounds.PlayStart();
        var micStart = Stopwatch.StartNew();
        try
        {
            _recorder.Start();
        }
        catch (Exception e)
        {
            if (_settings.Sounds) _sounds.PlayError();
            SetStatus(e is NAudio.MmException
                ? "Microphone unavailable — check Settings › Privacy & security › Microphone"
                : $"Microphone failed: {e.Message}");
            Log.Write($"mic start failed: {e}");
            return;
        }
        Log.Write($"mic started in {micStart.ElapsedMilliseconds} ms");

        _isRecording = true;
        _recordingStartedAt = DateTimeOffset.Now;
        _captureCancel = new CancellationTokenSource();
        var token = _captureCancel.Token;
        _live = new LiveChunks();
        _ = ChunkLoopAsync(_live, token);

        // Mute speakers after the start sound has played, since muting cuts it off.
        if (_settings.AutoMute)
        {
            _ = Task.Delay(_settings.Sounds ? 250 : 0, token).ContinueWith(t =>
            {
                if (t.IsCanceled || !_isRecording || _systemMuted) return;
                _muter.Mute();
                _systemMuted = true;
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        // Safety cap: auto-stop (and transcribe) after MaximumDuration.
        _ = Task.Delay(MaximumDuration, token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            Log.Write("auto-stop: maximum duration reached");
            StopCapture();
        }, TaskScheduler.FromCurrentSynchronizationContext());

        Recompute();
    }

    private void StopCapture()
    {
        if (!_isRecording) return;
        var released = Stopwatch.StartNew();
        _isRecording = false;
        _captureCancel?.Cancel();
        var chunks = _live;
        _live = null;

        var target = _paster.Target();
        var samples = _recorder.Stop();
        if (_recorder.LostInput)
            StatusMessage = "Microphone disconnected mid-recording — only the audio before it was used";

        var duration = samples.Length / (double)SpeechSegmenter.SampleRate;
        if (duration < MinimumDuration)
        {
            FinishRelease();
            Recompute();
            return;
        }
        EnqueueTranscription(samples, chunks, target, duration, _recordingStartedAt, released);
        FinishRelease();
    }

    private void FinishRelease()
    {
        RestoreAudio();
        if (_settings.Sounds) _sounds.PlayStop();
    }

    private void CancelCapture()
    {
        if (!_isRecording)
        {
            // Esc after release: drop every dictation still being transcribed.
            if (_pendingTranscriptions > 0 && _cancelledThrough < _lastClipId)
            {
                _cancelledThrough = _lastClipId;
                if (_settings.Sounds) _sounds.PlayCancel();
                Log.Write("pending dictation cancelled");
            }
            return;
        }
        _isRecording = false;
        _captureCancel?.Cancel();
        _live = null;
        _recorder.Cancel();
        RestoreAudio();
        if (_settings.Sounds) _sounds.PlayCancel();
        Recompute();
    }

    private void RestoreAudio()
    {
        if (!_systemMuted) return;
        _muter.Restore();
        _systemMuted = false;
    }

    private void Recompute()
    {
        if (!_isRecording) IsHandsFree = false;
        State = _isRecording ? DictationState.Recording
            : _pendingTranscriptions > 0 ? DictationState.Transcribing
            : DictationState.Idle;
        Changed?.Invoke();
    }

    // Transcribe while recording

    /// Background transcripts of one recording's finished chunks. UI thread only.
    private sealed class LiveChunks
    {
        /// Samples already handed to the transcriber.
        public int Committed;
        /// Where each chunk in Texts began.
        public readonly List<int> Starts = new();
        public readonly List<string> Texts = new();
        public Task? InFlight;
        public bool Failed;
        /// Transcript of the audio from Start to End, made during a pause.
        public (int Start, int End, string Text)? Speculation;
    }

    /// Every tick, cut the audio pending since the last cut at a pause and transcribe it
    /// in the background, so on release only the tail is left to decode.
    private async Task ChunkLoopAsync(LiveChunks chunks, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(100, token);
            }
            catch (TaskCanceledException)
            {
                return;
            }
            if (_live != chunks || !_engine.IsReady) continue;
            TranscribeFinishedChunk(chunks);
        }
    }

    private void TranscribeFinishedChunk(LiveChunks chunks)
    {
        if (chunks.InFlight is { IsCompleted: false } || chunks.Failed) return;
        var pending = _recorder.Samples(chunks.Committed);
        if (SpeechSegmenter.NextCut(pending) is not int cut)
        {
            Speculate(pending, chunks);
            return;
        }
        var chunk = pending[..cut];
        chunks.Starts.Add(chunks.Committed);
        chunks.Committed += cut;
        chunks.InFlight = RunChunkAsync(chunks, chunk);
    }

    private async Task RunChunkAsync(LiveChunks chunks, float[] chunk)
    {
        try
        {
            chunks.Texts.Add(await _engine.TranscribeAsync(chunk));
        }
        catch (Exception e)
        {
            Log.Write($"chunk decode failed: {e.Message}");
            chunks.Failed = true;
        }
    }

    /// When the user pauses, transcribe everything pending since the last cut without
    /// cutting, so a release that follows the pause finds the tail already decoded.
    private void Speculate(float[] pending, LiveChunks chunks)
    {
        if (!SpeechSegmenter.EndsInPause(pending)) return;
        var start = chunks.Committed;
        if (chunks.Speculation is { } previous && previous.Start == start
            && SpeechSegmenter.QuietAfter(pending, 0, previous.End - start)) return;
        chunks.InFlight = RunSpeculationAsync(chunks, start, pending);
    }

    private async Task RunSpeculationAsync(LiveChunks chunks, int start, float[] pending)
    {
        try
        {
            var text = await _engine.TranscribeAsync(pending);
            chunks.Speculation = (start, start + pending.Length, text);
        }
        catch (Exception)
        {
            // A failed speculation only costs speed: release decodes the tail instead.
        }
    }

    /// Chunk transcripts first, then the tail. Falls back to the whole clip if any chunk failed.
    private async Task<string> TranscribeAsync(float[] samples, LiveChunks? chunks)
    {
        if (chunks == null) return await _engine.TranscribeAsync(samples);
        if (chunks.InFlight != null) await chunks.InFlight;
        if (chunks.Failed) return await _engine.TranscribeAsync(samples);
        var speculation = chunks.Speculation is { } s && s.Start == chunks.Committed ? (s.End, s.Text) : ((int, string)?)null;
        return await SpeechSegmenter.FinishAsync(samples, chunks.Starts, chunks.Texts, chunks.Committed, speculation,
            _engine.TranscribeAsync);
    }

    // Serial transcription pipeline

    /// Starts transcribing a finished clip right away, then pastes it once every earlier
    /// clip has pasted, so pastes land in the order the recordings finished.
    private void EnqueueTranscription(float[] samples, LiveChunks? chunks, PasteTarget target, double duration,
        DateTimeOffset startedAt, Stopwatch released)
    {
        var id = ++_lastClipId;
        _pendingTranscriptions++;
        Recompute();

        var transcribe = Stopwatch.StartNew();
        var transcription = TranscribeAsync(samples, chunks);
        var previous = _pipelineTail;
        _pipelineTail = Pipeline();

        async Task Pipeline()
        {
            await previous;
            string? raw = null;
            Exception? error = null;
            try
            {
                raw = await transcription;
            }
            catch (Exception e)
            {
                error = e;
            }
            try
            {
                await ProcessAsync(id, raw, error, samples, chunks?.Texts.Count ?? 0, target, duration, startedAt,
                    released, transcribe.ElapsedMilliseconds);
            }
            catch (Exception e)
            {
                Log.Write($"dictation {id} failed: {e}");
            }
            _pendingTranscriptions--;
            Recompute();
        }
    }

    private async Task ProcessAsync(int id, string? raw, Exception? error, float[] samples, int chunkCount,
        PasteTarget target, double duration, DateTimeOffset startedAt, Stopwatch released, long transcribeMs)
    {
        if (raw == null)
        {
            if (id <= _cancelledThrough) return;
            Log.Write($"transcribe failed: {error}");
            SetStatus($"Transcription failed: {error?.Message}");
            if (_settings.Sounds) _sounds.PlayError();
            return;
        }
        if (id <= _cancelledThrough)
        {
            Log.Write($"dictation {id} cancelled before paste");
            return;
        }

        var cleaned = _cleaner.Clean(raw);
        if (raw.Length == 0 && duration >= 1)
        {
            SetStatus("Didn't hear any speech — check the microphone input");
            if (_settings.Sounds) _sounds.PlayError();
        }
        else if (cleaned.Trim().Length == 0)
        {
            // Spoke only fillers ("um uh"): it lands in history but nothing pastes — say so.
            SetStatus("Only filler words heard — nothing to paste");
            if (_settings.Sounds) _sounds.PlayError();
        }

        var outcome = PasteResult.Pasted;
        if (cleaned.Trim().Length > 0)
        {
            // Wait out the whole caret lookup. The character before the cursor is
            // saved before the extra reads, so a timeout there still keeps the
            // leading space. Esc during this wait must still stop the paste.
            await target.Caret;
            if (id <= _cancelledThrough) return;
            outcome = await _paster.PasteAsync(cleaned, target);
        }
        var latency = released.ElapsedMilliseconds;
        if (outcome == PasteResult.CopiedAppChanged)
        {
            SetStatus("You switched windows while transcribing — text copied, press Ctrl+V to paste");
            if (_settings.Sounds) _sounds.PlayError();
        }
        Log.Write($"dictation done: audio={duration:F2}s chunks={chunkCount} transcribe={transcribeMs}ms " +
                  $"release→paste={latency}ms into={target.AppName} result={outcome}");

        var entry = new HistoryEntry(Guid.NewGuid().ToString().ToUpperInvariant(), startedAt, duration, raw, cleaned, (int)latency);
        LastResult = entry;
        Changed?.Invoke();
        var keep = _settings.KeepRecordings;
        _ = Task.Run(() =>
        {
            try
            {
                _history.Append(entry);
                if (keep) _recordings.Save(samples, entry.Id);
            }
            catch (Exception e)
            {
                Log.Write($"history write failed: {e.Message}");
            }
        });
    }
}
