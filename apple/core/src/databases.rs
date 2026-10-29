//! Read-only HVSC reference data shared by the session (song lengths) and
//! the library (song lengths, STIL, and the release number that keys the
//! search-index cache). Loaded once from Phosphor's data folder on the
//! loader thread, then published through a shared slot.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::sync::watch;

use crate::config::{self, Config};
use crate::playlist::SonglengthDb;
use crate::stil::{self, StilDb};

#[derive(Default)]
pub(crate) struct Databases {
    pub songlengths: Option<SonglengthDb>,
    pub stil: Option<StilDb>,
    /// HVSC release, e.g. 85. Part of the index-cache key, derived the same
    /// way as Phosphor's (main.rs:4476-4485) so both apps share one cache.
    pub hvsc_version: Option<u32>,
}

/// `None` until the loader installs the databases (about a second after
/// launch). A watch channel, so the library can wait for them.
pub(crate) type SharedDatabases = Arc<watch::Sender<Option<Arc<Databases>>>>;

pub(crate) fn shared() -> SharedDatabases {
    Arc::new(watch::channel(None).0)
}

pub(crate) fn install(shared: &SharedDatabases, databases: Databases) {
    shared.send_replace(Some(Arc::new(databases)));
}

/// What's loaded so far: empty databases before the loader finishes.
pub(crate) fn current(shared: &SharedDatabases) -> Arc<Databases> {
    shared.borrow().clone().unwrap_or_default()
}

/// The databases once loaded. Index builds and tune listings wait for this:
/// an index built without them would lack song lengths and STIL flags, and
/// would be saved like that to the cache shared with Phosphor.
pub(crate) async fn loaded(shared: &SharedDatabases) -> Arc<Databases> {
    let mut rx = shared.subscribe();
    let db = match rx.wait_for(Option::is_some).await {
        Ok(db) => db.clone().unwrap_or_default(),
        // The sender lives as long as the PlayerCore; this is shutdown.
        Err(_) => Arc::default(),
    };
    db
}

impl Databases {
    /// Load what Phosphor has on disk, without writing anything back.
    ///
    /// Song lengths only come from `<config_dir>/Songlengths.md5`, like
    /// Phosphor's boot (main.rs:548-558). STIL comes from the remembered
    /// file, else `<config_dir>/STIL.txt` (main.rs:569-584).
    pub fn load(config: &Config) -> Self {
        let songlengths = config::songlength_db_path()
            .filter(|p| p.exists())
            .and_then(|p| log_err("Songlengths", &p, SonglengthDb::load(&p)));
        let stil = config
            .last_stil_file
            .as_ref()
            .map(PathBuf::from)
            .filter(|p| p.exists())
            .or_else(|| stil::stil_db_path().filter(|p| p.exists()))
            .and_then(|p| log_err("STIL", &p, StilDb::load(&p)));
        let hvsc_version = stil.as_ref().and_then(|s| s.hvsc_version).or_else(|| {
            config
                .hvsc_known_version
                .as_deref()
                .and_then(|v| v.trim().trim_start_matches(['v', 'V']).parse().ok())
        });
        Self {
            songlengths,
            stil,
            hvsc_version,
        }
    }

    /// The STIL text for one subtune of a tune, if STIL has anything on it.
    pub fn stil_text(&self, path: &Path, hvsc_root: Option<&Path>, song: u16) -> Option<String> {
        let entry = self.stil.as_ref()?.lookup(path, hvsc_root)?;
        let text = entry.format_for_display(song);
        (!text.trim().is_empty()).then_some(text)
    }
}

fn log_err<T>(what: &str, path: &Path, result: Result<T, String>) -> Option<T> {
    result
        .map_err(|e| eprintln!("[resonance] {what} at {}: {e}", path.display()))
        .ok()
}
