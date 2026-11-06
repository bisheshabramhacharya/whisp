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

At 24 takes this read as a clean no: p50 78-89 ms across the four settings in no
useful order (the setting with the most warming was the worst of them), so
warming looked worthless. That sample was too small to see the tail, and it did
not break out the encoder. 33 sub-5 s takes is where the difference lives.

**Doubled sample, 47 takes** (33 under 5 s, 14 at 4-8 s), same order, short
group only (`--json` per take, so these are per-take medians, not bucket rows):

| prewarm | release->paste p50 | p90 | takes over 100 ms | encoder p50 | encoder p90 | wake-ups / work per take |
|---|---|---|---|---|---|---|
| off | 85 ms | 139 ms | 14 of 33 | 46 ms | 68 ms | 0 / 0 ms |
| default (8 s) | 88 ms | 132 ms | 14 of 33 | 37 ms | 68 ms | 0 / 0 ms |
| idle over 300 ms | 74 ms | 101 ms | 5 of 33 | 36 ms | 37 ms | 5 / 247 ms |
| every tick | 80 ms | 129 ms | 12 of 33 | 36 ms | 72 ms | 22 / 1009 ms |

Start with the floor, because it decides how much of this is real. `off` and the
stock 8 s default both fire zero wake-ups: they are the same configuration
measured twice. They read 83 against 78 at 24 takes, 85 against 88 here, and 84
against 72 in the reversed-order repeat below. That is 5 to 12 ms of drift on the
median with nothing changed. The encoder shows it too: `off` pays 46 ms p50 in
this table against 37 for the default, and with no wake-ups in either there is
nothing but session warm-up to explain the difference, because `off` ran first.

Against that floor, the 300 ms setting moves the median and changes the shape of
the wait, and only the second part survives the noise. The median encoder barely moves, 37 to 36, and its p90 stops being a
different animal: 37 ms against 68. The slow takes mostly stop happening, 5 over
a tenth of a second against 14, and p90 falls from 132 to 101 on the wait. A
14 ms shift in p50 measured on a machine that drifts 12 ms between identical
settings is the weakest number in this file, and it is the one to distrust. The
tail numbers are the ones that hold.

**Repeat, 32 short takes, order reversed** (default, 300 ms, 300 ms, default), to
test whether the third slot in the first pass explained it:

| pass | release->paste p50 | mean | p90 | encoder p50 | wake-ups / work | engine work p50 |
|---|---|---|---|---|---|---|
| default | 84 ms | 86 ms | 131 ms | 37 ms | 0 / 0 ms | 109 ms |
| 300 ms | 68 ms | 66 ms | 99 ms | 35 ms | 5.0 / 249 ms | 332 ms |
| 300 ms again | 68 ms | 64 ms | 94 ms | 35 ms | 5.5 / 233 ms | 335 ms |
| default again | 72 ms | 77 ms | 130 ms | 37 ms | 0 / 0 ms | 86 ms |

So it is the setting, not the run order, and the proof is the p90, not the
median. The two identical default passes disagree by 12 ms on p50 (84 against
72) and by 1 ms on p90 (131 against 130). The two 300 ms passes agree on both
(68 and 68, 99 against 94). The p90 separates cold from warm by 30 ms while the
machine's own p50 drift is 12 ms, so that is the number to build on. Per take,
the spread across all four passes has a 39 ms median, which is why no
single-take comparison proves anything and why the 24 take sample missed it.

The cost is real too: 332-335 ms of dummy work per take against 86-109 ms, about
three times the engine work, for 30 ms off the p90 and the takes over a tenth of
a second cut from 14 of 33 to 5. Warming harder is not better. Every tick runs 22
wake-ups and 1,009 ms of dummy work per take and lands back at 80 ms p50 with the
encoder tail intact (p90 72 ms), because the dummies queue ahead of the decode
the release is waiting for. 300 ms idle is the setting that keeps the window warm
without competing with it.

## The gap is one Core ML round trip, and it is not the encoder

The live path pays 35-37 ms of encoder on a release, and a `--stages` loop that
decodes files back to back pays 22-23 ms for the same window. Those are not the
same situation: between dictations the engine sits idle for seconds, while the
loop never lets it idle. `--second-pass` decodes the same audio again in the
same process, on the bench's own task, right after the take, twice, which
separates the engine's state from the context the release decode runs in.

16 short takes, 2 s between them, stock 8 s prewarm:

| piece | live release decode | second decode | third decode |
|---|---|---|---|
| mel | 7.7 ms | 3.8 ms | not measured |
| encoder | 36.6 ms | 31.8 ms | 29.5 ms |
| RNNT | 29.3 ms | 22.8 ms | not measured |
| total | 70.7 ms | 55.9 ms | 53.7 ms |

