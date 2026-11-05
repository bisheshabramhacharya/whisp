# Committing while you talk, with words owned by start time

The first attempt at a 1 s cadence cut pieces with a 0.6 s audio overlap and then
decided in `SpeechSegmenter.join` which repeated words to drop by matching text.
String matching is a guess, and a guess that fails once is a wrong or doubled word.
This attempt removes the guess: a word belongs to the piece whose audio span
contains the word's own decoded start time, and every piece decodes a window wider
than its span so the word is heard whole wherever it sits.

It fails the same gate the first attempt failed, for a different reason, and the
numbers are below.

## What was built

The live loop commits the audio older than a 1 s held-back bound, once a second. A
commit decodes a second of left context behind its span and a second of right
context after it, and keeps only the words that start inside the span. The release
decodes from 0.5 s before the last commit to the end and keeps words that start at
or after it, so the release piece is just the last piece. `join` keeps its casing
rules and nothing else: no dedupe anywhere.

Word times come from the engine that the app actually runs. That was the first
thing this work found: the timed decode had been written on `ParakeetTranscriber`
while the default engine is `ShortWindowEngine`, so the partition would never have
run for a user. `ShortWindowEngine` now reports the encoder frame each token was
emitted on, one frame being 80 ms (`config.frameSamples / config.sampleRate`), and
both the trim and the decode window are rounded down to that frame grid. Without
the alignment the same word moved by up to a frame between windows; with it, word
starts agree exactly except for a handful right at a window edge:

| Check (`whisp-bench --timing-check`, 5 window offsets) | result |
|---|---|
| take 1, 28 words compared | 3 words moved one 80 ms frame, the rest identical |
| take 2, 60 words compared | 4 words moved one 80 ms frame, the rest identical |

## The gate

Eleven phase shifts of 100 ms on two spliced takes, through the live controller:
`whisp-bench --live --json --engine short --gap 1`, 22 runs per build. The takes are
8.8 s and 8.4 s of three say-set clips spliced with no gap, and their reference is
the concatenation of those clips' `.txt` files, 17 and 15 words, normalized the way
the scoreboard normalizes.

Both builds were measured in the same window with no other benchmark running. An
earlier pair of runs was discarded: it overlapped another thread's reference block
and its latency numbers are suspect.

| | take 1 | take 2 |
|---|---|---|
| main, edits vs reference per phase | 11, all 11 phases identical | 2, 2 distinct transcripts in 11 |
| partition, edits vs reference per phase | 8 in 9 phases, 11 in 2, **3 distinct transcripts** | 2 in 10 phases, 3 in 1, **5 distinct transcripts** |
| main release→paste | 66–108 ms | 65–108 ms |
| partition release→paste | 138–156 ms | 98–156 ms |

The partition is better on take 1 because it recovers a phrase the whole-clip
decode collapses: two identical "play some music" clips butted together are one
phrase to a single decode, and two commits see two. That gain is real and it is not
enough, because the transcript is no longer the same twice:

- take 1, 2 of 11 phases lose the second "play some music", and the figure lands on
  4,2, 4,290, or 4,2 across phases;
- take 2, "Chez Panisse" comes out as Chepanas, Cheapanis, Che Pennis, and Shea
  Chepanas in different phases, and one phase drops "Book".

## Why it fails

A seam is every second. The model is decoded per window, and the same word decoded
in a window that begins in one place and a window that begins 1 s later does not
always come out with the same text: it comes out as whichever spelling the context
that window had produced. Handing the word to one piece by start time decides *who
keeps it*, not *what it says*, so the transcript inherits a per-window spelling
that moves with the phase.

The other attempt at this idea committed every 30 s on an 82 s encoder window, so
each seam sat inside tens of seconds of context. Our window is 5 s. Per-second
commits on a 5 s window leave each word with a couple of seconds of context, and
that is where the spellings diverge.

This is not a value of R or A to tune. R only decides how far back the release
window starts, and A only decides how much audio follows the span; neither changes
how much context the model has when it decides a word. A larger commit interval
would, and that is a different shape: one seam per window instead of one per
second, at the cost of a bigger release tail.

It is also slower at release than main on these takes, 138–156 ms against
66–108 ms, because the release now decodes 1.5 s on top of decodes that already
ran during speech. The release decode on its own is 32–59 ms, which is what the
design predicted for a 1.5 s window; the rest of the latency is the paste path and
the commit that is still in flight at release.

## What is worth keeping

- Word times on the shipping engine, and `whisp-bench --timing-check`, which
  reports how far a word's start moves between windows. Both are in the branch and
  neither changes what a user gets today.
- The frame-alignment rule, without which the same word moves by up to 80 ms
  between windows.
- The measurements above, so the next attempt starts from them.

The branch `bis27-partition` holds all of it. Nothing here ships.
