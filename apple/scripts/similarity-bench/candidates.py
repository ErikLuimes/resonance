#!/usr/bin/env python3
"""Builds the candidates that need no neural model.

    uv run candidates.py b --features FILE.tsv --subset FILE --out B.npz
    uv run candidates.py mfcc --audio DIR --out C.npz
    uv run candidates.py fuse --a A.npz --b B.npz --share 0.5 --out G.npz
    uv run candidates.py pca --input X.npz --dims 128 [--int8] --out X128.npz
    uv run candidates.py local-scaling --input X.npz --k 10 --out H.npz
"""

from __future__ import annotations

import argparse
import os

import numpy as np

import corpus

RATE = 48_000
SEGMENT = 2048
HOP = 1024
BANDS = 40
COEFFICIENTS = 20
SILENT_RMS = 50


def manifest(audio_dir: str):
    with open(f"{audio_dir}/manifest.tsv") as f:
        for line in f:
            number, path, subtune, lengths = line.rstrip("\n").split("\t")
            yield number, path, int(subtune), [int(x) for x in lengths.split(",") if x]


def segments(audio_dir: str, number: str, lengths: list[int]) -> list[np.ndarray]:
    """A subtune's segments as floats, without the silent ones."""
    samples = np.fromfile(f"{audio_dir}/{number}.s16", dtype=np.int16)
    out, at = [], 0
    for n in lengths:
        part = samples[at:at + n].astype(np.float32)
        at += n
        if len(part) >= RATE and np.sqrt(np.mean(part * part)) >= SILENT_RMS:
            out.append(part / 32768)
    return out


def save(path: str, paths, subtunes, vectors, metric="cosine"):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    np.savez(path, paths=np.array(paths), subtunes=np.array(subtunes, dtype=np.int32),
             vectors=np.asarray(vectors, dtype=np.float32), metric=np.array(metric))
    print(f"{path}: {np.shape(vectors)}")


def standardize(x: np.ndarray) -> np.ndarray:
    std = x.std(axis=0)
    std[std < 1e-9] = np.inf
    return (x - x.mean(axis=0)) / std


def cmd_b(args):
    """A's standardized, weighted features plus the new ones at A's typical weight."""
    wanted = None
    if args.subset:
        with open(args.subset) as f:
            wanted = {(p, int(s)) for p, s in (l.rstrip("\n").split("\t") for l in f)}
    rows, features = corpus.load_features()
    index = {k: i for i, k in enumerate(rows.keys())}
    extra, keep = [], []
    with open(args.features) as f:
        next(f)
        for line in f:
            parts = line.rstrip("\n").split("\t")
            key = (parts[0], int(parts[1]))
            if key in index and (wanted is None or key in wanted):
                keep.append(index[key])
                extra.append([float(x) for x in parts[2:]])
    keep = np.array(keep)
    extra = np.array(extra, dtype=np.float32)
    if args.drop:
        columns = [i for i in range(extra.shape[1]) if str(i) not in args.drop.split(",")]
        extra = extra[:, columns]
    a = standardize(features[keep]) * corpus.WEIGHTS
    b = np.hstack([a, standardize(extra) * float(corpus.WEIGHTS.mean())])
    save(args.out, rows.paths[keep], rows.subtunes[keep], b)


