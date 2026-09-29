# Short-window encoder — build instead of download

Previously planned as a draft release (`speed-models-2026-09-29`, 524 MB
zip). **Upload skipped**: the M1 check builds the encoder on-device via
`convert-short-window.py` — zero model downloads (the 2.4 GB `.nemo`
auto-fetches from HF once), and no binaries ever hit git.

## Build on a stock Mac (Xcode CLT + `uv` only)

```bash
cd tools/convert
uv sync
uv pip install --no-deps --force-reinstall \
  "nemo_toolkit @ git+https://github.com/NVIDIA-NeMo/NeMo.git@95f92737cfb8ee0123bb328b07a2d24c6d859aff"
uv run --no-sync python convert-short-window.py --windows 5 --validate --install
```

`--install` copies `parakeet_unified_encoder_w5000_int8.mlmodelc` into
`~/Library/Application Support/FluidAudio/Models/parakeet-unified-en-0.6b/` —
the cache dir `ShortWindowEngine` scans. See README.md "Short-window
encoders" for the full input/output/dir conventions.

## If a release is ever wanted

The w5000 int8 bundle zips to 524 MB; w2000 is another ~561 MB. Reference
command (needs a `gh` login on the release owner's account):

```bash
cd build/short_window
ditto -c -k --sequesterRsrc --keepParent parakeet_unified_encoder_w5000_int8.mlmodelc \
  parakeet_unified_encoder_w5000_int8.mlmodelc.zip
gh release create speed-models-2026-09-29 --draft \
  --title "Speed-run models 2026-09-29" --notes-file ../../RELEASE.md \
  parakeet_unified_encoder_w5000_int8.mlmodelc.zip
```
