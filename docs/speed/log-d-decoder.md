# Track D speed log — runtime levers

All numbers are **VM** (VirtualMac, virtual Apple silicon, 8 cores, 16 GB — **no
ANE**, GPU+CPU only). Relative A/B only; M1 expected to differ in absolute terms
and in the CPU↔ANE dispatch split.

Environment per run below: `.build/release/whisp-bench` built with
`swift build -c release` on `speed/track-d-runtime` (base `origin/speed/all`).

## Baseline decode profile (why each lever)

`whisp-bench --profile testdata/subset/*.wav` (27 files, engine `parakeet`):

| stage    | calls | total ms | share |
|----------|-------|----------|-------|
| mel      | 1     | 3.3      | ~2%   |
| encoder  | 1     | 113.7    | ~84%  |
| joint    | ~74   | 10.7     | ~8%   |
| decoder  | ~26   | 6.8      | ~5%   |
| **total**| ~102–170 dispatches | ~135 | |

On this VM the single encoder call dominates; the per-dispatch overhead of the
~74-call joint loop is small on CPU but is the lever that should matter on ANE.

## Lever 1 — batched wide-joint RNNT (`fast` engine, `FastRnnt.swift`)

**What**: the HF repo ships `parakeet_unified_joint.mlmodelc`, a pointwise joint
head (`decoder [1,640,1]` × `encoder [1,1024,188]` → `logits [1,188,1,1025]`).
One call covers *all* frames under one decoder state; blank frames keep the
state, so joint calls collapse from `Σ(1 + tokensInFrame)` ≈ 74–120 to
`1 + #tokens` ≈ 46. Verified: `WHISP_FAST_CALLS=1` prints 33 joint calls for 32
emitted tokens. Same first-max argmax and softmax semantics as the single-step
joint; plus cached logit pointer (no per-step array reallocation).

**Accuracy (hard gate)**: byte-identical transcripts vs `parakeet` —
**0 diffs / 2920 files** (dictation + test-clean + loadable edge), and
`--compare parakeet,fast --runs 1 /tmp/edge32/*.wav` → agree **1.0000**, WER 0.00.

**Timing (VM)**: `--compare parakeet,fast --runs 30 --idle 20 testdata/subset/*.wav`
→ warm p50 **194.9 vs 193.4 ms** — a wash on CPU: each wide call computes 188
positions (~72× the FLOPs of one step), offsetting the saved dispatches. On ANE,
per-dispatch overhead is the dominant joint cost → hypothesis: `fast` wins on M1.
**Ship as opt-in engine (`fast`/`fastall`), needs-M1 verdict.**

Commands:
```
WHISP_FAST_CALLS=1 .build/release/whisp-bench --engine fast <files>
.build/release/whisp-bench --compare parakeet,fast --runs 30 --idle 20 testdata/subset/*.wav
# byte-identical: run default mode per engine over the gate list, diff 'transcript:' lines
```

## Lever 2 — pipeline slack (`par2` engine + segmenter)

### Speculation pause grid (`WHISP_SPEC_PAUSE_FRAMES`, default was 20 = 200 ms)

`whisp-bench --replay --engine parakeet` last-word-ok / wait p50:

| spec | dictation subset (12) | stitched (15) | edge quiet/midword (27) | verdict |
|------|---------------------|---------------|------------------------|---------|
| 10 (100 ms) | last-word **91.7–96.3%** | — | — | **FAIL** (mid-word dips truncate) |
| 15 (150 ms) | 100%, p50 82 @+100 | 100% | **77.8%** vs 83.3% base | **FAIL** (1 new dropped word) |
| 18 (180 ms) | 100%, p50 **86 @+100, 36 @+150** | 100%, ~0Δ | **83.3% = base** | **SHIP** |
| 20 (200 ms) | 100%, p50 100 @+100, 50 @+150 | 100% | 85.2/83.3% (pre-existing loss) | baseline |

