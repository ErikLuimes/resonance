//! Play history, shared with Phosphor: `recently_played.json` (the last
//! 100 unique tunes, newest first) and `heard.txt` (every tune ever played,
//! by MD5, for its "SIDs heard" count), both in Phosphor's config folder.
//! Phosphor records both whenever a track starts (main.rs `play_track`);
//! Resonance does the same through upstream's own types, so the two apps
//! keep one history. Each record re-reads the files first, so plays from a
//! Phosphor running alongside aren't overwritten.

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
