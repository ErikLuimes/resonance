#!/usr/bin/env python3
"""Checks the app's Rust ranking against this file's own copy of the formula.

    uv run rust_parity.py --store STORE [--embeddings ZIP] [--seeds 30]

Works on a copy of the store, in a scratch folder. Uses the `fingerprints`
example from core/examples, so build that first (--release). With no
--embeddings, it checks the features-only ranking.
"""

from __future__ import annotations

import argparse
import os
import random
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
import zipfile

import numpy as np

import corpus

TOOL = os.path.abspath(f"{os.path.dirname(__file__)}/../../target/release/examples/fingerprints")
NEW = 15 / 22
WEIGHTS = np.concatenate([corpus.WEIGHTS, np.full(19, NEW, dtype=np.float32)])
EMBEDDING_SHARE = 0.75
TOP = 12


def load(db_path: str):
    db = sqlite3.connect(db_path)
    scales = np.array([s for (s,) in db.execute("SELECT scale FROM embedding_scales ORDER BY dimension")], dtype=np.float32)
    columns = ",".join(f"f.{c}" for c in corpus.COLUMNS)
    fetched = db.execute(
        f"SELECT t.path, f.subtune, f.subtune = t.start_song, e.vector, f.extra, {columns}"
        " FROM fingerprints f JOIN tunes t ON t.md5 = f.md5"
        " LEFT JOIN embeddings e ON e.md5 = f.md5 AND e.subtune = f.subtune"
        " WHERE f.status = 1"
    ).fetchall()
    db.close()
    raw = np.array([r[5:] for r in fetched], dtype=np.float32)
    x = raw.copy()
    ln = lambda v: np.log1p(np.maximum(v, 0))  # noqa: E731
    x[:, 4], x[:, 5], x[:, 6] = ln(raw[:, 4]), ln(raw[:, 5]), ln(raw[:, 6])
    x[:, 10], x[:, 15] = ln(raw[:, 10] * 10), ln(raw[:, 15])
    x[:, 17], x[:, 18] = raw[:, 17] / 12, raw[:, 18] / 12
    x[:, 19:22] = -np.sort(-raw[:, 19:22], axis=1)
    extra = np.array([np.frombuffer(r[4], dtype="<f4") for r in fetched])
    features = np.hstack([x, extra])

    mean = features.astype(np.float64).mean(axis=0)
    std = features.astype(np.float64).std(axis=0)
    std[std * std <= 1e-12] = np.inf
    z = (features - mean.astype(np.float32)) / std.astype(np.float32) * WEIGHTS
    length = np.linalg.norm(z, axis=1, keepdims=True)
    vectors = z / np.where(length > 1e-6, length, 1)

    dims = len(scales)
    embeddings = np.zeros((len(fetched), max(dims, 1)), dtype=np.float32)
    has = np.zeros(len(fetched), dtype=bool)
    for i, r in enumerate(fetched):
        if r[3] is not None and len(r[3]) == dims:
            e = np.frombuffer(r[3], dtype=np.int8).astype(np.float32) * scales / 127
            n = float(e @ e)
            if n > 1e-12:
                embeddings[i] = e / np.sqrt(n)
                has[i] = True
    return fetched, vectors, embeddings, has


def typical_score(vectors, embeddings, has) -> float:
    """`Index::typical_score`: Rust's pairs, over Rust's row order, can't be
    matched here without its order, so this estimates; it affects the shown
    percentages, not the ranking."""
    rng = np.random.default_rng(1)
    with_e = np.flatnonzero(has)
    if len(with_e) < 2:
        return 0.0
    i, j = rng.choice(with_e, 4000), rng.choice(with_e, 4000)
    scores = EMBEDDING_SHARE * (embeddings[i] * embeddings[j]).sum(1) + (1 - EMBEDDING_SHARE) * (vectors[i] * vectors[j]).sum(1)
    return float(min(np.median(scores), 0.99))


