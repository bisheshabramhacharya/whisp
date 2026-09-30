# Changelog

## 0.3.1 — 2026-09-30

### Fixed
- **No more 30–75 second freezes on long dictations.** When the audio left after the last pause was longer than 15 s (quiet speech, or the last chunk re-decoded with a quiet ending), Whisp loaded a second copy of the speech model at release, and Core ML sometimes rebuilt it from scratch. That audio is now split at its quietest points and decoded on the models already loaded: a real 58 s take that froze for 45 s decodes in 0.6 s.

### Changed
- While the speech model is still loading after launch, the recording pill says so ("Loading model…") and the menu explains that your words will be typed once it's ready, instead of looking frozen.
- The recording pill has a new look: a violet-to-cyan waveform that moves outward from the center while you talk, and a soft rolling wave while it transcribes.
- New app icon to match: glowing violet-to-cyan voice bars on a night-blue tile. The welcome window uses it too.
- The README now walks through install, permissions and first dictation step by step, with an uninstall section.

## 0.3.0 — 2026-09-29

### Added
- **Twice as fast on short phrases.** The encoder now runs at the shortest window that fits what you said instead of always 15 s: clips under 5 s decode in 49 ms instead of 99 ms (p50, 213 real dictations on a base 8 GB M1), with identical text on 433 recordings. The 5-second encoder (~525 MB) downloads in the background after the first launch and is checked against a SHA-256 before use.
- **Learns your corrections.** Fix a word by hand after Whisp pastes it and Whisp adds that fix to your dictionary: only the words you changed, never the text you type afterwards. Real words need to be fixed twice before they're learned. The menu shows what was learned, with Undo, and **Learn from my corrections** turns it off.
- Model status on hover, and a message when a dictation fails instead of silence.
- `whisp-bench --compare`, `--replay` and `--profile` for engine A/B tests, and `tools/convert` to rebuild the models from NVIDIA's checkpoint.

### Changed
- Decoding ahead starts after a 180 ms pause (was 350 ms), checked every 100 ms, so more releases find their text already done.
- The text cleaner and dictionary are warmed at launch, so the first dictation no longer pays 46–67 ms.
- Silence trimming uses a loudness reference that one cough can't skew, so quiet last words are no longer cut.
- Option+letter chords cancel the dictation only in the first second of a hold.
- FluidAudio 0.15.7 → 0.17.4.
- Data folder locked to your user account (0700/0600). Recordings are kept until you turn them off.

### Fixed
- **No more 300–500 ms stalls after a long dictation.** Whichever encoder size sat unused (the 5 s one during a long take, the 15 s one during short ones) went cold and was slow on its next run. Whisp now wakes the size the next release will need while you're still talking. Replaying the last 40 real dictations in real time: release→paste p50 147 → 92 ms, p90 350 → 176 ms, worst 504 → 221 ms.
- Esc no longer spends a decode on a cancelled clip; losing permissions stops the mic.
- The frontmost app is checked again right before ⌘V.
- System audio left muted by a crash is restored on the next launch.
- A damaged dictionary or corrections file is never overwritten.
- "the the" style doubles you meant ("I had had enough") are kept; clock times read "5:30".

## 0.2.0 — 2026-09-25

### Added
- **Cmd+Shift+V** re-pastes your last dictation at the cursor, so a take that landed in an app with no text field is one keystroke away.
- `install.sh`: a one-line installer that clones, builds and installs (`curl -fsSL https://raw.githubusercontent.com/bisheshabramhacharya/whisp/main/install.sh | bash`).
- `SECURITY.md`: the threat model and how to report a vulnerability.

### Changed
- New app icon in the shared ivory family (was indigo/violet). `scripts/make-icon.sh` now also refreshes `docs/icon.png`.
- The idle menu-bar icon uses the shared `MenuBarIcon` style.
- Transcription starts while you still talk: audio is cut at natural pauses and decoded in the background, so a two-minute ramble pastes as fast as a one-liner.
- Faster release path: median key-release-to-paste is 0.15 s over 56 real dictations on a base 8 GB M1; mic stop dropped from 40 ms to 1 ms.
- "Fix a Misheard Word…" menu item appends to your personal dictionary.
- Esc cancels even right after you let go; if focus moves to another app mid-transcription, the text is copied instead of lost.

### Fixed
- Reliability gaps in the dictation pipeline: mic device changes, stale clipboard snapshots, permission re-grants, and failed model loads are all handled.

## 0.1.0 — 2026-09-22

First working build: hold Right Option and talk, let go, and your words are typed at the cursor. Parakeet Unified 0.6B on the Neural Engine, filler and stutter cleanup, misheard-word dictionary, history, resizable pill.
