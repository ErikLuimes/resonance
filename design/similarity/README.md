# Sounds Like: how it was chosen

Sounds Like blends two things: 41 features of how a player drives the chip, and a compressed MERT
embedding of how the tune sounds. Both were chosen by the benchmark in
[`apple/scripts/similarity-bench`](../../apple/scripts/similarity-bench). Change the method only
against that benchmark.

## Method

There is no reference list of which SID tunes sound alike, and no peer-reviewed SID similarity study
was found, so candidates were compared on proxies:

| Metric | Role | What it asks |
|---|---|---|
| Same-composer precision@7 | Primary | How many of the top 7 are by the same composer, leaving out the same file and same title |
| Same-file subtune hit@7 | Primary | Does another subtune of the same file reach the top 7 |
| Cover reciprocal rank | Secondary | How high does another STIL-credited version of the same tune rank |
| Hub skew | Guard | How unevenly tunes appear in top-7 lists |

- Composers were split 70/30 by a stable hash. Candidates and weights were chosen on development
  data only.
- Finalists and their weights were frozen, then scored once on held-out composers.
- Confidence intervals are paired bootstrap 95% intervals. Up to 2,000 seed tunes per metric.
- Both tests used about 5,000 tunes. The plan was to score finalists on the whole collection, but a
  fresh 5,000-tune held-out set was used instead because of the rendering cost. It is equally unbiased,
  though absolute numbers depend on collection size.

## Results

### Held-out composers (scored once)

| Method | Same composer | Same-file subtune | Cover rank | Hub skew |
|---|---|---|---|---|
| A: original 22 features | 12.1% | 34.7% | 4.8% | 2.8 |
| B: A + 19 register features | 20.3% | 46.9% | 7.1% | 2.2 |
| B + MuQ-MuLan, 50/50 | 22.4% | 46.1% | 8.2% | 2.4 |
| **B + MERT, 75/25 (shipped)** | **23.3%** | **46.7%** | **8.9%** | 2.5 |

Against A, the shipped method gains +11.1 points on same composer (95% CI +10.2 to +12.1) and +12.0
on same-file (+7.7 to +16.8). Against B it gains +3.0 on same composer (+2.4 to +3.6), with no
detectable change on same-file (−4.0 to +3.5) or covers (−0.2 to +3.7). Random picks would match the
same composer 0.64% of the time.

### Development data, single methods

| Method | Same composer | Same-file subtune | Cover rank |
|---|---|---|---|
| A: original 22 features | 11.9% | 38.1% | 4.8% |
| B: A + 19 register features | 21.9% | 50.0% | 4.9% |
| C: MFCC statistics | 5.9% | 23.2% | 5.9% |
| D: CLAP (`laion/larger_clap_music`) | 2.9% | 10.9% | 5.3% |
| E: MuQ-MuLan | 9.2% | 24.2% | 8.0% |
| F: MERT-v1-95M | 12.0% | 32.9% | 7.5% |

### Full collection

- 88,010 fingerprints finished and 1,067 failed. 99.6% of the finished ones (87,667) have an embedding.
- Downloads: `fingerprints-x2.zip` 42 MB, `embeddings-e1.zip` 11 MB.
- Rust against `rust_parity.py`, 37 seeds: 30 identical in order. Three of the other seven are silent
  tunes, where about 415 others tie and the choice is arbitrary. Without embeddings, all 37 had the
  same top 12, and 35 the same order.
- A query takes about 0.3 s from a cold process. Peak memory is about 265 MB, or 248 MB without
  embeddings.

## What was learned

- **The similarity formula barely matters; the input does.** Euclidean, rank-normalized and whitened
  variants of the original features all tied with cosine.
- **Envelope settings carry most of B's gain.** Leaving out ADSR drops same-composer from 21.9% to
  16.8% and same-file from 50.0% to 40.1%. Filter, time and interval features add little.
- **Pretrained audio models don't win alone here,** though MuQ-MuLan and MERT do beat the features on
  covers. CLAP, the best general-purpose candidate on paper, came last on the primary metrics.
