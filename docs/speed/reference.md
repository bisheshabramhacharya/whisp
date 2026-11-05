# Reference text for accuracy (BIS-20)

Every accuracy number in `scoreboard.sh` today compares a build against our own
previous output. That catches a regression. It cannot catch a word that has
always been wrong, because the baseline is wrong the same way.

This is the other side of that comparison. Two models that are big, slow and
different from each other, and different from the app's own engine, transcribe
the same recording. Where they agree, we treat the text as correct and use it as
the reference. Where they disagree, nothing is guessed: both texts are kept and
the recording is left out of the agreed set.

Reference material only. The app never links, ships, or needs any of this.

## The two models

| | model | disk | memory | why this one |
|---|---|---|---|---|
| A | whisper large-v3-turbo q5_0, whisper.cpp with Metal | 574 MB | about 2 GB while it runs | strongest English accuracy that fits 8 GB, and fast enough to run on this Mini |
| B | Apple's on-device transcriber, macOS 26 framework | 0, it is part of the OS | small, system managed | a different vendor with a different architecture, which is the only reason agreement between A and B means anything |

Parakeet is deliberately not used. It is the app's own engine family, so
agreeing with it would prove nothing.

## What is built

`scripts/speed/reference.py` picks the recordings, runs both models, and writes
one small JSON per recording. Nothing is copied: the audio is read where it lies.

```
~/.whisp-reference/models   the whisper weights, in case the cache is rebuilt
~/.whisp-reference/text     <id>.json per recording: both texts, both flags, words, seconds
~/.whisp-reference/set      the agreed set: <id>.wav symlink plus <id>.txt, which is
                            the shape the scoreboard reads
~/.whisp-reference/casual   the fast casual set, a subset of the agreed set
```

Two flags per recording, because the difference between them is the finding:

- `strict` means the word sequences match exactly, case included.
- `loose` means they match once case is ignored.

If strict is 70 and loose is 85, a sixth of the disagreements are capitalisation
and product spelling rather than a misheard word. If both are 70, the models
genuinely hear different words.

The slice is sized by audio, not by file count: every long take, then a stable
hash order fill of the average and short buckets up to a budget in hours. Rerun
and it resumes; `--force` redoes everything. `--stats` reports the cache without
touching the models.

```
scripts/speed/reference.py --budget-hours 10     # build the slice
scripts/speed/reference.py --probe 20            # throughput only, nothing cached
scripts/speed/reference.py --stats               # agreement numbers
scripts/speed/casual-set.py                      # the casual set from the agreed ones
```

## What it costs

The models load once per run (whisper runs as a local server for the duration).
On this M1 that is minutes, not hours, for the 10 hour slice. Everything stays on
this machine: no cloud, no credits, no upload.

## How the scoreboard uses it

Both are opt-in environment variables and neither changes an existing gate:

```
WHISP_REFERENCE=~/.whisp-reference/set  scripts/speed/scoreboard.sh
WHISP_CASUAL_SET=~/.whisp-reference/casual scripts/speed/scoreboard.sh
```

The reference row prints as `reference set, agreed   [two models agree]`, next to
the last-word gate, not instead of it. Recordings where the two models disagreed
are simply not in the set. The last-word gate and the per-bucket wait numbers are
computed exactly as before.

## Rules for anyone changing this

- Never copy audio, and never commit a transcript, an audio file, or a recording
  name. Only counts and rates belong in a PR or an issue.
- Never let the app depend on a reference model being present. This measures the
  app, it is not part of it.
- Agreement is stricter than it needs to be on purpose: a spelling difference
  counts as disagreement, and gets recorded rather than resolved.
