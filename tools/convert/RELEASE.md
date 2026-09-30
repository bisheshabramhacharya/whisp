# Short-window encoder release (`models-v1`)

Whisp's default engine fetches `parakeet_unified_encoder_w5000_int8.mlmodelc`
from the `models-v1` GitHub release on first run and refuses it unless the
zip's SHA-256 matches `ShortWindowEngine.fastBundle` in the app.

| asset | SHA-256 |
|---|---|
| `parakeet_unified_encoder_w5000_int8.mlmodelc.zip` (525 MB) | `2ebd982a4e5b896f41d6cc05554de76c04a837c7879e07d7b9475d80129f4584` |

Licensed by NVIDIA Corporation under the
[NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/):
the weights of `nvidia/parakeet-unified-en-0.6b`, re-traced at a 5 s input
window and int8-quantized. No weights were changed beyond quantization.

## Rebuild it yourself (Xcode CLT + `uv`)

```bash
cd tools/convert
uv sync
uv pip install --no-deps --force-reinstall \
  "nemo_toolkit @ git+https://github.com/NVIDIA-NeMo/NeMo.git@95f92737cfb8ee0123bb328b07a2d24c6d859aff"
uv run --no-sync python convert-short-window.py --windows 5 --validate --install
```

`--install` copies the bundle into
`~/Library/Application Support/FluidAudio/Models/parakeet-unified-en-0.6b/`,
where `ShortWindowEngine` finds it; the app then skips the download.

## Publishing a new bundle

```bash
cd build/short_window
ditto -c -k --norsrc parakeet_unified_encoder_w5000_int8.mlmodelc \
  parakeet_unified_encoder_w5000_int8.mlmodelc.zip
shasum -a 256 parakeet_unified_encoder_w5000_int8.mlmodelc.zip
gh release create models-v2 --title "Models v2" --notes-file ../../RELEASE.md \
  parakeet_unified_encoder_w5000_int8.mlmodelc.zip
```

Then point `ShortWindowEngine.fastBundle` at the new tag and checksum. The zip
holds the bundle's contents at its root (no enclosing folder).