What this table is for is the warm-up, and warm-up saturates almost
immediately: the second decode recovers 15 ms, the third only 4 more (pass 2
slower than pass 3 on 14 of 16 takes, mean +3.9 ms). So an encoder idled for two
seconds costs about 30 ms, not 22; the 22 ms figure is a loop that never pauses.
Its live column is not a measurement of the gap, because the 16 takes are a mix
of two kinds of take that this file used to compare against each other. That
comparison is withdrawn.

**Split the sample by what the code does before comparing, not after.** On a
take where the capture loop already decoded a chunk before the key came up, the
release decode only has the tail left, while `--second-pass` decodes the whole
clip again. Those two numbers are different amounts of work, so their difference
is not a gap. 47 takes, split by whether a chunk ran before release:

| takes | n | release decode p50 | second pass p50 |
|---|---|---|---|
| no chunk before release | 32 | 72.7 ms | 58.7 ms |
| a chunk before release | 15 | 65.0 ms | 133.9 ms |

The seam takes are the long ones, p50 6.0 s, which is why they read fast at
release and slow on the second pass: the second pass pays for audio the release
decode never touched. That negative gap is an artifact of the split, not a
result, and nothing in this file should be read off that row.

The per-stage split this note used to carry, encoder +7 ms, RNNT +6.5, mel
+3.9, came from the mixed 16-take sample, so there is no seam-free measurement
behind it. It is withdrawn here rather than restated as a number.

On the comparable takes the reading is simpler. The release decode is one Core
ML round trip, and it answers 20 to 30 ms slower at release than the same
request a moment later: 84.4 ms at release against 50.3 ms for the same audio on
the same thread. It is deterministic, slower on 14 of 14 takes. And it is not our process doing extra work: across a 73.0 ms
release window the whole process burns 2.4 ms of CPU, against 1.7 ms for the
same decode a moment later. Warm-up, this file's own polling loop, priority and
our own CPU are each measured out of it, so the wait is inside the model
service.

That leaves two jobs, tracked as BIS-21 and BIS-29. A warm window does not help
it (the 300 ms setting above leaves the base encoder time at 35-36 ms), and no
setting of the prewarm threshold will.
The mic tap delivering its last chunk and the capture loop unwinding are not the
cause; an earlier version of this section said they were, and that was wrong.
What is left is the model service itself.

One more suspect was this file's own harness: the waiting loop described in the
next section. `--poll-ms` puts a number on it there, and it comes to a few
milliseconds at most, so it cannot carry the 20 to 30 ms either.

## A bench that polls the thing it is timing, on the same actor, measures itself

The replay loop above waits for the pasted text by checking `controller.lastResult`
every 1 ms, and it does that on the main actor, which is the same thread the
release decode runs on. That is about 70 wake-ups inside a 70 ms decode, all of
them competing with the decode they are waiting for. Any number this harness
produces for the release decode carries an unknown share of its own checking
loop, and the `--second-pass` figures above are measured with no such loop
running, so part of the gap between the release decode and a second pass may
be the harness. `--poll-ms` changes the interval so the share can be measured:
same takes at 1 ms and at 20 ms, and the delta is what the loop costs.

`--poll-ms` puts a number on it. 16 short takes, two rounds, each round running
1 ms and then 20 ms over the same takes in the same order:

| round | 1 ms p50 | 20 ms p50 | paired 1 ms minus 20 ms (mean / median) | 1 ms slower on |
|---|---|---|---|---|
| 1 | 70.5 ms | 70.0 ms | -0.7 / +4.5 ms | 9 of 16 |
| 2 | 85.0 ms | 75.5 ms | +7.4 / +7.0 ms | 10 of 16 |

So the loop costs a few milliseconds at most, and it does not agree with itself
between rounds: round 1 says nothing and round 2 says about 7 ms, both inside the
12 ms this machine drifts between identical settings. It cannot carry the 20 to 30
ms the live release decode pays over the same request a moment later, so that
gap survives. The
harness's own share is now measured at a few ms rather than assumed, which is the
only honest way to keep quoting the rest.

The lesson is general and worth one line on its own: a benchmark that waits by
polling, on the same actor as the code under test, is measuring itself. Measure
that share before blaming the code.

## Nothing here changes the app

With the stock 8 s threshold, no wake-up fires for a take under about 5 s (0
measured), so what the app does today is the "default" row: zero cost and the
slower tail. Changing the threshold to 300 ms is a real trade (30 ms off the p90,
the slow takes mostly gone, three times the engine work, a warmer machine all
day) and it belongs with the threshold itself in BIS-18, not with this
measurement branch. This branch ships the bench flags, the per-take
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
