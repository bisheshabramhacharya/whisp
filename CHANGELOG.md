# Changelog

## 0.2.0 — 2026-09-25

### Added
- **Cmd+Shift+V** re-pastes your last dictation at the cursor, so a take that landed in an app with no text field is one keystroke away.
- `install.sh`: a one-line installer that clones, builds and installs (`curl -fsSL https://whisper.bishesha.com/install.sh | bash`).
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
