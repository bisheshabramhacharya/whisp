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

## Warming the window does not close the base gap, but it does cut the tail

`--live` replays through `DictationController`, so each number below is the
app's own key release to pasted text. `WHISP_PREWARM_MS` and `WHISP_PREWARM=off`
are bench knobs; the app's default is unchanged at 8 s.

**First pass, 24 takes** (16 of 1-3.5 s, 8 of 4-8 s), four settings, same takes
and order:

| prewarm | release->paste p50 (<=5 s) | wake-ups per take p50 | engine work per take p50 |
|---|---|---|---|
| off | 83 ms | 0 / 0 ms | 90 ms |
| default (8 s idle) | 78 ms | 0 / 0 ms | 92 ms |
| idle over 300 ms | 78 ms | 6 / 288 ms | 371 ms |
| every tick | 89 ms | 23 / 1096 ms | 1237 ms |

At 24 takes this read as a clean no: the release decode was 77-88 ms in every
setting with the encoder at 36-37 ms, so warming bought nothing. That sample was
too small to see the tail. 33 sub-5 s takes is where the difference lives.

**Doubled sample, 47 takes** (33 under 5 s, 14 at 4-8 s), same order, short
group only (`--json` per take, so these are per-take medians, not bucket rows):

| prewarm | release->paste p50 | p90 | takes over 100 ms | encoder p50 | encoder p90 | wake-ups / work per take |
|---|---|---|---|---|---|---|
| off | 85 ms | 139 ms | 14 of 33 | 46 ms | 68 ms | 0 / 0 ms |
| default (8 s) | 88 ms | 132 ms | 14 of 33 | 37 ms | 68 ms | 0 / 0 ms |
| idle over 300 ms | 74 ms | 101 ms | 5 of 33 | 36 ms | 37 ms | 5 / 247 ms |
| every tick | 80 ms | 129 ms | 12 of 33 | 36 ms | 72 ms | 22 / 1009 ms |

The 300 ms setting is the first one that changes the shape of the wait: the
slow takes mostly stop happening (5 over a tenth of a second against 14), and
the encoder stops spiking (p90 37 ms against 68 ms). The median encoder barely
moves, 37 to 36, so the win is entirely in the tail.

**Repeat, 32 short takes, order reversed** (default, 300 ms, 300 ms, default), to
test whether the third slot in the first pass explained it:

| pass | release->paste p50 | mean | p90 | encoder p50 | wake-ups / work | engine work p50 |
|---|---|---|---|---|---|---|
| default | 84 ms | 86 ms | 131 ms | 37 ms | 0 / 0 ms | 109 ms |
| 300 ms | 68 ms | 66 ms | 99 ms | 35 ms | 5.0 / 249 ms | 332 ms |
| 300 ms again | 68 ms | 64 ms | 94 ms | 35 ms | 5.5 / 233 ms | 335 ms |
| default again | 72 ms | 77 ms | 130 ms | 37 ms | 0 / 0 ms | 86 ms |

So it is the setting, not the run order. 300 ms wins in both adjacent pairs
(84 to 68, 72 to 68), the two 300 ms runs agree with each other (68 and 68) while
the two default runs do not (84 and 72), and the p90 belongs to the warm runs
(94-99) and never to the cold ones (130-131). Per take, the spread across all
four passes has a 39 ms median, which is why no single-take comparison proves
anything and why the 24 take sample missed it.

The cost is real too: 332-335 ms of dummy work per take against 86-109 ms, about
three times the engine work, for a tenth of a second off the slow takes. Warming
harder is not better. Every tick runs 22 wake-ups and 1,009 ms of dummy work per
take and lands back at 80 ms p50 with the encoder tail intact (p90 72 ms),
because the dummies queue ahead of the decode the release is waiting for. 300 ms
idle is the setting that keeps the window warm without competing with it.

## The base gap is still not explained by warmth

The live path pays 35-37 ms of encoder on a release against 22-23 ms for the
same window in a warm `--stages` decode, and no prewarm setting closes that: the
warm runs here sit at 35, not 22. Warming only removes the 68-72 ms outliers
above it. So the 13-15 ms that a live decode costs over a bench decode is not
ANE idle, and dummies do not touch it. `--idle-curve` on one 1.7 s clip does
show an idle penalty in a bench process (0 ms 39, 100 ms 49, 500 ms 54, 1000 ms
58, 2000 ms 49, 4000 ms 50, 8000 ms 91), which is what made warming look
promising; the live path does not behave that way.

That leaves the live context: the priority and thread the release decode task
runs on (a plain `Task {}` inherits its priority from the main-actor call that
starts it in `DictationController.stopCapture`), whatever the capture loop still
has awake at the moment of release, and the second encoder lane the transcriber
keeps for overlapping decodes. Next thread measures those, not the encoder's
warmth. Implementation waits on BIS-19.

## Nothing here changes the app

With the stock 8 s threshold, no wake-up fires for a take under about 5 s (0
measured), so what the app does today is the "default" row: zero cost and the
slower tail. Changing the threshold to 300 ms is a real trade (a tenth of a
second off the slow short takes, three times the engine work, on a machine that
a tenth of a second off the slow short takes, three times the engine work, a
warmer machine all day) and it belongs with the threshold itself in BIS-18, not
with this measurement branch. This branch ships the bench flags, the per-take
JSON and these notes. The default stays at 8 s.

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
