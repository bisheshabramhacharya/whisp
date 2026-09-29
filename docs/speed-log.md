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

300-clip dictation set baseline: (running serially — fills in when the run lands)

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
