using Whisp.Core.Text;

namespace Whisp.Core;

/// Serializes pending WAV and history writes without blocking the dictation UI.
public sealed class TakePersistence(PendingTakes pending, HistoryStore history, RecordingArchive recordings,
    FillerCleaner cleaner, Action<string> log)
{
    public const string SaveFailedMessage = "Couldn't save that take — check disk space and file permissions";
    public const string RecoveryFailedMessage = "Couldn't recover every unsaved take — Whisp will retry next time";
    public const string RecoveredMessage = "Recovered a take the app lost — find it in History";

    private readonly object _gate = new();
    private Task _writes = Task.CompletedTask;

    private Task<T> Enqueue<T>(Func<T> work)
    {
        lock (_gate)
        {
            var next = _writes.ContinueWith(_ => work(), CancellationToken.None,
                TaskContinuationOptions.None, TaskScheduler.Default);
            _writes = next;
            return next;
        }
    }

    public Task StageAsync(string id, float[] samples, DateTimeOffset date) =>
        Enqueue(() => TryWrite("pending WAV save", () => pending.Save(id, samples, date)));

    public Task DiscardAsync(string id) =>
        Enqueue(() => TryWrite("pending WAV removal", () => pending.Remove(id)));

    public Task<bool> CompleteAsync(HistoryEntry entry, float[]? samples) =>
        Enqueue(() => TryWrite("history append", () => history.Append(entry)) && ArchiveAndRetire(entry.Id, samples));

    public Task FlushAsync()
    {
        lock (_gate) return _writes;
    }

    public async Task<string?> RecoverAsync(Func<Task> prepare, Func<float[], Task<string>> transcribe, bool keepRecordings)
    {
        PendingTakes.Take[] takes;
        try
        {
            takes = await Enqueue(() =>
            {
                TryWrite("partial WAV cleanup", pending.RemovePartials);
                return pending.List();
            });
        }
        catch (Exception e) when (IsFileError(e))
        {
            log($"pending WAV listing failed: {e.Message}");
            return RecoveryFailedMessage;
        }
        if (takes.Length == 0) return null;

        try
        {
            await prepare();
        }
        catch (Exception e)
        {
            log($"pending take preparation failed: {e.Message}");
            return RecoveryFailedMessage;
        }

        HashSet<string> savedIds;
        try
        {
            savedIds = await Enqueue(() => history.LoadAll().Select(entry => entry.Id).ToHashSet(StringComparer.Ordinal));
        }
        catch (Exception e) when (IsFileError(e))
        {
            log($"history read for recovery failed: {e.Message}");
            return SaveFailedMessage;
        }

        var recovered = false;
        var recoveryFailed = false;
        var writeFailed = false;
        foreach (var take in takes)
        {
            var historyAlreadySaved = savedIds.Contains(take.Id);
            if (historyAlreadySaved && !keepRecordings)
            {
                await DiscardAsync(take.Id);
                continue;
            }

            float[] samples;
            try
            {
                samples = await Task.Run(() => pending.Load(take.Id));
            }
            catch (Exception e) when (e is InvalidDataException or EndOfStreamException)
            {
                log($"pending WAV is corrupt: {e.Message}");
                await DiscardAsync(take.Id);
                continue;
            }
            catch (Exception e) when (IsFileError(e))
            {
                log($"pending WAV read failed: {e.Message}");
                recoveryFailed = true;
                continue;
            }

            if (samples.Length == 0)
            {
                await DiscardAsync(take.Id);
                continue;
            }

            if (historyAlreadySaved)
            {
                writeFailed |= !await Enqueue(() => ArchiveAndRetire(take.Id, samples));
                continue;
            }

            string raw;
            try
            {
                raw = await transcribe(samples);
            }
            catch (Exception e)
            {
                log($"pending take transcription failed: {e.Message}");
                recoveryFailed = true;
                continue;
            }

            var text = cleaner.CleanAndFormat(raw);
            if (string.IsNullOrWhiteSpace(text))
            {
                await DiscardAsync(take.Id);
                continue;
            }

            var entry = new HistoryEntry(take.Id, take.Date, samples.Length / (double)Wav.SampleRate, raw, text, 0);
            if (await CompleteAsync(entry, keepRecordings ? samples : null)) recovered = true;
            else writeFailed = true;
        }

        if (writeFailed) return SaveFailedMessage;
        if (recoveryFailed) return RecoveryFailedMessage;
        return recovered ? RecoveredMessage : null;
    }

    private bool ArchiveAndRetire(string id, float[]? samples) =>
        (samples == null || TryWrite("recording archive save", () => recordings.Save(samples, id)))
        && TryWrite("pending WAV removal", () => pending.Remove(id));

    private bool TryWrite(string operation, Action write)
    {
        try
        {
            write();
            return true;
        }
        catch (Exception e) when (IsFileError(e))
        {
            log($"{operation} failed: {e.Message}");
            return false;
        }
    }

    private static bool IsFileError(Exception e) => e is IOException or UnauthorizedAccessException;
}
