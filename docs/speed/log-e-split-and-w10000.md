# Speed log — the "leftover too long for the 5 s window" work

Continuation of `log.md`'s leftover-bucket measurement (the item that showed
~19% of +0 releases pay a flat 15 s window because the speech after the last
pause ran 5–15 s). Everything below was measured on the same M4 VM
(VirtualMac2,1, **no Neural Engine** — GPU+CPU only): relative A/B numbers
only, never M1 claims. The M1 verdict comes from
`scripts/speed/m1-check.sh` on the owner's 8 GB M1.

## Where the waits were (330 files, `short`, +0 ms)

| leftover bucket | share | wait p50 | wait p95 | last-word ok |
|---|---|---|---|---|
| <5 s | 80.9% | 60 | 66 | 98.9% |
| 5–10 s | 11.8% | 164 | 177 | 100% |
| 10–15 s | 7.3% | 179 | 201 | 100% |
| >15 s | 0% | — | — | — |

The 5–10 s and 10–15 s buckets pay a nearly flat 165–200 ms regardless of
leftover length — the 15 s encoder's fixed cost. Speculation only covers
0–8% of them.

## Option 2 — piecewise `split` engine (PR #45)

`split` (`ShortWindowEngine(piecewise: true)`, opt-in) decodes leftovers in
the band `(pieceW, 2·pieceW − overlap]` as two overlapping pieces on the
already-loaded 5 s window:

- `SpeechSegmenter.splitTwo` cuts inside a real quiet run (≥80 ms of
  sub-threshold frames = a word gap); without one it cuts at the quietest
  mid-word point and widens the tail piece's reach-back to ~1.2 s so the
  word spanning the cut decodes whole in the tail. Unsplittable inputs
  return whole (stock 15 s path).
- `SpeechSegmenter.joinOverlap` merges the transcripts: the largest shared
  boundary run is kept once, a truncated side yields to the side that
  decoded the complete word, and a stoplist keeps real short words from
  ever being dropped as fragments.
- The band check is `variant(for: count)?.windowSamples == maxWindowSamples`,
  so a mid window that fits the input (w10000) always beats pieces, and
  piecewise is a no-op with no short bundle installed.

### Measured (VM, 330-file replay, +0 ms)

| bucket | `short` p50/p95 | `split` p50/p95 |
|---|---|---|
| <5 s | 60 / 66 | 60 / 67 |
| 5–10 s | 164 / 177 | 150 / 186 |
| 10–15 s | 179 / 201 | 176 / 186 |

`--compare parakeet,short,split` (30 unbroken + 40 LibriSpeech-band files,
3 runs): `split` warm p50 **134.4 ms** vs `short` 149.0 / `parakeet` 151.9;
WER 4.90 vs 4.34/4.42; word agreement **0.9976**; last-word ok 100% in both
band buckets.

The 2 residual disagreements are piece-context decode variance, not lost
words: the same audio decoded at ~3 s of context legitimately reads
differently than at 5 s ("Gamewell"→"game well", "Humpty"→"Humpy") — the
tail piece agreed with the head piece both times, coverage is complete.

### Dead ends written down

- **Split everything >5 s into ≤5 s pieces**: regresses the 10–15 s bucket
  (three 5 s passes cost more than one 15 s pass) and 5–10 s p95 (the
  remainder falls back to the 15 s window). Fixed by the band gate.
- **Boundary-less split**: corrupts words at the cut (duplication +
  truncation, e.g. "the inv" + "the invoice" → "the inv the invoice").
  Fixed by overlapping pieces + `joinOverlap`.
- **Quietest-dip cut without a quiet-run check**: dips inside a word
  (syllable boundaries like "Game|well") look like pauses at 10 ms
  granularity; real continuous speech (LibriSpeech read speech) can have
  zero ≥30 ms pauses in 5 s. Fixed by preferring ≥80 ms quiet runs and a
  1.2 s tail reach-back for mid-word cuts.

## Option 3 — 10 s window encoder (PR #46) — the winner

`parakeet_unified_encoder_w10000_int8.mlmodelc` built with
`convert-short-window.py --windows 10 --validate` from
`nvidia/parakeet-unified-en-0.6b` (same weights, traced at 10 s, int8):
enc_len torch=41 = coreml=41, max_abs 0.046 (w5000 tolerance). 502 MB zip.

**Identical transcripts.** `--compare` over the same 70 files:
`short`+w10000 word agreement **1.0000** vs parakeet, WER **4.34**
(identical to `short` — same weights, no seam). `split`'s residual variance
does not exist here.

| metric | `parakeet` | `short` | `split` | `short` + w10000 |
|---|---|---|---|---|
| warm p50 (70 files) | 171.8 | 149.0 | 134.4 | **119.6** |
| warm p95 | 226.0 | 188.4 | 186.7 | **200.9** |
| 5–10 s bucket p50/p95 (replay) | — | 164/177 | 150/186 | **130/161** |
| 10–15 s bucket p50/p95 | — | 179/201 | 176/186 | 168/175 |
| peak replay RSS | — | 2.71 GB | 3.24 GB | 3.92 GB |

Nothing to code: `ShortWindowEngine` already discovers `w{ms}` bundles in
the model dir, so installing it upgrades `short`/`split` automatically.
Opt-in by construction — it is never auto-downloaded (unlike `fastBundle`).

### Dead ends written down

- **Piecewise on w10000 for 10–15 s leftovers**: two ~10 s passes ≈ 20 s
  of encoder time vs one 15 s pass — pieces lose by construction (same
  math that made w5000 pieces beat one 15 s pass for ≤10 s). Not built.
- **Auto-downloading w10000 like `fastBundle`**: +502 MB for every user
  to fix a 12% bucket — kept opt-in.

## Option 4 — multi-function bundle — dead end

Confirmed on coremltools 9.0: `linear_quantize_weights` is decorated
`_multifunction_unsupported` and raises "not supported for a
multifunction model" — the int8 pass can't run, so a multi-function
bundle ships fp16 (~1.6 GB). It also requires a macOS 15+ deployment
target while Whisp supports macOS 14. Window bundles also can't share one
weight.bin. No speed win was left on the table: the multi-function form
saves model-count, not decode time.

## Where it landed

- **5–10 s leftovers**: w10000 single pass (PR #46, opt-in bundle).
  Fallback for anyone without the bundle: `split` pieces (PR #45, opt-in
  engine) — same code path, smaller win, small decode-variance residual.
- **10–15 s leftovers**: still the flat 15 s window — no cheaper option
  exists at the same weights; speculation + prewarm are the only levers.
- **Default engine unchanged** in every PR; M1 verification is
  `scripts/speed/m1-check.sh <wavs> parakeet,short,split` (PR #47 adds the
  per-engine bucket/edge/memory reporting it needs).
