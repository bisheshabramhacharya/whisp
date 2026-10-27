# Speed

Where the time goes between letting go of the key and the text appearing,
what made it faster, and what didn't. Numbers are from a base 8 GB M1 on the
owner's own recordings unless marked VM (an M4 virtual machine, no Neural
Engine: relative comparisons only).

## Where the time goes

Mic stop, text cleanup and the paste take a few milliseconds together. Almost
all of the wait is the speech model turning the last bit of audio into text.
The stock Parakeet encoder is traced at a fixed 15 s window, so a 2 s phrase
paid for 15 s of encoder work.

## What shipped

| Change | Measured on the M1 | Same words? |
|---|---|---|
| 5 s encoder window (`short`, the default) | clips under 5 s: 98.9 → 48.6 ms p50 (213 recordings) | identical on 213 + 220 recordings |
| Release replay, letting go right at the last word | wait p50 106 → 63 ms (40 recordings) | last word kept in every release |
| Release replay, letting go 100 ms after | wait p50 90 → 35–39 ms | same |
| Decode ahead after a 180 ms pause (was 200) | no-wait releases at +200 ms: 43% → 50% | same |
| Cleaner + dictionary warmed at launch | first dictation no longer pays 46–67 ms | same code, earlier |
| FluidAudio 0.15.7 → 0.17.4 | same speed | identical on 40 recordings |
| Wake the encoder size the release will need, while you talk | real-time replay of the last 40 dictations: p50 147 → 92 ms, p90 350 → 176, worst 504 → 221 | same decode, earlier wake-up |

## Measured dead ends

| Idea | Result | Status |
|---|---|---|
| Streaming decode while you talk (`streaming`) | ~88 ms flat on the VM, but loses or mishears the last word in ~5% of releases (vs ~1%) | opt-in only |
| Batched wide joint (FastRnnt) | M1: 160 / 177 ms vs 155 ms stock | removed |
| Second decode lane (`par2`) | helps p95 only when a release races a decode; +600 MB | opt-in only |
| Speculating after 150 ms pauses | dropped a quiet last word on the edge set | not used |
| Keeping the Neural Engine warm | idle penalty is only 10–15 ms on macOS 26 (was 60–120 ms); what does hurt is one encoder size sitting unused while the other runs (next run 250–465 ms), fixed above | not needed |
| Pause detection above 200 Hz, against the room's hum | long takes ~15 ms faster on average, but the last word was lost in 4 of 20 releases vs 1 of 20: cuts land right before the last word, which then decodes alone | not used |

## 10 s window (not measured here)

About a third of releases still waited over 100 ms because the speech after
the last pause was longer than 5 s, so it went to the 15 s encoder. Room
noise keeps the segmenter from finding those pauses, and cutting more often
dropped the last word, so the segmenter is unchanged.

`ShortWindowEngine` now also uses a 10 s encoder
(`parakeet_unified_encoder_w10000_int8`) when that bundle is on disk, with
the same smallest-window-that-fits rule as the 5 s one. A 7 s tail is one
full-attention pass, so the text matches the 15 s model; splitting it into
5 s pieces would not. The window is prewarmed the same way: while you talk,
the engine wakes the size a release of the audio so far would use.

It is a second int8 bundle, not one shared weight file. A multi-function
Core ML model only loads on macOS 15, and this app is macOS 14. The int8
quantizer also rejects multi-function models, and the constants baked at
trace time differ per window, so two bundles cannot share `weight.bin`.
One int8 window is about 560 MB on disk. How much resident memory grows
after load has not been measured.

The zip is not published yet. Until its SHA-256 is filled in on
`ShortWindowEngine.middleBundle`, the app does not try to download it.
Build it locally with `tools/convert` (`--windows 10 --install`). No speed
number for the 10 s window is claimed here: this environment cannot run Core ML.

## Reproduce

```sh
swift build -c release
swift run -c release whisp-tests

# one-time, on a Mac: build the 10 s encoder into the FluidAudio cache
cd tools/convert && uv sync
uv pip install --no-deps --force-reinstall \
  "nemo_toolkit @ git+https://github.com/NVIDIA-NeMo/NeMo.git@95f92737cfb8ee0123bb328b07a2d24c6d859aff"
uv run --no-sync python convert-short-window.py --windows 10 --validate --install
cd ../..

# The "short loaded windows" line must include 10s. "resident" is phys_footprint
# after prepare. Run it once without the bundle (move the .mlmodelc aside) and
# once with it; the difference is the 10 s encoder's resident cost. Use the
# second launch — the first also pays to compile the model.
.build/release/whisp-bench --replay --engine short --offsets 0 <one wav>

# Identical text. Use files whose speech is 5–10 s. agree must be 1.0000, and
# "short encoder decodes" must show a 10s bucket whose inputs sit in that range,
# not a 15s bucket. No warning about 5–10s audio on a larger window.
.build/release/whisp-bench --compare parakeet,short --runs 2 --idle 0 <5–10 s wavs>

# p95 wait at release, same files, bundle installed vs moved aside. Last-word
# ok must match. Read the numbers off the machine; they are not known yet.
.build/release/whisp-bench --replay --engine short <wavs>

# real time, through the app's own dictation code, next to what the app measured:
.build/release/whisp-bench --live --history ~/Library/Application\ Support/Whisp/history.jsonl \
  ~/Library/Application\ Support/Whisp/recordings/<id>.wav …
scripts/speed/m1-check.sh <folder of wavs> parakeet,short
```

Detailed logs: [log.md](log.md), [short window](log-b-short-window.md),
[streaming](log-c-streaming.md), [decoder and pipeline](log-d-decoder.md),
and the [full report](vm-report.md).