def mel_filters() -> np.ndarray:
    def mel(hz):
        return 2595 * np.log10(1 + hz / 700)
    def hz(m):
        return 700 * (10 ** (m / 2595) - 1)
    bins = np.floor((SEGMENT + 1) * hz(np.linspace(mel(40), mel(11_000), BANDS + 2)) / RATE).astype(int)
    filters = np.zeros((BANDS, SEGMENT // 2 + 1), dtype=np.float32)
    for b in range(BANDS):
        lo, mid, hi = bins[b], bins[b + 1], bins[b + 2]
        filters[b, lo:mid] = (np.arange(lo, mid) - lo) / max(mid - lo, 1)
        filters[b, mid:hi] = (hi - np.arange(mid, hi)) / max(hi - mid, 1)
    return filters


def cmd_mfcc(args):
    """The textbook summary: MFCC means, deviations and delta deviations."""
    filters = mel_filters()
    window = np.hanning(SEGMENT).astype(np.float32)
    k = np.arange(COEFFICIENTS)[:, None]
    m = np.arange(BANDS)[None, :]
    dct = np.cos(np.pi * k * (m + 0.5) / BANDS).astype(np.float32)
    paths, subtunes, vectors = [], [], []
    for number, path, subtune, lengths in manifest(args.audio):
        coefficients = []
        for part in segments(args.audio, number, lengths):
            frames = np.lib.stride_tricks.sliding_window_view(part, SEGMENT)[::HOP] * window
            power = np.abs(np.fft.rfft(frames, axis=1)) ** 2
            coefficients.append(np.log(power @ filters.T + 1e-9) @ dct.T)
        if not coefficients:
            continue
        delta = np.vstack([np.diff(c, axis=0) for c in coefficients])
        c = np.vstack(coefficients)
        paths.append(path)
        subtunes.append(subtune)
        vectors.append(np.hstack([c.mean(0), c.std(0), delta.std(0)]))
    save(args.out, paths, subtunes, standardize(np.array(vectors, dtype=np.float32)))


def load(path):
    d = np.load(path, allow_pickle=False)
    return d["paths"], d["subtunes"], d["vectors"].astype(np.float32)


def unit(v):
    length = np.linalg.norm(v, axis=1, keepdims=True)
    return v / np.where(length > 1e-9, length, 1)


def cmd_fuse(args):
    """Cosine scores add up when unit vectors are joined with square-root shares."""
    pa, sa, va = load(args.a)
    pb, sb, vb = load(args.b)
    index = {k: i for i, k in enumerate(zip(pb.tolist(), sb.tolist()))}
    where = np.array([index.get(k, -1) for k in zip(pa.tolist(), sa.tolist())])
    have = where >= 0
    joined = np.hstack([
        unit(va[have]) * np.sqrt(args.share),
        unit(vb[where[have]]) * np.sqrt(1 - args.share),
    ])
    save(args.out, pa[have], sa[have], joined)


def cmd_pca(args):
    paths, subtunes, v = load(args.input)
    v = unit(v)
    # Not centered: cosines between the rows have to survive. Taking out the
    # mean direction changes them, and with them a fusion's effective shares.
    u, s, _ = np.linalg.svd(v, full_matrices=False)
    reduced = u[:, :args.dims] * s[:args.dims]
    if args.int8:
        # Per dimension, stored with a scale each: the first dimension is far
        # larger than the rest and would otherwise take all the precision.
        peak = np.abs(reduced).max(axis=0)
        peak[peak == 0] = 1
        reduced = np.clip(np.round(reduced / peak * 127), -127, 127) * peak / 127
    kept = float((s[:args.dims] ** 2).sum() / (s ** 2).sum())
    print(f"{args.dims} dims keep {kept:.2%} of the energy")
    save(args.out, paths, subtunes, reduced)


def cmd_local_scaling(args):
    """Non-iterative contextual dissimilarity: d / sqrt(mu_i mu_j), expressed as
    vectors isn't possible, so each row stores its k-NN mean for bench.py."""
    paths, subtunes, v = load(args.input)
    v = unit(v)
    means = np.zeros(len(v), dtype=np.float32)
    for start in range(0, len(v), 512):
        d = 1 - v[start:start + 512] @ v.T
        near = np.partition(d, args.k, axis=1)[:, 1:args.k + 1]
        means[start:start + 512] = near.mean(axis=1)
    np.savez(args.out, paths=paths, subtunes=subtunes, vectors=v, metric=np.array("nicdm"), scale=means)
    print(f"{args.out}: k={args.k}, mean scale {means.mean():.3f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("b")
    p.add_argument("--features", required=True)
    p.add_argument("--subset")
    p.add_argument("--drop", help="comma-separated register feature columns to leave out")
    p.add_argument("--out", required=True)
    p.set_defaults(run=cmd_b)
    p = sub.add_parser("mfcc")
    p.add_argument("--audio", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(run=cmd_mfcc)
    p = sub.add_parser("fuse")
    p.add_argument("--a", required=True)
    p.add_argument("--b", required=True)
    p.add_argument("--share", type=float, default=0.5)
    p.add_argument("--out", required=True)
    p.set_defaults(run=cmd_fuse)
    p = sub.add_parser("pca")
    p.add_argument("--input", required=True)
    p.add_argument("--dims", type=int, required=True)
    p.add_argument("--int8", action="store_true")
    p.add_argument("--out", required=True)
    p.set_defaults(run=cmd_pca)
    p = sub.add_parser("local-scaling")
    p.add_argument("--input", required=True)
    p.add_argument("--k", type=int, default=10)
    p.add_argument("--out", required=True)
    p.set_defaults(run=cmd_local_scaling)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
