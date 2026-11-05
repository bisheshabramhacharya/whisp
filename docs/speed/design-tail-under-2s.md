# The release tail is the thing to control (BIS-19 design)

Goal: p50 under 38 / 40 / 46 ms for takes of 1-10 s, 10-60 s and 5+ min, and a
worst case under 100 ms. This note is about what the numbers say is reachable and
by which shape, so nothing promised here needs the model to be faster than it is.

## What one decode costs, measured

Four-cell and seven-cell probes, one process, idle M1 (1 minute load 1.18 to
1.41), engine code unchanged, loud input, three passes per cell. Encoder time is
flat because a window pass is fixed; the decoder scales with the audio:

| audio decoded | window | mel | encoder | decoder | total |
|---|---|---|---|---|---|
| 1.0 s | 5 s | 2.8 | 25.2 | 9.2 | **37.2 ms** |
| 2.0 s | 5 s | 2.8 | 25.7 | 15.8 | **44.3 ms** |
| 3.0 s | 5 s | 2.6 | 29.5 | 22.5 | **54.7 ms** |
| 5.0 s | 5 s | 2.5 | 24.7 | 35.3 | **62.5 ms** |
| 5.2 s | 15 s | 6.9 | 69.5 | 35.7 | **112.1 ms** |
| 12.0 s | 15 s | 7.1 | 69.6 | 83.1 | **159.9 ms** |

Pass 1 and the warm passes agree within a few ms, and the numbers match the
stage table already in this directory (5 s window 22.1 ms, 15 s window 70.3 ms).
Decoder cost is about 6.5 ms per second of audio.

Two things follow, and they are the whole design:

1. **Crossing 5 s more than doubles the cost.** 4.9 s of audio is ~61 ms; 5.2 s
   is ~112 ms, because it moves to the 15 s window. No tuning of the 15 s path
   closes that gap: the pass is 69 ms of encoder by itself.
2. **The decoder is proportional to the audio decoded at release.** Every second
   of tail is ~13 ms mel+encoder+decoder at the margin, so a 12 s tail cannot be
   under 100 ms however warm the window is.

The ceiling, therefore, is set by one number: how much audio the release still
has to decode.

Add the live path to the decode and the picture gets tighter. The owner's own
16-take row puts everything that is not the decode at 1 ms or less, so:

| release tail | decode | with path | short 38 | average 40 | long 46 |
|---|---|---|---|---|---|
| 1.0 s | 37.2 ms | ~38 ms | misses by 0.2 | meets | meets |
| 1.5 s | ~41 ms (not probed; between the 1.0 and 2.0 cells) | ~42 ms | misses | misses | meets |
| 2.0 s | 44.3 ms | ~45 ms | misses | misses | meets |
| 3.0 s | 54.7 ms | ~56 ms | misses | misses | misses |
| 5.0 s | 62.5 ms | ~63 ms | misses | misses | misses |

**No tail length meets all three targets.** The short bucket's 38 ms is
essentially the floor of one 5 s pass (25 ms of encoder, 2.8 of mel, 9.2 of
decoder for a second of audio) plus the path, so it is a floor target, not a
setting: the honest promise for short takes is **38 to 41 ms**, and a 1 s tail
is the only setting that gets there. The average target (40) needs 1.0 s or
less; the long target (46) is met up to about 2 s. So the design starts at a
**1.0 s held-back tail**, not 1.5 s, and only raises it if the last-word rate
needs it, at about 6.5 ms per extra half second.

### Margin, and a slower day

Three passes at 1.0 s spread 1.4 ms (37.2, 37.5, 38.6) and at 2.0 s spread
2.2 ms, on a machine whose 1 minute load moved between 1.18 and 1.41. That is
the size of the noise, and the design has to survive it rather than pick the
best pass.

