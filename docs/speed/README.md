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
| Refuse a cut only when louder speech follows (see [quiet takes](#quiet-takes-refuse-a-cut-only-when-louder-speech-follows)) | long bucket worst 9329 → 151 ms; 9 1/2 min take 6124 → 4 ms; 8 min take 2799 → 2 ms | WER identical on all three sets |

## Quiet takes: refuse a cut only when louder speech follows

The scoreboard's first real run found the worst number in the product: the long
bucket (5+ minute takes) p50 167 ms but a worst case of 9329 ms. It is one
9 1/2 minute recording, which reproduces at 6124 ms through the app's own
dictation path (`--live`) and shows 6429 ms in the app's own history.

That recording sits under the segmenter's absolute near-silence test the whole
way (RMS 0.0027, peak 0.011, apart from one click). `nextCut` refuses a cut when
the audio before it fails that test, and it has to: a quiet chunk sent to the
transcriber alone comes back empty, so the segmenter keeps it attached to louder
speech that follows. On a take recorded quietly from start to finish there is no
louder speech to attach to, so every cut was refused: the live loop committed
nothing after the first 28 s, the release had 536 s left, and it decoded that in
15 s windows — 6103 ms of decode in one release, with no decode at all for the
43 s before the key came up.

The rule now asks the question it means: `cutDropsQuietSpeech` refuses a cut only
when the audio before it is quiet next to absolute levels **and** the audio after
it is not. On a loud take the first test already answers "not quiet", so every
loud take decodes exactly as before; the scoreboard's owner-recording comparison
is what proves it.

| | before | after |
|---|---|---|
| scoreboard long bucket (5+ min, n=3) | p50 167, worst 9329 ms | p50 5, p95 151, worst 151 ms |
| 9 1/2 min take, release to paste (`--live`) | 6124 ms (app: 6429) | 4 ms |
| 8 min take, release to paste (`--live`) | 2799 ms (app) | 2 ms |
| decode in one release, 9 1/2 min take | 6103 ms, 536 s of audio | none |
| chunks cut on the 9 1/2 min take | 2 | 47 |
| longest gap with no decode before release | 43448 ms | 5533 ms |

The scoreboard's whole table after the change, same sample as the recorded
baseline: short p50 84 / p95 219 / worst 248 ms (was 88 / 461 / 795), average
p50 105 / 243 / 243 (was 100 / 247 / 247), long as above. WER unchanged on all
three sets: test-clean 1.70, test-other 3.19, dictation 4.55.

`swift run -c release whisp-tests` passes 497/497. The owner-recording row moved
the other way: same-or-better 96.2% (was 100%) and 1 new dropped last word, on
three takes of 17.3, 35.9 and 43.1 s that start with silence, where the new rule
now cuts inside that silence instead of leaving it attached to the speech that
follows. That row is noisy at n=78 — the same baseline code measured the same
9 1/2 minute take at 9329, 4675 and 5981 ms in three runs, and one baseline run
differed from the recorded baseline on a 5.5 s take that has no cuts to move —
but the machine (five threads on one 8 GB M1) was too busy to get a clean
same-code repeat, so this is unproven rather than cleared.

## Measured dead ends

| Idea | Result | Status |
|---|---|---|
| Streaming decode while you talk (`streaming`) | ~88 ms flat on the VM, but loses or mishears the last word in ~5% of releases (vs ~1%) | opt-in only |
| Batched wide joint (FastRnnt) | M1: 160 / 177 ms vs 155 ms stock | removed |
| Second decode lane (`par2`) | helps p95 only when a release races a decode; +600 MB | opt-in only |
| Speculating after 150 ms pauses | dropped a quiet last word on the edge set | not used |
| Keeping the Neural Engine warm | idle penalty is only 10–15 ms on macOS 26 (was 60–120 ms); what does hurt is one encoder size sitting unused while the other runs (next run 250–465 ms), fixed above | not needed |
| Pause detection above 200 Hz, against the room's hum | long takes ~15 ms faster on average, but the last word was lost in 4 of 20 releases vs 1 of 20: cuts land right before the last word, which then decodes alone | not used |

## 10 s window

About a third of releases still waited over 100 ms because the speech after
the last pause was longer than 5 s, so it went to the 15 s encoder. Room
noise keeps the segmenter from finding those pauses, and cutting more often
dropped the last word, so the segmenter is unchanged.

On the VM (`short`, 330 files, release at +0 ms) those leftovers fall into two
buckets: 5–10 s (11.8% of releases) waits p50 164 / p95 177 ms and 10–15 s
(7.3%) 179 / 201 ms, both paying the 15 s encoder's flat cost. The 10 s window
takes the first bucket to **130 / 161 ms** with transcripts identical to the
15 s window, and the second to 168 / 175 ms. VM numbers only — the M1 verdict
is `scripts/speed/m1-check.sh`. A piecewise alternative that decoded two
overlapped 5 s pieces also measured faster on the 5–10 s bucket (164 → 150 ms
VM) but was not shipped, so there is no `split` engine to pass to `--engine`
(see [log-e](log-e-split-and-w10000.md)); 10–15 s has no cheaper option at the
same weights either, because two pieces on any window cost more than one 15 s
pass.

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
One int8 window is about 560 MB on disk. Latency is pending a Mac run.
Per-process `phys_footprint` (and `footprint -p`) does not include the Core ML
encoders: with the 5 s and 15 s int8 encoders loaded, about 1.1 GB of weights,
both read 74 MB. That memory sits outside the whisp process, most likely in
the Neural Engine daemon, so no per-process number can see it. The bench
prints a system-wide `vm_stat` delta around model load (free, wired,
anonymous, compressor). Compare that delta with the 10 s bundle installed and
with it moved aside.

The zip is not published yet, so `ShortWindowEngine.middleBundle.sha256` is
empty and the app does not download the 10 s window; a bundle already on disk
is used without a checksum. Follow-up: publish
`parakeet_unified_encoder_w10000_int8.mlmodelc.zip` on `models-v2` and paste
its SHA-256 into `middleBundle` (see `tools/convert/RELEASE.md`). The number
recorded for the drafted zip is
`ba03f26fd519b193f76701a26a13680714d8dc0861a623e42e57ffd887f1cb50` — re-hash
it if the bundle is rebuilt, and do not paste a number you have not verified.
Once that checksum lands the bundle is fetched on launch like the 5 s one, so
the download is gated on publishing, not opt-in. Until then `--install` copies
a locally built bundle into the FluidAudio model cache, which is the directory
the engine scans, and `WHISP_MODEL_DIR` points the bench at another folder of
the same files.

## Scoreboard

One command, on the Mini, prints the wait, the accuracy and the last-word
delta for whatever the tree currently builds:

```sh
scripts/speed/scoreboard.sh            # measure and print
scripts/speed/scoreboard.sh --record   # also write docs/speed/scoreboard/
```

Wait is key release to text appearing, measured by real-time replay of the
owner's own recordings through the app's dictation path (`whisp-bench --live`),
bucketed by how long the speech is: short 1-10 s, average 10-60 s, long 5+ min.
Replay runs in real time, so the buckets are sampled to fit a 45 minute run;
the rule and the sample size are printed with the table. Each bucket's p50 is
checked against its target (38 / 40 / 46 ms) and every bucket against 100 ms.

Accuracy is WER on LibriSpeech test-clean and test-other and on the `say`-made
dictation set, which is labelled a casual stand-in: `WHISP_CASUAL_SET=<dir>`
swaps in a real casual set (one `<file>.wav` plus `<file>.txt` per clip). The
last-word gate compares each recording's text against the recorded baseline
build: same or better means no word the baseline heard went missing, and a new
dropped last word is a recording whose last word changed. Zero is the gate.

A run takes the benchmark lock first, so nothing else on the Mini can be
measuring at the same time. Per-file results are cached under
`~/.whisp-scoreboard-cache` and keyed by the sha256 of the built `whisp-bench`
plus the engine flags, so a repeat run on the same binary is near instant
(seconds) and a rebuilt engine always replays; `--force` ignores the cache.
`--record` writes `baseline-<engine sha>.json`, `latest.json` and `latest.md`.
Only aggregates land there: no audio, no transcripts, no recording names, ever.

The last-word delta compares against the recorded baseline build, which needs
that build's cached per-file rows. If the cache is wiped, run the scoreboard
once on the baseline build to restore them, or the accuracy row reads `n/a`
rather than a made-up number.

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

# "short loaded windows" must include 10s. phys_footprint is process-only and
# excludes the encoders (74 MB with the 5 s and 15 s bundles loaded). Read the
# "system memory (vm_stat)" line. Run once with the bundle and once with it
# moved aside, and keep the second launch of each — the first also compiles
# the model. The difference between those deltas is pending that Mac run.
.build/release/whisp-bench --replay --engine short --offsets 0 <one wav>

# Identical text. Use files whose speech is 5–10 s. agree must be 1.0000, and
# "short encoder decodes" must show a 10s bucket whose inputs sit in that range,
# not a 15s bucket. No warning about 5–10s audio on a larger window.
.build/release/whisp-bench --compare parakeet,short --runs 2 --idle 0 <5–10 s wavs>

# p95 wait at release, same files, bundle installed vs moved aside. Last-word
# ok must match. The p95 numbers are pending that Mac run.
.build/release/whisp-bench --replay --engine short <wavs>

# real time, through the app's own dictation code, next to what the app measured:
.build/release/whisp-bench --live --history ~/Library/Application\ Support/Whisp/history.jsonl \
  ~/Library/Application\ Support/Whisp/recordings/<id>.wav …
scripts/speed/m1-check.sh <folder of wavs> parakeet,short
```

Detailed logs: [log.md](log.md), [short window](log-b-short-window.md),
[streaming](log-c-streaming.md), [decoder and pipeline](log-d-decoder.md),
[split + 10 s window](log-e-split-and-w10000.md),
and the [full report](vm-report.md).
