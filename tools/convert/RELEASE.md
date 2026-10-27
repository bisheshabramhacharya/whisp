# Short-window encoder releases

Whisp's default engine fetches pinned encoder bundles into the FluidAudio
cache on launch and refuses a zip whose SHA-256 doesn't match the constant
in `ShortWindowEngine`. A bundle with an empty checksum is not downloaded
(a missing file must not fail every launch). A bundle already in the cache,
including one copied there by `--install`, is used either way.

| constant | asset | release | SHA-256 |
|---|---|---|---|
| `fastBundle` | `parakeet_unified_encoder_w5000_int8.mlmodelc.zip` (525 MB) | `models-v1` | `2ebd982a4e5b896f41d6cc05554de76c04a837c7879e07d7b9475d80129f4584` |
| `middleBundle` | `parakeet_unified_encoder_w10000_int8.mlmodelc.zip` | `models-v2` | *(empty until published)* |

The 10 s bundle is the same weights traced at 160,000 samples. It covers
tails that are longer than 5 s and up to 10 s, which otherwise pay the
stock 15 s encoder. It is a second file, not a multi-function model
(macOS 14 can't load those).

Licensed by NVIDIA Corporation under the
[NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/):
the weights of `nvidia/parakeet-unified-en-0.6b`, re-traced at a shorter
input window and int8-quantized. No weights were changed beyond quantization.

## Rebuild it yourself (Xcode CLT + `uv`)

```bash
cd tools/convert
uv sync
uv pip install --no-deps --force-reinstall \
  "nemo_toolkit @ git+https://github.com/NVIDIA-NeMo/NeMo.git@95f92737cfb8ee0123bb328b07a2d24c6d859aff"
uv run --no-sync python convert-short-window.py --windows 5 --validate --install
# the 10 s window, same recipe:
uv run --no-sync python convert-short-window.py --windows 10 --validate --install
```

`--validate` checks encoder activations on the valid frames of a short `say`
clip (about 3 s, so it fits a 10 s window). Text identity on 5–10 s recordings
is `whisp-bench --compare`, not this script.

`--install` copies the bundle into
`~/Library/Application Support/FluidAudio/Models/parakeet-unified-en-0.6b/`,
where `ShortWindowEngine` finds it; the app then skips the download.

## Publishing the 10 s bundle

Leave `fastBundle` on `models-v1`. Publish the 10 s zip on `models-v2`, then
paste the checksum into `ShortWindowEngine.middleBundle`. Until that string
is non-empty, the app will not request the URL.

```bash
cd build/short_window
ditto -c -k --norsrc parakeet_unified_encoder_w10000_int8.mlmodelc \
  parakeet_unified_encoder_w10000_int8.mlmodelc.zip
shasum -a 256 parakeet_unified_encoder_w10000_int8.mlmodelc.zip
gh release create models-v2 --title "Models v2" --notes-file ../../RELEASE.md \
  parakeet_unified_encoder_w10000_int8.mlmodelc.zip
```

The zip holds the bundle's contents at its root (no enclosing folder).
