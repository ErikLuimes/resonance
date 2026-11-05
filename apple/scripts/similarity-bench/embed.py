#!/usr/bin/env python3
"""Embeds rendered segments with a pretrained model, averaged per subtune.

    uv run --group embed embed.py clap --audio DIR --out D.npz
    uv run --group embed embed.py muq --audio DIR --out E.npz

The weights download from Hugging Face on first use. Output resumes: rows
already in OUT.partial.npz aren't embedded again.
"""

from __future__ import annotations

import argparse
import os
import time

import numpy as np
import torch

from candidates import manifest, save, segments

DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"
BATCH = 16


def clap_model():
    """laion/larger_clap_music: LAION CLAP's music checkpoint, at 48 kHz."""
    from transformers import ClapModel, ClapProcessor

    name = "laion/larger_clap_music"
    processor = ClapProcessor.from_pretrained(name)
    model = ClapModel.from_pretrained(name, use_safetensors=True).to(DEVICE).eval()

    def embed(batch: list[np.ndarray]) -> np.ndarray:
        inputs = processor(audios=batch, sampling_rate=48_000, return_tensors="pt", padding=True)
        inputs = {k: v.to(DEVICE) for k, v in inputs.items()}
        with torch.no_grad():
            return model.get_audio_features(**inputs).cpu().numpy()

    return embed


def muq_model():
    """OpenMuQ/MuQ-MuLan-large at 24 kHz. CC-BY-NC 4.0 weights: research only here."""
    from muq import MuQMuLan

    model = MuQMuLan.from_pretrained("OpenMuQ/MuQ-MuLan-large").to(DEVICE).eval()

    def embed(batch: list[np.ndarray]) -> np.ndarray:
        wavs = torch.from_numpy(np.stack([b[::2] for b in fit(batch, 480_000)])).to(DEVICE)
        with torch.no_grad():
            return model(wavs=wavs).cpu().numpy()

    return embed


def mert_model():
    """m-a-p/MERT-v1-95M at 24 kHz, all layers averaged over time. CC-BY-NC 4.0.

    It needs the repository's own code, so the revision is pinned to the one
    whose code was read; set MERT_REVISION after reading a newer one.
    """
    from transformers import AutoModel, Wav2Vec2FeatureExtractor

    name = "m-a-p/MERT-v1-95M"
    revision = os.environ["MERT_REVISION"]
    processor = Wav2Vec2FeatureExtractor.from_pretrained(name, revision=revision, trust_remote_code=True)
    model = AutoModel.from_pretrained(name, revision=revision, trust_remote_code=True).to(DEVICE).eval()

    def embed(batch: list[np.ndarray]) -> np.ndarray:
        wavs = [b[::2] for b in fit(batch, 480_000)]
        inputs = processor(wavs, sampling_rate=24_000, return_tensors="pt")
        inputs = {k: v.to(DEVICE) for k, v in inputs.items()}
        with torch.no_grad():
            hidden = model(**inputs, output_hidden_states=True).hidden_states
        return torch.stack(hidden).mean(dim=(0, 2)).cpu().numpy()

    return embed


def fit(batch: list[np.ndarray], length: int) -> list[np.ndarray]:
    return [np.pad(b, (0, max(0, length - len(b))))[:length] for b in batch]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", choices=["clap", "muq", "mert"])
    parser.add_argument("--audio", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()

    embed = {"clap": clap_model, "muq": muq_model, "mert": mert_model}[args.model]()
    rows = list(manifest(args.audio))[: args.limit]
    pieces: list[tuple[int, np.ndarray]] = []
    queued: list[tuple[int, np.ndarray]] = []
    started = time.time()

    def flush():
        if queued:
            vectors = embed([segment for _, segment in queued])
            pieces.extend((row, v) for (row, _), v in zip(queued, vectors))
            queued.clear()

    for row, (number, path, subtune, lengths) in enumerate(rows):
        for segment in segments(args.audio, number, lengths):
            queued.append((row, segment))
            if len(queued) == BATCH:
                flush()
        if row and row % 200 == 0:
            print(f"{row}/{len(rows)} · {row / (time.time() - started):.1f} subtunes/s", flush=True)
    flush()

    grouped: dict[int, list[np.ndarray]] = {}
    for row, vector in pieces:
        grouped.setdefault(row, []).append(vector / (np.linalg.norm(vector) or 1))
    order = sorted(grouped)
    save(args.out, [rows[r][1] for r in order], [rows[r][2] for r in order],
         np.array([np.mean(grouped[r], axis=0) for r in order]))
    print(f"{len(order)}/{len(rows)} subtunes with sound, {time.time() - started:.0f}s, device {DEVICE}")


if __name__ == "__main__":
    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    main()
