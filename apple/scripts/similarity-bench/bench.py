#!/usr/bin/env python3
"""Benchmark for Sounds Like. Reads the fingerprint store and embedding files;
writes only the --out report and files under the cache folder.

    uv run bench.py dump Delta_path...            app-equivalent rankings
    uv run bench.py subset --size 5000            pick the bake-off subset
    uv run bench.py eval --subset FILE [--candidate NAME=FILE.npz ...]
    uv run bench.py eval --final --candidate ...  held-out composers, once

A candidate file is an .npz with `paths`, `subtunes` and float `vectors`, plus
`metric` ("cosine", the default, or "euclidean"). Candidate A is always added.
"""

from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict

import numpy as np

import corpus

TOP = 7
SHORTLIST = 400


def scores_for(seeds: np.ndarray, vectors: np.ndarray, metric: str) -> np.ndarray:
    if metric == "cosine":
        return seeds @ vectors.T
    if metric == "nicdm":
        raise AssertionError("handled by Bench._shortlists")
    return -(
        (seeds * seeds).sum(1, keepdims=True)
        + (vectors * vectors).sum(1)
        - 2 * seeds @ vectors.T
    )


def load_candidate(path: str, rows: corpus.Rows) -> tuple[np.ndarray, str, np.ndarray]:
    """The candidate's vectors in `rows` order, its metric, and which rows it has."""
    data = np.load(path, allow_pickle=False)
    index = {k: i for i, k in enumerate(zip(data["paths"].tolist(), data["subtunes"].tolist()))}
    where = np.array([index.get(k, -1) for k in rows.keys()])
    have = where >= 0
    vectors = np.zeros((len(rows), data["vectors"].shape[1]), dtype=np.float32)
    vectors[have] = data["vectors"][where[have]]
    metric = str(data["metric"]) if "metric" in data else "cosine"
    if metric in ("cosine", "nicdm"):
        length = np.linalg.norm(vectors, axis=1, keepdims=True)
        vectors = vectors / np.where(length > 1e-9, length, 1)
    return vectors, metric, have


