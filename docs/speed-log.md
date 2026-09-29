# Speed log — release→paste

All numbers measured on the Devin VM (VirtualMac2,1, Apple M4 virtual, **no Neural Engine** — GPU+CPU only). Labeled "VM": relative A/B comparisons only, never M1 claims. Owner baseline (M1, reported): release→paste p50 178 ms / p90 242 ms / max 320 ms, 16% under 100 ms; decode ≈ all of it.

Environment: `swift build -c release` on `speed/all` (FluidAudio 0.17.4). Models: `parakeet-unified-en-0.6b` int8 encoder + fp decoder/joint, stock FluidAudio cache.

## Baseline stage profile (VM)

Command: `.build/release/whisp-bench --profile --runs 3 --show <40 files: 30 dictation + 10 LibriSpeech>`

| stage | ms | calls/decode |
|---|---|---|
| mel (15 s padded window) | ~3.0 | — |
| encoder (fixed 15 s window) | ~112–180 (run-dependent; ~148 mean over 40 files) | 1 |
| joint decision | ~10 (65 calls mean; ~1/frame+tokens) | ~65 |
| RNNT decoder | ~7 (24 calls mean; ~1/token+1) | ~24 |
| loop overhead | ~0.2 | — |
| **total** | **~134–230** | **~90** |

Encoder ≈ 85% of decode on this CPU/GPU VM — the fixed-15 s window means a 1.4 s command pays 15 s of encoder. On the M1's ANE the encoder is far cheaper and the ~90 sequential joint/decoder dispatches (~1 ms each incl. marshalling) become the binding term — both tracks target their own side of that.

## Release replay (VM, `parakeet` engine)

Command: `whisp-bench --replay --offsets 0,50,100,150,200,350,600,1000 <clips>`

Mechanics confirmed on a padded 2.4 s clip: release at last-word +0/+100 ms → full tail decode (~124 ms VM); +200 ms → speculation fired but still in-flight → ~42 ms wait (remainder); +350 ms+ → speculation hit → ~0 ms. Today's app only wins when the owner holds ≥350 ms past the last word.

300-clip dictation-set baseline (command above over all 300 clips, serial, fixed build):

| release offset | wait p50 | wait p95 | wait mean | no-wait | spec-hit | last-word ok |
|---|---|---|---|---|---|---|
| +0 ms | 131 | 167 | 134 | 0% | 2% | 99.0% |
| +50 ms | 130 | 163 | 131 | 0% | 16% | 99.0% |
| +100 ms | 122 | 158 | 113 | 0% | 66% | 99.0% |
| +150 ms | 73 | 123 | 71 | 3% | 100% | 99.0% |
| +200 ms | 24 | 77 | 29 | 32% | 99% | 99.0% |
| +350 ms | 0 | 113 | 10 | 91% | 90% | 99.0% |
| +600 ms | 0 | 0 | 0 | 100% | 90% | 99.0% |
| +1000 ms | 0 | 0 | 0 | 100% | 89% | 99.0% |

Baseline floor: last-word ok is 99.0% at every offset — exactly 3 clips lose the last word even today: **blip-059.wav** ("In"), **word-043.wav** ("Thanks."), **word-051.wav** ("Seven.") — short quiet clips whose clipped decode returns empty at every offset. The accuracy gate for new engines is "zero NEW dropped final words" vs this floor.

Caveat: a second aggregate (`--show` rerun while other benches contended) read p50 187 / p95 224 at +0 — use the serial table above; ~30–40% inflation under parallel load is the norm on this VM.

## Compare + profile baseline (VM, serial)

`--compare parakeet,profiled --runs 20 --idle 30` over 40 files (30 dictation + 10 test-clean):

- parakeet: warm p50 130.6 / p95 165.8; idle 30 s + rewarm p50 130.4 / max 174.9 — rewarm fully hides the cold-start on this VM.
- profiled (ported internals driving the same .mlmodelc): warm p50 129.4 / p95 164.8; word agreement vs parakeet **1.0000**; WER identical.
- WER on the mixed set: 6.56 (dictation refs = the `say` source text; includes normalization losses). Baseline for the ±0.1 pt gate.
- WER baselines (parakeet, `--runs 1 --idle 0`): test-clean 100 files → **3.45**; test-other 50 files → **1.28** (odd but measured — the sorted-first-50 slice happens to be easy; use same-subset deltas, not absolute). profiled differs only on `1688-142285-0000.flac` (one word, favors profiled). Longer LibriSpeech clips decode at warm p50 ~216–221 ms (>15 s files go multi-window).
- Ref-lookup fix: `loadFiles` now tries `<file>.<ext>.txt` then `<file>.txt` — dictation refs were silently skipped before (WER 0.00 by omission). Commit dc6f81d.
- Clean serial `--profile` (39 dictation files, 3 runs): mel 3.1 / encoder 119.4 (92%) / joint 4.1 (23 calls) / decoder 2.7 (8 calls) / overhead 0.1 → total 129.6 ms, 32 CoreML calls, 15 encoder frames, 7 tokens. Earlier 148 ms mean was ~14% CPU-contended.

