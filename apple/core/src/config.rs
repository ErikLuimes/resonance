//! Upstream's `config` module, except for where the data goes.
//!
//! The engine sources find their folder (favourites, play history, the
//! search index, the curated playlists cache, the debug log) by calling
//! `crate::config::config_dir()`. This module is that path: it re-exports
//! everything in upstream's `src/config.rs` (compiled as
//! `crate::phosphor_config`) and shadows `config_dir` alone, so Resonance
//! can choose the folder without editing upstream.
//!
//! Calls inside upstream's `config.rs` itself still reach its own
//! `config_dir`: `Config::load` and `songlength_db_path` keep reading
//! Phosphor's folder, which is what Resonance wants from them.
//!
//! `PlayerCore::new` sets the folder to Resonance's own; until then it's
//! `~/Library/Application Support/Resonance`, never Phosphor's.

use std::path::PathBuf;
use std::sync::RwLock;

pub use crate::phosphor_config::*;

static DATA_DIR: RwLock<Option<PathBuf>> = RwLock::new(None);

#[cfg(test)]
thread_local! {
    /// A test's own folder, so tests running in parallel don't share one.
    static TEST_DATA_DIR: std::cell::RefCell<Option<PathBuf>> = const { std::cell::RefCell::new(None) };
}

/// The folder the engine sources keep their files in.
pub fn config_dir() -> Option<PathBuf> {
    #[cfg(test)]
    if let Some(dir) = TEST_DATA_DIR.with(|dir| dir.borrow().clone()) {
        return Some(dir);
    }
    DATA_DIR
        .read()
        .ok()
        .and_then(|dir| dir.clone())
        .or_else(|| {
            let home = std::env::var_os("HOME")?;
            Some(PathBuf::from(home).join("Library/Application Support/Resonance"))
        })
}

/// Phosphor's own folder, `~/Library/Application Support/phosphor`,
/// whatever `config_dir` is set to. Only Import from Phosphor reads it.
pub fn phosphor_dir() -> Option<PathBuf> {
    crate::phosphor_config::config_dir()
}

/// Upstream's HTTP clients take the proxy from Phosphor's config.json;
/// Resonance's use the system's.
pub fn apply_proxy(builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
    builder
}

/// Keep the engine's files in `dir` from now on.
pub(crate) fn set_data_dir(dir: PathBuf) {
    if let Ok(mut current) = DATA_DIR.write() {
        *current = Some(dir);
    }
}

/// Runs `body` with `config_dir` set to `dir` on this thread only.
#[cfg(test)]
pub(crate) fn with_test_data_dir<T>(dir: &std::path::Path, body: impl FnOnce() -> T) -> T {
    struct Reset;
    impl Drop for Reset {
        fn drop(&mut self) {
            TEST_DATA_DIR.with(|dir| *dir.borrow_mut() = None);
        }
    }
    TEST_DATA_DIR.with(|current| *current.borrow_mut() = Some(dir.to_path_buf()));
    let _reset = Reset;
    body()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::favorites::FavoritesDb;
    use crate::heard_db::HeardDb;
    use crate::playlist::PlaylistEntry;
    use crate::recently_played::RecentlyPlayed;

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "resonance-config-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn upstream_modules_write_to_the_chosen_folder() {
        let dir = temp_dir();
        with_test_data_dir(&dir, || {
            let entry = PlaylistEntry {
                path: PathBuf::from("/hvsc/Commando.sid"),
                title: "Commando".to_string(),
                author: "Rob Hubbard".to_string(),
                released: "1985".to_string(),
                songs: 1,
                selected_song: 1,
                is_pal: true,
                num_sids: 1,
                is_rsid: false,
                md5: Some("0123456789abcdef0123456789abcdef".to_string()),
                duration_secs: None,
                has_wds: false,
            };

            let mut favourites = FavoritesDb::load();
            favourites.toggle(&entry);
            favourites.save();

            let mut recent = RecentlyPlayed::load();
            recent.record("0123456789abcdef0123456789abcdef", "Commando", "Rob Hubbard", "1985", &entry.path);
            recent.save();

            let mut heard = HeardDb::load();
            heard.record("0123456789abcdef0123456789abcdef");
            heard.save();

            assert_eq!(crate::published_playlists::cache_dir(), Some(dir.join("published_playlists")));
            assert_eq!(crate::stil::stil_db_path(), Some(dir.join("STIL.txt")));
        });
        assert!(dir.join("favorites.json").exists());
        assert!(dir.join("recently_played.json").exists());
        assert!(dir.join("heard.txt").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn phosphor_files_stay_in_phosphors_folder() {
        let dir = temp_dir();
        with_test_data_dir(&dir, || {
            let phosphor = phosphor_dir().unwrap();
            assert!(phosphor.ends_with("Library/Application Support/phosphor"));
            assert_eq!(Config::config_path(), Some(phosphor.join("config.json")));
            assert_eq!(songlength_db_path(), Some(phosphor.join("Songlengths.md5")));
        });
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn defaults_to_resonances_folder() {
        // No test calls set_data_dir, so the process-wide folder is still
        // unset here.
        let dir = config_dir().unwrap();
        assert!(dir.ends_with("Library/Application Support/Resonance"));
        assert_ne!(Some(dir), phosphor_dir());
    }
}
