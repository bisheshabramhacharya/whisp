# Draft release: `speed-models-2026-09-29`

Short-window Parakeet Unified encoders for `ShortWindowEngine` (`asrEngine
short`). Same weights as the stock `parakeet_unified_encoder_int8.mlmodelc`,
re-traced at a 5 s window and int8-quantized — see `tools/convert/` and
`docs/speed-log-b.md`.

## Assets

| asset | size | contents |
|---|---|---|
| `parakeet_unified_encoder_w5000_int8.mlmodelc.zip` | 524 MB | 5 s window encoder, mel `[1,128,501]`, int8, iOS17 |

SHA256 `b1fde737224107f16c2f71e9ed5fda3fe9e1131267e412e6b873fefd7161a904`.

A 2 s window (`w2000_int8`, 561 MB) also exists and is exercised by the engine
when present; it is not attached here to keep the release under the 1 GB cap.
Rebuild it with `convert-short-window.py --windows 2`.

## Install

```bash
DEST="$HOME/Library/Application Support/FluidAudio/Models/parakeet-unified-en-0.6b"
unzip -o parakeet_unified_encoder_w5000_int8.mlmodelc.zip -d /tmp
mv /tmp/parakeet_unified_encoder_w5000_int8.mlmodelc "$DEST/"   # or ditto straight in
defaults write com.bishesha.whisp asrEngine short
```

The engine discovers every `parakeet_unified_encoder_w{ms}[_int8].mlmodelc` in
the cache dir and picks the smallest window ≥ the trimmed input length; absent
bundles fall back to the stock 15 s encoder (and >15 s inputs to the chunked
path), so removing the bundles restores stock behavior.

## Recreate / upload

```bash
cd tools/convert
uv run --no-sync python convert-short-window.py --windows 5
(cd build/short_window/parakeet_unified_encoder_w5000_int8.mlmodelc && \
  zip -qr /tmp/parakeet_unified_encoder_w5000_int8.mlmodelc.zip .)

gh release create speed-models-2026-09-29 \
  --repo bisheshabramhacharya/whisp --draft \
  --title "Short-window Parakeet encoders (Track B)" \
  --notes-file tools/convert/RELEASE.md \
  /tmp/parakeet_unified_encoder_w5000_int8.mlmodelc.zip
```