class Bench:
    def __init__(self, rows: corpus.Rows, final: bool, seeds_wanted: int, rng_seed: int = 7):
        self.rows = rows
        paths = rows.paths.tolist()
        self.paths = paths
        self.composers = [corpus.composer(p) for p in paths]
        self.titles = [corpus.title_key(p) for p in paths]
        files_by_composer: dict[str, set[str]] = defaultdict(set)
        subtunes_by_file: dict[str, int] = defaultdict(int)
        for p, c in zip(paths, self.composers):
            subtunes_by_file[p] += 1
            if c:
                files_by_composer[c].add(p)
        rng = np.random.default_rng(rng_seed)
        held = np.array([corpus.is_held_out(p) for p in paths])
        wanted_group = held if final else ~held
        start = np.flatnonzero(rows.is_start & wanted_group)

        composer_seeds = [
            i for i in start
            if self.composers[i] and len(files_by_composer[self.composers[i]]) >= 20
        ]
        file_seeds = [i for i in start if subtunes_by_file[paths[i]] >= 3]
        self.composer_seeds = self._sample(rng, composer_seeds, seeds_wanted)
        self.file_seeds = self._sample(rng, file_seeds, seeds_wanted)

        self.groups: dict[str, list[set[str]]] = defaultdict(list)
        present = set(paths)
        groups = corpus.cover_groups()
        for g in groups:
            members = g.paths & present
            if len(members) >= 3:
                for p in members:
                    self.groups[p].append(members)
        cover_seeds = [i for i in start if paths[i] in self.groups]
        self.cover_seeds = self._sample(rng, cover_seeds, seeds_wanted)

        hub_pool = np.flatnonzero(rows.is_start)
        self.hub_seeds = self._sample(rng, hub_pool.tolist(), 20_000)
        self.chance = float(np.mean([
            (len(files_by_composer[self.composers[i]]) - 1) / max(len(set(paths)) - 1, 1)
            for i in self.composer_seeds
        ])) if len(self.composer_seeds) else 0.0

    @staticmethod
    def _sample(rng, items, n) -> np.ndarray:
        items = np.array(items, dtype=np.int64)
        if len(items) <= n:
            return items
        return np.sort(rng.choice(items, n, replace=False))

    def _shortlists(self, seeds, vectors, metric, have, chunk=256):
        """(seed index, row indices best first, row scores), per seed with a vector."""
        for start in range(0, len(seeds), chunk):
            batch = seeds[start:start + chunk]
            if metric == "nicdm":
                # Schnitzer et al. 2012: distance over the two tunes' local scales.
                scale = self.nicdm_scale
                scores = -(1 - vectors[batch] @ vectors.T) / np.sqrt(np.outer(scale[batch], scale))
            else:
                scores = scores_for(vectors[batch], vectors, metric)
            scores[:, ~have] = -np.inf
            k = min(SHORTLIST, scores.shape[1] - 1)
            top = np.argpartition(-scores, k, axis=1)[:, :k]
            for row, seed in enumerate(batch):
                order = top[row][np.argsort(-scores[row, top[row]], kind="stable")]
                yield int(seed), order, scores[row]

    def evaluate(self, vectors, metric, have) -> dict:
        paths, composers, titles = self.paths, self.composers, self.titles
        if metric == "nicdm":
            means = np.zeros(len(vectors), dtype=np.float32)
            for start in range(0, len(vectors), 512):
                d = 1 - vectors[start:start + 512] @ vectors.T
                means[start:start + 512] = np.partition(d, 10, axis=1)[:, 1:11].mean(axis=1)
            self.nicdm_scale = np.maximum(means, 1e-6)
        out: dict = {}

        precision = np.full(len(self.composer_seeds), np.nan)
        for at, (seed, order, _) in enumerate(self._shortlists(self.composer_seeds, vectors, metric, have)):
            if not have[seed]:
                continue
            seen = {paths[seed]}
            hits = taken = 0
            for i in order:
                p = paths[i]
                if p in seen or titles[i] == titles[seed]:
                    continue
                seen.add(p)
                taken += 1
                hits += composers[i] == composers[seed]
                if taken == TOP:
                    break
            precision[at] = hits / TOP if taken else 0.0
        out["composer"] = precision

        hit = np.full(len(self.file_seeds), np.nan)
        for at, (seed, order, _) in enumerate(self._shortlists(self.file_seeds, vectors, metric, have)):
            if not have[seed]:
                continue
            near = [i for i in order if i != seed][:TOP]
            hit[at] = float(any(paths[i] == paths[seed] for i in near))
        out["same_file"] = hit

        reciprocal = np.full(len(self.cover_seeds), np.nan)
        for at, (seed, _, scores) in enumerate(self._shortlists(self.cover_seeds, vectors, metric, have)):
            if not have[seed]:
                continue
            members = set().union(*self.groups[paths[seed]]) - {paths[seed]}
            member_rows = [i for i, p in enumerate(paths) if p in members and have[i]]
            if member_rows:
                best = scores[member_rows].max()
                better = int((scores > best).sum()) - int(scores[seed] > best)
                reciprocal[at] = 1 / (better + 1)
        out["cover_rr"] = reciprocal

        occurrences: dict[str, int] = defaultdict(int)
        for seed, order, _ in self._shortlists(self.hub_seeds, vectors, metric, have):
            if not have[seed]:
                continue
            seen = {paths[seed]}
            for i in order:
                if paths[i] not in seen:
                    seen.add(paths[i])
                    occurrences[paths[i]] += 1
                    if len(seen) > TOP:
                        break
        counts = np.array([occurrences.get(p, 0) for p in set(paths)], dtype=np.float64)
        spread = counts.std() or 1.0
        out["hub_skew"] = float((((counts - counts.mean()) / spread) ** 3).mean())
        out["hub_max"] = int(counts.max())
        out["never_listed"] = float((counts == 0).mean())
        return out


def interval(values: np.ndarray, base: np.ndarray | None = None, resamples=2000) -> tuple[float, float, float]:
    """Mean (of the paired difference when `base` is given) and its 95% interval."""
    use = ~np.isnan(values) if base is None else ~(np.isnan(values) | np.isnan(base))
    x = values[use] if base is None else values[use] - base[use]
    if len(x) == 0:
        return (float("nan"),) * 3
    rng = np.random.default_rng(11)
    means = x[rng.integers(0, len(x), (resamples, len(x)))].mean(axis=1)
    return float(x.mean()), float(np.percentile(means, 2.5)), float(np.percentile(means, 97.5))


