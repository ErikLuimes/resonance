//! Read-only HVSC reference data shared by the session (song lengths) and
//! the library (song lengths, STIL, and the release number that keys the
//! search-index cache). Loaded once from Phosphor's data folder on the
//! loader thread, then published through a shared slot.

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use tokio::sync::watch;

use crate::config::{self, Config};
use crate::playlist::SonglengthDb;
use crate::stil::{self, StilDb};

#[derive(Default)]
pub(crate) struct Databases {
    pub songlengths: Option<SonglengthDb>,
    pub stil: Option<StilDb>,
    /// The same STIL.txt's entries as written, for the app's own parser.
    pub stil_text: Option<StilText>,
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
        let stil_file = config
            .last_stil_file
            .as_ref()
            .map(PathBuf::from)
            .filter(|p| p.exists())
            .or_else(|| stil::stil_db_path().filter(|p| p.exists()));
        let stil = stil_file
            .as_ref()
            .and_then(|p| log_err("STIL", p, StilDb::load(p)));
        let stil_text = stil_file
            .as_ref()
            .and_then(|p| log_err("STIL", p, StilText::load(p)));
        let hvsc_version = stil.as_ref().and_then(|s| s.hvsc_version).or_else(|| {
            config
                .hvsc_known_version
                .as_deref()
                .and_then(|v| v.trim().trim_start_matches(['v', 'V']).parse().ok())
        });
        Self {
            songlengths,
            stil,
            stil_text,
            hvsc_version,
        }
    }

    /// STIL's entry on a tune or folder (`path` on disk), as STIL.txt has
    /// it; see `StilText::excerpt`.
    pub fn stil_text(&self, path: &Path, hvsc_root: Option<&Path>) -> Option<String> {
        self.stil_text
            .as_ref()?
            .excerpt(&hvsc_path(path, hvsc_root)?)
    }
}

/// STIL.txt's entries as written, by lowercased HVSC path. `StilDb` joins
/// a field's lines and keeps no quotes or bylines apart; the app's parser
/// works those out from the text itself, line breaks included.
#[derive(Debug, Default)]
pub(crate) struct StilText {
    entries: HashMap<String, String>,
}

impl StilText {
    pub fn load(path: &Path) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
        Ok(Self::parse(&decode_stil(&bytes)))
    }

    /// A line starting with "/" opens an entry (a folder's ends in "/"); it
    /// runs to the next one, or to a "#" divider.
    fn parse(text: &str) -> Self {
        let mut entries = HashMap::new();
        let mut current: Option<(String, Vec<&str>)> = None;
        for line in text.lines() {
            if line.starts_with('/') || line.starts_with('#') {
                if let Some((key, lines)) = current.take() {
                    entries.insert(key, lines.join("\n").trim_end().to_string());
                }
                if line.starts_with('/') {
                    current = Some((line.trim().to_lowercase(), vec![line.trim_end()]));
                }
            } else if let Some((_, lines)) = current.as_mut() {
                lines.push(line.trim_end());
            }
        }
        if let Some((key, lines)) = current {
            entries.insert(key, lines.join("\n").trim_end().to_string());
        }
        Self { entries }
    }

    /// The entry on `hvsc_path` ("/MUSICIANS/H/Hubbard_Rob/Commando.sid",
    /// or a folder with or without its trailing "/"), after the entries of
    /// the folders it's in: those declare whose initials sign its comments.
    pub fn excerpt(&self, hvsc_path: &str) -> Option<String> {
        let mut key = hvsc_path.to_lowercase();
        if !self.entries.contains_key(&key) && !key.ends_with('/') {
            key.push('/');
        }
        let entry = self.entries.get(&key)?;
        let mut parts: Vec<&str> = key
            .match_indices('/')
            .map(|(i, _)| &key[..=i])
            .filter(|folder| folder.len() < key.len())
            .filter_map(|folder| self.entries.get(folder))
            .map(String::as_str)
            .collect();
        parts.push(entry);
        Some(parts.join("\n\n"))
    }
}

/// HVSC ships STIL.txt in Latin-1; some copies are re-encoded as UTF-8.
fn decode_stil(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(text) => text.to_string(),
        Err(_) => bytes.iter().map(|&b| char::from(b)).collect(),
    }
}

