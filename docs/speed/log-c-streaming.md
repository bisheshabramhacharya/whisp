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
  failure falls back to a batch decode of the take's retained audio, and
  an empty `finish()` on audible audio retries once with right-context
  silence padding (rescues deterministic upstream decode dead zones).
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

@2080: parakeet WER **2.22** / streaming WER **2.35** (**+0.13 pt**, gate ≤ +0.1 — just over);
agreement 0.9941, 170 disagreement files. For scale: FluidAudio's own
published gap for this model pair is +0.31 pt (offline 1.83 / streaming
2.14) — our harness measures a tighter delta.

Timing columns on that run are inflated (three bench processes contended
for CPU); see the dedicated timing section.

### LibriSpeech test-other (500-file subset)

@2080: parakeet WER **5.79** / streaming WER **6.31** (**+0.52 pt**),
agreement 0.9848, 83 disagreement files.

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

### Release replay (60 dictation files × 8 offsets, `--mic-drop 30`)

Parakeet (live-loop replay):

| offset | wait p50 | wait p95 | last-word ok |
|---|---|---|---|
| +0 ms | 237 | 268 | 93.3% |
| +50 | 238 | 277 | 100% |
| +100 | 225 | 256 | 100% |
| +150 | 177 | 243 | 100% |
| +200 | 127 | 193 | 100% |
| +350 | 0 | 103 | 100% |
| +600 | 0 | 0 | 100% |
| +1000 | 0 | 0 | 100% |

Streaming @2080 (feed during capture, `finish()` at release, with the
empty-finish rescue):

| offset | wait p50 | wait p95 | last-word ok |
|---|---|---|---|
| +0 ms | 89 | 97 | 93.3% |
| +50 | 88 | 94 | 96.7% |
| +100 | 88 | 95 | 95.0% |
| +150 | 89 | 95 | 93.3% |
| +200 | 88 | 98 | 95.0% |
| +350 | 88 | 96 | 96.7% |
| +600 | 88 | 96 | 96.7% |
| +1000 | 87 | 98 | 95.0% |

Streaming's finish is offset-invariant (~88 ms VM) — decode happened
during capture; the wait is one final holdback-0 window re-encode.

**Last-word gate misses: 23/480 releases lose or mis-hear the final word
vs parakeet's ~1%** (parakeet: 4/480, all at +0 where the release lands
inside the word). Breakdown:
- ~6 were *empty-output dead zones* — deterministic total-frame-count
  alignments where the streaming decoder emits zero tokens (reproduced
  in FluidAudio's own `--streaming` harness → upstream model quirk, not
  the engine). Fixed by the empty-finish rescue: `finish()` returning
  "" on non-silent audio retries one padded batch decode
  (`takeAudio + rightSamples` zeros). All dead cases rescued; cost ~170 ms
  on the rescued path only.
- ~17 are *tail-word drift*: the stream's final emission mis-transcribes
  the last word ("Cheapanis"→"Cheapennis", "Screenshot this"→"Screenshot
  is"). Not a missing-tail issue — persists at +1000 ms where ~1 s of
  post-word silence was captured. The streaming model's last-emission
  token path is simply less reliable than the offline decode's.

### Timing

Interleaved `--compare parakeet,streaming --runs 30 --idle 20` on 5
dictation files (extra-123/128/133, names-065, med-095), quiet VM:

| engine | warm p50 | warm p95 | idle+rewarm p50 | idle+rewarm max |
|---|---|---|---|---|
| parakeet | 131.2 ms | 163.7 ms | 127.2 ms | 156.5 ms |
| streaming@2080 (batch path) | 87.8 ms | 529.1 ms | 86.2 ms | 507.1 ms |

Notes: streaming's batch `transcribe` p50 beats parakeet's outright
(windowed chunked decode is cheaper per call than the 15 s offline
window); its p95 tail is worse (~5× — occasional multi-window cold
decodes; under CPU contention earlier runs inflated further). On the
live path none of that matters: the release wait is `finish()` only —
p50 **88 ms**, p95 ~96 ms (replay table above) vs parakeet's
131–238 ms tail decode at release offsets ≤200 ms.

Feed-busy (time inside `feed()` per captured audio, from the replay
instrumentation, % of capture duration):

| tier | feed-busy | finish p50 |
|---|---|---|
| 320 | ~33–41% | 66 ms |
| 640 | ~8–12% | 67 ms |
| 1120 | ~5–13% | 70 ms |
| 2080 | p50 1.8%, mean 2.6%, max 7.3% (60 files) | 88 ms |

320 is unworkable as a live engine (a third of a CPU while talking);
640/1120 are cheap; 2080 is cheapest AND most accurate — the bigger
window means fewer, larger steps.

### Tier decision

640's 80 ms right context starves ambiguous words ("ounces"→"answers",
"schedule a meeting"→"schedule made", WER 13.24 vs 9.78 on the dictation
set @320-class); 1120 restores most of the loss; 2080 (the model card's
best-WER streaming mode) is best on every accuracy axis. Default: **t2080**.

### Disagreement analysis

The streaming model emits ITN-formatted text natively (digits, currency,
times: "72", "94110", "6:45 am") where offline parakeet spells numbers
out. Most remaining diffs are that convention split — semantically equal
or better for paste-into-doc use — plus a small lexical remainder.

### Verdict

VM numbers: release→text p50 ≈ **88 ms** (vs parakeet ~127–238 ms at
early release offsets) — well under the 100 ms target *before* ANE
speedup. But the accuracy gates are missed by the letter: WER +0.13 pt
(test-clean) / +0.52 pt (test-other), agreement 0.9891, and ~4% more
last-word failures than parakeet. Recommendation: **ship opt-in only**
(`asrEngine=streaming` stays non-default) with this caveat documented —
the tail-word drift needs an M1 check and/or a FluidAudio upstream fix
before this can replace the default path.

### Known issues

- `--replay --engine parakeet` traps (Trace/BPT 5) on the 267 s
  `long-103.wav` — preexisting shared-code bug on very long clips
  (Track A replayer, fixed on speed/all @113e28c); streaming replay
  unaffected (skips collectEvents).
- Streaming-model dead zones: empty transcript at certain total frame
  counts (deterministic, upstream); mitigated by the empty-finish rescue
  in `StreamingEngine.finish`.