| | p50 | p95 | what it meets |
|---|---|---|---|
| 1.0 s tail, this machine | 38 to 39 ms | 40 to 41 ms | average (40) and long (46); short (38) only on a pass that measures 37 |
| 1.0 s tail, 10 % slower | ~42 ms | ~44 ms | long only |
| 1.6 s tail (0.6 s overlap plus a full cadence), 10 % slower | ~47 ms | ~49 ms | nothing |

So the promise is **p50 under 40 ms and p95 under 43 ms for short and average
takes on this machine, and long under 46 ms**, and the thing that gives on a
slow day is the short and average targets, bucket by bucket, in that order.
What does not give is accuracy: the tail length is fixed by the cadence, not by
how fast the machine is, so a slow day costs milliseconds and no words.

There is no hidden overhead to win back: on 16 of the owner's 1 to 3.5 s takes the
live path measured release to paste 68 ms with the decode at 68 ms, and mic stop,
flush, enqueue, clean, paste and scheduling at 1 ms or less each.

## How the three shipped pieces fit

- **The cut bound** (`pendingCutLimit`, 60 s) is the backstop. It is what turned
  the 9329 ms worst case into 977 ms by making sure something is committed.
- **The piece gate** (`pieceNeedsDecoding`) is the second backstop: silent pieces
  of a long tail cost nothing, so a tail that slips through cannot cost 36
  decodes. It took 977 to 208 ms.
- **The alternation finding** says which window can be warm. Sticking to one
  window is 68 ms for a 15 s pass; alternating with the 5 s window makes the same
  pass ~140 ms. Whatever the release decodes, only one window should be in play
  while it decodes. WHIB-5 owns the prewarm path (the 8 s staleness test against
  an app that lives in a 100 ms to 4 s band), so this design depends on its
  outcome rather than editing it.

None of those three shortens the tail itself. That is the missing piece.

## The design: hold back a fixed tail, commit everything older

`DictationController`'s live loop commits audio in chunks and the release decodes
whatever is left. Today the chunks are cut only at pauses (and by the forced cut
at 14 s), so a release that lands in the middle of a long utterance inherits the
whole utterance: the 12 s no-pause case decodes 12 s on the 15 s window, 160 ms.

Change the unit: while he talks, commit everything older than `heldBack`
seconds, cutting where the audio is quietest inside that window, and decode the
next piece with a little of the previous piece's audio in front of it. At
release, decode only the held-back tail, with its overlap.

- `heldBack` = **1.0 s**, the only setting that reaches the short target. Each
  commit is one cadence (1.0 s) plus a **0.6 s overlap** of audio the previous
  commit already covered, about one word, so each committed piece is ~1.6 s of
  audio and one 5 s window pass, ~42 ms, and the model is busy about 4% of the
  time while he talks.
- A commit cut lands in the last pause inside the window; with no pause it lands
  in the quietest 10 ms frame, the same rule the forced cut uses today. That
  keeps most cuts out of the middle of a word.
- At release nothing has to wait: **no in-flight decode is ever accepted as
  final text**, which is the mistake `streaming` made (5% last-word loss against
  1%, `log-c-streaming.md`). The release decode always runs, over at most 1.6 s
  of audio (a full cadence plus the overlap), which is ~38 ms at p50 and ~42 ms
  at worst.
- The 60 s bound and the piece gate stay as backstops for anything that slips
  through, which is what keeps a starved tick or a quiet take bounded rather
  than what makes the common case fast.

### The seam: overlapping pieces, not disjoint ones

A cut with no pause lands inside a word. Disjoint pieces then hand each half of
that word to a different decode and each half becomes whatever the decoder makes
of it, which is a **wrong word, not a missing one**, and no loss-only gate can
see it. So the pieces overlap by ~0.6 s, every word at a seam is decoded whole
in the later piece, and `SpeechSegmenter.join` has to drop the words the later
piece repeats:

1. Drop from the later text the longest run of normalized words that repeats the
   earlier text's tail.
2. If no run matches and the earlier text's last token is a proper prefix of the
   later text's first token, drop the earlier stub (the cut landed mid-word).
3. Never drop anything else: an unmatched seam keeps both texts, which doubles a
   word at worst instead of deleting one.

