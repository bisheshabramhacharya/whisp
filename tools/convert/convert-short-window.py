#!/usr/bin/env python3
"""Export short-window offline encoders for nvidia/parakeet-unified-en-0.6b.

The shipped offline encoder is traced at a fixed 15 s window (mel
[1,128,1501]). A shorter window is the SAME model — full attention
(att_context_size=[-1,-1,-1]) masks only by mel_length, convolutions are
padded with zeros, and per-feature mel normalization uses only valid frames —
so a fixed short-window trace produces identical encoder outputs on the valid
frames while paying O(window) (attention O(window^2)) cost instead of the full
15 s every decode.

Exports each requested window as:
  parakeet_unified_encoder_w{MS}.mlpackage        (fp16)
  parakeet_unified_encoder_w{MS}_int8.mlpackage   (per-channel int8)
and compiles .mlmodelc bundles next to them with coremlcompiler.

Inputs: only the .nemo checkpoint (auto-downloaded from HF when missing) — no
binary assets are committed; --validate synthesizes speech with `say` when
--audio-file is absent. --install copies each *_int8.mlmodelc into the
FluidAudio model cache (the dir ShortWindowEngine scans).

Validation (--validate): for each window, compares encoder activations on a
real audio file against the NeMo torch encoder and against the shipped 15 s
CoreML encoder (valid frames only — must be ~identical).

Usage:
    uv run --no-sync python convert-short-window.py \
        --windows 2,5 --output-dir ./build/short_window --validate --install
"""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

import coremltools as ct
import numpy as np
import soundfile as sf
import torch

import nemo.collections.asr as nemo_asr

from components import (
    EncoderWrapper,
    ExportSettings,
    PreprocessorWrapper,
    coreml_convert,
)

MODEL_ID = "nvidia/parakeet-unified-en-0.6b"
NEMO_FILENAME = "parakeet-unified-en-0.6b.nemo"
AUTHOR = "Fluid Inference"
DEFAULT_NEMO_PATH = Path(NEMO_FILENAME)

SAMPLE_RATE = 16000

# Where ShortWindowEngine looks for bundles — mirrors FluidAudio's cache.
MODEL_CACHE = (
    Path.home()
    / "Library/Application Support/FluidAudio/Models/parakeet-unified-en-0.6b"
)


def ensure_nemo(path: Path) -> Path:
    """Return the .nemo checkpoint, downloading it from HF on first use."""
    if path.exists():
        return path
    from huggingface_hub import hf_hub_download

    print(f"{path} not found — downloading from HF {MODEL_ID} (~2.4 GB)…")
    downloaded = hf_hub_download(MODEL_ID, NEMO_FILENAME)
    return Path(downloaded)


def _tensor_shape(tensor: torch.Tensor) -> tuple:
    return tuple(int(dim) for dim in tensor.shape)


def compile_package(pkg: Path, out_dir: Path) -> Path:
    """mlpackage -> .mlmodelc via Xcode's coremlcompiler."""
    out_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(pkg), str(out_dir)],
        check=True,
    )
    produced = out_dir / (pkg.stem + ".mlmodelc")
    assert produced.exists(), f"compile produced nothing for {pkg.name}"
    return produced


def quantize_int8(src: Path, dst: Path) -> Path:
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )

    cfg = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(
            mode="linear_symmetric", granularity="per_channel", dtype="int8"
        )
    )
    model = ct.models.MLModel(str(src), compute_units=ct.ComputeUnit.CPU_ONLY)
    quantized = linear_quantize_weights(model, cfg)
    quantized.save(str(dst))
    return dst


def export_window(asr_model, window_s: float, out_dir: Path) -> dict:
    """Trace the full-attention encoder on a `window_s`-second mel input."""
    samples = int(window_s * SAMPLE_RATE)
    audio = torch.zeros(1, samples, dtype=torch.float32)
    audio_length = torch.tensor([samples], dtype=torch.int32)

    preprocessor = PreprocessorWrapper(asr_model.preprocessor.eval())
    encoder = EncoderWrapper(asr_model.encoder.eval())

    with torch.inference_mode():
        mel_ref, mel_length_ref = preprocessor(audio, audio_length)
        mel_length_ref = mel_length_ref.to(dtype=torch.int32)

    settings = ExportSettings(
        output_dir=out_dir,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        deployment_target=ct.target.iOS17,
        compute_precision=None,
        max_audio_seconds=window_s,
        max_symbol_steps=1,
    )

    print(f"Tracing encoder @ {window_s:.3f} s window (mel {_tensor_shape(mel_ref)})…")
    traced = torch.jit.trace(encoder, (mel_ref, mel_length_ref), strict=False)
    model = coreml_convert(
        traced,
        [
            ct.TensorType(name="mel", shape=_tensor_shape(mel_ref), dtype=np.float32),
            ct.TensorType(name="mel_length", shape=(1,), dtype=np.int32),
        ],
        [
            ct.TensorType(name="encoder", dtype=np.float32),
            ct.TensorType(name="encoder_length", dtype=np.int32),
        ],
        settings,
    )
    model.short_description = (
        f"Parakeet-unified offline encoder, {window_s:g} s window (full attention)"
    )
    model.author = AUTHOR
    ms = int(round(window_s * 1000))
    pkg = out_dir / f"parakeet_unified_encoder_w{ms}.mlpackage"
    model.save(str(pkg))
    print(f"saved {pkg}")

    print(f"Quantizing int8 → {pkg.stem}_int8…")
    int8_pkg = out_dir / f"parakeet_unified_encoder_w{ms}_int8.mlpackage"
    quantize_int8(pkg, int8_pkg)
    print(f"saved {int8_pkg}")

    compile_package(pkg, out_dir)
    compile_package(int8_pkg, out_dir)
    return {
        "window_seconds": window_s,
        "mel_shape": list(_tensor_shape(mel_ref)),
        "fp16": pkg.name,
        "int8": int8_pkg.name,
    }


