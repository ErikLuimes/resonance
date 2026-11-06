//! "Sounds like": how close two subtunes are, by how the player drives the
//! chip and, where the published embeddings have both, by how they sound.
//!
//! Each feature is z-scored over the whole store first, so a feature that
//! barely varies across HVSC (most tunes have no ring modulation) can't
//! dominate, and one where a tune stands out counts. A query is a straight
//! pass over the store, which fits in memory (the process peaks at about
//! 265 MB for HVSC's ~90k subtunes with embeddings). `design/similarity` has
//! the benchmark that chose all this; change it only against that benchmark.

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
    NEW, NEW, NEW, NEW, NEW, NEW, // envelope settings
    NEW, NEW, NEW, NEW, // filter modes, resonance
    NEW, NEW, NEW, // 8580, chips, combined waveforms
    NEW, NEW, // notes over time
    NEW, NEW, NEW, NEW, // melodic steps
];
/// The weight the first 22 average: the benchmark's choice, not tuned.
const NEW: f32 = 15.0 / 22.0;

/// How much the audio embedding counts against the features, in the cosines.
/// The benchmark's frozen value; embeddings all lie close together, so in
/// effect the features still decide much of the order.
const EMBEDDING_SHARE: f32 = 0.75;

pub(crate) struct Index {
    rows: Vec<FeatureRow>,
    /// Standardised, weighted and unit length, row-major.
    vectors: Vec<[f32; FEATURES]>,
    /// Unit length; None where the subtune has no embedding.
    embeddings: Vec<Option<Box<[f32]>>>,
    /// The blended score of two typical subtunes: shown as 0% alike, as the
    /// features' cosine already gives, since embeddings alone read near 100%.
    typical: f32,
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
    pub fn build(mut rows: Vec<FeatureRow>) -> Self {
        let embeddings: Vec<Option<Box<[f32]>>> =
            rows.iter_mut().map(|r| r.embedding.take().and_then(unit_embedding)).collect();
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
            embeddings,
            typical: 0.0,
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
        index.typical = index.typical_score();
        index
    }

    /// The median blended score over a spread of pairs.
    fn typical_score(&self) -> f32 {
        let with: Vec<usize> = (0..self.rows.len()).filter(|&i| self.embeddings[i].is_some()).collect();
        if with.len() < 2 {
            return 0.0;
        }
        let mut scores: Vec<f32> = (0..with.len().min(4000))
            .map(|k| {
                let i = with[k * with.len() / with.len().min(4000)];
                let j = with[(k * 7919 + with.len() / 2) % with.len()];
                self.blended(i, j)
            })
            .collect();
        scores.sort_by(f32::total_cmp);
        scores[scores.len() / 2].min(0.99)
    }

    fn feature_score(&self, i: usize, j: usize) -> f32 {
        dot(&self.vectors[i], &self.vectors[j])
    }

    fn blended(&self, i: usize, j: usize) -> f32 {
        let (Some(a), Some(b)) = (&self.embeddings[i], &self.embeddings[j]) else {
            return self.feature_score(i, j);
        };
        EMBEDDING_SHARE * dot(a, b) + (1.0 - EMBEDDING_SHARE) * self.feature_score(i, j)
    }

    /// How alike two subtunes are: blended when the first has an embedding,
    /// which then leaves out those without (None); by features otherwise.
    fn pair(&self, seed: usize, other: usize) -> Option<f32> {
        if self.embeddings[seed].is_none() {
            return Some(self.feature_score(seed, other));
        }
        self.embeddings[other].as_ref()?;
        Some(self.shown(self.blended(seed, other)))
    }

