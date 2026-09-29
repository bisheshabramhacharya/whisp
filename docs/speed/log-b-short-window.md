# Track B speed log — shorter encoder window

All numbers below are **VM numbers** (VirtualMac: GPU+CPU only, no Apple Neural
Engine). They are relative A/B measurements on this VM, not M1 values.

## Lever

The offline Parakeet Unified encoder (`parakeet_unified_encoder_int8.mlmodelc`)
is traced at a fixed mel input of `[1, 128, 1501]` = 15 s. Every decode pays a
15 s encoder pass (~80 % of decode time on this VM: ~113 of ~137 ms for a 5 s
clip, per `--profile`). `ShortWindowEngine` re-exports the same weights at
shorter fixed windows (`parakeet_unified_encoder_w{ms}[_int8].mlmodelc` via
`tools/convert/convert-short-window.py`) and picks the smallest window that fits
the gated (silence-checked, trimmed, ≥0.3 s-padded) input. Everything else —
mel, greedy RNNT, tokenizer — is unchanged.

* Windows shipped/tested: **w2000** (mel `[1,128,201]`) and **w5000**
  (`[1,128,501]`), int8 per-channel symmetric quantized, iOS17 target, same
  recipe as the stock FluidAudio export (mobius `convert-coreml.py`).
* Engine name `short`: `defaults write com.bishesha.whisp asrEngine short`
  or `whisp-bench --compare parakeet,short`.
* Fallbacks: no short bundles in the model cache → stock 15 s encoder;
  input > 15 s → `UnifiedAsrManager` sliding-window path.

### Why parity holds

Parakeet's encoder uses **full attention** (`att_context_size = [-1,-1,-1]`):
attention is masked by `mel_length` only, and mel `per_feature` normalization
uses only valid frames — identical to the 15 s model's mask on the same input.
Conformer convs see the same zero-padded right edge as the 15 s export. So the
valid-region encoder outputs equal the 15 s model's up to fp/int8 rounding.
Measured: w5000-int8 vs NeMo torch encoder, 3.5 s clip — enc_len identical
(44), output corr 0.9998, mean |Δ| 0.0011.

## Results

### Transcript equality (WER gates)

```
whisp-bench --compare parakeet,short --runs 3 <files>
```

| Set | files | parakeet WER | short WER | word agreement |
|---|---|---|---|---|
| LibriSpeech test-clean (first 250, sorted) | 250 | 2.36 | 2.24 | 1.0000 |
| LibriSpeech test-other (first 500, sorted) | 500 | 5.79 | 5.79 | 0.9999 |
| Dictation set (all 300) | 300 | 0.00 | 0.00 | **1.0000** |

Disagreements vs parakeet: **1 file of 1050** —
`test-other/1688/142285/1688-142285-0000.flac` (exactly 15.0 s). short scored
WER 0.00 vs reference, parakeet 3.03 — parakeet's ≥15 s chunked path lost one
word ("ANON" tail); not a regression.

### Interleaved A/B timing — release-tail distribution

30 dictation files, 1.6–10.8 s (short commands / questions / names; spans the
w2000, w5000 and 15 s-fallback paths):

```
whisp-bench --compare parakeet,short --runs 30 --idle 30 <30 files>
```

| engine | warm p50 | warm p95 | idle30+rewarm p50 | idle30+rewarm max |
|---|---|---|---|---|
| parakeet | 123.7 ms | 153.1 ms | 125.6 ms | 158.7 ms |
| short | **38.9 ms** | 150.3 ms | **38.8 ms** | 158.0 ms |

**VM decode p50: 123.7 → 38.9 ms (-68 %).** p95 unchanged — the p95 files are
the >5 s clips that still pay the stock 15 s window (a w8000 bundle would pull
those down too; weights dominate bundle size, not window length).

Earlier 1.7 s probe (w2000): `compare parakeet,short --runs 3` on 3 blip files:
116.8 → 32.8 ms p50.

### Release replay — `whisp-bench --replay`

Dictation set **minus three >4 min monologues** (`long-103/104/105`,
267–554 s): the replay harness SIGTRAPs on them for **both** engines
(pre-existing Track-A tooling limit; `whisp-bench --replay --engine parakeet
testdata/dictation/long-103.wav` reproduces the trap). 297 files:

```
whisp-bench --replay --engine parakeet <297 dictation wavs>
whisp-bench --replay --engine short    <297 dictation wavs>
```

