//! Play history: `recently_played.json` (the last 100 unique tunes, newest
//! first) and `heard.txt` (every tune ever played, by MD5, for its "SIDs
//! heard" count), in Resonance's folder (see `crate::config`). Phosphor
//! records both whenever a track starts (main.rs `play_track`); Resonance
//! does the same through upstream's own types, so the files stay in
//! Phosphor's format. Each record re-reads the files first.

use std::collections::HashSet;
use std::path::Path;

use serde::de::DeserializeOwned;

use crate::favorites::FavoritesDb;
use crate::heard_db::HeardDb;
use crate::playlist::PlaylistEntry;
use crate::recently_played::{RecentEntry, RecentlyPlayed};

/// Record that `entry` started playing. Tunes without an MD5 (unreadable
/// headers) aren't recorded, as in Phosphor.
pub(crate) fn record(entry: &PlaylistEntry) {
    let Some(md5) = entry.md5.as_deref() else {
        return;
    };
    let mut recent = RecentlyPlayed::load();
    recent.record(md5, &entry.title, &entry.author, &entry.released, &entry.path);
    recent.save();
    let mut heard = HeardDb::load();
    heard.record(md5);
    // Only writes when the MD5 was new.
    heard.save();
}

/// The recently played tunes, newest first.
pub(crate) fn recent() -> Vec<RecentEntry> {
    RecentlyPlayed::load().entries.into_iter().collect()
}

/// How many different tunes have ever been played.
pub(crate) fn heard_count() -> usize {
    HeardDb::load().heard.len()
}

/// Empty the recently played list.
pub(crate) fn clear_recent() {
    RecentlyPlayed::default().save();
}

/// Forget every tune ever heard. `HeardDb` only saves
/// when a tune was added, so the file is emptied directly.
pub(crate) fn reset_heard() {
    if let Some(path) = crate::config::config_dir().map(|d| d.join("heard.txt")) {
        if path.exists() {
            let _ = std::fs::write(path, "");
        }
    }
}

// ── Importing from Phosphor ──────────────────────────────────────────────────

/// What an import added.
#[derive(Debug, Default, PartialEq)]
pub(crate) struct Imported {
    pub favorites: usize,
    pub recent: usize,
    pub heard: usize,
}

/// Merge the favourites and play history in `dir` (Phosphor's folder)
/// into Resonance's. Nothing is removed: a tune in both keeps Resonance's
/// favourite, and its later play. `dir` is only read.
pub(crate) fn import_from(dir: &Path) -> Imported {
    Imported {
        favorites: import_favorites(dir),
        recent: import_recent(dir),
        heard: import_heard(dir),
    }
}

