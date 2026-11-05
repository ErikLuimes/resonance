#!/usr/bin/env python3
"""Embeds every fingerprinted subtune with MERT, in batches, keeping no audio.

    MERT_REVISION=<sha> uv run --group embed embed_all.py [--batch 6000] [--threads 12]

Each subtune is rendered once per MD5. A batch's audio is deleted as soon as
it's embedded, so the run needs about 15 GB of free space, not 200 GB. A batch
with its output file already there is skipped, so a second run resumes.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sqlite3
import subprocess
import sys

import corpus

HERE = os.path.dirname(os.path.abspath(__file__))
RENDER = os.path.abspath(f"{HERE}/../../target/release/examples/render_audio")


def all_subtunes(db: str) -> list[tuple[str, int, float]]:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    chosen: dict[tuple[str, int], tuple[str, int, float]] = {}
    for md5, path, subtune, secs in conn.execute(
        "SELECT t.md5, t.path, f.subtune, f.scanned_secs FROM fingerprints f "
        "JOIN tunes t ON t.md5 = f.md5 WHERE f.status = 1 ORDER BY t.path, f.subtune"
    ):
        chosen.setdefault((md5, subtune), (path, subtune, secs))
    conn.close()
    return sorted(chosen.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--batch", type=int, default=6000)
    parser.add_argument("--threads", type=int, default=12)
    parser.add_argument("--work", default=f"{corpus.CACHE_DIR}/full")
    args = parser.parse_args()
    if "MERT_REVISION" not in os.environ:
        sys.exit("Set MERT_REVISION to the revision whose code you've read.")

    rows = all_subtunes(corpus.DEFAULT_DB)
    os.makedirs(args.work, exist_ok=True)
    batches = range(0, len(rows), args.batch)
    print(f"{len(rows)} subtunes in {len(batches)} batches", flush=True)
    for number, start in enumerate(batches):
        out = f"{args.work}/batch-{number:03}.npz"
        if os.path.exists(out):
            continue
        audio = f"{args.work}/audio-{number:03}"
        listing = f"{args.work}/batch-{number:03}.tsv"
        with open(listing, "w") as f:
            for path, subtune, secs in rows[start:start + args.batch]:
                f.write(f"{path}\t{subtune}\t{secs:.2f}\n")
        subprocess.run(
            [RENDER, listing, corpus.HVSC_ROOT, audio, str(args.threads)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        partial = f"{args.work}/batch-{number:03}.partial.npz"
        subprocess.run(
            [sys.executable, f"{HERE}/embed.py", "mert", "--audio", audio, "--out", partial],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        os.replace(partial, out)
        shutil.rmtree(audio)
        print(f"batch {number + 1}/{len(batches)} done", flush=True)
    print("all batches done", flush=True)


if __name__ == "__main__":
    main()