spec=18: spec-hit 100% vs 75% at +100 ms; edge last-word identical to 200 ms at
every offset (the 85.2/83.3% losses exist at 200 ms too — properties of the
quiet/midword test audio, not the segmenter). Default flipped 20→18.

Commands:
```
WHISP_SPEC_PAUSE_FRAMES=18 .build/release/whisp-bench --replay --engine parakeet testdata/subset/*.wav
WHISP_SPEC_PAUSE_FRAMES=18 .build/release/whisp-bench --replay --engine parakeet /tmp/edge32/*.wav
```
(`/tmp/edge32` = edge wavs with corrected float32 fmt headers — the stock edge
files declare 16-bit float while containing float32, so `loadSamples16kMono`
rejects them. Pre-existing harness limitation, not a Track-D regression.)

### Chunk-cut pause (`WHISP_MIN_PAUSE_FRAMES`)

Grid 20/27/35 on subset: **35 optimal** (20 strictly worse at every offset —
cuts too eagerly inside phrase-internal quiet). No change.

### Parallel tail decode lane (`unifiedLanes`, `par2` engine)

`transcribe()` used to await `chunks.inFlight` serially, then decode the tail.
Now, when a release lands mid-chunk-decode with a deterministic tail
(non-silent, no spec coverage), the tail decodes on a second
`UnifiedAsrManager` lane concurrently: `wait = max(rem, tail)` instead of
`rem + tail`.

Measured on subset via instrumented replay (patched `simulateRelease` prints
`[par2] off rem tail`; instrumentation not shipped): p95 **357→309 ms (−48)**;
p50 ~0 — only ~2/27 releases race an in-flight decode, saving ~340 ms each.
Text identical by construction (fires only when the tail is deterministic);
with `lanes=1` the queue makes behavior identical to serial. Cost of lanes=2:
one extra model set (~600 MB RAM). App wiring stays lanes=1 (`ASREngine.make`
uses `ParakeetTranscriber()`); `par2` engine proves the headroom for the owner
to flip. **Ship opt-in.**

## Lever 3 — mic tail (dead end, documented)

`--mic-drop 100` and `--mic-drop 20` both give last-word **96.3%** at +0 ms
release (1/27 file loses the final word) and **100% at ≥+50 ms**. `stop()` drops
the in-flight IO buffer; device IO quantum is ~100 ms on this VM (~10–20 ms on a
real M1 — much smaller exposure there). A drain-wait fix would add release→paste
latency — self-defeating for the p50≤100 ms target — and the tap bufferSize is a
hint the HAL ignores anyway. **No latency-safe fix inside owned files; the ~4%
edge is real but VM-quantum-inflated.**

## Lever 4 — paste path

`Paster.swift` read: AX focus + ⌘V with a 20 ms timeout, no fixed sleeps on the
release path. The frontmost-app recheck before ⌘V landed via the lead
(@4e3ca66). Nothing safe to cut. **No change.**

## Lever 5 — first-decode penalty

`prepare()` loads all models eagerly at composition; `rewarm()` covers >20 s
idle (all transcribers implement it). First-decode is already off the release
path. **Documented, no change.**

## Audit fixes folded in (correctness, not speed)

- `enqueueTranscription`: bail `id <= cancelledThrough` at task start — Esc
  while a dictation waits on the transcriber no longer spends a decode on it.
- `hotkeyPermissionLost`: `cancelCapture()` when recording — the capture used
  to run to the 10-min cap after permissions were revoked.

## Harness note (Track A)

`ReleaseReplay.collectEvents` indexed an `ArraySlice` by absolute index
(`pending[..<cut]`) — trap on multi-cut files / wrong span otherwise. Ran
locally with `pending.prefix(cut)` to measure; **fixed upstream @113e28c**.

## Test gate

`swift run -c release whisp-tests` → **270/270** on `speed/track-d-runtime`
at each commit.
