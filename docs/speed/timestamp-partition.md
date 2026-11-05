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

Three numbers describe the shape. `L`, the left context, is the audio a commit
decodes before its own span; `A`, the right context, is the audio after it; `R`, the
release overlap, is how far before the last commit the release window starts. Both
`L` and `A` are 1.0 s here and `R` is 0.5 s.

The live loop commits the audio older than a 1 s held-back bound, once a second. A
commit decodes `L` behind its span and `A` after it, and keeps only the words that
start inside the span. The release decodes from `R` before the last commit to the
end and keeps words that start at or after it, so the release piece is just the last
piece. `join` keeps its casing rules and nothing else: no dedupe anywhere.

On a 5 s encoder window those constants leave room rather than exhaust it: a 1 s
span with `L` 1 s and `A` 1 s fills 3 s of the 5 s window, so about 2 s of window
went unused. `A` was fixed at 1 s by a constant, not by the window, and a larger `A`
was never tried.

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

## The three second cadence, and the end of the direction

A seam every second leaves too little context, so the fair next move was to commit
less often. Three seconds is the most a 5 s window can carry: `L` 1 s, the span 3 s
and `A` 1 s fill it exactly, and a four or five second commit would push every
decode to the 15 s encoder and cost three to five times the encoder pass per
commit. Same gate, same takes, one seam every three seconds:

| | take 1, 11 phases | take 2, 11 phases |
|---|---|---|
| main, distinct transcripts | 1 | 2 |
| one second cadence | 3 | 5 |
| three second cadence | 3 | **2**, equal to main |
| three second cadence, edits vs reference per phase | 8 in 10 phases, 11 in 1 | 2, level with main |

Take 2 reaches main's stability, which was the expected direction. Take 1 does not:
one phase loses the repeated phrase and one reads 4,200 instead of 4,299, so the
transcript still moves with the phase. The prediction that fewer seams would make
the two identical copies share a span and collapse more often did not hold either;
the repeat survives in 10 of 11 phases. Both readings agree on the same thing: the
seam is the problem, not how often it falls, and a seam inside speech is not safe
at this window size.

Release to paste, same takes: 101 to 162 ms at three seconds, mostly about 150,
against main's 65 to 108. The direction closes here. A wider encoder window, where
one seam sits inside tens of seconds of context, is the only thing that would change
these rows, and that is a model and converter change rather than a cut policy.

## Why it fails, and it is two effects, not one

Take 2 is the context effect. "Chez Panisse" comes out as Chepanas, Cheapanis, Che
Pennis and Shea Chepanas in different phases: the same word decoded in a window that
begins in one place and a window that begins a second later gets whichever spelling
that window's context produced. Ownership by start time decides who keeps a word,
not what it says, so the transcript inherits a spelling that moves with the phase.

Take 1 is the other effect, and it is cut placement rather than context. The two
"play some music" clips are identical and sit next to each other with no gap. When a
seam falls between them, each copy is inside its own span and both survive, which is
why 9 of 11 phases keep the repeat where a single decode collapses it. In p3 and p7
a single span holds both copies and the model returns one, exactly as main does. The
repeat's survival is the seam landing in the right place, not the partition
understanding the audio.

That distinction matters for what comes next, and it is the opposite of what an
earlier draft of this document said: a larger commit interval means fewer seams,
which means the two identical copies share one span more often and collapse more
often. Fewer seams buy stability and cost the repeat. The two effects pull in
opposite directions on this pair of takes.

What is certain from this run: a seam every second leaves each word a couple of
seconds of context on a 5 s window, so the transcript moves with the phase, and no
value of `R` or `A` changes how much context the model has when it decides a word.
`R` only moves the start of the release window and `A` only adds audio after a span;
neither changes the evidence the model had. A different commit interval is a
different shape, and the counter-argument above is why it is not obviously better.

The earlier attempt at this idea, by the sidecar this was modelled on, re-decodes
everything pending every 0.4 s and only commits once 60 s of audio is pending, with
20 s of left context and a 2 s release overlap inside a window that can reach 82 s
(`sidecar/stream_asr.py` in their repo at commit `2e9a5b7`, read in `reports/WHIB-10.md`
on this machine). A seam there is one per 60 s of speech sitting inside tens of
seconds of context, which is why the same primitive holds up for them and not for a
one second cadence on a 5 s window.

It is also slower at release than main on these takes, 138–156 ms against
66–108 ms, because the release decodes 1.5 s on top of decodes that already ran
during speech. The release decode on its own is 32–59 ms, which is what the design
predicted for a 1.5 s window; the rest of the latency is the paste path and the
commit still in flight at release.

## What is worth keeping

- Word times on the shipping engine, and `whisp-bench --timing-check`, which
  reports how far a word's start moves between windows. Both are in the branch and
  neither changes what a user gets today.
- The frame-alignment rule, without which the same word moves by up to 80 ms
  between windows.
- The measurements above, so the next attempt starts from them.

The branch `bis27-partition` holds all of it. Nothing here ships.