`join` does not do this today; it concatenates with sentence-case heuristics.
This is new code with a new failure mode, a dropped or doubled word at a seam,
and the phase sweep below is what proves it right rather than an argument.

### The 12 s no-pause case, worked through

Today it decodes 12 s at release: 160 ms.

With the tail held back, the live loop commits every 1.0 s, each commit ~42 ms on
the 5 s window, so the model is busy about 4% of the time while he talks and
only the 5 s window is warm. At release the tail is at most 1.6 s, one pass, no
window switch, ~38 ms. The seams move from one per utterance to one per second,
which is why the sweep is the acceptance test.

### The 90 s no-pause case, where the backstops are

Two backstops can fire on a long no-pause utterance, and which one does depends
on how loud it is:

- **Loud speech** (peak above the gate's 0.05): today's forced cut at
  `forceChunk` = 14 s fires and cuts at the quietest 100 ms of the last 5 s, so a
  90 s loud take is committed every ~14 s and never reaches the 60 s bound. Its
  release tail is under 15 s: one 15 s window, ~160 ms.
- **Quiet speech** (under the absolute gate, RMS < 0.004 and peak < 0.05): every
  candidate cut is held attached by `cutDropsQuietSpeech` until pending reaches
  `pendingCutLimit` = 60 s = 960_000 samples, and only then does the guard give
  way. A 90 s quiet no-pause take therefore commits ~60 s around t = 60 s and
  carries the remaining ~30 s at release, which the piece gate splits into two
  15 s pieces, ~320 ms, or near nothing when the pieces are silent (the 9 1/2
  minute take measured 218 ms exactly that way).

Under the design neither fires: pending never exceeds `heldBack` plus one tick,
so a 90 s no-pause take has the same release as a 5 s one, ~38 ms, and the cost
moves to ~90 seams. Both backstops keep their tests and gain one where ticks stop
being served, so they are exercised under the new cadence instead of only in
theory. The piece gate is also being fixed separately (PR 65 skipped a quiet
piece that held a take's last five words); a starved tick still runs that path,
so it has to be right regardless of the cadence.

## What has to be measured before it ships

Every hold from the last two changes stays: at least as accurate, and zero new
dropped last words on the owner's recordings.

1. **Cut-phase sweep.** The same unbroken take, shifted by 0 to `heldBack` in
   100 ms steps, must give a byte-identical transcript at every phase. Any word
   that lands badly shows up in at least one phase; this is the test that would
   have caught the streaming loss too.
2. **Seam-local diff that counts substitutions.** Align against whole-clip text
   and require zero insertions, deletions *and* substitutions within one word of
   every seam, on `testdata/unbroken`. A loss-only gate passes the disjoint shape,
   which is why this one counts substitutions.
3. **Dedupe test.** Overlapping pieces produce each word exactly once, including
   the mid-word case and a genuine repeat ("that that") across a seam.
4. Agreement against whole-clip decoding on the 300-clip dictation set and the
   432-clip edge set, with a WER delta, not only agreement: a WER on the same
   clips catches substitutions the loss gate cannot.
5. Last-word rate and mid-take accuracy on the same takes in the same session, as
   two numbers, against today's ~1% last-word loss.
6. The scoreboard on the same sample, before and after, including a long take
   that trails off quietly, or the long row cannot see quiet-tail damage at all.
7. **Back-to-back takes:** two releases within a second of each other with a
   commit decode in flight. The felt wait is the *next* release, and this design
   puts work into the speaking window, so that interaction needs its own number.
8. Duty cycle and heat: ~4% of the speaking window on decodes that do not run
   today. Check it does not show up as a slower release anywhere (the 8 GB box
   has form here).

## What this design does not do

It does not make the model cheaper. It moves work from release to during-speech,
which is the only place the work can go: 37 ms is the floor for a decode, and the
short target is 38 ms. Anything still decoding more than ~4 s at release will not
reach the worst-case target, no matter what else is tuned.
