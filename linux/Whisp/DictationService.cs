using System.Net.Sockets;
using System.Text;
using Whisp.Core.Text;

namespace Whisp;

internal sealed class DictationService(SpeechEngine engine, FillerCleaner cleaner)
{
    public async Task RunAsync(Socket server, CancellationToken stop)
    {
        using var takeCancellation = CancellationTokenSource.CreateLinkedTokenSource(stop);
        var preparing = PrepareAsync(stop);
        var recordingArgs = Capture.GetArgumentsAsync(stop);
        Task pending = Task.CompletedTask;
        CancellationTokenSource? processing = null;
        Capture? capture = null;
        string? target = null;
        var buffer = new byte[32];

        try
        {
            while (!stop.IsCancellationRequested)
            {
                var length = await server.ReceiveAsync(buffer, SocketFlags.None, stop);
                switch (Encoding.ASCII.GetString(buffer, 0, length))
                {
                    case "press" when capture is null && pending.IsCompleted:
                        if (!preparing.IsCompletedSuccessfully || !preparing.Result)
                        {
                            Console.Error.WriteLine("Whisp: speech model is not ready.");
                            break;
                        }
                        try
                        {
                            capture = new Capture(await recordingArgs);
                            target = await Desktop.FocusedWindowAsync(stop);
                        }
                        catch (Exception e) when (!stop.IsCancellationRequested)
                        {
                            Console.Error.WriteLine($"Whisp: could not start mic: {e.Message}");
                        }
                        break;
                    case "release" when capture is not null:
                        processing?.Dispose();
                        processing = CancellationTokenSource.CreateLinkedTokenSource(takeCancellation.Token);
                        pending = CompleteAsync(capture, target, processing.Token);
                        capture = null;
                        break;
                    case "cancel":
                        processing?.Cancel();
                        if (capture is not null) await capture.DisposeAsync();
                        capture = null;
                        break;
                }
            }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested)
        {
        }
        finally
        {
            if (capture is not null) await capture.DisposeAsync();
            await pending;
            processing?.Dispose();
            await preparing;
            try { await recordingArgs; }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
        }
    }

    private async Task<bool> PrepareAsync(CancellationToken stop)
    {
        try
        {
            await engine.PrepareAsync(stop);
            return true;
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested)
        {
            return false;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"Whisp: could not prepare model: {e.Message} Restart Whisp to retry.");
            return false;
        }
    }

    private async Task CompleteAsync(Capture capture, string? target, CancellationToken cancellation)
    {
        try
        {
            var samples = await capture.FinishAsync();
            cancellation.ThrowIfCancellationRequested();
            var clean = cleaner.Clean(await engine.TranscribeAsync(samples));
            cancellation.ThrowIfCancellationRequested();
            if (!string.IsNullOrWhiteSpace(clean)) await Desktop.InsertAsync(clean, target, cancellation);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"Whisp: dictation failed: {e.Message}");
        }
        finally
        {
            await capture.DisposeAsync();
        }
    }
}
