//! The background job that fingerprints HVSC.
//!
//! Two passes over the collection's indexed tunes: first every tune's start
//! song, so the lists fill in early, then the other subtunes. Workers run at
//! utility QoS, each with its own SQLite connection, and skip what's already
//! in the store, so a scan picks up where the last one stopped: after a
//! pause, a quit or a crash.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use super::extract::scan_tune;
use super::store::{Status, Store, MAX_ATTEMPTS};
use crate::databases::Databases;
use crate::player::sid_file;

/// Scan at most this much of a subtune; the lanes span what was scanned.
pub(crate) const MAX_SCAN_SECS: f32 = 180.0;
/// For subtunes the Songlengths database doesn't know.
const DEFAULT_SCAN_SECS: f32 = 120.0;
const MIN_SCAN_SECS: f32 = 2.0;

/// One indexed tune: its path on disk and in the collection.
pub(crate) struct ScanTune {
    pub path: PathBuf,
    pub rel: String,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct Progress {
    pub running: bool,
    pub paused: bool,
    /// Both passes have run to the end.
    pub finished: bool,
    /// 1: start songs, 2: the other subtunes.
    pub pass: u8,
    /// Subtunes in the collection, and how many are scanned or given up on.
    pub total: u32,
    pub done: u32,
    pub failed: u32,
    /// Bumped by every fingerprint saved.
    pub revision: u64,
    pub error: Option<String>,
}

#[derive(Default)]
struct Shared {
    running: AtomicBool,
    paused: AtomicBool,
    cancel: AtomicBool,
    finished: AtomicBool,
    pass: AtomicU32,
    total: AtomicU32,
    done: AtomicU32,
    failed: AtomicU32,
    revision: AtomicU64,
    error: Mutex<Option<String>>,
}

pub(crate) struct Scanner {
    db_path: PathBuf,
    shared: Arc<Shared>,
    coordinator: Mutex<Option<thread::JoinHandle<()>>>,
}

impl Scanner {
    pub fn new(db_path: PathBuf) -> Self {
        Self {
            db_path,
            shared: Arc::default(),
            coordinator: Mutex::new(None),
        }
    }

    pub fn db_path(&self) -> &Path {
        &self.db_path
    }

    pub fn is_running(&self) -> bool {
        self.shared.running.load(Ordering::Acquire)
    }

    /// Stopped but not yet wound down.
    pub fn is_stopping(&self) -> bool {
        self.shared.cancel.load(Ordering::Acquire)
    }

    /// Start scanning `tunes` (with `songs` subtunes in all); a no-op while
    /// a scan runs.
    pub fn start(&self, tunes: Vec<ScanTune>, songs: u32, databases: Arc<Databases>) {
        let mut slot = self.coordinator.lock().unwrap();
        if self.is_running() && !self.is_stopping() {
            return;
        }
        // A stopped scan winding down, or one that has ended.
        if let Some(old) = slot.take() {
            let _ = old.join();
        }
        self.shared.running.store(true, Ordering::Release);
        let s = &self.shared;
        s.cancel.store(false, Ordering::Release);
        s.finished.store(false, Ordering::Release);
        s.pass.store(1, Ordering::Release);
        s.total.store(songs, Ordering::Release);
        // Counted here, so the first status after a start already shows
        // what earlier scans saved.
        let counts = Store::open(&self.db_path).and_then(|store| store.counts());
        let (done, failed) = counts.as_ref().copied().unwrap_or((0, 0));
        s.done.store(done.min(songs), Ordering::Release);
        s.failed.store(failed.min(songs.saturating_sub(done)), Ordering::Release);
        *s.error.lock().unwrap() = counts
            .err()
            .map(|e| format!("can't open {}: {e}", self.db_path.display()));
        let shared = self.shared.clone();
        let db_path = self.db_path.clone();
        *slot = Some(
            thread::Builder::new()
                .name("resonance-fingerprints".into())
                .spawn(move || {
                    coordinate(&shared, &db_path, tunes, &databases);
                    shared.running.store(false, Ordering::Release);
                })
                .expect("failed to spawn the fingerprint scan"),
        );
    }

    pub fn set_paused(&self, paused: bool) {
        self.shared.paused.store(paused, Ordering::Release);
    }

    /// Stop the scan; it resumes from the store next time. Returns at
    /// once; the workers stop within a few seconds of emulated time.
    pub fn stop(&self) {
        self.shared.cancel.store(true, Ordering::Release);
    }

    /// Stop the scan and wait for its workers.
    pub fn cancel(&self) {
        self.stop();
        if let Some(handle) = self.coordinator.lock().unwrap().take() {
            let _ = handle.join();
        }
    }

    pub fn progress(&self) -> Progress {
        let s = &self.shared;
        Progress {
            running: s.running.load(Ordering::Acquire),
            paused: s.paused.load(Ordering::Acquire),
            finished: s.finished.load(Ordering::Acquire),
            pass: s.pass.load(Ordering::Acquire) as u8,
            total: s.total.load(Ordering::Acquire),
            done: s.done.load(Ordering::Acquire),
            failed: s.failed.load(Ordering::Acquire),
            revision: s.revision.load(Ordering::Acquire),
            error: s.error.lock().unwrap().clone(),
        }
    }