def validate(asr_model, out_dir: Path, windows: list, audio_path: Path) -> None:
    """Per window: CoreML encoder vs torch NeMo encoder and vs the shipped 15 s encoder."""
    data, sr = sf.read(str(audio_path), dtype="float32")
    assert sr == SAMPLE_RATE
    if data.ndim > 1:
        data = data[:, 0]

    preprocessor = PreprocessorWrapper(asr_model.preprocessor.eval())
    encoder = EncoderWrapper(asr_model.encoder.eval())

    # NeMo torch reference on the native (unpadded) clip
    with torch.inference_mode():
        at = torch.from_numpy(data).unsqueeze(0)
        al = torch.tensor([data.size], dtype=torch.long)
        mel_t, mel_len_t = preprocessor(at, al)
        enc_t, enc_len_t = encoder(mel_t, mel_len_t.to(torch.long))
    enc_t = enc_t.numpy()
    valid = int(enc_len_t[0])

    for window_s in windows:
        samples = int(window_s * SAMPLE_RATE)
        if data.size > samples:
            print(f"[{window_s}s] audio longer than window — skipping parity")
            continue
        ms = int(round(window_s * 1000))
        pkg = out_dir / f"parakeet_unified_encoder_w{ms}_int8.mlpackage"
        if not pkg.exists():
            pkg = out_dir / f"parakeet_unified_encoder_w{ms}.mlpackage"
        cm = ct.models.MLModel(str(pkg), compute_units=ct.ComputeUnit.CPU_ONLY)

        # Mel for the padded window, computed by the torch preprocessor — same
        # front-end math the Swift UnifiedMelExtractor performs.
        with torch.inference_mode():
            buf = torch.zeros(1, samples, dtype=torch.float32)
            buf[0, : data.size] = torch.from_numpy(data)
            mel_w, mel_len_w = preprocessor(buf, al)
        out = cm.predict(
            {"mel": mel_w.numpy(), "mel_length": mel_len_w.numpy().astype(np.int32)}
        )
        enc_cm = out["encoder"]
        enc_len_cm = int(out["encoder_length"][0])
        diff = np.abs(enc_t[:, :, :valid] - enc_cm[:, :, :valid])
        print(
            f"[{window_s}s] enc_len torch={valid} coreml={enc_len_cm} "
            f"max_abs={diff.max():.5f} mean_abs={diff.mean():.7f}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nemo-path", type=Path, default=DEFAULT_NEMO_PATH)
    parser.add_argument("--output-dir", type=Path, default=Path("build/short_window"))
    parser.add_argument(
        "--windows",
        type=str,
        default="2,5",
        help="comma-separated window sizes in seconds (default 2,5)",
    )
    parser.add_argument("--validate", action="store_true")
    parser.add_argument(
        "--audio-file",
        type=Path,
        default=None,
        help="16 kHz WAV for --validate; default: synthesizes one with `say`",
    )
    parser.add_argument(
        "--install",
        action="store_true",
        help="copy each _int8.mlmodelc into the FluidAudio model cache "
        "(the dir ShortWindowEngine scans)",
    )
    args = parser.parse_args()

    windows = sorted(float(x) for x in args.windows.split(","))
    args.output_dir.mkdir(parents=True, exist_ok=True)

    nemo_path = ensure_nemo(args.nemo_path)
    print(f"Loading {nemo_path}…")
    asr_model = nemo_asr.models.EncDecRNNTBPEModel.restore_from(
        str(nemo_path), map_location="cpu"
    )
    asr_model.eval()
    # Full attention — never the streaming chunked mask.
    asr_model.encoder.set_default_att_context_size(att_context_size=[-1, -1, -1])

    results = []
    for w in windows:
        results.append(export_window(asr_model, w, args.output_dir))

    meta = {
        "model_id": MODEL_ID,
        "source": "same weights as parakeet_unified_encoder_int8.mlmodelc, traced at shorter windows",
        "windows": results,
    }
    (args.output_dir / "short_windows.json").write_text(json.dumps(meta, indent=2))

    if args.install:
        MODEL_CACHE.mkdir(parents=True, exist_ok=True)
        for r in results:
            ms = int(round(r["window_seconds"] * 1000))
            src = args.output_dir / f"parakeet_unified_encoder_w{ms}_int8.mlmodelc"
            dst = MODEL_CACHE / src.name
            if dst.exists():
                print(f"installed already: {dst.name}")
                continue
            subprocess.run(["cp", "-R", str(src), str(dst)], check=True)
            print(f"installed {dst}")

    if args.validate:
        from sample_audio import ensure_audio

        audio = args.audio_file or ensure_audio()
        validate(asr_model, args.output_dir, windows, audio)


if __name__ == "__main__":
    main()