def expected(seed, paths, subtunes, vectors, embeddings, has):
    if has[seed]:
        scores = EMBEDDING_SHARE * (embeddings @ embeddings[seed]) + (1 - EMBEDDING_SHARE) * (vectors @ vectors[seed])
        scores[~has] = -np.inf
    else:
        scores = vectors @ vectors[seed]
    best: dict[str, tuple[float, int]] = {}
    for i in np.argsort(-scores):
        if not np.isfinite(scores[i]):
            break
        p = paths[i]
        if p != paths[seed] and p not in best:
            best[p] = (float(scores[i]), int(subtunes[i]))
            if len(best) == TOP:
                break
    return best


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", required=True)
    parser.add_argument("--embeddings")
    parser.add_argument("--seeds", type=int, default=30)
    args = parser.parse_args()

    work = tempfile.mkdtemp(prefix="rust-parity-")
    try:
        store_dir = f"{work}/resonance-fingerprints"
        os.makedirs(store_dir)
        db_path = f"{store_dir}/fingerprints.sqlite"
        shutil.copy(args.store, db_path)
        if args.embeddings:
            with zipfile.ZipFile(args.embeddings) as z:
                z.extract("embeddings.sqlite", work)
            db = sqlite3.connect(db_path)
            db.execute("ATTACH DATABASE ? AS seed", (f"{work}/embeddings.sqlite",))
            db.executescript(
                "DELETE FROM main.embeddings; DELETE FROM main.embedding_scales;"
                "INSERT INTO main.embedding_scales SELECT dimension, scale FROM seed.embedding_scales;"
                "INSERT INTO main.embeddings SELECT md5, subtune, vector FROM seed.embeddings;"
            )
            db.commit()
            db.close()

        fetched, vectors, embeddings, has = load(db_path)
        paths = [r[0] for r in fetched]
        subtunes = [r[1] for r in fetched]
        starts = {r[0]: i for i, r in enumerate(fetched) if r[2]}
        print(f"{len(fetched)} rows, {int(has.sum())} with embeddings")
        typical = typical_score(vectors, embeddings, has)
        print(f"typical score (estimated): {typical:.4f}")

        random.seed(11)
        named = [p for p in starts if re.search(r"/Delta(_[^/]*)?\.sid$", p)][:4]
        no_embedding = [p for p, i in starts.items() if not has[i]][:3]
        seeds = named + no_embedding + random.sample(sorted(starts), args.seeds)

        env = dict(os.environ, TMPDIR=work)
        same_order = same_set = 0
        pct_gaps = []
        overlap = []
        times = []
        for path in seeds:
            t0 = time.time()
            out = subprocess.run(
                [TOOL, "similar", path], env=env, capture_output=True, text=True, timeout=300
            ).stdout
            times.append(time.time() - t0)
            got = []
            for line in out.splitlines():
                m = re.match(r"\s*(-?\d+)%\s.*#(\d+)\s+(\S.*)$", line)
                if m:
                    got.append((m[3].strip().removeprefix(corpus.HVSC_ROOT + "/"), int(m[2]), int(m[1])))
            want = expected(starts[path], paths, subtunes, vectors, embeddings, has)
            order_ok = [g[0] for g in got] == list(want)
            same_order += order_ok
            shared = {g[0] for g in got} & set(want)
            same_set += len(shared) == TOP
            overlap.append(len(shared))
            if has[starts[path]]:
                for g in got:
                    if g[0] in want:
                        pct_gaps.append(abs(g[2] - max((want[g[0]][0] - typical) / (1 - typical), 0) * 100))
            if not order_ok:
                print(f"  differs: {path}: overlap {len(shared)}/{TOP}")
            if path in named:
                print(f"\n{path} ({'embedded' if has[starts[path]] else 'no embedding'})")
                print("\n".join(f"  {g[2]:>4}%  {g[0]} #{g[1]}" for g in got))
                print()
        print(f"{len(seeds)} seeds: identical order {same_order}, identical set {same_set}, mean overlap {np.mean(overlap):.2f}/{TOP}")
        if pct_gaps:
            print(f"shown percent, Rust vs here: mean gap {np.mean(pct_gaps):.2f}, worst {max(pct_gaps):.1f}")
        print(f"process time per query (includes opening the store and building the index): median {np.median(times):.2f}s")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
