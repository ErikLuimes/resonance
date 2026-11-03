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
use store::Store;

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