Tooling fix during this run: `collectEvents` indexed `pending[..<cut]` where `pending` is a `samples[committed..<tick]` slice (index base `committed`) but `cut` is 0-based — `Trace/BPT trap: 5` on the second chunk event, i.e. only on takes long enough to commit ≥2 chunks (the 4.5–9 min `long-*` clips). Fixed with `pending.prefix(cut)` (speed/track-a-tools @ 113e28c, merged to speed/all @ 9441327). The same style of bug would silently under-feed a decode whenever `committed < cut` — no corrupted data was recorded: first cuts always ran with `committed == 0`, and no run survived to write results.

Verified after fix on long-103.wav (267.8 s, 20+ chunk events): full replay completes; +0 ms release → 154 ms wait (full tail decode), +150/+200 → spec in-flight remainder 117/67 ms, +350+ → spec hit 0 ms, last-word ok 100% at every offset.

## Replay mechanics (why the app looks the way it does)

The serial-pipeline model (one decode in flight; a decode at tick T masks ticks until T+D — matching `DictationController`'s `chunks.inFlight` early-return) reproduces the owner's observation that speculation only pays ≥350 ms after the last word: a speculation needs ~200 ms of trailing pause to trigger, then ~decode-time to land. Release inside that window waits out the in-flight remainder; release before it decodes the whole tail. So the big wins are (a) a cheaper tail decode and (b) earlier speculation triggers — exactly Tracks B/C/D.

## FluidAudio bump (lever: library version)

- 0.15.7 → 0.17.4: transcripts **byte-identical** on 40 LibriSpeech test-clean files (diff empty), `whisp-tests` 270/270 both. PR: <https://github.com/bisheshabramhacharya/whisp/pull/21>
- Needed by Track C anyway (streaming seam fixes #904/#906/#908/#910 landed 0.15.8+; 0.17.0 bulk-fill `MLMultiArray` helps the RNNT loop).

## Test sets

- LibriSpeech test-clean 2620 + test-other 500 (`scripts/speed/fetch-librispeech.sh`, refs as `.flac.txt`).
- Dictation set 300 `say` clips: short commands, questions, one-word, ≤0.3 s blips, trailing names/products, numbers/times/money, multi-sentence takes, plus 3 long takes that came out 4.5–9 min (longer than spec — kept: they exercise the multi-chunk path and caught a replay bug); 8 voices × 3 rates; 0.15 s lead + 1.2 s tail silence (`scripts/speed/gen-dictation.sh`).
- Edge set 432 clips: quiet final word −20/−30 dB, cough mid-take, noise 10/20 dB SNR, −15 dB low gain, hard clipping, trailing breath, mid-word truncation (`scripts/speed/gen-edge.sh`).

## Track logs

- Track A (this file): profiler, replay, compare, test sets, baselines.
- Track B (short encoder window): `docs/speed-log-b.md` on `speed/track-b-*`.
- Track C (streaming engine): `docs/speed-log-c.md` on `speed/track-c-*`.
- Track D (RNNT/pipeline): `docs/speed-log-d.md` on `speed/track-d-*`.

## Lead work since B merged (2026-09-29)

- **w5000 encoder rebuilt on this VM** (`uv run --no-sync python tools/convert/convert-short-window.py --windows 5 --validate --install`, coremltools on macOS 26.5.2 arm64): NeMo→CoreML parity `enc_len torch=41 coreml=41, mean_abs 0.0012, max_abs 0.048`. `whisp-bench --compare parakeet,short` on 30 dictation files ×20 runs: **warm p50 128.7→57.7 ms (-55%), WER 8.75=8.75, agree 1.0000** — reproduces B's win on a second machine.
- **Release asset staged**: `parakeet_unified_encoder_w5000_int8.mlmodelc.zip` = 501 MB (≤1 GB cap). One manual step remains for the owner (no GitHub auth on this box): `gh release create speed-models-2026-09-29 --draft --repo bisheshabramhacharya/whisp <zip>` then m1-check downloads it.
- **Prewarm cleanup** (PR #23): `cleaner.clean("warm at 5.30")` detached at launch pays clockTimeRules+dictionary lazy costs; targets the 46–67 ms first-take cleanup the review measured.
- **Frontmost recheck** (PR #24): recheck `frontmostApplication` immediately before `postCommandV` — closes the wrong-window race between the clipboard-snapshot await and the HID post (review finding 4 residual).
- Compare caveat: `idle+rewarm p50 0.0` — with `--idle 0` the >20 s rewarm threshold never trips; the column is only meaningful at `--idle ≥ 20`.

## Track D merges (2026-09-29)

- **PR #26 FastRnnt** (speed/d-fast-rnnt): batched wide joint (`parakeet_unified_joint.mlmodelc` from the HF repo via `additionalModelNames`) — logits valid across blank runs → joint calls ~120→46/decode, decoder calls unchanged. Byte-identical dumps on dictation+edge+test-clean. VM-CPU wash (194.9 vs 193.4 p50, `--compare parakeet,fast --runs 30 --idle 20` 27-file subset) — the win is dispatch-bound, i.e. ANE → needs-M1. Engine names `fast` (.cpuOnly joint) / `fastall` (.all).
- **PR #27 pipeline** (speed/d-pipeline): `earlyTail` — release during in-flight decode + no covering speculation + non-silent tail → tail decode starts immediately; lanes=1 queues identically (ordering preserved), `par2` overlaps → wait `max(rem,tail)` vs `rem+tail`, p95 357→309 @ +0. Segmenter knobs `WHISP_MIN_PAUSE_FRAMES`/`WHISP_SPEC_PAUSE_FRAMES`; grid: spec=150 ms safe (100% last-word), 100 ms fails; minPause 35 optimal. Shipped default unchanged pending edge validation.
- speed/all @ f17a82f: 270/270; `--compare parakeet,short,fast` 15 files ×5: p50 128.2/55.9/127.5, WER 16.67 all, agree 1.0000.

## Post-D-merge full replay (speed/all @ f17a82f, 300 files, `--replay --engine parakeet`)

wait p50: +0 → 132, +100 → 123, +150 → 74, +200 → 25, +350 → 0, +600 → 0; last-word ok 99.0% at every offset — identical to the pre-merge baseline: the serial parakeet path is unchanged (earlyTail only races in-flight decodes; lanes=1 preserves ordering). `--compare parakeet,short,fast` post-merge: WER 16.67 / agree 1.0000 across all three.

## Lead fix: pending-corrections clobber (PR #28)

`PendingCorrections.init` turned an undecodable file into `entries = []`, then `save()` overwrote it — violating the documented never-clobber rule (audit repro confirmed). Now flags `fileUnreadable` on existing-but-undecodable input and `save()` skips until it parses. Not a speed lever; folded in because the audit flagged it.

## `short` engine full replay (speed/all @ f17a82f, `--replay --engine short`, 300 files)

wait p50: +0 → **61**, +100 → **54**, +150 → **4**, +200 → **0**, +350 → **0**, +600 → **0** (vs parakeet 132/123/74/25/0/0); last-word ok 99.0% every offset — gate holds. File mix: 266/300 <5 s (w5000), 31 at 5–15 s (stock window), 3 >15 s. The +0 median lands inside the <5 s group: w5000 decode ≈ 55–60 ms **on this VM** (`--compare` 57.7 warm p50) vs ~39 ms on B's VM — machine-relative, not a regression. p95 161 at +0 is the 5–15 s + >15 s tail still paying the stock window — the remaining M1-check question for >5 s takes.

## Audit items fixed (2026-09-29)

- **corrections-pending clobber** (PR #28, merged 83ad3e7): undecodable file → `fileUnreadable` → `save()` skips. Never-clobber rule now holds.
- **LCS quadratic on unchanged text** (PR #30, merged 83ad3e7): `a == b` early-out skips the O(n·m) table (audit: 59 ms/69 MB @ 3 000 words). Prefix/suffix strip evaluated and rejected — interior words can LCS-match suffix words (a="x A"/b="y x A": substitution vs insertion), so it changes learned blocks; table kept for edited text. Not release-path work.

## Track D round 2 + Track A edge fix

- `speculatePauseFrames` 20→18 (200→180 ms): edge grid — 150 ms drops a quiet-variant
  last word (77.8% vs 83.3%); 180 ms matches 200 at every offset; dictation subset
  wait p50 −14 ms at +100/+150. Shipped via PR #29 (`speed/track-d-runtime`).
- Audit folds in `DictationController` (same PR): `enqueueTranscription` bails when
  `id <= cancelledThrough` at task start (Esc no longer spends a decode);
  `hotkeyPermissionLost` cancels capture (was running to the 10-min cap).
- Track A bug fixed: `gen-edge.sh` wrote `bitsPerSample=16` on float32 data →
  `AVAudioFile` rejected every edge file. Header now 32; **432-file edge set
  regenerated and loads cleanly through `loadSamples16kMono`** (verified on
  cmd-000-*.wav batch). Earlier edge numbers (D's 32-file /tmp fix) remain valid.
- mic-drop nuance: VM IO quantum ~100 ms inflates the ~4% last-word exposure; on a
  real M1 (~10–20 ms quantum) exposure is much smaller — still a dead end for a
  latency-free fix inside owned files.

## New edge coverage for `short`

After the `gen-edge.sh` header fix (432 files now load through `loadSamples16kMono`):
`--compare parakeet,short --runs 1 --idle 0` on the first 40 edge files →
**agree 1.0000**, WER identical (9.17 both), decode 127.2→56.8 ms. Full-432 run in flight.

Full-432 edge compare on speed/all: `parakeet` vs `short` → **agree 1.0000**,
WER identical 8.57/8.57, decode 130.1→59.4 ms (−54%). `short` is now verified
word-identical on dictation-300 AND edge-432 (no test-clean regression: 2.24 vs 2.36).
