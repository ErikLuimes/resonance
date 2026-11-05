#!/usr/bin/env python3
"""Packs the finished MERT batches into the asset the app downloads.

    uv run export_embeddings.py [--dims 128] [--out ../../build/embeddings-e1.zip]

Compresses with uncentered PCA, which keeps cosines (centering would change the
fusion's effective shares), then to 8 bits per dimension with a scale for each.
The result is the release asset embeddings-e1.zip, under CC-BY-NC 4.0 like the
MERT weights it derives from:

    gh release upload fingerprints apple/build/embeddings-e1.zip --clobber
"""

from __future__ import annotations

import argparse
import glob
import os
import sqlite3
import tempfile
import zipfile

import numpy as np

import corpus

SET_VERSION = 1
LICENCE = """Resonance audio embeddings, set {version}.

Compressed embeddings of High Voltage SID Collection tunes, made with
MERT-v1-95M (https://huggingface.co/m-a-p/MERT-v1-95M, revision {revision}) by
Yizhi Li et al., whose weights are under the Creative Commons
Attribution-NonCommercial 4.0 licence. These embeddings are distributed under
the same licence: https://creativecommons.org/licenses/by-nc/4.0/

Changes: rendered audio was embedded, averaged per subtune, then reduced to
{dims} dimensions by uncentered PCA and quantized to 8 bits.

Resonance's code is MIT-licensed; that licence doesn't extend to this file.
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dims", type=int, default=128)
    parser.add_argument("--work", default=f"{corpus.CACHE_DIR}/full")
    parser.add_argument("--db", default=corpus.DEFAULT_DB)
    parser.add_argument("--revision", default="12af15fef9d0ac838c3f475bfbbf26d2060dd4f5")
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "../../build/embeddings-e1.zip"))
    args = parser.parse_args()

    paths, subtunes, parts = [], [], []
    for file in sorted(glob.glob(f"{args.work}/batch-[0-9][0-9][0-9].npz")):
        data = np.load(file, allow_pickle=False)
        paths += data["paths"].tolist()
        subtunes += data["subtunes"].tolist()
        parts.append(data["vectors"].astype(np.float64))
    vectors = np.vstack(parts)
    vectors /= np.maximum(np.linalg.norm(vectors, axis=1, keepdims=True), 1e-12)
    print(f"{len(vectors)} embeddings")

    # The eigenvectors of VᵀV: the same result as an SVD of V, in far less memory.
    values, basis = np.linalg.eigh(vectors.T @ vectors)
    order = np.argsort(values)[::-1][: args.dims]
    print(f"{args.dims} dims keep {values[order].sum() / values.sum():.2%} of the energy")
    reduced = vectors @ basis[:, order]
    peak = np.abs(reduced).max(axis=0)
    peak[peak == 0] = 1
    quantized = np.clip(np.round(reduced / peak * 127), -127, 127).astype(np.int8)

    conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    md5s = dict(conn.execute("SELECT path, md5 FROM tunes"))
    conn.close()

    with tempfile.TemporaryDirectory() as work:
        db_path = f"{work}/embeddings.sqlite"
        db = sqlite3.connect(db_path)
        db.executescript(
            "CREATE TABLE embeddings (md5 TEXT NOT NULL, subtune INTEGER NOT NULL, vector BLOB NOT NULL,"
            " PRIMARY KEY (md5, subtune)) WITHOUT ROWID;"
            "CREATE TABLE embedding_scales (dimension INTEGER PRIMARY KEY, scale REAL NOT NULL);"
            f"PRAGMA user_version = {SET_VERSION};"
        )
        db.executemany("INSERT INTO embedding_scales VALUES (?, ?)", enumerate(peak.tolist()))
        db.executemany(
            "INSERT OR IGNORE INTO embeddings VALUES (?, ?, ?)",
            ((md5s[p], s, q.tobytes()) for p, s, q in zip(paths, subtunes, quantized)),
        )
        db.commit()
        db.execute("VACUUM")
        db.close()
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        with zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            archive.write(db_path, "embeddings.sqlite")
            archive.writestr(
                "LICENSE.txt",
                LICENCE.format(version=SET_VERSION, revision=args.revision, dims=args.dims),
            )
    print(f"{args.out}: {os.path.getsize(args.out) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
