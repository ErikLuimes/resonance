"""The fingerprint store and STIL, read-only, and the split the benchmark uses."""

from __future__ import annotations

import hashlib
import os
import re
import sqlite3
from collections import defaultdict
from dataclasses import dataclass

import numpy as np

APP_DIR = os.path.expanduser("~/Library/Application Support/Resonance")
CACHE_DIR = os.path.expanduser("~/Library/Caches/ResonanceSimilarity")
# A copy of the extractor-1 store the bake-off ran on: the app's own moves on.
DEFAULT_DB = f"{CACHE_DIR}/fingerprints-v1.sqlite"
HVSC_ROOT = os.path.expanduser("~/Library/Application Support/phosphor/HVSC")
DEFAULT_STIL = f"{HVSC_ROOT}/DOCUMENTS/STIL.txt"

# Same order as `Fingerprint::features` in core/src/fingerprint/extract.rs.
COLUMNS = (
    "mix_tri mix_saw mix_pul mix_noi notes_per_sec arp_rate vibrato_rate "
    "filter_usage cutoff_mean cutoff_spread cutoff_motion ring sync digi pwm_depth "
    "noise_hits pulse_bass pitch_mean pitch_spread level1 level2 level3"
).split()

# `WEIGHTS` in core/src/fingerprint/similar.rs.
WEIGHTS = np.array(
    [.7, .7, .7, .7, 1, 1, .7, 1, .5, .5, .7, .7, .7, 1, .7, .8, .7, .6, .4, .4, .4, .4],
    dtype=np.float32,
)

HELD_OUT_SHARE = 0.3


@dataclass
class Rows:
    """One entry per subtune per path, in a fixed order."""

    paths: np.ndarray
    subtunes: np.ndarray
    is_start: np.ndarray

    def __len__(self) -> int:
        return len(self.paths)

    def keys(self) -> list[tuple[str, int]]:
        return list(zip(self.paths.tolist(), self.subtunes.tolist()))

    def take(self, index: np.ndarray) -> "Rows":
        return Rows(self.paths[index], self.subtunes[index], self.is_start[index])


def load_features(db: str = DEFAULT_DB) -> tuple[Rows, np.ndarray]:
    """Every finished subtune's raw vector, as `Store::features` returns it."""
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    query = (
        "SELECT t.path, f.subtune, f.subtune = t.start_song, "
        + ",".join(f"f.{c}" for c in COLUMNS)
        + " FROM fingerprints f JOIN tunes t ON t.md5 = f.md5"
        " WHERE f.status = 1 AND f.version = 1 ORDER BY t.path, f.subtune"
    )
    fetched = conn.execute(query).fetchall()
    conn.close()
    paths = np.array([r[0] for r in fetched])
    subtunes = np.array([r[1] for r in fetched], dtype=np.int32)
    is_start = np.array([bool(r[2]) for r in fetched])
    raw = np.array([r[3:] for r in fetched], dtype=np.float32)

    def ln(x: np.ndarray) -> np.ndarray:
        return np.log1p(np.maximum(x, 0))

    x = raw.copy()
    x[:, 4] = ln(raw[:, 4])
    x[:, 5] = ln(raw[:, 5])
    x[:, 6] = ln(raw[:, 6])
    x[:, 10] = ln(raw[:, 10] * 10)
    x[:, 15] = ln(raw[:, 15])
    x[:, 17] = raw[:, 17] / 12
    x[:, 18] = raw[:, 18] / 12
    x[:, 19:22] = -np.sort(-raw[:, 19:22], axis=1)
    return Rows(paths, subtunes, is_start), x


def current_vectors(features: np.ndarray) -> np.ndarray:
    """Candidate A: `Index::build`, standardised over the rows it's given."""
    mean = features.astype(np.float64).mean(axis=0)
    std = features.astype(np.float64).std(axis=0)
    std[std * std <= 1e-12] = np.inf
    z = ((features - mean.astype(np.float32)) / std.astype(np.float32)) * WEIGHTS
    length = np.linalg.norm(z, axis=1, keepdims=True)
    return z / np.where(length > 1e-6, length, 1)


def composer(path: str) -> str | None:
    """`composer_folder` in similar.rs."""
    parts = path.split("/")
    return "/".join(parts[:3]) if parts[0] == "MUSICIANS" and len(parts) > 3 else None


def title_key(path: str) -> str:
    """A file's name without its version or part: Delta_v2 and Delta collide."""
    stem = path.rsplit("/", 1)[-1].rsplit(".", 1)[0].lower()
    stem = re.sub(r"_(v|version|part|pt|remix|mix|rmx|\d)+[_\d]*$", "", stem)
    stem = re.sub(r"_\d+$", "", stem)
    return re.sub(r"[^a-z0-9]", "", stem)


def is_held_out(path: str) -> bool:
    """Stable per composer, per file elsewhere; never changes between runs."""
    group = composer(path) or path
    digest = hashlib.sha256(group.encode()).digest()
    return int.from_bytes(digest[:4], "big") / 2**32 < HELD_OUT_SHARE


@dataclass
class CoverGroup:
    title: str
    artist: str
    paths: set[str]


def cover_groups(stil_path: str = DEFAULT_STIL, min_files: int = 3) -> list[CoverGroup]:
    """Files whose STIL credits the same title and original artist."""
    groups: dict[tuple[str, str], set[str]] = defaultdict(set)
    path = None
    title = None
    with open(stil_path, encoding="latin-1") as f:
        for line in f:
            if line.startswith("/"):
                path, title = line.strip().lstrip("/"), None
                continue
            match = re.match(r"\s*(TITLE|ARTIST):\s*(.*)", line)
            if not match or path is None:
                continue
            if match[1] == "TITLE":
                title = re.sub(r"\s*[\[(].*$", "", match[2]).strip().lower()
                if title in ("", "unknown", "<?>"):
                    title = None
            elif title:
                artist = re.sub(r"\s*[\[(].*$", "", match[2]).strip().lower()
                groups[(title, artist)].add(path)
                title = None
    return [CoverGroup(t, a, p) for (t, a), p in groups.items() if len(p) >= min_files]
