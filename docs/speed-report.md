# Speed report — release→paste feels instant

Goal: release→paste **p50 ≤ 100 ms, p95 ≤ 200 ms** on the owner's M1 (8 GB), zero accuracy loss.
Owner-measured baseline (37 real dictations, last 24 h): **p50 174 / p95 251 ms**, mic stop 0–2 ms,
cleanup 2/46 ms, paste 3/14 ms — **decode is ~90% of the budget** (transcription 152/236 ms).

All numbers below are **VM numbers** (VirtualMac2,1, M4 virtual, no Neural Engine — CPU/GPU only)
unless marked M1. They are relative A/B evidence, not M1 predictions; the M1 check exists to
confirm. Every claim cites the command that produced it in `docs/speed-log*.md`.

## Scorecard

| # | Lever | VM result | Predicted M1 effect | Accuracy | Risk | Status | PR |
|---|---|---|---|---|---|---|---|
| A | Bench tooling (profile / replay / compare) | — | — | — | none | shipped | [#20](https://github.com/bisheshabramhacharya/whisp/pull/20) |
| 0 | `asrEngine` hidden switch | — | — | identical (default unchanged) | none | shipped | [#19](https://github.com/bisheshabramhacharya/whisp/pull/19) |
| 1 | FluidAudio 0.15.7→0.17.4 | same | unlocks streaming + 0.17.0 RNNT speedups | byte-identical transcripts (40 files) | low | shipped | [#21](https://github.com/bisheshabramhacharya/whisp/pull/21) |
| 2 | **Short encoder window** (`asrEngine short`, w5000 bundle) | decode p50 **123.7→38.9 ms (-68%)**; replay wait +0 ms **123→40** | **the big one**: encoder ≈ 85% of decode; a ≤5 s take encodes 5 s not 15 s | **word-identical on all 300 dictation clips**; test-clean-250 WER 2.24 vs 2.36; test-other-500 5.79=5.79 (agree 0.9999); zero new dropped words | low — new bundle, fallback = stock | **shipped, needs M1 confirm** | [#22](https://github.com/bisheshabramhacharya/whisp/pull/22) |
| 3 | Streaming decode during capture (`asrEngine streaming`, t2080) | release→text = `finish()` ≈ **88 ms VM, flat at every offset** (60-file replay, +0..+1000) | kills the whole tail decode — but the streaming model's last-emission is less reliable | **dead end — three gate misses**: last-word misses **23/480 (4.8%)** vs parakeet 4/480 (~17 tail-word mis-transcriptions persisting at +1000 ms — "Screenshot this"→"Screenshot is" — plus ~6 empty-output dead zones, rescued via batch fallback); test-clean WER **+0.13 pt** (2.35 vs 2.22, gate +0.1) and test-other +0.52; agreement 0.9891 (ITN diffs dominate) | med — new decode path, batch fallback | **dead end for this run** — code ships opt-in (`asrEngine streaming`), off by default | [#33](https://github.com/bisheshabramhacharya/whisp/pull/33) |
| 4a | FastRnnt wide-joint (`fast`, `fastall`) | joint calls ~120→46 per decode; VM-CPU p50 194.9 vs 193.4 — a wash on CPU (each call does 72× FLOPs) | dispatch-bound → **ANE is where it pays**; needs-M1 verdict | byte-identical transcripts (dictation+edge+test-clean dumps) | low — opt-in engine (`asrEngine fast`/`fastall`, #31) | shipped, needs-M1 | [#26](https://github.com/bisheshabramhacharya/whisp/pull/26) |
| 4b | Parallel tail lane (`par2` engine, `unifiedLanes`) | wait = `max(rem,tail)` vs `rem+tail`; p95 357→309 ms at +0 offset | shrinks p95 on releases racing a decode; +600 MB/lane memory | text path unchanged — same decode of the same span | low — opt-in (`asrEngine par2`, #31), default 1 lane = today | shipped | [#27](https://github.com/bisheshabramhacharya/whisp/pull/27) |
| 4c | Speculation pause 200→**180** ms | stitched: release-wait p50 −14 ms at +100/+150 offsets | earlier speculation → more releases hit spec-hit | **150 ms failed edge**: quiet-variant last-word 77.8% vs 83.3%; 180 ms keeps every offset identical to 200 | low — one constant (env-overridable) | shipped | [#27](https://github.com/bisheshabramhacharya/whisp/pull/27) |
| 5 | Prewarm cleaner + dictionary at launch | clean() warm cost off critical path | removes 46–67 ms **first-take** cleanup | identical (same code, earlier) | none | shipped | [#23](https://github.com/bisheshabramhacharya/whisp/pull/23) |
| 6 | Frontmost recheck before Cmd+V | none (µs read) | none — correctness, not speed | identical | none | shipped | [#24](https://github.com/bisheshabramhacharya/whisp/pull/24) |
| 7 | `WHISP_MODEL_DIR` scan in ShortWindowEngine | none | none — enables the M1 check's ≤1 GB scratch assets | identical | none | shipped | [#25](https://github.com/bisheshabramhacharya/whisp/pull/25) |

## Latency budget, before → after (VM, ≤5 s take, serial)

| stage | before (ms) | after — short window | after — streaming |
|---|---|---|---|
| mic stop | 0 | 0 | 0 |
| decode (release→text) | 124–131 | **39–57** | `finish()` ≈ 82–84 |
| cleanup | 2 (first take 46–67) | 2 (**0 added: prewarmed**) | same |
| paste | 3 | 3 | 3 |
| **release→paste** | **~130** | **~45–65** | **~85–90** |

Owner's M1 decode (152/236 ms real-app) is dominated by the same fixed 15 s window; the
short-window engine removes 2/3 of that work *by construction* on any hardware — on M1's ANE
the absolute numbers should be smaller still.

## Release replay — wait p50 by release offset (VM)

Baseline `parakeet` vs `short`, 300 dictation clips, `--replay --offsets 0..600` (parakeet column @ spec=180 as shipped):

| offset | parakeet p50 | short p50 | streaming p50 |
|---|---|---|---|
| +0 ms | 131 | **61** | 82 |
| +100 ms | 101 | **54** | ~83 |
| +150 ms | 51 | **4** | ~83 |
| +200 ms | 2 | **0** | ~83 |
| +350 ms | 0 | **0** | ~84 |
| +600 ms | 0 | **0** | ~84 |

last-word ok 99.0% at every offset for `short` — the 3-file floor (blip-059, word-043,
word-051) is unchanged vs baseline, so zero NEW dropped final words. Parakeet column re-verified on speed/all @ c14109c (spec=180); `short` column @ f17a82f,
`--replay --engine short` over the full 300-clip dictation set.
Streaming column: `finish()` ≈ **88 ms flat at every offset** (Track C's 60-file × 8-offset
replay @t2080 — the streaming encoder re-encodes a ~17.9 s window per step on CPU; ANE
could collapse it). `short` dominates at every offset ≥ +100 — and streaming misses
23/480 last words vs parakeet 4/480, so it stays off.

## Dead ends (measured, kept for the record)

From Track B's log (`docs/speed-log-b.md`):

- **Fixed [1,128,1501] mel tensor**: the encoder model pins its input shape; can't slice the
  mel window — re-tracing at a shorter window is the only route (that's the shipped lever).
- **Streaming encoders for the offline path**: WER 2.25–2.47% vs 1.68% baseline — fails the
  accuracy gate. Streaming is only viable live (Track C), where its cache-aware design applies.
- **Multi-function bundle / 4-bit palettization**: needs iOS18+ — the app targets macOS 14.
- **Sharing weight.bin across window variants**: layouts differ per window → each bundle is
  self-contained (w5000 = 563 MB; w2000+w5000 = 1.12 GB > 1 GB cap → w5000 ships alone,
  w2000 documented as a local drop-in).

Lead audit items (from the independent review at 098dac7):

- Clipboard snapshot blocking (audit F4) — **dead end, reasoned**: `paster.target()` already
  fires the snapshot on a detached task at *key release*, so it runs concurrently with the
  ~130 ms decode, and `capturedOrFresh` reuses it; real-app logs show Paste median 3 ms,
  p95 14 ms. Only an adversarial (>~100 MB) clipboard could outlast decode, and capping the
  snapshot would change restore semantics (dropped clipboard items) for an unmeasured gain.
  The frontmost-recheck half of F4 shipped ([#24]).
- Mic stop discards post-release buffer (MicRecorder.swift:190-205) — **dead end, measured**:
  ~4% last-word loss at +0 release on this VM — but the VM's ~100 ms IO quantum inflates it;
  on a real M1 (~10–20 ms quantum) exposure is much smaller. No latency-free fix inside the
  owned files — draining the final audio buffer at release is real follow-up work (MicRecorder),
  flagged for the owner.
- Permission loss leaves capture running — **shipped**: `hotkeyPermissionLost` now cancels
  capture (`if isRecording { cancelCapture() }`). speed/all @ 303ad8d.
- Cancelled work keeps decoding — **shipped**: `enqueueTranscription` bails at task start when
  `id <= cancelledThrough` — an Esc during the wait never spends a decode. speed/all @ 303ad8d.
- Learner LCS O(n·m) on main (CorrectionLearner:76-101) — **shipped**: `diff` early-outs on
  unchanged text (the common case; output-identical). Prefix/suffix stripping rejected: it
  changes the LCS alignment and thus the learned blocks — kept the full table for edits.
  [#30](https://github.com/bisheshabramhacharya/whisp/pull/30)
- Pending-corrections clobber (CorrectionLearner:297-337) — **shipped**: undecodable file no
  longer overwritten. [#28](https://github.com/bisheshabramhacharya/whisp/pull/28)

## M1 check (one command)

```bash
# owner side, once: upload the staged bundle as a draft release
gh release create speed-models-2026-09-29 --draft --repo bisheshabramhacharya/whisp \
  parakeet_unified_encoder_w5000_int8.mlmodelc.zip

# then, from a clone at speed/all (or the PR head):
scripts/speed/m1-check.sh /path/to/recordings-folder parakeet,short
# optional wider sweep: parakeet,short,fast,streaming,par2,profiled
```

Downloads ≤1 GB into a scratch dir (auto-deleted; `WHISP_MODEL_DIR` keeps the owner's
model cache untouched), prints stage timings + replay waits + word agreement + LibriSpeech
WER, and the `defaults write com.bishesha.whisp asrEngine short` line to try it live.
(Caveat: the `fast`/`par2`/`streaming` engines pull small extra FluidAudio bundles —
`parakeet_unified_joint` and the streaming encoders, tens of MB — via ModelHub into the
normal model cache on first use, same as any app update would.)

## Can p50 ≤ 100 ms land on the M1?

**Yes, likely — the short window alone probably gets there.** Arithmetic: M1 decode median
152 ms, of which the fixed-15 s encoder is ~85% on this VM's profile (129.6 ms total,
119.4 encoder). w5000 removes ~2/3 of encoder work *structurally* — even at parity per unit
work that's ~100 ms off decode → release→paste ≈ **75–100 ms** for ≤5 s takes before counting
ANE being faster per MAC than this VM's CPU. p95 needs the streaming/finish work (C) and the
D-side joint/decoder loop to trim the >5 s and cold-path tails. The M1 check turns "likely"
into a measurement.

## Plain-language summary

Whisp spent ~155 ms of your ~174 ms release→paste in the transcription stage (median
152 ms on your M1), and ~85%
of that was the encoder padding every take out to a fixed 15-second window — a 2-second
command paid for 15 seconds of math. The fix that does almost all the work: encode only
what you actually said. On this VM the decode for a typical take drops from ~128 ms to
~57 ms, the transcripts are byte-identical across all 300 dictation clips and all 432
hostile edge clips, and real WER slightly improves. On your M1 that predicts a median
release→paste of roughly 75–100 ms — the target — before the Neural Engine's speed is
even counted. It's behind a hidden setting until the M1 check confirms it:
`defaults write com.bishesha.whisp asrEngine short`.

Everything else is smaller and opt-in: the speculation window is now 180 ms (releases
that land while you're still speaking hit a finished guess far more often); a second
decoder lane can overlap the tail; a batched joint call trims per-token overhead —
that one is a CPU wash here but should win on the Neural Engine. The streaming engine
was the interesting experiment: it flattens the release wait to ~88 ms at every
offset — but the streaming model mis-hears or drops the *last* word in ~5% of
releases (vs ~1% for the normal path), even when you give it a full second of
trailing silence. Since a faster Whisp that changes a word you said is a failure,
streaming is a dead end for this run; the code stays as an opt-in experiment.

Measured dead ends, honestly: the microphone drops the tail of the last word if you
release mid-syllable (~4% on this VM, less on real hardware); streaming encoder windows
below the stock one fail accuracy; the clipboard snapshot is already off the critical
path. Correctness fixes riding along: permission loss no longer leaves the mic running,
Esc no longer pays a decode, the frontmost app is rechecked before ⌘V, a corrupt
corrections file can never be overwritten, first-take cleanup is prewarmed.

One command on your Mac measures the real thing:
`scripts/speed/m1-check.sh <recordings-folder> parakeet,short` — prints the same tables
against your actual dictations, then deletes its downloads.
