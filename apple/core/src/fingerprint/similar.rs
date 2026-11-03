//! "Sounds like": cosine similarity between standardised feature vectors.
//!
//! Each feature is z-scored over the whole store first, so a feature that
//! barely varies across HVSC (most tunes have no ring modulation) can't
//! dominate, and one where a tune stands out counts. The whole store fits
//! in memory (HVSC's ~100k subtunes × 22 floats is under 10 MB), so a query
//! is a straight pass over it.

use std::collections::HashMap;

use super::extract::FEATURES;
use super::store::FeatureRow;

/// How much each feature counts after standardising. The waveform mix and
/// the voice levels come as groups of four and three, so their members
/// count for less each.
const WEIGHTS: [f32; FEATURES] = [
    0.7, 0.7, 0.7, 0.7, // waveform mix
    1.0, 1.0, 0.7, // notes, arpeggios, vibrato
    1.0, 0.5, 0.5, 0.7, // filter
    0.7, 0.7, 1.0, 0.7, // ring, sync, digi, pulse-width modulation
    0.8, 0.7, 0.6, 0.4, // noise hits, pulse bass, pitch
    0.4, 0.4, 0.4, // voice levels
];

pub(crate) struct Index {
    rows: Vec<FeatureRow>,
    /// Standardised, weighted and unit length, row-major.
    vectors: Vec<[f32; FEATURES]>,
    mean: [f32; FEATURES],
    std: [f32; FEATURES],
    by_key: HashMap<(String, u16), usize>,
    by_path: HashMap<String, usize>,
}

pub(crate) struct Match<'a> {
    pub path: &'a str,
    pub subtune: u16,
    /// Cosine similarity, −1…1.
    pub score: f32,
}

impl Index {
    pub fn build(rows: Vec<FeatureRow>) -> Self {
        let n = rows.len().max(1) as f64;
        let mut mean = [0f64; FEATURES];
        for r in &rows {
            for (m, &x) in mean.iter_mut().zip(&r.features) {
                *m += x as f64 / n;
            }
        }
        let mut var = [0f64; FEATURES];
        for r in &rows {
            for (k, &x) in r.features.iter().enumerate() {
                var[k] += (x as f64 - mean[k]).powi(2) / n;
            }
        }
        let mean = mean.map(|m| m as f32);
        // A feature nobody varies on contributes nothing rather than NaN.
        let std = var.map(|v| if v > 1e-12 { v.sqrt() as f32 } else { f32::INFINITY });

        let mut index = Self {
            vectors: Vec::with_capacity(rows.len()),
            rows: Vec::new(),
            mean,
            std,
            by_key: HashMap::with_capacity(rows.len()),
            by_path: HashMap::new(),
        };
        for (i, r) in rows.iter().enumerate() {
            let v = index.vector(&r.features);
            index.vectors.push(v);
            index.by_key.insert((r.path.clone(), r.subtune), i);
            if r.is_start || !index.by_path.contains_key(&r.path) {
                index.by_path.insert(r.path.clone(), i);
            }
        }
        index.rows = rows;
        index
    }

    pub fn len(&self) -> usize {
        self.rows.len()
    }

    /// Whether the file at `path` is in the index.
    pub fn contains(&self, path: &str) -> bool {
        self.by_path.contains_key(path)
    }

    fn vector(&self, features: &[f32; FEATURES]) -> [f32; FEATURES] {
        let mut v = [0f32; FEATURES];
        for k in 0..FEATURES {
            v[k] = (features[k] - self.mean[k]) / self.std[k] * WEIGHTS[k];
        }
        let len = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        if len > 1e-6 {
            v.iter_mut().for_each(|x| *x /= len);
        }
        v
    }

    /// The composers who sound most like the one whose MUSICIANS folder is
    /// `folder` (collection-relative, "MUSICIANS/H/Hubbard_Rob"), best
    /// first: each composer is the average of their tunes' start songs,
    /// and needs at least `min_tunes` of them scanned.
    pub fn similar_composers(&self, folder: &str, min_tunes: usize, limit: usize) -> Vec<(String, f32)> {
        let mut sums: HashMap<&str, ([f32; FEATURES], usize)> = HashMap::new();
        for &i in self.by_path.values() {
            let Some(composer) = composer_folder(&self.rows[i].path) else { continue };
            let slot = sums.entry(composer).or_insert(([0.0; FEATURES], 0));
            for (s, x) in slot.0.iter_mut().zip(&self.vectors[i]) {
                *s += x;
            }
            slot.1 += 1;
        }
        let unit = |(mut v, n): ([f32; FEATURES], usize)| -> Option<[f32; FEATURES]> {
            if n < min_tunes {
                return None;
            }
            let len = v.iter().map(|x| x * x).sum::<f32>().sqrt();
            (len > 1e-6).then(|| {
                v.iter_mut().for_each(|x| *x /= len);
                v
            })
        };
        let Some(target) = sums.get(folder).copied().and_then(unit) else { return Vec::new() };
        let mut scored: Vec<(String, f32)> = sums
            .into_iter()
            .filter(|(f, _)| *f != folder)
            .filter_map(|(f, sum)| {
                let v = unit(sum)?;
                Some((f.to_string(), v.iter().zip(&target).map(|(a, b)| a * b).sum()))
            })
            .collect();
        scored.sort_by(|a, b| b.1.total_cmp(&a.1));
        scored.truncate(limit);
        scored
    }

    /// How alike two files sound (their start songs), −1…1; None when
    /// either hasn't been scanned.
    pub fn score(&self, a: &str, b: &str) -> Option<f32> {
        let (&i, &j) = (self.by_path.get(a)?, self.by_path.get(b)?);
        Some(self.vectors[i].iter().zip(&self.vectors[j]).map(|(x, y)| x * y).sum())
    }

    /// The tunes most like `path`'s `subtune` (its start song when None),
    /// best first: one subtune per file, never the file itself.
    pub fn similar(&self, path: &str, subtune: Option<u16>, limit: usize) -> Vec<Match<'_>> {
        let seed = match subtune {
            Some(s) => self.by_key.get(&(path.to_string(), s)),
            None => self.by_path.get(path),
        };
        let Some(&seed) = seed else { return Vec::new() };
        let target = self.vectors[seed];

        let mut best: HashMap<&str, (usize, f32)> = HashMap::new();
        for (i, v) in self.vectors.iter().enumerate() {
            let row = &self.rows[i];
            if row.path == path {
                continue;
            }
            let score: f32 = v.iter().zip(&target).map(|(a, b)| a * b).sum();
            let slot = best.entry(row.path.as_str()).or_insert((i, f32::MIN));
            if score > slot.1 {
                *slot = (i, score);
            }
        }
        let mut matches: Vec<Match> = best
            .into_values()
            .map(|(i, score)| Match {
                path: &self.rows[i].path,
                subtune: self.rows[i].subtune,
                score,
            })
            .collect();
        matches.sort_by(|a, b| b.score.total_cmp(&a.score).then_with(|| a.path.cmp(b.path)));
        matches.truncate(limit);
        matches
    }
}

/// The composer folder a collection path is in: "MUSICIANS/H/Hubbard_Rob"
/// for any tune under it (some composers have subfolders). None outside
/// MUSICIANS.
pub(crate) fn composer_folder(path: &str) -> Option<&str> {
    let mut slashes = path.match_indices('/').map(|(i, _)| i);
    if !path.starts_with("MUSICIANS/") {
        return None;
    }
    let end = slashes.nth(2)?;
    Some(&path[..end])
}
