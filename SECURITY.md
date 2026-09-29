# Security Policy

Whisp is a local dictation app that holds three powerful macOS grants —
Microphone, Input Monitoring, and Accessibility — so it holds itself to a
high bar.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting:
https://github.com/bisheshabramhacharya/whisp/security/advisories/new

Include steps to reproduce and, if you can, a log excerpt:

```sh
log stream --predicate 'subsystem == "com.bishesha.whisp"'
```

Expect a reply within a week.

## What Whisp does with your data

- Audio is recorded only while the hotkey is held (or hands-free mode is on).
- Transcription runs on-device via FluidAudio and NVIDIA's Parakeet. No cloud.
- The only network requests Whisp makes are one-time model downloads: the
  speech model from Hugging Face (re-fetched automatically if the local copy
  is missing or corrupt) and the 5-second encoder from this repo's `models-v1`
  GitHub release, which is rejected unless its SHA-256 matches the value
  compiled into the app. No audio, text, or usage data is ever sent.
- History, dictionary, and recordings live in
  `~/Library/Application Support/Whisp/` (locked to your user account,
  0700/0600). Recordings are kept by default so you can build a fine-tuning
  set. **Keep recordings** in the menu turns recording off entirely.
- The two global event taps are session-level and see only this login
  session's keystrokes. The dictation tap (Right Option) is **listen-only**:
  it can observe but cannot consume or inject events. The re-paste tap
  (Cmd+Shift+V) is **active** and swallows that one chord system-wide —
  apps that use Cmd+Shift+V for paste-without-formatting never see it
  while Whisp runs. Every other keystroke passes through both taps
  untouched; nothing read by the taps is stored or logged.

## What we deliberately don't claim

- Whisp is not sandboxed: pasting into other apps requires Accessibility.
- The paste path simulates ⌘V, so the dictation briefly passes through the
  clipboard; your previous clipboard contents are restored afterwards.
- Disk encryption, other malware on your Mac, and anyone who can already read
  `~/Library/Application Support/Whisp/` are outside Whisp's threat model.
  That is FileVault's and macOS's job.

## Supported versions

Only the latest release is supported.
