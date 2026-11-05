# Reference text for accuracy (BIS-20)

Every accuracy number in `scoreboard.sh` today compares a build against our own
previous output. That catches a regression. It cannot catch a word that has
always been wrong, because the baseline is wrong the same way.

This is the other side of that comparison: for each recording, text from a model
that is not the app's engine and does not ship with the app. Nothing here is
guessed, and nothing here is part of the app. It is a ruler, not a component.

## What we learned before building it

The first design asked two independent engines to agree, and used only the
places where they did. On 650 of his own recordings, 10 hours of audio, that
turned out to be the wrong test:

- exact agreement on 5 recordings, 0.8%
- agreement once case is ignored on 20, 3.1%
- no agreement at all on 630, 96.9%

Underneath those flags, the two engines are a median 13.6% of words apart
(p25 9.5%, p75 19.7%, p90 30.0%). Real dictation has names, product spellings
and half-swallowed words, and two engines do not transcribe that identically.
The takes over five minutes were the worst: median 50.2% apart, and 18 of the
21 are unusable as reference.

A bigger model does not rescue it either. On 40 identical files, three engines
reading the same audio: turbo against Apple 11.1% of words apart, whisper
large-v3 full against Apple 12.1%, and turbo against large-v3 full 3.3% (the two
whisper models produce the same words on 11 of the 40). The app was closer to
large-v3 full on 19 of those 40 and closer to Apple on 21, a coin flip. Neither
engine is ground truth, and the full model is not worth four extra hours of
rebuilding. Exact agreement between two engines is simply not available on this
audio.

## So: one reference, one flag

- The reference is one big model's text, for every recording, taken at face
  value. WER against it is the number to track.
- A second engine transcribes the same audio only to catch the recordings where
  the reference itself is not worth measuring against. Those are dropped, not
  repaired: no second text, a decoder that looped until the word count doubled,
  or a gap of 35% words or more. That is the tail of the distribution, so it
  removes the wreckage and keeps the ordinary disagreements.
- The reference has its own error rate and the doc says so plainly: a median
  12.8% of words away from the second engine (p25 8.9%, p75 18.0%) on the
  recordings kept. WER against it is a stable ruler across builds, not a claim
  that the text is right word for word. Treat a WER difference under about two
  points as noise, because that is the size of the ruler's own error.

On the 650, that keeps 592 recordings and drops 58: 43 too far apart, 8 repeat
loops, 6 with no second text, 1 with no reference text.

## The engines

| | role | model | disk | why |
|---|---|---|---|---|
| reference | the text we measure against | whisper large-v3-turbo q5_0 through whisper.cpp with Metal | 574 MB | strongest English accuracy that fits 8 GB, and the same whisper family as the full model without its cost |
| flag | the cross-check | Apple's on-device transcriber, macOS 26 | 0, part of the OS | a different vendor and architecture, so a wild gap means something |

Whisper large-v3 full q5_0 (1.1 GB) is downloaded and one flag away
(`--model large-v3`). It is not the default because on identical audio the two
whisper models are 3.3% of words apart and full sits no closer to the
cross-check than turbo does, while switching means redoing the whole cache,
about four hours on this Mini.

Parakeet is deliberately not used. It is the app's own engine family, so it
could not serve as an outside opinion.

## What is built

`scripts/speed/reference.py` picks the recordings, runs both engines, and writes
one small JSON per recording. Nothing is copied: the audio is read where it lies.

```
~/.whisp-reference/models   the whisper weights, in case the cache is rebuilt
~/.whisp-reference/text     <id>.json per recording: both texts, the gap, the flag
~/.whisp-reference/set      the reference set: <id>.wav symlink plus <id>.txt,
                            the shape the scoreboard reads
~/.whisp-reference/casual   the fast casual set, built from the kept recordings
```

The slice is sized by audio, not by file count: every long take, then a stable
hash order fill of the average and short buckets up to a budget in hours. Rerun
and it resumes; `--force` redoes everything.

```
scripts/speed/reference.py --budget-hours 10     # build the slice
scripts/speed/reference.py --set                # rebuild the set, no model loaded
scripts/speed/reference.py --probe 20           # throughput only, nothing cached
scripts/speed/reference.py --stats              # the numbers above
scripts/speed/casual-set.py                     # the casual set from the kept ones
```

## What it costs

Measured on this Mini, 15 recordings and 496 seconds of audio: whisper turbo
7.4x realtime, Apple's transcriber 40x realtime. The 650-recording, 10-hour slice
took 83.8 minutes of wall clock in one block. large-v3 full runs about 2.4x
realtime, so the same slice with it is roughly four hours. Apple's engine needed
its on-device assets downloaded the first time (the CLI fetches them itself); a
Mac without them transcribes nothing and says so.

Everything stays on this machine: no cloud, no credits, no upload.

## How the scoreboard uses it

Both are opt-in environment variables and neither changes an existing gate:

```
WHISP_REFERENCE=~/.whisp-reference/set  scripts/speed/scoreboard.sh
WHISP_CASUAL_SET=~/.whisp-reference/casual scripts/speed/scoreboard.sh
```

The casual set is built from the same kept recordings: the fastest short and
average takes, fastest first, capped at ten minutes of audio because the
scoreboard replays a set in real time. Today that is 16 takes, 5.8 minutes, a
mean 5.03 words per second, against the `say` stand-in's slow, tidy studio
speech. Long takes are left to the reference row: one long take is 7 to 10
minutes, so it would eat the whole budget on its own.

The row prints as `reference set, whisper   [ref errs ~1 word in 8]`, next to
the last-word gate, not instead of it. It samples 40 recordings by default (about
20 minutes of replay) and 6 under `--quick`, so the row never quietly turns the
scoreboard into a marathon. The last-word gate and the per-bucket wait numbers
are computed exactly as before, whether or not these variables are set.

## Rules for anyone changing this

- Never copy audio, and never commit a transcript, an audio file, or a recording
  name. Only counts and rates belong in a PR or an issue.
- Never let the app depend on a reference model being present. This measures the
  app, it is not part of it.
- A flag is a reason to drop a recording, never a reason to pick the text we
  like better. Keeping both texts and the gap is what makes the choice auditable.
- If the reference changes model, rebuild the whole cache in one go and rewrite
  these numbers. A cache half from one model and half from another is not a
  ruler.
