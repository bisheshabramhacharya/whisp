using System.Runtime.InteropServices;
using Whisp.Core;
using Whisp.Core.Text;

internal static class CrashRecoveryTests
{
    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    public static async Task RunAsync(Action<string, string, string> expect, string root)
    {
        Directory.CreateDirectory(root);
        try
        {
            var paths = new AppPaths(root, Path.Combine(root, "models"));
            var pending = new PendingTakes(paths.PendingDirectory);
            var history = new HistoryStore(paths.HistoryFile);
            var date = new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.Zero);
            string PendingFile(string id) => Path.Combine(paths.PendingDirectory, id + ".wav");
            TakePersistence OpenApp() => new(new PendingTakes(paths.PendingDirectory), new HistoryStore(paths.HistoryFile),
                new RecordingArchive(paths.RecordingsDirectory), new FillerCleaner(), _ => { });
            void Check(bool condition, string label) => expect(condition ? "true" : "false", "true", label);

            pending.Save("round-trip", [0, 0.5f, -0.5f, 1, -1], date);
            expect(pending.List().Single().Id, "round-trip", "pending WAV is listed");
            var audio = pending.Load("round-trip");
            Check(audio.Length == 5 && Math.Abs(audio[1] - 0.5f) < 0.001f, "pending WAV round trip");
            File.WriteAllText(PendingFile("junk"), "not a wav");
            try
            {
                pending.Load("junk");
                Check(false, "corrupt pending WAV rejected");
            }
            catch (InvalidDataException)
            {
                Check(true, "corrupt pending WAV rejected");
            }
            pending.Remove("round-trip");
            pending.Remove("junk");
            Check(pending.List().Length == 0, "round-trip files retired");

            var firstRun = OpenApp();
            var samples = new float[Wav.SampleRate];
            Array.Fill(samples, 0.1f);
            await firstRun.StageAsync("normal", samples, date);
            expect(pending.List().Single().Id, "normal", "in-flight take has a pending WAV");
            await firstRun.CompleteAsync(new HistoryEntry("normal", date, 1, "normal take", "Normal take", 100), null);
            Check(pending.List().Length == 0, "finished take retires its pending WAV");

            var stage = firstRun.StageAsync("cancelled", samples, date.AddSeconds(1));
            await firstRun.DiscardAsync("cancelled");
            await stage;
            Check(pending.List().Length == 0, "cancel on an in-flight write retires the pending WAV");

            // Simulate process loss: stage on the first instance; replay with fresh app/storage objects.
            await firstRun.StageAsync("newer", new float[Wav.SampleRate * 2], date.AddSeconds(3));
            await firstRun.StageAsync("older", samples, date.AddSeconds(2));
            using (var chunk = new BinaryWriter(File.Create(PendingFile("bad"))))
            {
                chunk.Write("RIFF"u8);
                chunk.Write(12);
                chunk.Write("WAVE"u8);
                chunk.Write("JUNK"u8);
                chunk.Write(-8);
            }
            File.WriteAllText(PendingFile("orphan") + ".partial", "interrupted WAV write");

            var checkClipboard = OperatingSystem.IsWindows()
                && Environment.GetEnvironmentVariable("WHISP_TEST_RECOVERY_CLIPBOARD") == "1";
            var clipboardSequence = checkClipboard ? GetClipboardSequenceNumber() : 0;
            var replayed = new List<int>();
            var restarted = OpenApp();
            var status = await restarted.RecoverAsync(() => Task.CompletedTask, waveform =>
            {
                replayed.Add(waveform.Length);
                Check(waveform.Length != Wav.SampleRate || Math.Abs(waveform[0] - 0.1f) < 0.001f,
                    "restarted app decodes samples from the saved WAV");
                return Task.FromResult(waveform.Length == Wav.SampleRate
                    ? "um put it in agents dot md for twenty five dollars"
                    : "is the chat gpt tab working");
            }, keepRecordings: false);

            expect(string.Join(",", replayed), "16000,32000", "launch replays oldest first and ignores corrupt WAV");
            expect(string.Join(",", history.LoadLast(10).Select(entry => entry.Cleaned)),
                "Is the ChatGPT tab working?,Put it in AGENTS.md for $25.,Normal take", "restart saves CleanAndFormat text, newest first");
            var older = history.LoadLast(10)[1];
            Check(older.Id == "older" && older.Date == date.AddSeconds(2) && older.DurationSec == 1 && older.LatencyMs == 0,
                "replayed history entry keeps the take identity, date and duration");
            Check(!Directory.Exists(paths.RecordingsDirectory), "recovery respects Keep Recordings off");
            Check(!Directory.EnumerateFiles(paths.PendingDirectory).Any(), "replay consumes good/corrupt WAVs and stale partials");
            expect(status ?? "<null>", TakePersistence.RecoveredMessage, "recovery points to History");

            await firstRun.StageAsync("empty", samples, date.AddSeconds(4));
            var before = history.LoadLast(10).Count;
            expect((await OpenApp().RecoverAsync(() => Task.CompletedTask, _ => Task.FromResult(""), false)) ?? "<null>",
                "<null>", "empty transcript is not reported as recovered");
            Check(pending.List().Length == 0 && history.LoadLast(10).Count == before,
                "empty transcript retires its WAV without adding history");

            var blockedDir = Path.Combine(root, "broken-history.jsonl");
            Directory.CreateDirectory(blockedDir);
            var brokenHistory = new HistoryStore(blockedDir);
            var archive = new RecordingArchive(paths.RecordingsDirectory);
            var broken = new TakePersistence(pending, brokenHistory, archive, new FillerCleaner(), _ => { });
            await broken.StageAsync("blocked", samples, date.AddSeconds(5));
            await broken.StageAsync("can-save", new float[Wav.SampleRate * 2], date.AddSeconds(6));
            expect((await broken.RecoverAsync(() => Task.CompletedTask, waveform =>
            {
                if (waveform.Length == Wav.SampleRate * 2) Directory.Delete(blockedDir);
                return Task.FromResult("twenty five dollars to ship");
            }, keepRecordings: true)) ?? "<null>", TakePersistence.SaveFailedMessage,
                "history write failure outranks a successful replay in the same pass");
            expect(pending.List().Single().Id, "blocked", "history write failure leaves take for the next launch");
            expect(brokenHistory.LoadLast(1).Single().Id, "can-save", "other take still saves after a write failure");
            Check(File.Exists(Path.Combine(paths.RecordingsDirectory, "can-save.wav")), "recovery respects Keep Recordings on");

            // A crash after history append but before retirement must not duplicate history.
            pending.Save("can-save", samples, date.AddSeconds(6));
            var retry = new TakePersistence(pending, brokenHistory, archive, new FillerCleaner(), _ => { });
            expect((await retry.RecoverAsync(() => Task.CompletedTask, _ => Task.FromResult("retry the take"), true)) ?? "<null>",
                TakePersistence.RecoveredMessage, "next launch recovers the take whose write failed");
            expect(string.Join(",", brokenHistory.LoadLast(10).Select(entry => entry.Id)), "blocked,can-save",
                "a history entry already written is not duplicated");
            Check(pending.List().Length == 0, "successful retry retires pending WAVs");

            if (checkClipboard)
            {
                expect(GetClipboardSequenceNumber().ToString(), clipboardSequence.ToString(),
                    "native clipboard sequence unchanged during successful, empty and failed replay");
                Console.WriteLine("Crash recovery: checked Windows clipboard sequence number");
            }
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
