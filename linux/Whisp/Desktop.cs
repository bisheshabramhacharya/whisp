using System.Buffers.Binary;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Whisp.Core;

namespace Whisp;

internal sealed class Capture : IAsyncDisposable
{
    private const int MaxBytes = 10 * 60 * Wav.SampleRate * sizeof(short);
    private readonly Process _mic;
    private readonly Task<byte[]> _read;

    public Capture(string[] args)
    {
        _mic = Desktop.Start("pw-record", args, output: true);
        _read = ReadAsync();
    }

    public static async Task<string[]> GetArgumentsAsync(CancellationToken cancellation)
    {
        var help = await Desktop.RunAsync("pw-record", ["--help"], null, cancellation);
        string[] args = ["--format", "s16", "--rate", "16000", "--channels", "1", "-"];
        return help?.Contains("--raw", StringComparison.Ordinal) == true ? ["--raw", ..args] : args;
    }

    private async Task<byte[]> ReadAsync()
    {
        using var bytes = new MemoryStream();
        var input = _mic.StandardOutput.BaseStream;
        var buffer = new byte[8192];
        while (bytes.Length < MaxBytes)
        {
            var count = await input.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, MaxBytes - bytes.Length)));
            if (count == 0) break;
            bytes.Write(buffer, 0, count);
        }
        if (bytes.Length == MaxBytes) Desktop.Terminate(_mic);
        return bytes.ToArray();
    }

    public async Task<float[]> FinishAsync()
    {
        var wasRunning = !_mic.HasExited;
        if (wasRunning)
        {
            Signal(_mic.Id, 15); // SIGTERM lets pw-record flush buffered PCM.
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            try { await _mic.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException) { Desktop.Terminate(_mic); }
        }
        var pcm = await _read;
        await _mic.WaitForExitAsync();
        if (!wasRunning && _mic.ExitCode != 0 && pcm.Length != MaxBytes)
            throw new IOException($"pw-record exited with status {_mic.ExitCode}.");
        var samples = new float[pcm.Length / sizeof(short)];
        for (var i = 0; i < samples.Length; i++)
            samples[i] = BinaryPrimitives.ReadInt16LittleEndian(pcm.AsSpan(i * sizeof(short))) / 32768f;
        return samples;
    }

    [DllImport("libc", EntryPoint = "kill")]
    private static extern int Signal(int pid, int signal);

    public async ValueTask DisposeAsync()
    {
        Desktop.Terminate(_mic);
        try { await _read; }
        catch (IOException) { }
        await _mic.WaitForExitAsync();
        _mic.Dispose();
    }
}

internal static class Desktop
{
    public static async Task<string?> FocusedWindowAsync(CancellationToken cancellation)
    {
        var output = await RunAsync("hyprctl", ["-j", "activewindow"], null, cancellation);
        if (output is null) return null;
        try
        {
            using var document = JsonDocument.Parse(output);
            return document.RootElement.TryGetProperty("address", out var address) ? address.GetString() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static async Task InsertAsync(string text, string? target, CancellationToken cancellation)
    {
        if (await RunAsync("wl-copy", [], text, cancellation, output: false) is null)
        {
            Console.Error.WriteLine("Whisp: could not type or copy the dictation.");
            return;
        }
        if (!string.IsNullOrEmpty(target) && target == await FocusedWindowAsync(cancellation))
        {
            if (await RunAsync("wtype", ["-M", "ctrl", "-k", "v", "-m", "ctrl"], null, cancellation) is not null) return;
        }
        Console.Error.WriteLine("Whisp: dictation copied; paste it where you want it.");
    }

    public static async Task<string?> RunAsync(string name, string[] args, string? input, CancellationToken cancellation,
        bool output = true)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(3));
        try
        {
            cancellation.ThrowIfCancellationRequested();
            using var process = Start(name, args, output, input is not null);
            using var onCancel = timeout.Token.Register(() => Terminate(process));
            if (input is not null)
            {
                await process.StandardInput.WriteAsync(input.AsMemory(), timeout.Token);
                process.StandardInput.Close();
            }
            var result = output ? await process.StandardOutput.ReadToEndAsync(timeout.Token) : "";
            await process.WaitForExitAsync(timeout.Token);
            return process.ExitCode == 0 ? result : null;
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception e) when (e is IOException or System.ComponentModel.Win32Exception)
        {
            cancellation.ThrowIfCancellationRequested();
            return null;
        }
    }

    public static Process Start(string command, string[] args, bool output, bool input = false)
    {
        var info = new ProcessStartInfo(command)
        {
            UseShellExecute = false,
            RedirectStandardOutput = output,
            RedirectStandardInput = input,
        };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return Process.Start(info) ?? throw new IOException($"could not start {command}");
    }

    public static void Terminate(Process process)
    {
        try { if (!process.HasExited) process.Kill(); }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }
}
