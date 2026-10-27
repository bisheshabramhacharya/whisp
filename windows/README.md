# Whisp for Windows

Hold **Right Alt**, say what you want to write, and let go. Your words are typed
wherever the cursor is: Slack, Outlook, Word, Notepad, VS Code, a browser tab.
Same as Whisp on the Mac — same speech model family, same cleanup rules, same
dictionary file — and just as private: everything runs on your PC.

## What you need

| | |
|---|---|
| **PC** | 64-bit Windows 10 or 11 on an Intel or AMD processor |
| **Memory** | 8 GB is plenty (Whisp uses about 1.2 GB while running) |
| **Disk** | About 1 GB: 660 MB for the speech model, the rest for the app (2.9 GB more if you switch to Cohere) |
| **Internet** | Only to install and to download the speech model once |
| **Language** | English |

No graphics card needed: the model runs on the CPU, about 15–20× faster than
real time on a desktop Ryzen 7.

## Install

Open **PowerShell** (press Start, type *PowerShell*, press Enter), paste this
line and press Enter:

```powershell
irm https://raw.githubusercontent.com/bisheshabramhacharya/whisp/main/windows/install.ps1 | iex
```

The installer downloads the latest release, builds it on your PC (installing
a private copy of the .NET 8 SDK if you don't have one — no admin rights
needed), installs Whisp to `%LOCALAPPDATA%\Programs\Whisp`, adds it to the
Start menu, and starts it. A welcome window shows how to dictate while the
speech model (about 660 MB) downloads in the background.

**Updating:** run the same line again. You keep your settings, history and words.

**Uninstalling:** *Settings › Apps › Installed apps › Whisp › Uninstall*. Your
dictionary and history in `%APPDATA%\Whisp` are kept; delete that folder to
remove them too.

> **Using Wispr Flow or Willow?** Quit it first if it listens to the same key.

## How to use it