/// A tune's or folder's path as STIL names it: "/MUSICIANS/H/Hubbard_Rob/
/// Commando.sid". Outside the HVSC folder, counted from its MUSICIANS,
/// GAMES or DEMOS folder, as in another copy of HVSC.
fn hvsc_path(path: &Path, hvsc_root: Option<&Path>) -> Option<String> {
    let parts: Vec<String> = path
        .components()
        .filter_map(|c| match c {
            Component::Normal(part) => Some(part.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect();
    let inside = hvsc_root
        .and_then(|root| path.strip_prefix(root).ok())
        .map(|rel| parts.len() - rel.components().count())
        .or_else(|| {
            parts
                .iter()
                .rposition(|p| ["MUSICIANS", "GAMES", "DEMOS"].contains(&p.as_str()))
        })?;
    (inside < parts.len()).then(|| format!("/{}", parts[inside..].join("/")))
}

fn log_err<T>(what: &str, path: &Path, result: Result<T, String>) -> Option<T> {
    result
        .map_err(|e| eprintln!("[resonance] {what} at {}: {e}", path.display()))
        .ok()
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{hvsc_path, StilText};

    const STIL: &str = "### /MUSICIANS/ ###\r\n\
        \r\n\
        /MUSICIANS/H/Hubbard_Rob/\r\n\
        COMMENT: Hubbard's own comments are denoted (RH).\r\n\
        \r\n\
        /MUSICIANS/H/Hubbard_Rob/Commando.sid\r\n\
        COMMENT: \"There is an interesting story behind Commando. I\r\n\
        \x20        went down to their office...\" (RH)\r\n\
        (#1)\r\n\
        \x20 TITLE: BGM1 [from the arcade game Commando] (0:00)\r\n\
        \r\n\
        ### /MUSICIANS/J/ ###\r\n\
        /MUSICIANS/J/Jammer/Lyrics.sid\r\n\
        COMMENT: Last entry, no blank line after it.";

    #[test]
    fn excerpts_hold_the_entry_after_its_folders_entries() {
        let stil = StilText::parse(STIL);
        assert_eq!(
            stil.excerpt("/MUSICIANS/H/Hubbard_Rob/Commando.sid")
                .as_deref(),
            Some(
                "/MUSICIANS/H/Hubbard_Rob/\n\
                 COMMENT: Hubbard's own comments are denoted (RH).\n\
                 \n\
                 /MUSICIANS/H/Hubbard_Rob/Commando.sid\n\
                 COMMENT: \"There is an interesting story behind Commando. I\n\
                 \x20        went down to their office...\" (RH)\n\
                 (#1)\n\
                 \x20 TITLE: BGM1 [from the arcade game Commando] (0:00)"
            )
        );
        // A folder, as the library names it (no trailing slash).
        assert_eq!(
            stil.excerpt("/musicians/h/hubbard_rob").as_deref(),
            Some("/MUSICIANS/H/Hubbard_Rob/\nCOMMENT: Hubbard's own comments are denoted (RH).")
        );
        assert_eq!(
            stil.excerpt("/MUSICIANS/J/Jammer/Lyrics.sid").as_deref(),
            Some("/MUSICIANS/J/Jammer/Lyrics.sid\nCOMMENT: Last entry, no blank line after it.")
        );
        assert_eq!(stil.excerpt("/MUSICIANS/H/Hubbard_Rob/Delta.sid"), None);
    }

    #[test]
    fn latin1_stil_keeps_its_accents() {
        assert_eq!(
            super::decode_stil(b"Paco's (\xC1d\xE1m Papp)"),
            "Paco's (Ádám Papp)"
        );
        assert_eq!(super::decode_stil("Ádám".as_bytes()), "Ádám");
    }

    #[test]
    fn hvsc_paths_count_from_the_root_or_the_category_folder() {
        let root = Some(Path::new("/HVSC"));
        let tune = Path::new("/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid");
        assert_eq!(
            hvsc_path(tune, root).as_deref(),
            Some("/MUSICIANS/H/Hubbard_Rob/Commando.sid")
        );
        let elsewhere = Path::new("/Music/C64/GAMES/A-F/Catalypse.sid");
        assert_eq!(
            hvsc_path(elsewhere, root).as_deref(),
            Some("/GAMES/A-F/Catalypse.sid")
        );
        assert_eq!(hvsc_path(Path::new("/Music/Own.sid"), root), None);
        assert_eq!(hvsc_path(Path::new("/HVSC"), root), None);
    }
}