fn read_json<T: DeserializeOwned>(path: &Path) -> Option<T> {
    serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

fn import_favorites(dir: &Path) -> usize {
    let Some(theirs) = read_json::<FavoritesDb>(&dir.join("favorites.json")) else {
        return 0;
    };
    let mut ours = FavoritesDb::load();
    let before = ours.entries.len();
    for mut entry in theirs.entries {
        entry.md5 = entry.md5.to_lowercase();
        if ours.hashes.insert(entry.md5.clone()) {
            ours.entries.push(entry);
        }
    }
    let added = ours.entries.len() - before;
    if added > 0 {
        // Newest first, as upstream keeps them.
        ours.entries.sort_by(|a, b| b.added_at.cmp(&a.added_at));
        ours.save();
    }
    added
}

fn import_recent(dir: &Path) -> usize {
    let Some(theirs) = read_json::<RecentlyPlayed>(&dir.join("recently_played.json")) else {
        return 0;
    };
    let mut ours = RecentlyPlayed::load();
    let known: HashSet<String> = ours.entries.iter().map(|e| e.md5.clone()).collect();
    let mut entries: Vec<RecentEntry> = ours.entries.drain(..).collect();
    for entry in theirs.entries {
        match entries.iter_mut().find(|e| e.md5 == entry.md5) {
            Some(e) if entry.played_at > e.played_at => *e = entry,
            Some(_) => {}
            None => entries.push(entry),
        }
    }
    // Newest first, and only the last 100, as upstream keeps them.
    entries.sort_by(|a, b| b.played_at.cmp(&a.played_at));
    entries.truncate(100);
    let added = entries.iter().filter(|e| !known.contains(&e.md5)).count();
    ours.entries = entries.into();
    ours.save();
    added
}

fn import_heard(dir: &Path) -> usize {
    let Ok(text) = std::fs::read_to_string(dir.join("heard.txt")) else {
        return 0;
    };
    let mut ours = HeardDb::load();
    let added = text.lines().filter(|md5| ours.record(md5)).count();
    // Only writes when something was added.
    ours.save();
    added
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::with_test_data_dir;
    use crate::favorites::FavoriteEntry;
    use std::path::PathBuf;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("resonance-history-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn md5(n: u8) -> String {
        format!("{n:032x}")
    }

    fn favourite(n: u8, added_at: u64) -> FavoriteEntry {
        FavoriteEntry {
            md5: md5(n),
            title: format!("Tune {n}"),
            author: String::new(),
            released: String::new(),
            path: Some(PathBuf::from(format!("/hvsc/{n}.sid"))),
            added_at,
        }
    }

    fn recent(n: u8, played_at: u64) -> RecentEntry {
        RecentEntry {
            md5: md5(n),
            title: format!("Tune {n}"),
            author: String::new(),
            released: String::new(),
            path: PathBuf::from(format!("/hvsc/{n}.sid")),
            played_at,
        }
    }

    fn write_json<T: serde::Serialize>(path: PathBuf, value: &T) {
        std::fs::write(path, serde_json::to_string(value).unwrap()).unwrap();
    }

    #[test]
    fn merges_phosphors_favourites_and_history() {
        let phosphor = temp_dir("phosphor-merge");
        let resonance = temp_dir("resonance-merge");
        let mut theirs = FavoritesDb::default();
        theirs.entries = vec![favourite(1, 30), favourite(2, 10)];
        write_json(phosphor.join("favorites.json"), &theirs);
        let mut played = RecentlyPlayed::default();
        played.entries = vec![recent(1, 500), recent(3, 100)].into();
        write_json(phosphor.join("recently_played.json"), &played);
        std::fs::write(phosphor.join("heard.txt"), format!("{}\n{}", md5(1), md5(4))).unwrap();

        with_test_data_dir(&resonance, || {
            let mut ours = FavoritesDb::default();
            ours.entries = vec![favourite(2, 20)];
            ours.save();
            let mut played = RecentlyPlayed::default();
            played.entries = vec![recent(1, 200), recent(5, 300)].into();
            played.save();
            let mut heard = HeardDb::load();
            heard.record(&md5(1));
            heard.save();

            let imported = import_from(&phosphor);
            assert_eq!(imported, Imported { favorites: 1, recent: 1, heard: 1 });

            let favourites = FavoritesDb::load();
            let order: Vec<_> = favourites.entries.iter().map(|e| (e.md5.clone(), e.added_at)).collect();
            assert_eq!(order, vec![(md5(1), 30), (md5(2), 20)], "ours kept, newest first");

            let order: Vec<_> = RecentlyPlayed::load().entries.iter().map(|e| (e.md5.clone(), e.played_at)).collect();
            assert_eq!(order, vec![(md5(1), 500), (md5(5), 300), (md5(3), 100)], "the later play wins");

            assert_eq!(heard_count(), 2);

            assert_eq!(import_from(&phosphor), Imported::default(), "a second import adds nothing");
        });
        assert!(phosphor.join("favorites.json").exists(), "Phosphor's files are only read");
        let _ = std::fs::remove_dir_all(&phosphor);
        let _ = std::fs::remove_dir_all(&resonance);
    }

    #[test]
    fn nothing_to_import_without_phosphor() {
        let phosphor = temp_dir("phosphor-none");
        let resonance = temp_dir("resonance-none");
        with_test_data_dir(&resonance, || {
            assert_eq!(import_from(&phosphor.join("missing")), Imported::default());
        });
        let _ = std::fs::remove_dir_all(&phosphor);
        let _ = std::fs::remove_dir_all(&resonance);
    }
}
