# Decode cost on the M1 (thread WHIB beat): where a single decode's milliseconds go

All numbers here are from the Mac Mini (M1, 8 GB, real Neural Engine), one
benchmark at a time, `whisp-bench --stages` (new) unless said otherwise. The VM
numbers in `log.md` are not comparable.

## How the split was measured

`whisp-bench --stages --engine short --runs N <clips>` decodes through the app's
own `ShortWindowEngine` and prints, per clip, the median over the measured runs
(the first run of each file is paid as warm-up and dropped) of: mel, encoder,
RNNT total, and the RNNT split into joint decisions and decoder steps with the
number of Core ML calls each one made. A file that needs more than one encoder
window prints one row per window from its last run, because the split points are
the same in every run, and those files stay out of the summary mean.

`ShortWindowEngine.DecodeTimings` gained
`jointMs`/`decoderMs`/`jointCalls`/`decoderCalls` for it. The four counters are
recorded on every decode the app runs, not only when the bench reads them, and
they cost about 0.1 us per call against a 200-600 us call.

## Stage split (warm, `say` clips, one file per row)

| clip | window | decode | mel | encoder | RNNT | joint | decoder |
|---|---|---|---|---|---|---|---|
| 0.5 s | 5 s | 30.8 | 2.7 | 22.1 | 6.6 | 3.0 (11 calls) | 3.5 (5 calls) |
| 2.0 s | 5 s | 49.5 | 2.3 | 26.9 | 20.6 | 9.4 (41 calls) | 10.7 (16 calls) |
| 4.2 s | 5 s | 64.0 | 2.3 | 26.4 | 35.4 | 17.0 (80 calls) | 17.4 (29 calls) |
| 9.0 s | 15 s | 154.2 | 7.1 | 70.3 | 77.0 | 37.5 (172 calls) | 38.0 (61 calls) |

Reading it: the encoder is a flat ~26 ms on the 5 s window no matter how long
the clip, so it is 70% of a 1 s take and half of a 2 s one. The RNNT grows with
speech length and overtakes the encoder around 3-4 s. Per dispatch the joint
costs ~0.21 ms and the decoder ~0.6 ms, and the joint runs about twice per
token (one blank check per frame, one decision per symbol).

Duration census of the owner's 2,598 recordings (`afinfo`, counts only, whole
seconds): 211 under 1 s, then 141 at 1-2 s, 110 at 2-3 s, 120 at 3-4 s, 74 at
4-5 s, 90 at 5-6 s, and a long tail. So 371 of the 844 takes in the 1-10 s
bucket are under 4 s (44%), 251 of those are under 3 s, and 462 recordings in
total fit a 3 s window once the 211 sub-second takes are counted.

## Measured and dropped: a 3 s encoder window

Built it (`tools/convert/convert-short-window.py --windows 3`, same weights,
same int8 recipe, 48000 samples, 500 MB zip) and measured it three ways. It is
faster, and not enough to justify what it costs.

**Decoder level, same binary, bundle installed vs moved away** (median of 7
warm decodes):

| clip | decode with | decode without | mel | encoder |
|---|---|---|---|---|
| 0.5 s | 35.9 | 42.4 | 2.0 vs 3.5 | 25.6 vs 29.8 |
| 2.0 s | 48.8 | 58.7 | 2.1 vs 3.9 | 25.3 vs 30.2 |

**User-visible wait, live replay of 14 sub-3 s clips through the app's own
path**, bundle out then in: p50 83 -> 79 ms, mean 77.4 -> 74.9, better on 9 of
14 clips. Only 2-4 ms, because by release most of a short take has already been
decoded during recording; the release decode is the leftover, so the encoder
saving lands on a fraction of the work.

**Scoreboard** (cold run, final commit): short bucket p50 90 ms against 88 on
the recorded 588c9ee baseline, with the untouched long bucket inflated 167 ->
188 and average 100 -> 103, i.e. the run was noisy enough to swallow a 4 ms
change.

Accuracy was clean: identical text on 324 files (200 dictation, 100
LibriSpeech test-clean, 24 probe clips) with the bundle in and out, and
LibriSpeech WER identical to the baseline to the error count (test-clean 104
errors over 6102 words, test-other 175 over 5492).

Verdict: a 500 MB download and a third encoder resident in the process, for
2-4 ms of p50 on short takes that the scoreboard cannot see. Dropped. The
bundle is archived at `~/.capy/work/whisp-w3000/` on the Mini with the numbers;
it is not installed in the FluidAudio cache and nothing pins it.

The useful thing this leaves behind: the encoder has a large fixed cost per
decode (25-26 ms at a 3 s window, 30-31 ms at 5 s, 70-87 ms at 15 s), so
windows are close to exhausted as a lever. The remaining terms are that fixed
encoder cost and the RNNT's 0.21 ms joint / 0.6 ms decoder per dispatch.

## Shipped: whisp-bench --stages

Nothing in the app changed. `--stages` prints the split above for any file set,
through the engine the app really uses, and `ShortWindowEngine.DecodeTimings`
gained `jointMs`, `decoderMs`, `jointCalls`, `decoderCalls` to feed it. Exact
same decode path, no behaviour change.

## Dead ends (do not redo without a new reason)

- **Batched joint via `MLModel.predictions(fromBatch:)`**. Blank runs are
  independent (the decoder state only changes when a symbol emits), so one
  batch call can decide several frames. Measured: 446 frames decided in 80
  dispatches instead of 80 frames in 80 dispatches, but the per-frame cost only
  improved 1.4x (0.21 -> 0.15 ms), so joint time went 16.7 -> 60.6 ms. Core ML
  does not amortise the per-frame work; only the call overhead. Note this is a
  different thing from FastRnnt's wide-joint model (PR #26), which was also
  slower here.
- **Compute units**. The models already run where they belong. Decoder or joint
  on the Neural Engine or GPU is slower (`WHISP_*_UNITS` knobs used for the
  test, removed): 2-4 s clips decoded at 60.5 ms with the shipped settings vs
  84.6-109.5 ms with any alternative. Encoder on `.cpuAndNeuralEngine` (31.2 ms)
  matches `.all` (30.6 ms) and beats `.cpuOnly` (72.4 ms) and `.cpuAndGPU`
  (135 ms).
