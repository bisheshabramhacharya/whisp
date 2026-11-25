using Velopack;
using Velopack.Sources;

namespace Whisp;

internal static class ReleaseUpdates
{
    internal static async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            var source = new GithubSource("https://github.com/bisheshabramhacharya/whisp", null, prerelease: false);
            var manager = new UpdateManager(source);
            if (!manager.IsInstalled)
                return;

            using var timer = new PeriodicTimer(TimeSpan.FromHours(6));
            do
            {
                try
                {
                    if (manager.UpdatePendingRestart != null)
                        return;
                    var update = await manager.CheckForUpdatesAsync();
                    if (update != null)
                    {
                        await manager.DownloadUpdatesAsync(update, cancelToken: cancellationToken);
                        Log.Write("Whisp update downloaded; it will install on next launch.");
                        return;
                    }
                }
                catch (Exception e) when (!cancellationToken.IsCancellationRequested)
                {
                    Log.Write($"update check: {e.Message}");
                }
            } while (await timer.WaitForNextTickAsync(cancellationToken));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception e)
        {
            Log.Write($"updater: {e.Message}");
        }
    }
}
