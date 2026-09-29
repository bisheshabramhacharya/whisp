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
| 3 | Streaming decode during capture (`asrEngine streaming`) | release→text = `finish()` ≈ 80–90 ms VM | kills the whole tail decode — only the right-context flush remains | **gate risk**: word agreement vs parakeet = 0.9602 (t640) / 0.9818 (t1120) / 0.9891 (t2080) — diffs are mostly ITN style ("72" vs "seventy two"); WER-vs-refs arbitrates | med — new decode path, batch fallback | **pending — agreement < 99.5% gate** | — |
| 4a | FastRnnt wide-joint (`fast`, `fastall`) | joint calls ~120→46 per decode; VM-CPU p50 194.9 vs 193.4 — a wash on CPU (each call does 72× FLOPs) | dispatch-bound → **ANE is where it pays**; needs-M1 verdict | byte-identical transcripts (dictation+edge+test-clean dumps) | low — opt-in engine | shipped, needs-M1 | [#26](https://github.com/bisheshabramhacharya/whisp/pull/26) |
| 4b | Parallel tail lane (`par2` engine, `unifiedLanes`) | wait = `max(rem,tail)` vs `rem+tail`; p95 357→309 ms at +0 offset | shrinks p95 on releases racing a decode; +600 MB/lane memory | text path unchanged — same decode of the same span | low — opt-in, default 1 lane = today | shipped | [#27](https://github.com/bisheshabramhacharya/whisp/pull/27) |
| 4c | Speculation pause 200→150 ms | stitched: +100 ms p50 82 vs 111, +150 p50 32 vs 71 | earlier speculation → more releases hit spec-hit | last-word 100% at 150 ms; 100 ms fails (mid-word dips) | low — one constant (env-overridable) | **edge validation in flight** | [#27](https://github.com/bisheshabramhacharya/whisp/pull/27) |
| 5 | Prewarm cleaner + dictionary at launch | clean() warm cost off critical path | removes 46–67 ms **first-take** cleanup | identical (same code, earlier) | none | shipped | [#23](https://github.com/bisheshabramhacharya/whisp/pull/23) |
| 6 | Frontmost recheck before Cmd+V | none (µs read) | none — correctness, not speed | identical | none | shipped | [#24](https://github.com/bisheshabramhacharya/whisp/pull/24) |
| 7 | `WHISP_MODEL_DIR` scan in ShortWindowEngine | none | none — enables the M1 check's ≤1 GB scratch assets | identical | none | shipped | [#25](https://github.com/bisheshabramhacharya/whisp/pull/25) |

## Latency budget, before → after (VM, ≤5 s take, serial)

| stage | before (ms) | after — short window | after — streaming |
|---|---|---|---|
| mic stop | 0 | 0 | 0 |
| decode (release→text) | 124–131 | **39–57** | `finish()` flush — pending C |
| cleanup | 2 (first take 46–67) | 2 (**0 added: prewarmed**) | same |
| paste | 3 | 3 | 3 |
| **release→paste** | **~130** | **~45–65** | pending C |

Owner's M1 decode (152/236 ms real-app) is dominated by the same fixed 15 s window; the
short-window engine removes 2/3 of that work *by construction* on any hardware — on M1's ANE
the absolute numbers should be smaller still.

## Release replay — wait p50 by release offset (VM)

Baseline `parakeet` vs `short`, 300 dictation clips, `--replay --offsets 0..1000`:

| offset | parakeet p50 | short p50 | streaming p50 |
|---|---|---|---|
| +0 ms | 131 | 40 | pending C |
| +100 ms | 122 | pending | pending C |
| +150 ms | 73 | pending | pending C |
| +200 ms | 24 | pending | pending C |
| +350 ms | 0 | ~0 | pending C |

last-word ok ≥ 99.0% gate held at every offset for `short` (floor: blip-059, word-043,
word-051 drop on every engine including baseline — see log).

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

- Mic stop discards post-release buffer (MicRecorder.swift:190-205) — **Track D owns the fix**;
  replay `--mic-drop` quantifies it (in-flight IO quantum up to ~100 ms at risk).
- Permission loss leaves capture running (DictationController:173-179) — correctness, tracked.
- Cancelled work keeps decoding (DictationController:312-328) — wastes CPU, tracked.
- Pending-corrections clobber (CorrectionLearner:297-337) — correctness, tracked.
- Learner LCS O(n²) on main (CorrectionLearner:76-101) — off the release path; 59 ms at
  3 000 words — second-round if time.

## M1 check (one command)

```bash
# owner side, once: upload the staged bundle as a draft release
gh release create speed-models-2026-09-29 --draft --repo bisheshabramhacharya/whisp \
  parakeet_unified_encoder_w5000_int8.mlmodelc.zip

# then, from a clone at speed/all (or the PR head):
scripts/speed/m1-check.sh /path/to/recordings-folder parakeet,short
# optional wider sweep: parakeet,short,streaming,profiled
```

Downloads ≤1 GB into a scratch dir (auto-deleted; `WHISP_MODEL_DIR` keeps the owner's
model cache untouched), prints stage timings + replay waits + word agreement + LibriSpeech
WER, and the `defaults write com.bishesha.whisp asrEngine short` line to try it live.

## Can p50 ≤ 100 ms land on the M1?

**Yes, likely — the short window alone probably gets there.** Arithmetic: M1 decode median
152 ms, of which the fixed-15 s encoder is ~85% on this VM's profile (129.6 ms total,
119.4 encoder). w5000 removes ~2/3 of encoder work *structurally* — even at parity per unit
work that's ~100 ms off decode → release→paste ≈ **75–100 ms** for ≤5 s takes before counting
ANE being faster per MAC than this VM's CPU. p95 needs the streaming/finish work (C) and the
D-side joint/decoder loop to trim the >5 s and cold-path tails. The M1 check turns "likely"
into a measurement.