def cmd_dump(args):
    rows, features = corpus.load_features(args.db)
    vectors = corpus.current_vectors(features)
    paths = rows.paths.tolist()
    for seed_path in args.paths:
        seeds = np.flatnonzero((rows.paths == seed_path) & rows.is_start)
        if len(seeds) == 0:
            seeds = np.flatnonzero(rows.paths == seed_path)[:1]
        scores = vectors @ vectors[seeds[0]]
        best: dict[str, float] = {}
        for i in np.argsort(-scores)[:5000]:
            if paths[i] != seed_path and paths[i] not in best:
                best[paths[i]] = float(scores[i])
        print(seed_path)
        for p, s in sorted(best.items(), key=lambda kv: (-kv[1], kv[0]))[: args.limit]:
            print(f"  {s:+.4f} {p}")


def cmd_subset(args):
    """Development data only; held-out composers can't leak into the bake-off."""
    rows, features = corpus.load_features(args.db)
    rng = np.random.default_rng(3)
    by_file: dict[str, list[int]] = defaultdict(list)
    for i, p in enumerate(rows.paths.tolist()):
        if corpus.is_held_out(p) == args.held_out:
            by_file[p].append(i)
    files = sorted(by_file)
    digi_at = corpus.COLUMNS.index("digi")
    musicians: dict[str, list[str]] = defaultdict(list)
    games, demos, digi, multi_sid = [], [], [], []
    for p in files:
        if c := corpus.composer(p):
            musicians[c].append(p)
        elif p.startswith("GAMES"):
            games.append(p)
        elif p.startswith("DEMOS"):
            demos.append(p)
        if features[by_file[p], digi_at].max() >= 0.1:
            digi.append(p)
    chosen: set[str] = set()
    quota = {"music": int(args.size * 0.6), "games": int(args.size * 0.18), "demos": int(args.size * 0.12)}
    big = [c for c in sorted(musicians) if len(musicians[c]) >= 20]
    rng.shuffle(big)
    for c in big:
        if len(chosen) >= quota["music"]:
            break
        tunes = sorted(musicians[c])
        rng.shuffle(tunes)
        chosen.update(tunes[:30])
    for pool, n in ((games, quota["games"]), (demos, quota["demos"])):
        pool = [p for p in pool if p not in chosen]
        chosen.update(rng.choice(pool, min(n, len(pool)), replace=False).tolist())
    digi = [p for p in digi if p not in chosen]
    chosen.update(rng.choice(digi, min(int(args.size * 0.05), len(digi)), replace=False).tolist())
    rest = [p for p in files if p not in chosen]
    if len(chosen) < args.size:
        chosen.update(rng.choice(rest, args.size - len(chosen), replace=False).tolist())
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        for p in sorted(chosen):
            subs = rows.subtunes[by_file[p]].tolist()
            starts = rows.is_start[by_file[p]].tolist()
            for s, is_start in zip(subs, starts):
                # Every subtune counts for the same-file test, up to eight a file.
                if is_start or subs.index(s) < 8:
                    f.write(f"{p}\t{s}\n")
    print(f"{len(chosen)} files -> {args.out}")


def cmd_render_list(args):
    """The input for core/examples/render_audio.rs: path, subtune, seconds."""
    import sqlite3

    conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    secs = {
        (p, s): t
        for p, s, t in conn.execute(
            "SELECT t.path, f.subtune, f.scanned_secs FROM fingerprints f JOIN tunes t ON t.md5 = f.md5 "
            "WHERE f.status = 1 AND f.version = 1"
        )
    }
    conn.close()
    with open(args.subset) as f, open(args.out, "w") as out:
        for line in f:
            p, s = line.rstrip("\n").split("\t")
            out.write(f"{p}\t{s}\t{secs[(p, int(s))]:.2f}\n")