| offset | wait p50 parakeet | wait p50 short | last-word ok parakeet | last-word ok short |
|---|---|---|---|---|
| +0 ms | 123 | **40** | 99.0 % | 99.0 % |
| +50 ms | 123 | **40** | 99.0 % | 99.0 % |
| +100 ms | 117 | **35** | 99.0 % | 99.0 % |
| +150 ms | 68 | **0** | 99.0 % | 99.0 % |
| +200 ms | 19 | **0** | 99.0 % | 99.0 % |
| +350 ms | 0 | 0 | 99.0 % | 99.0 % |
| +600 ms | 0 | 0 | 99.0 % | 99.0 % |
| +1000 ms | 0 | 0 | 99.0 % | 99.0 % |

**Zero new dropped final words vs `parakeet` at every offset** — identical
99.0 % last-word survival, and the whole-clip transcripts are already known to
be word-identical (dictation agreement 1.0000 above), so no file can drop a
different final word. Wait p50 at release+0 ms drops 123 → 40 ms; by +150 ms
the tail decode is already speculated in-flight often enough that p50 wait is 0.


## Commands that produced the numbers

```bash
# conversion (in tools/convert/): NeMo checkpoint -> traced short windows -> int8 -> mlmodelc
uv run --no-sync python convert-short-window.py --windows 2,5 --validate

# gates
swift run -c release whisp-tests                       # 270/270
.build/release/whisp-bench --compare parakeet,short --runs 3 <test-clean 250 flacs>
.build/release/whisp-bench --compare parakeet,short --runs 3 <test-other 500 flacs>
.build/release/whisp-bench --compare parakeet,short --runs 3 <dictation 300 wavs>
.build/release/whisp-bench --compare parakeet,short --runs 30 --idle 30 <30 dictation wavs>
.build/release/whisp-bench --replay --engine parakeet|short <297 dictation wavs>
```

## Dead ends / notes

* **Path A dead**: stock encoder input is fixed `[1,128,1501]` — no range dim.
* Streaming encoders (625/769 mel frames): chunked attention loses the zero-WER
  gate (HF-reported aggregate WER 2.25–2.47 % vs batch 1.68 %). Not used.
* Multi-function CoreML bundle (w2000+w5000 sharing one weight blob): merges
  and compiles, but multifunction mil forces the `<ios18>` target — whisp is
  macOS 14 → unusable. Also `linear_quantize_weights` rejects multifunction
  models.
* 4-bit palettization (`per_grouped_channel`): requires iOS18 — same dead end.
* Weight sharing across window bundles: `weight.bin` layouts differ per window
  (window-dependent consts baked at trace time) — can't share one blob.
* Release size: w2000_int8 + w5000_int8 = 1.12 GB > the 1 GB cap → owner
  decision: **no release upload at all** — m1-check builds w5000 on-device via
  `tools/convert` (see "M1 check instructions" below); w2000 stays a
  documented local drop-in (same naming convention).

## M1 check instructions

A scratch checkout can reproduce the whole lever on a stock Mac (Xcode CLT +
`uv`) — no committed binaries, no GitHub release download. The w5000 encoder
builds from the public HF `.nemo` checkpoint (~2.4 GB, auto-downloaded once):
the compiled mlmodelc already in the FluidAudio cache is *not* a usable
conversion input.

```bash
git clone https://github.com/bisheshabramhacharya/whisp && cd whisp
git checkout speed/track-b-short-window   # or speed/all after merge
swift build -c release

# one-time: build + install the 5 s window encoder into the FluidAudio cache
cd tools/convert
uv sync
uv pip install --no-deps --force-reinstall \
  "nemo_toolkit @ git+https://github.com/NVIDIA-NeMo/NeMo.git@95f92737cfb8ee0123bb328b07a2d24c6d859aff"
uv run --no-sync python convert-short-window.py --windows 5 --validate --install
cd ../..
```

`--install` drops `parakeet_unified_encoder_w5000_int8.mlmodelc` into
`~/Library/Application Support/FluidAudio/Models/parakeet-unified-en-0.6b/` —
the exact directory `ShortWindowEngine` scans (`w{ms}[_int8].mlmodelc`
naming convention; `_int8` preferred per window).

```bash
# A/B timing: decode p50 parakeet vs short, warm + idle(30s)+rewarm
.build/release/whisp-bench --compare parakeet,short --runs 20 --idle 30 <wavs...>

# release replay over a WAV folder: last-word-ok per offset per engine
.build/release/whisp-bench --replay --engine short <dictation wavs>
.build/release/whisp-bench --replay --engine parakeet <same wavs>   # baseline
```

Generate clips if none exist: `scripts/speed/gen-dictation.sh` (300 `say`
wavs into `testdata/dictation/`). For <2 s clips also build `--windows 2,5`
(w2000 shaves ~20 ms more; not needed for the p50 gate).