- **Hubness correction (NICDM local scaling) didn't help** on the primary metrics, so it isn't used.
- **Compression:** 128 dimensions at 8 bits per dimension loses almost nothing (24.9% against 25.1%
  same composer). Use uncentered PCA. Centering removes the large direction all MERT vectors share,
  which changes the fusion's effective shares, and at first looked like a large compression loss.
- **The 75/25 share isn't the real balance.** MERT cosines are all high with little spread, so the
  features still decide much of the order.

## Limits

- These are proxies for "sounds alike". Same-composer may partly reward a composer's register habits
  and player routine, not only how tunes sound, and that favors register features. A listening
  test would be stronger evidence and hasn't been run.
- The rendered audio uses reSID with default settings, three 10-second segments per subtune.
- Melody-based cover detection is a different feature and isn't attempted here.
- Scanning the same subtune twice can give different features: about 10% of 400 sampled rows moved by
  more than 1% of a feature's spread. The cause isn't established. The published set fixes one version
  for everyone who downloads it, but a local scan differs slightly.
- Scans run without C64 ROMs, so most BASIC tunes fail or come back silent. Silent tunes match each
  other at 100%. About 415 rows are affected.
- The published set covers one HVSC release. A tune from another release has a different MD5, so it's
  scanned locally and has no embedding.
- Tunes without an embedding (new in a later HVSC release, or silent or failed in the render) use the
  features alone as a seed, and don't appear in the lists of tunes that have embeddings.

## Licenses

- MERT-v1-95M weights are CC-BY-NC 4.0, and the published embeddings carry the same license in their
  own release asset (`embeddings-e1.zip`). The app does no ML inference and doesn't ship the weights.
- MERT's repository code was read before running it, at revision
  `12af15fef9d0ac838c3f475bfbbf26d2060dd4f5`.
- MuQ-MuLan weights are CC-BY-NC 4.0. `laion/larger_clap_music` is Apache-2.0.

## Running it

```bash
cd apple/scripts/similarity-bench
uv run bench.py subset --size 5000
uv run bench.py render-list
uv run bench.py eval --subset ~/Library/Caches/ResonanceSimilarity/subset.tsv --candidate "NAME=FILE.npz"
```

- `core/examples/render_audio.rs` renders audio, and `register_features.rs` extracts B's features
  from a list.
- `embed.py` embeds with a model, `candidates.py` builds B, C, fusions and PCA.
- `embed_all.py` embeds the whole collection, and `export_embeddings.py --db STORE` packs the release
  asset. Pass a store scanned from the files that were rendered, because MD5s differ between HVSC
  releases.
- `rust_parity.py --store STORE [--embeddings ZIP]` checks the Rust ranking against its own copy of the
  formula.
- The bake-off used a copy of the extractor-1 store, at
  `~/Library/Caches/ResonanceSimilarity/fingerprints-v1.sqlite`.
- The held-out split has been spent. New work should still choose on development data, but a new
  held-out score would no longer be untouched.

## Sources

- [Vohra & Akama 2026, perceptual similarity with CLAP and MuQ-MuLan](https://arxiv.org/html/2601.19109v1)
- [Pretrained backends for recommendation, 2026](https://arxiv.org/html/2604.23077v1)
- [Tamm & Aljanaki 2024, pretrained backends](https://arxiv.org/pdf/2409.08987v1.pdf)
- [Araz et al. 2024, deep representations for sound similarity](https://repositori.upf.edu/items/8767ee32-c467-4f2f-bdc5-839a35706e1f)
- [Schnitzer et al. 2012, hubness and scaling](https://jmlr2020.csail.mit.edu/papers/volume13/schnitzer12a/schnitzer12a.pdf)
- [Feldbauer & Flexer 2016, centering versus scaling](https://ouci.dntb.gov.ua/works/4MKQ2gx9)
- [MERT-v1-95M](https://huggingface.co/m-a-p/MERT-v1-95M)
- [MuQ-MuLan](https://huggingface.co/OpenMuQ/MuQ-MuLan-large)
- [LAION CLAP](https://huggingface.co/laion/larger_clap_music)
