"""Generate a validation WAV with macOS `say` + `afconvert` — no binary audio
assets are committed to the repo. Used by convert-short-window.py --validate
and compare-models.py when no --audio-file is given.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

SAMPLE_RATE = 16000
DEFAULT_PATH = Path(__file__).parent / "audio" / "validation_16k.wav"

# ~3.5 s at say's default rate — fits the 5 s validation window.
_TEXT = "The quick brown fox jumps over the lazy dog near the river bank."


def ensure_audio(path: Path = DEFAULT_PATH) -> Path:
    """Return `path`, synthesizing ~5 s of 16 kHz mono speech if absent."""
    if path.exists():
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    aiff = path.with_suffix(".aiff")
    subprocess.run(["say", "-o", str(aiff), _TEXT], check=True)
    subprocess.run(
        [
            "afconvert", "-f", "WAVE", "-d", f"LEF32@{SAMPLE_RATE}", "-c", "1",
            str(aiff), str(path),
        ],
        check=True,
    )
    aiff.unlink()
    return path
