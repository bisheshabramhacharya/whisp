# Release-to-text on short takes: where the wait is, and why warming it does not help

Measured on the Mac Mini (M1, 8 GB, real Neural Engine), one benchmark at a
time, `whisp-bench --live --engine short` replaying the owner's own recordings
in place (counts and numbers only, no audio or text leaves the machine).

## The felt wait is the decode

16 takes of 1-3.5 s (clip p50 2.4 s), release landing right after speech:

| piece | p50 |
|---|---|
| release -> paste | 68 ms |
| waiting on a decode already in flight | 0 ms |
| decode started after release | 68 ms |
| mic stop + chunk flush + enqueue + clean + paste + scheduling | 1 ms or less |

Nothing waits behind an in-flight decode, because a take that ends in speech
never gets a speculation. So the ~38 ms that a 88 ms scoreboard p50 and a 49.5 ms
bench decode seemed to leave unaccounted for is not overhead: the live path
decodes slower than a warm bench decode of the same work, and the sampled takes
are longer.

## Warming the window does not close that gap

`--live` on 24 takes (16 of 1-3.5 s, 8 of 4-8 s), four prewarm settings, same
takes and order. `WHISP_PREWARM_MS` and `WHISP_PREWARM=off` are bench knobs; the
app's default is unchanged at 8 s.

| prewarm | release->paste p50 (<=5 s) | wake-ups per take p50 | engine work per take p50 |
|---|---|---|---|
| off | 83 ms | 0 / 0 ms | 90 ms |
| default (8 s idle) | 78 ms | 0 / 0 ms | 92 ms |
| idle over 300 ms | 78 ms | 6 / 288 ms | 371 ms |
| every tick | 89 ms | 23 / 1096 ms | 1237 ms |

Read it twice: **the release decode is 77-88 ms in every configuration**, with
the encoder at 36-37 ms whether anything was warmed or not. Warming costs 4x the
engine work at a 300 ms threshold and 13x at every tick, and buys nothing: the
one setting with a lower p50 (78 against 83) ran no wake-ups at all, so that
difference is run-to-run noise, not the mechanism.

`--idle-curve` on one 1.7 s clip does show an idle penalty in a bench process
(0 ms 39, 100 ms 49, 500 ms 54, 1000 ms 58, 2000 ms 49, 4000 ms 50, 8000 ms 91),
which is what made warming look promising. The live path does not behave that
way: it pays ~36 ms of encoder on every release regardless. So the live-path
encoder gap against a warm bench decode (36 against 22-23) is not ANE idle, and
dummies do not touch it. Next thread should look at the live context instead:
thread and QoS of the release decode task, and whatever the capture loop leaves
running, not at the encoder's warmth.

## The default is left alone on purpose

With the 8 s threshold, prewarm never fires for takes under about 5 s (0
wake-ups measured), so it is dead code on the path this thread owns; forcing it
on makes the wait worse. Where it does fire is long takes, which belong to
BIS-18, and the notes there already record a 5 s dummy at ~100 ms and a 15 s
dummy at ~115 ms competing with the window the release needs. That is the same
result from the other side: a dummy is not cheap.

## Weights cannot get smaller on this deployment target

Both routes to fewer weight bytes are refused by Core ML on a macOS 14 target:

- 4-bit linear quantization: `The 4-bit quantization is supported since iOS18.
  Please re-convert your model with minimum_deployment_target set to at least
  ct.target.iOS18.`
- Per-group palettization (the useful one for Conformer weights): same error for
  `per_grouped_channel`, which is the only granularity coremltools offers for
  palettization besides `per_tensor`.

`per_tensor` palettization is allowed at iOS17 and is far too coarse for these
weights. So encoder, decoder and joint stay int8/fp16 until the OS floor moves,
and the remaining decode terms are the ones already measured: ~23 ms fixed
encoder pass on the 5 s window, 0.21 ms per joint call, 0.6 ms per decoder call.