    /// A blended score with the typical pair at 0 and the same subtune at 1.
    fn shown(&self, score: f32) -> f32 {
        (score - self.typical) / (1.0 - self.typical)
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
        #[derive(Clone)]
        struct Sum {
            features: Vec<f32>,
            embedding: Vec<f32>,
            tunes: usize,
            embedded: usize,
        }
        let mut sums: HashMap<&str, Sum> = HashMap::new();
        for &i in self.by_path.values() {
            let Some(composer) = composer_folder(&self.rows[i].path) else { continue };
            let slot = sums.entry(composer).or_insert_with(|| Sum {
                features: vec![0.0; FEATURES],
                embedding: Vec::new(),
                tunes: 0,
                embedded: 0,
            });
            add(&mut slot.features, &self.vectors[i]);
            slot.tunes += 1;
            if let Some(e) = &self.embeddings[i] {
                slot.embedding.resize(e.len(), 0.0);
                add(&mut slot.embedding, e);
                slot.embedded += 1;
            }
        }
        let sums: HashMap<&str, Sum> = sums
            .into_iter()
            .filter(|(_, s)| s.tunes >= min_tunes)
            .map(|(f, mut s)| {
                normalise(&mut s.features);
                normalise(&mut s.embedding);
                (f, s)
            })
            .collect();
        let Some(target) = sums.get(folder) else { return Vec::new() };
        let blend = target.embedded >= min_tunes;
        let mut scored: Vec<(String, f32)> = sums
            .iter()
            .filter(|(f, s)| **f != folder && (!blend || s.embedded >= min_tunes))
            .map(|(f, s)| {
                let features = dot(&s.features, &target.features);
                let score = if blend {
                    self.shown(EMBEDDING_SHARE * dot(&s.embedding, &target.embedding) + (1.0 - EMBEDDING_SHARE) * features)
                } else {
                    features
                };
                (f.to_string(), score)
            })
            .collect();
        scored.sort_by(|a, b| b.1.total_cmp(&a.1));
        scored.truncate(limit);
        scored
    }

    /// Each file's start song as (path, features before standardising).
    pub fn start_songs(&self) -> Vec<(&str, &[f32; FEATURES])> {
        self.by_path.iter().map(|(path, &i)| (path.as_str(), &self.rows[i].features)).collect()
    }

    /// How alike each file's start song is to the average of `group`'s, by
    /// the features alone: embeddings all lie close together, which an
    /// average blurs further. Empty when none of `group` is in the index.
    pub fn likeness_to_group(&self, group: &[&str]) -> HashMap<&str, f32> {
        let mut centre = vec![0f32; FEATURES];
        let mut count = 0;
        for path in group {
            if let Some(&i) = self.by_path.get(*path) {
                add(&mut centre, &self.vectors[i]);
                count += 1;
            }
        }
        if count == 0 {
            return HashMap::new();
        }
        normalise(&mut centre);
        self.by_path.iter().map(|(path, &i)| (path.as_str(), dot(&self.vectors[i], &centre))).collect()
    }

    /// How alike two files sound (their start songs), −1…1; None when
    /// either hasn't been scanned.
    pub fn score(&self, a: &str, b: &str) -> Option<f32> {
        let (&i, &j) = (self.by_path.get(a)?, self.by_path.get(b)?);
        self.pair(i, j)
    }

    /// The tunes most like `path`'s `subtune` (its start song when None),
    /// best first: one subtune per file, never the file itself.
    pub fn similar(&self, path: &str, subtune: Option<u16>, limit: usize) -> Vec<Match<'_>> {
        let seed = match subtune {
            Some(s) => self.by_key.get(&(path.to_string(), s)),
            None => self.by_path.get(path),
        };
        let Some(&seed) = seed else { return Vec::new() };

        let mut best: HashMap<&str, (usize, f32)> = HashMap::new();
        for (i, row) in self.rows.iter().enumerate() {
            if row.path == path {
                continue;
            }
            let Some(score) = self.pair(seed, i) else { continue };
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

fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

fn add(sum: &mut [f32], v: &[f32]) {
    for (s, x) in sum.iter_mut().zip(v) {
        *s += x;
    }
}

fn normalise(v: &mut [f32]) {
    let length = dot(v, v).sqrt();
    if length > 1e-6 {
        v.iter_mut().for_each(|x| *x /= length);
    }
}

fn unit_embedding(mut v: Vec<f32>) -> Option<Box<[f32]>> {
    (dot(&v, &v) > 1e-12).then(|| {
        normalise(&mut v);
        v.into_boxed_slice()
    })
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