def cmd_eval(args):
    if args.final and not args.yes_i_mean_it:
        raise SystemExit("--final spends the held-out set; add --yes-i-mean-it")
    rows, features = corpus.load_features(args.db)
    if args.subset:
        wanted = set()
        with open(args.subset) as f:
            for line in f:
                p, s = line.rstrip("\n").split("\t")
                wanted.add((p, int(s)))
        keep = np.array([k in wanted for k in rows.keys()])
        rows = rows.take(np.flatnonzero(keep))
        features = features[keep]
    candidates = [("A current", corpus.current_vectors(features), "cosine", np.ones(len(rows), bool))]
    for spec in args.candidate:
        name, path = spec.split("=", 1)
        vectors, metric, have = load_candidate(path, rows)
        candidates.append((name, vectors, metric, have))
    have_all = np.logical_and.reduce([c[3] for c in candidates])
    missing = int((~have_all).sum())
    if missing:
        print(f"note: {missing} of {len(rows)} rows missing from a candidate; those are excluded.")
        keep = np.flatnonzero(have_all)
        rows = rows.take(keep)
        candidates = [(n, v[keep], m, h[keep]) for n, v, m, h in candidates]
    bench = Bench(rows, args.final, args.seeds)
    print(
        f"{len(rows)} rows, {len(set(rows.paths.tolist()))} files. Seeds: composer "
        f"{len(bench.composer_seeds)}, same-file {len(bench.file_seeds)}, covers "
        f"{len(bench.cover_seeds)}. Same-composer chance {bench.chance:.2%}. "
        f"Split: {'HELD-OUT' if args.final else 'development'}."
    )
    results = {}
    for name, vectors, metric, have in candidates:
        results[name] = bench.evaluate(vectors, metric, have)
    base = results["A current"]
    report = {}
    for name, r in results.items():
        line = {}
        for key in ("composer", "same_file", "cover_rr"):
            mean, lo, hi = interval(r[key])
            line[key] = {"mean": mean, "ci95": [lo, hi]}
            if name != "A current":
                d, dlo, dhi = interval(r[key], base[key])
                line[key]["vs_A"] = {"mean": d, "ci95": [dlo, dhi]}
        line["hub_skew"], line["hub_max"], line["never_listed"] = r["hub_skew"], r["hub_max"], r["never_listed"]
        report[name] = line
        def fmt(k):
            c = line[k]
            s = f"{c['mean']:6.1%} [{c['ci95'][0]:.1%},{c['ci95'][1]:.1%}]"
            if "vs_A" in c:
                v = c["vs_A"]
                s += f" d{v['mean']:+.1%} [{v['ci95'][0]:+.1%},{v['ci95'][1]:+.1%}]"
            return s
        print(
            f"{name:26} composer {fmt('composer')} | same-file {fmt('same_file')} | "
            f"cover MRR {fmt('cover_rr')} | hub skew {line['hub_skew']:.1f} "
            f"max {line['hub_max']} unlisted {line['never_listed']:.0%}",
            flush=True,
        )
    if args.base:
        print(f"\nPaired against {args.base}:")
        for name, r in results.items():
            if name in (args.base, "A current"):
                continue
            parts = []
            comparison = {}
            for key in ("composer", "same_file", "cover_rr"):
                d, lo, hi = interval(r[key], results[args.base][key])
                comparison[key] = {"mean": d, "ci95": [lo, hi]}
                parts.append(f"{key} {d:+.1%} [{lo:+.1%},{hi:+.1%}]")
            report[name][f"vs_{args.base}"] = comparison
            print(f"{name:26} " + " | ".join(parts))
    if args.out:
        with open(args.out, "w") as f:
            json.dump(report, f, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=corpus.DEFAULT_DB)
    sub = parser.add_subparsers(dest="command", required=True)
    dump = sub.add_parser("dump")
    dump.add_argument("paths", nargs="+")
    dump.add_argument("--limit", type=int, default=12)
    dump.set_defaults(run=cmd_dump)
    subset = sub.add_parser("subset")
    subset.add_argument("--size", type=int, default=5000)
    subset.add_argument("--held-out", action="store_true", help="for the final test only")
    subset.add_argument("--out", default=f"{corpus.CACHE_DIR}/subset.tsv")
    subset.set_defaults(run=cmd_subset)
    render_list = sub.add_parser("render-list")
    render_list.add_argument("--subset", default=f"{corpus.CACHE_DIR}/subset.tsv")
    render_list.add_argument("--out", default=f"{corpus.CACHE_DIR}/render.tsv")
    render_list.set_defaults(run=cmd_render_list)
    ev = sub.add_parser("eval")
    ev.add_argument("--subset")
    ev.add_argument("--candidate", action="append", default=[])
    ev.add_argument("--seeds", type=int, default=2000)
    ev.add_argument("--final", action="store_true")
    ev.add_argument("--yes-i-mean-it", action="store_true")
    ev.add_argument("--base", help="also compare every candidate with this one")
    ev.add_argument("--out")
    ev.set_defaults(run=cmd_eval)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
