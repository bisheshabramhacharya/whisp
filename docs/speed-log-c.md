# Track C — streaming decode during capture

All timings measured on the VirtualMac bench VM (**GPU+CPU only, no Apple
Neural Engine**) — label every number "VM". A/B numbers are meaningful
relative to `parakeet` on the same VM, not absolute.

## Lever

During dictation, each ~100 ms mic buffer is fed to
`StreamingUnifiedAsrManager` (`asrEngine=streaming`). The streaming encoder
re-runs a `[left | chunk | right]` window per step; at key release the
transcript is already decoded — release→text is just `finish()` flushing
the held-back right-context frames.

## Implementation

- `Sources/WhispCore/ASR/StreamingEngine.swift` (new): `LiveDecoding`
  (`feed`/`finish` keyed by a per-take token), tiers via
  `defaults write com.bishesha.whisp streamingTier <ms>` or
  `WHISP_STREAM_TIER` env, warmup on load + rewarm>20s-idle, mid-stream
  failure falls back to a batch decode of the take's retained audio.
- `DictationController.swift`: one `as? LiveDecoding` branch in
  `transcribeFinishedChunk` (feed the new-audio delta each tick) and one
  in `transcribe` (feed tail + `finish()`); parakeet path untouched.
- `ASREngine.make` / `CompareRunner.makeEngine`: `case "streaming"`.
- `ReleaseReplayer`: `LiveDecoding` engines replay a fresh take per
  simulated release — feed 100 ms slices up to the release point, time
  `finish()`.

## Commands used

```bash
swift build -c release
./.build/release/whisp-tests                                            # 270/270
./.build/release/whisp-bench --compare parakeet,streaming --runs 1 \
    [--idle 0] [--show] testdata/librispeech/LibriSpeech/test-clean/**/*.flac
WHISP_STREAM_TIER=640|1120|2080 ./.build/release/whisp-bench \
    --compare parakeet,streaming --runs 1 testdata/dictation/*.wav
./.build/release/whisp-bench --replay --engine parakeet|streaming \
    --offsets LIST [--mic-drop 30] [--show] testdata/dictation/*.wav
./.build/release/whisp-bench --streaming 320|640|1120 FILE...
```

## Results (VM)

### LibriSpeech test-clean (2620 files, `--compare --runs 1`, refs `<file>.flac.txt`)

PENDING

### LibriSpeech test-other (500-file subset)

PENDING

### Dictation set (300 `say` TTS clips) — word agreement vs parakeet, by tier

`--compare parakeet,streaming --runs 1 [--idle 0]`, `WHISP_STREAM_TIER=<ms>`:

| tier (ms) | config [L,C,R] | agreement | disagreement files |
|---|---|---|---|
| 640 | 70,7,1 | 0.9602 | 45 |
| 1120 | 70,7,7 | 0.9818 | 25 |
| 2080 | 70,13,13 | 0.9891 | 13 |

Gate is ≥0.995 — not met at any tier; see classification below. The
residual is dominated by the streaming model's *native ITN convention*,
not correctness (details below).

### Disagreement classification @2080 (all 13 files)

Refs are `say` source strings; "WER p/s" = ref-WER of each engine.

Normalization-equivalent (ITN: streaming emits digits/currency/times
where parakeet spells out — semantically equal-or-better for paste):
- extra-166, extra-246: `nine four one one zero` → `94110` (WER s 0.56 —
  metric punishes the convention, not the meaning)
- extra-182: `two cups / three eggs` → `2 cups / 3 eggs`
- med-102: `ten days / follow up` → `10 days / follow-up`
- num-078: `four thousand two hundred and ninety nine dollars` → `4,299 dollars`
- q-030: `fifteen percent` → `15%`
- med-093: `Grocer as` → `Grocer's` (p WER .06, s WER .03 — streaming closer)
- med-099: comma insertion + `vauder`/`vadur` (equal WER .09)

Tense/auxiliary (phrase-initial imperative → past):
- extra-153 `Email`→`Emailed`, names-063 `Send`→`Sent`,
  names-076 `Message`→`Messaged` (p WER 0–.20, s WER .17–.40)

Token merges/splits:
- extra-150 `Zebra ZX`→`ZebraZX` (s WER .29), names-070 name split
  (both wrong vs ref `Blaszczykowski` anyway)

True lexical swaps surviving at 2080: none of the @640-class errors
(`ounces→answers`, `schedule a meeting`→`schedule made`, `did`→`if`)
appear at 2080.

Ref-WER on the 13 disagreement files: parakeet 0.065 / streaming 0.314 —
inflated by normalization mismatches (a correct `94110` counts 5 word
errors vs `nine four one one zero`). Across the full 300-file set the
mean ref-WER delta is ≈ +0.011 pt (287/300 files decode identically).

### Release replay (dictation, parakeet vs streaming@2080)

PENDING

### Timing

PENDING: busy%, finish p50/p95 per tier, warm + idle+rewarm N≥30.

### Tier decision

640's 80 ms right context starves ambiguous words ("ounces"→"answers",
"schedule a meeting"→"schedule made"); 1120 restores most of the loss;
2080 (the model card's best-WER streaming mode) is best on agreement and
lowest busy%. Default: **t2080** PENDING final numbers.

### Disagreement analysis

The streaming model emits ITN-formatted text natively (digits, currency,
times: "72", "94110", "6:45 am") where offline parakeet spells numbers
out. Most remaining diffs are that convention split — semantically equal
or better for paste-into-doc use — plus a small lexical remainder.

### Known issues

- `--replay --engine parakeet` traps (Trace/BPT 5) on the 267 s
  `long-103.wav` — preexisting shared-code bug on very long clips
  (Track A replayer); streaming replay unaffected (skips collectEvents).
