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

## What has been measured so far

Twelve owner recordings with a 5 to 10 s final speech run, whole clip, warm-up pass
on this M1:

| model | p50 | worst | words |
|---|---|---|---|
| unified (shipped) | 136 ms | 628 ms | 502 |
| v3 | 143 ms | 726 ms | 508 |
| 110m | 51 ms | 105 ms | 499 |

WER on a 25-clip `say` slice (1455 words): unified 1.03 percent, v3 0.69, 110m
0.41. That ranking inverts the real picture, because the slice is synthetic: 110m
produces visibly worse text on real takes while winning there. Do not use it to
pick.

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