    /// Bumped by every fingerprint saved, by this scan or an earlier one.
    pub fn revision(&self) -> u64 {
        self.shared.revision.load(Ordering::Acquire)
    }
}

fn coordinate(shared: &Arc<Shared>, db_path: &Path, tunes: Vec<ScanTune>, databases: &Databases) {
    let fail = |e: String| {
        eprintln!("[resonance] fingerprint scan: {e}");
        *shared.error.lock().unwrap() = Some(e);
    };
    if let Some(e) = shared.error.lock().unwrap().clone() {
        eprintln!("[resonance] fingerprint scan: {e}");
        return;
    }

    let workers = thread::available_parallelism()
        .map_or(2, |n| n.get() / 2)
        .clamp(1, 6);
    for pass in [1u8, 2] {
        shared.pass.store(pass as u32, Ordering::Release);
        let next = AtomicUsize::new(0);
        let ok = thread::scope(|scope| {
            let handles: Vec<_> = (0..workers)
                .map(|_| scope.spawn(|| work(shared, db_path, &tunes, &next, pass, databases)))
                .collect();
            handles
                .into_iter()
                .map(|h| h.join().unwrap_or_else(|_| Err("a scan worker panicked".into())))
                .collect::<Result<Vec<()>, String>>()
        });
        if let Err(e) = ok {
            return fail(e);
        }
        if shared.cancel.load(Ordering::Acquire) {
            return;
        }
    }
    shared.finished.store(true, Ordering::Release);
}

fn work(
    shared: &Shared,
    db_path: &Path,
    tunes: &[ScanTune],
    next: &AtomicUsize,
    pass: u8,
    databases: &Databases,
) -> Result<(), String> {
    lower_priority();
    let store = Store::open(db_path).map_err(|e| e.to_string())?;
    loop {
        while shared.paused.load(Ordering::Acquire) && !shared.cancel.load(Ordering::Acquire) {
            thread::sleep(Duration::from_millis(200));
        }
        if shared.cancel.load(Ordering::Acquire) {
            return Ok(());
        }
        let i = next.fetch_add(1, Ordering::AcqRel);
        let Some(tune) = tunes.get(i) else { return Ok(()) };
        scan_file(shared, &store, tune, pass, databases).map_err(|e| e.to_string())?;
    }
}

/// Scan this pass's subtunes of one file. Unreadable files are skipped;
/// only store errors end the scan.
fn scan_file(
    shared: &Shared,
    store: &Store,
    tune: &ScanTune,
    pass: u8,
    databases: &Databases,
) -> rusqlite::Result<()> {
    let Ok(data) = std::fs::read(&tune.path) else { return Ok(()) };
    let Ok(header) = sid_file::parse_header(&data) else { return Ok(()) };
    let md5 = format!("{:x}", md5::compute(&data));
    let songs = header.songs.max(1);
    let start = header.start_song.clamp(1, songs);
    if pass == 1 {
        store.set_tune(&tune.rel, &md5, start, songs)?;
    }
    let subtunes: Vec<u16> = if pass == 1 {
        vec![start]
    } else {
        (1..=songs).filter(|&s| s != start).collect()
    };

    for subtune in subtunes {
        if shared.cancel.load(Ordering::Acquire) {
            break;
        }
        match store.status(&md5, subtune)? {
            Some((Status::Done | Status::Failed, _)) => continue,
            Some((Status::Scanning, attempts)) if attempts >= MAX_ATTEMPTS => {
                // Cut short that often: it takes the scan down with it.
                store.mark_failed(&md5, subtune, "scan didn't finish")?;
                shared.failed.fetch_add(1, Ordering::AcqRel);
                continue;
            }
            _ => {}
        }
        let secs = databases
            .songlengths
            .as_ref()
            .and_then(|db| db.lookup(&md5, subtune as usize - 1))
            .filter(|&s| s > 0)
            .map_or(DEFAULT_SCAN_SECS, |s| s as f32)
            .clamp(MIN_SCAN_SECS, MAX_SCAN_SECS);

        store.mark_scanning(&md5, subtune)?;
        let cancelled = || shared.cancel.load(Ordering::Acquire);
        let result = catch_unwind(AssertUnwindSafe(|| scan_tune(&data, subtune, secs, &cancelled)))
            .unwrap_or_else(|_| Err("the emulator panicked".into()));
        match result {
            // Stopped, not stuck: this attempt doesn't count.
            Ok(None) => store.forget_attempt(&md5, subtune)?,
            Ok(Some(fp)) => {
                store.save(&md5, subtune, &fp)?;
                shared.done.fetch_add(1, Ordering::AcqRel);
                shared.revision.fetch_add(1, Ordering::AcqRel);
            }
            Err(e) => {
                store.mark_failed(&md5, subtune, &e)?;
                shared.failed.fetch_add(1, Ordering::AcqRel);
            }
        }
    }
    Ok(())
}

/// Keep the scan off the performance cores' backs while music plays.
fn lower_priority() {
    #[cfg(target_vendor = "apple")]
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_UTILITY, 0);
    }
}
