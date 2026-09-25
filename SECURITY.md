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
- The only network request Whisp makes is the one-time model download from
  Hugging Face.
- History, dictionary, and recordings live in
  `~/Library/Application Support/Whisp/`. Recordings are kept by default so
  you can build a fine-tuning set; **Keep recordings** in the menu turns that
  off.
- The global event taps match exactly two chords: Right Option (dictation)
  and Cmd+Shift+V (re-paste last). Every other keystroke passes through
  untouched.

## What we deliberately don't claim

- Whisp is not sandboxed: pasting into other apps requires Accessibility.
- The paste path simulates ⌘V, so the dictation briefly passes through the
  clipboard; your previous clipboard contents are restored afterwards.
- Disk encryption, other malware on your Mac, and anyone who can already read
  `~/Library/Application Support/Whisp/` are outside Whisp's threat model.
  That is FileVault's and macOS's job.

## Supported versions

Only the latest release is supported.
