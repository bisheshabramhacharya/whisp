# Model candidates, and the rule that judges them

The short bucket is the common case and it still waits about 85 ms, so the largest
remaining lever is a model that decodes faster without losing words. This page
holds the shortlist and the rule, so the same question does not get answered two
different ways.

## The rule

A model is judged on the owner's real recordings and on the last-word gate. WER on
the `say`-generated dictation set does not decide it, and a model that turns "whole
entire thing" into "whole target thing" on a real take is not a candidate whatever
number it prints. No model is tuned to a synthetic corpus, and the say-set WER is
reported for context rather than as the metric.

The gate, concretely: the twelve owner recordings whose final speech run is 5 to
10 s, whole clip and warm, word-identical text, and no new dropped last word. Then
WER against `whisper large-v3` full on a fixed slice as the accuracy number, because
two independent transcribers do not agree closely enough to serve as exact
references: `whisper turbo` and Apple's transcriber agree on only 0.8 percent of 650
recordings strictly.

## What was measured, and why nothing displaced unified

Twelve owner recordings whose final speech run is 5 to 10 s, 204 s of audio in
total, whole clip through the Parakeet path, one process per model, warm-up then one
measured decode per clip. `--model` aliases as on `bis25`, and `ultra` from the probe
branch, because the shipped enum does not carry it.

| model | p50 | worst | last word kept | words disagreeing with unified |
|---|---|---|---|---|
| unified (shipped) | 139 ms | 636 ms | **11 of 11** | baseline |
| v3 | 137 ms | 740 ms | 9 of 11 | 68 of 525 |
| 110m | **51 ms** | **112 ms** | 8 of 11 | 105 of 525 |
| ultra | 128 ms | 730 ms | 8 of 11 | 66 of 525 |

A first decode after load gives 143, 166, 51 and 144 ms in the same order, so the
ordering is not a cold-start artifact; 110m is 2.7 times faster at p50 and 5.7 times
at worst in both runs.

Three cautions, because the table is easy to over-read:

- These are whole-clip decodes on the 15 s window path. The shipped default decodes a
  release on the 5 s window at 30 to 40 ms, so this table compares the models with
  each other and not with what a person feels at release.
- "Words disagreeing with unified" is not accuracy. Unified is not truth. It says
  these two engines disagree on a fifth of the words for 110m, which is a reason to
  distrust 110m only together with the real-speech examples that follow.
- Every candidate drops the last word on the same three clips, 2, 5 and 11, and
  unified keeps it on all three. Clip 6 loses it for all four including unified. Those
  four clips are where the twelve-clip gate earns its keep, and they are the reason
  the set exists.

110m is the only candidate that is faster, and it pays with the last word on three
clips where the shipped model keeps it, plus a fifth of the words. v3 and ultra are
slower than unified and drop the last word on three clips each. `ultra` needed a
download and first load of 58 seconds, and is not faster than the shipped model
despite the name.

**Verdict: the shipped model stays.** No WER run was taken, deliberately: a candidate
has to survive the twelve clips first, and none did, so 110 minutes of reference WER
would not have changed the answer. If 110m is ever re-traced at 5 s, the twelve clips
are the first thing it has to pass again.

## The structural constraint

The 5 s and 10 s encoders are re-traced copies of the unified encoder. A candidate
model exists at 15 s only until someone re-traces its encoder at 5 s with
`tools/convert/`. So a model swap without a re-trace makes the common short take
slower, not faster, which is the opposite of the point.

## The shortlist, in the order it should be tested

1. **ultra.** Same v3 architecture and contract, better than v3 on every published
   benchmark. Its own documentation warns that the int8 encoder flips tokens on some
   windows, so the twelve-clip gate is the first thing it has to survive.
2. **110m.** The only candidate that is fast on the current architecture, 51 ms p50,
   and the only one whose speed could move the short bucket without a re-trace.
3. **v3.** A newer checkpoint at the same speed as unified; worth the WER number and
   unlikely to be worth a swap on its own.
4. **redux.** Last. A 183 MB 2-bit encoder, English worse than v3, first load took
   8 minutes once and was not re-run after that, warm-up 145 ms on a 1.7 s clip
   against unified's 86, and 2.17 GB peak RSS on an 8 GB machine. It was run once
   with the log open as the crew decided: if it is broken at this version, it is
   recorded as broken, and no further block goes into it.

## What comes next

`ultra` through the twelve takes at 15 s first, because it is the candidate most
likely to beat the shipped model on text. Then 110m and v3 get WER against
`whisper large-v3` on the fixed slice, and only a model that survives both is worth
re-tracing at 5 s to keep short takes fast.
