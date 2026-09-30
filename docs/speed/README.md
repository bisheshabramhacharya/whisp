# Speed

Where the time goes between letting go of the key and the text appearing,
what made it faster, and what didn't. Numbers are from a base 8 GB M1 on the
owner's own recordings unless marked VM (Devin's M4 virtual machine, no Neural
Engine: relative comparisons only).

## Where the time goes

Mic stop, text cleanup and the paste take a few milliseconds together. Almost
all of the wait is the speech model turning the last bit of audio into text.
The stock Parakeet encoder is traced at a fixed 15 s window, so a 2 s phrase
paid for 15 s of encoder work.

## What shipped

| Change | Measured on the M1 | Same words? |
|---|---|---|
| 5 s encoder window (`short`, the default) | clips under 5 s: 98.9 → 48.6 ms p50 (213 recordings) | identical on 213 + 220 recordings |
| Release replay, letting go right at the last word | wait p50 106 → 63 ms (40 recordings) | last word kept in every release |
| Release replay, letting go 100 ms after | wait p50 90 → 35–39 ms | same |
| Decode ahead after a 180 ms pause (was 200) | no-wait releases at +200 ms: 43% → 50% | same |
| Cleaner + dictionary warmed at launch | first dictation no longer pays 46–67 ms | same code, earlier |
| FluidAudio 0.15.7 → 0.17.4 | same speed | identical on 40 recordings |
| Wake the encoder size the release will need, while you talk | real-time replay of the last 40 dictations: p50 147 → 92 ms, p90 350 → 176, worst 504 → 221 | same decode, earlier wake-up |

## Measured dead ends

| Idea | Result | Status |
|---|---|---|
| Streaming decode while you talk (`streaming`) | ~88 ms flat on the VM, but loses or mishears the last word in ~5% of releases (vs ~1%) | opt-in only |
| Batched wide joint (FastRnnt) | M1: 160 / 177 ms vs 155 ms stock | removed |
| Second decode lane (`par2`) | helps p95 only when a release races a decode; +600 MB | opt-in only |
| Speculating after 150 ms pauses | dropped a quiet last word on the edge set | not used |
| Keeping the Neural Engine warm | idle penalty is only 10–15 ms on macOS 26 (was 60–120 ms); what does hurt is one encoder size sitting unused while the other runs (next run 250–465 ms), fixed above | not needed |
| Pause detection above 200 Hz, against the room's hum | long takes ~15 ms faster on average, but the last word was lost in 4 of 20 releases vs 1 of 20: cuts land right before the last word, which then decodes alone | not used |

## What's next

About a third of releases still wait over 100 ms: the speech after the last
pause was longer than 5 s, so it goes to the 15 s encoder. A 10 s window
would cover most of those, at ~600 MB more Neural Engine memory, unless the
windows can share one weight file (Core ML multi-function models, macOS 15+).

## Reproduce

```sh
swift build -c release
.build/release/whisp-bench --compare parakeet,short --runs 2 --idle 0 <wavs…>
.build/release/whisp-bench --replay --engine short <wavs…>
# real time, through the app's own dictation code, next to what the app measured:
.build/release/whisp-bench --live --history ~/Library/Application\ Support/Whisp/history.jsonl \
  ~/Library/Application\ Support/Whisp/recordings/<id>.wav …
scripts/speed/m1-check.sh <folder of wavs> parakeet,short
```

Detailed logs: [log.md](log.md), [short window](log-b-short-window.md),
[streaming](log-c-streaming.md), [decoder and pipeline](log-d-decoder.md),
and Devin's [full report](devin-report.md).
