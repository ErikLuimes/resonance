//! Sound fingerprints for the tune lists and "Sounds like": a feature
//! extractor (`extract`), the resumable scan over HVSC (`scan`), their
//! SQLite store (`store`) and the similarity search (`similar`).

mod extract;
mod scan;
mod similar;
mod store;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub(crate) use extract::{tag, Fingerprint, BINS};
pub(crate) use scan::{ScanTune, Scanner};
pub(crate) use similar::Index;
pub(crate) use store::EXTRACTOR_VERSION;
use store::Store;

/// A subtune's look, as percentages: its nine traits and its waveform mix
/// (triangle, saw, pulse, noise), what the app's MorphSphere is made of.
pub(crate) type Look = ([u8; 9], [u8; 4]);

/// The look of every finished subtune in the store file at `path`, by MD5
/// and subtune: the share server's preview cards draw them.
pub(crate) fn traits_by_md5(
    path: &std::path::Path,
) -> Result<std::collections::HashMap<String, std::collections::BTreeMap<u16, Look>>, String> {
    let store = Store::open(path).map_err(|e| e.to_string())?;
    let rows = store.traits_by_md5().map_err(|e| e.to_string())?;
    let mut traits: std::collections::HashMap<_, std::collections::BTreeMap<_, _>> = Default::default();
    for (md5, subtune, fp) in rows {
        let percent = |v: f32| (v.clamp(0.0, 1.0) * 100.0).round() as u8;
        let look = (fp.traits().map(percent), fp.mix.map(percent));
        traits.entry(md5).or_default().insert(subtune, look);
    }
    Ok(traits)
}

/// While a scan runs, "Sounds like" rebuilds its index at most this often.
const INDEX_REFRESH: Duration = Duration::from_secs(60);

/// The scan, plus a read connection and the similarity index for lookups.
pub(crate) struct Fingerprints {
    scanner: Scanner,
    reader: Mutex<Option<Store>>,
    /// The index, the scan revision it was built at, and when.
    index: Mutex<Option<(Arc<Index>, u64, Instant)>>,
}

impl Fingerprints {
    pub fn new(db_path: PathBuf) -> Self {
        Self {
            scanner: Scanner::new(db_path),
            reader: Mutex::new(None),
            index: Mutex::new(None),
        }
    }

    pub fn scanner(&self) -> &Scanner {
        &self.scanner
    }

    /// Stop the scan and forget fingerprints: the ones given up on, or
    /// all of them. The next `start` scans what's missing. Blocking: waits
    /// for the scan's workers.
    pub fn forget(&self, failed_only: bool) -> rusqlite::Result<()> {
        self.scanner.cancel();
        let store = Store::open(self.scanner.db_path())?;
        if failed_only {
            store.forget_failed()?;
        } else {
            store.clear()?;
        }
        *self.index.lock().unwrap_or_else(|p| p.into_inner()) = None;
        Ok(())
    }

    /// Stop the scan and merge the fingerprint set in the store file at
    /// `seed` (see `Store::import`); the next `start` scans what's still
    /// missing. Blocking.
    pub fn import(&self, seed: &std::path::Path) -> Result<usize, String> {
        self.scanner.cancel();
        let store = Store::open(self.scanner.db_path()).map_err(|e| e.to_string())?;
        let added = store.import(seed)?;
        *self.index.lock().unwrap_or_else(|p| p.into_inner()) = None;
        Ok(added)
    }

    /// Run `f` on the read connection, opening it on first use.
    fn read<T>(&self, f: impl FnOnce(&Store) -> rusqlite::Result<T>) -> Option<T> {
        let mut slot = self.reader.lock().unwrap_or_else(|p| p.into_inner());
        if slot.is_none() {
            *slot = Store::open(self.scanner.db_path())
                .map_err(|e| eprintln!("[resonance] fingerprints: {e}"))
                .ok();
        }
        f(slot.as_ref()?)
            .map_err(|e| eprintln!("[resonance] fingerprints: {e}"))
            .ok()
    }

    /// The fingerprint of the tune at collection path `rel`: `subtune`, or
    /// its start song. Blocking.
    pub fn lookup(&self, rel: &str, subtune: Option<u16>) -> Option<(u16, Fingerprint)> {
        self.read(|s| s.by_path(rel, subtune)).flatten()
    }

    /// The similarity index, rebuilt from the store when the scan has added
    /// to it (at most once a minute while it runs, unless `seed`, a
    /// collection path, was scanned since, so a tune just fingerprinted
    /// finds its matches). Blocking.
    pub fn index_for(&self, seed: Option<&str>) -> Arc<Index> {
        let revision = self.scanner.revision();
        let mut slot = self.index.lock().unwrap_or_else(|p| p.into_inner());
        if let Some((index, built_at, when)) = slot.as_ref() {
            let fresh = *built_at == revision
                || (self.scanner.is_running()
                    && when.elapsed() < INDEX_REFRESH
                    && seed.is_none_or(|s| index.contains(s)));
            if fresh && index.len() > 0 {
                return index.clone();
            }
        }
        let rows = self.read(|s| s.features()).unwrap_or_default();
        let index = Arc::new(Index::build(rows));
        *slot = Some((index.clone(), revision, Instant::now()));
        index
    }
}

#[cfg(test)]
mod tests;