| Do this | What happens |
|---|---|
| **Hold Right Alt**, talk, let go | Your words are typed at the cursor |
| **Double-tap Right Alt** | Hands-free: keeps listening until you press it again |
| **Esc** | Cancels, even right after you let go |
| **Ctrl+Alt+V** | Types your last dictation again |
| **Drag the pill** | Moves it. It stays where you put it. Right-click it for the menu. |
| Tray icon → **Fix a Misheard Word…** | Teach Whisp a word it got wrong |
| Tray icon → **History** | Click any past dictation to copy it |
| Tray icon → **Recording Pill** | Tiny, Small or Large, always shown or only while talking |
| Tray icon → **Push-to-Talk Key** | Right Alt or Right Ctrl |
| Tray icon → **Speech Model** | Parakeet (default) or Cohere Transcribe — see [Choosing the model](#choosing-the-model) |

Whisp lives in the system tray, by the clock (click the **^** if it's hidden;
drag it onto the taskbar to keep it in view). On keyboard layouts where Right
Alt is **AltGr** (German, French, Polish, …), pick **Right Ctrl** instead.

Right Alt still works in shortcuts: pressing another key in the first second of
a hold cancels the dictation and lets the shortcut through.

## Bring your Mac's words, history and settings

On the Mac, open Terminal and run:

```sh
curl -fsSL https://raw.githubusercontent.com/bisheshabramhacharya/whisp/main/scripts/export-for-windows.sh | sh
```

It saves `whisp-export.zip` on your Desktop with your dictionary, history,
recordings and menu settings (`WHISP_EXPORT_RECORDINGS=0` leaves recordings
out). Copy it to the PC (AirDrop to your phone, a USB stick, iCloud Drive, or
email), then pick **Import from Mac…** in the Whisp tray menu or the welcome
window.

Importing merges; nothing on the PC is overwritten. Dictionary words and
replacements are added, history entries are added by id, recordings are copied
when missing, and sounds / mute / keep recordings / pill size come from the Mac.
The Mac's pill position and hotkey don't carry over (different screens and
keyboards).

## Files

The data folder mirrors the Mac's `~/Library/Application Support/Whisp`, and
the files are interchangeable in both directions:

| | |
|---|---|
| `%APPDATA%\Whisp\dictionary.json` | Your words — same format as on the Mac (see the main README) |
| `%APPDATA%\Whisp\history.jsonl` | Past dictations |
| `%APPDATA%\Whisp\recordings\` | WAVs, if **Keep Recordings** is on |
| `%APPDATA%\Whisp\settings.json` | Menu settings |
| `%APPDATA%\Whisp\whisp.log` | Timings and errors (never what you said) |
| `%LOCALAPPDATA%\Whisp\Models\` | The speech model |

Edits to `dictionary.json` apply to your next dictation; **Edit Dictionary…**
in the tray menu opens it in Notepad.

## How it differs from the Mac version

- **Speech model.** The same NVIDIA Parakeet Unified 0.6B model, run by
  [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) on the CPU (int8 ONNX
  export, [csukuangfj2/sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming](https://huggingface.co/csukuangfj2/sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming),
  pinned by SHA-256) instead of Core ML on the Neural Engine. See
  [Choosing the model](#choosing-the-model).
- **No permissions to grant.** Windows doesn't gate keyboard hooks or typing
  into other apps. If the microphone is blocked, turn on *Settings › Privacy &
  security › Microphone › Let desktop apps access your microphone*.
- **Not yet ported:** learning from corrections you make by hand after a paste
  (use **Fix a Misheard Word…**), and the multi-step guided setup (Windows gets
  one welcome page).
- Whisp can't type into apps running as administrator (Windows blocks it).

## Choosing the model

Every speech model sherpa-onnx can run that is competitive on the
[Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)
was measured on a desktop PC (Ryzen 7 5700G, 8 cores, 32 GB) over 200
LibriSpeech test utterances — 100 from test-clean and 100 from the harder
test-other — with the same text normalization for all:

| Model | Download | Word errors, clean | Word errors, harder | Short clip (< 6 s)¹ | 6–15 s clip¹ | Memory |
|---|---|---|---|---|---|---|
| **Parakeet Unified 0.6B int8** (default) | 660 MB | 1.21% | 2.76% | **0.26 s** | **0.48 s** | 1.2 GB |
| Parakeet Unified 0.6B fp32 | 2.4 GB | 1.11% | 2.82% | 0.31 s | 0.59 s | 3.0 GB |
| Parakeet TDT 0.6B v2 int8 | 630 MB | 1.11% | 2.98% | 0.24 s | 0.48 s | 1.1 GB |
| Cohere Transcribe 2B int8 | 2.9 GB | **0.90%** | **2.27%** | 0.69 s | 1.43 s | 3.7 GB |
| Qwen3-ASR 0.6B int8 | 940 MB | 2.36% | 3.68% | 0.74 s | 1.52 s | 3.4 GB |

¹ Median time to transcribe, 8 threads. Parakeet Unified int8 and Cohere were
timed again with nothing else running; the other rows overlapped other work and
may be a little slow.

**Parakeet Unified int8 is the default.** It's the Mac app's model, and it
transcribes about 2.7× faster than Cohere for close to the same accuracy. On
audiobooks Cohere makes slightly fewer mistakes (mostly rare names from old
novels), but on dictation-style test phrases Parakeet did better: it wrote
"Kubernetes" and "5:30" where Cohere wrote "Kibernets" and "5 30". If you
want to try Cohere anyway, pick it under **Speech Model** in the tray menu; it
downloads once (2.9 GB) and you can switch back at any time.

**Graphics cards.** sherpa-onnx has a CUDA build, and it was tried on a GTX 1070
(Pascal): the int8 models ran about 5× *slower* than on the CPU, the fp32
model failed to start (current cuDNN no longer supports Pascal), and Cohere
returned empty transcripts. A GPU would also mean a ~3 GB download of NVIDIA
libraries, so Whisp runs on the CPU only.

## Development

```powershell
dotnet run --project windows/WhispTests -c Release     # tests (same cleanup/dictionary/hotkey tables as the Mac)
dotnet run --project windows/Whisp                     # run the app
dotnet publish windows/Whisp -c Release -r win-x64 --self-contained -o dist  # what install.ps1 builds
$env:WHISP_SRC = (Get-Location); ./windows/install.ps1 # install from this checkout
```

`Whisp.exe --transcribe clip.wav` prints the raw and cleaned transcript of a
16 kHz mono WAV. `WHISP_HOME` and `WHISP_MODELS` move the data and model
folders; `WHISP_TEST_MIC=a.wav;b.wav` replays WAVs instead of the microphone
(one per dictation) for end-to-end tests.

The Mac build traces the Core ML encoder at a fixed length, so a long tail
uses a 5 s or 10 s window instead of always paying for 15 s. This build's
ONNX encoder already takes the audio's own length, and its time scales with
the clip (see the table above), so those extra bundles are not ported.

```
windows/WhispCore    text cleanup, dictionary, hotkey state machine, segmenter, storage, Mac import
                     (line-for-line ports of Sources/WhispCore; no Windows APIs, so it's testable anywhere)
windows/Whisp        tray app: keyboard hook, mic, sherpa-onnx engine, paster, recording pill
windows/WhispTests   test runner
windows/install.ps1  installer; uninstall.ps1 is copied next to the app
```
