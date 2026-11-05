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

| release tail | best possible total | meets |
|---|---|---|
| 1.0 s | ~37 ms | short bucket target (38) |
| 2.0 s | ~44 ms | long bucket target (46), not short or average |
| 3.0 s | ~55 ms | nothing |
| 5.0 s | ~61 ms | nothing, but under the 100 ms worst case |
| 5.2 s and up | 112 ms + | nothing, and over the worst case |

So: **a 1 s tail is the only shape that meets the short target, and a 2 s tail is
the only shape that meets all three.** Both require the release to decode no more
than that, and both require a warm 5 s window.

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

Change the unit: while he talks, commit everything older than `heldBack` seconds,
cutting at a pause when one is available and at a fixed cadence when not. At
release, decode only the held-back tail.

- `heldBack` = 1.0 s meets the short target; 1.5 s keeps a full word plus its
  leading context while still sitting at ~40 ms. Pick 1.5 s first and measure;
  drop to 1.0 s if the last-word rate holds.
- The committed pieces stay on the 5 s window (each is ~1.5 s of audio), which is
  the 25 ms pass, and they are decoded while he talks, not at release.
- At release nothing has to wait: **no in-flight decode is ever accepted as final
  text**, which is the mistake `streaming` made (5% last-word loss against 1%,
  `log-c-streaming.md`). The release decode always runs, over ≤ 1.5 s of audio.
- The 60 s bound and the piece gate stay as backstops for anything that slips
  through, and they are what keeps a quiet or silent take bounded.

### The 12 s no-pause case, worked through

That is the case that decides whether this holds under 40 ms. Today it decodes
12 s at release: 160 ms.

With the tail held back, the live loop commits at ~1.5 s steps. At 1.5 s steps a
2 s commit on the 5 s window costs ~44 ms, so the model is busy about 3% of the
time while he talks, on the 5 s window only. At release the tail is ≤ 1.5 s,
~40 ms, one warm 5 s pass, and no window switch. The seams move from one cut per
utterance to one every 1.5 s, so `SpeechSegmenter.join` is doing more work than
today: agreement against whole-clip decoding is the gate for that, not a guess.

## What has to be measured before it ships

1. Agreement against whole-clip decoding on the 300-clip dictation set and the
   432-clip edge set, with the same holds as the last two changes: at least as
   accurate, and zero new dropped last words on the owner's recordings.
2. Last-word rate at release vs today's ~1%. The held-back tail is what protects
   it; if a 1.5 s tail loses the word a full-context decode kept, raise it to 2 s
   and re-measure, and say what the cost was.
3. Seam quality: word-level diff against whole-clip text, per seam, on the
   no-pause set (`testdata/unbroken`).
4. The scoreboard, on the same sample, before and after, including the long
   bucket, since that is where the cut bound and the piece gate are doing the
   work.
5. Duty cycle and heat: the live loop would run ~3% of the time on decodes it does
   not run today. Check it does not show up as a slower release anywhere (the
   8 GB box has form here).

## What this design does not do

It does not make the model cheaper. It moves work from release to during-speech,
which is the only place the work can go: 37 ms is the floor for a decode, and the
short target is 38 ms. Anything still decoding more than ~4 s at release will not
reach the worst-case target, no matter what else is tuned.
