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

    /// What STIL says about one subtune of a tune, if anything.
    pub fn stil_notes(
        &self,
        path: &Path,
        hvsc_root: Option<&Path>,
        song: u16,
    ) -> Option<StilNotes> {
        let entry = self.stil.as_ref()?.lookup(path, hvsc_root)?;
        let notes = StilNotes {
            comment: reflowed(&entry.global_comment),
            blocks: entry
                .for_subtune(song)
                .into_iter()
                .map(|t| StilBlock {
                    subtune: t.subtune.into(),
                    name: reflowed(&t.name),
                    title: reflowed(&t.title),
                    artist: reflowed(&t.artist),
                    author: reflowed(&t.author),
                    comment: reflowed(&t.comment),
                })
                .filter(|b| {
                    [&b.name, &b.title, &b.artist, &b.author, &b.comment]
                        .iter()
                        .any(|f| f.is_some())
                })
                .collect(),
        };
        (notes.comment.is_some() || !notes.blocks.is_empty()).then_some(notes)
    }

    /// STIL's note on a whole folder, most often a composer's
    /// (`MUSICIANS/H/Hubbard_Rob`, relative to the HVSC root).
    pub fn folder_note(&self, folder: &Path) -> Option<String> {
        let rel = folder.to_string_lossy().replace('\\', "/");
        let key = format!("/{}/", rel.trim_matches('/'));
        let entry = self.stil.as_ref()?.lookup_by_hvsc_path(&key)?;
        reflowed(&entry.global_comment)
    }
}

/// STIL on one subtune: the file's comment, then the blocks that apply
/// (the whole tune's before the subtune's own), all text reflowed.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct StilNotes {
    pub comment: Option<String>,
    pub blocks: Vec<StilBlock>,
}

/// One STIL block: the piece a (sub)tune covers, and notes on it.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct StilBlock {
    /// 0 for the whole tune.
    pub subtune: u16,
    /// NAME: the subtune's own name, e.g. its part in a game.
    pub name: Option<String>,
    /// TITLE: the piece it covers.
    pub title: Option<String>,
    /// ARTIST: who performed that piece.
    pub artist: Option<String>,
    /// AUTHOR: who wrote that piece.
    pub author: Option<String>,
    pub comment: Option<String>,
}

/// A STIL field reflowed, or `None` when it's missing or blank.
fn reflowed(field: &Option<String>) -> Option<String> {
    field
        .as_deref()
        .map(reflow)
        .filter(|t| !t.trim().is_empty())
}

/// Text width of a STIL line: fields wrap at 80 columns, their values
/// indented to column 9.
const STIL_TEXT_WIDTH: usize = 71;

/// Undo STIL's hard wrapping, which leaves ragged lines in a narrow column.
/// The parser keeps every line break, so each one is judged on its own.
fn reflow(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut last: Option<&str> = None;
    for line in text.lines().map(str::trim_end) {
        match last {
            Some(prev) if is_wrap(prev, line) => {
                out.push(' ');
                out.push_str(line.trim_start());
            }
            Some(_) => {
                out.push('\n');
                out.push_str(line);
            }
            None => out.push_str(line),
        }
        last = Some(line);
    }
    out
}

/// Whether the break between `prev` and `next` is STIL's wrapping rather
/// than the writer's. A wrap when `next`'s first word wouldn't have fit;
/// otherwise when `prev` stops mid-sentence, as writers who wrapped short
/// of 80 columns leave it. Short unfinished lines are deliberate (lyrics,
/// lists), unless the next line is a path too long to have fit.
fn is_wrap(prev: &str, next: &str) -> bool {
    let Some(first_word) = next.split_whitespace().next() else {
        return false;
    };
    let prev_len = prev.chars().count();
    if prev_len + 1 + first_word.chars().count() > STIL_TEXT_WIDTH {
        return true;
    }
    let ends_sentence = prev.ends_with(['.', '!', '?', ':', '"', '\'', ')', ']']);
    !ends_sentence && (prev_len >= 40 || next.starts_with('/'))
}

fn log_err<T>(what: &str, path: &Path, result: Result<T, String>) -> Option<T> {
    result
        .map_err(|e| eprintln!("[resonance] {what} at {}: {e}", path.display()))
        .ok()
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{reflow, Databases, StilBlock, StilNotes};
    use crate::stil::StilDb;

    #[test]
    fn stil_notes_hold_the_file_comment_and_the_subtunes_blocks() {
        let file = std::env::temp_dir().join(format!("resonance-stil-{}.txt", std::process::id()));
        std::fs::write(
            &file,
            "/MUSICIANS/F/Fanta/Lightforce.sid\n\
             COMMENT: Remixed for a compo.\n\
             (#1)\n  \
             TITLE: Lightforce\n \
             ARTIST: Rob Hubbard\n\
             COMMENT: Based on /MUSICIANS/H/Hubbard_Rob/Lightforce.sid\n\
             (#2)\n\
             COMMENT: An original.\n",
        )
        .unwrap();
        let db = Databases {
            stil: Some(StilDb::load(&file).unwrap()),
            ..Databases::default()
        };
        std::fs::remove_file(&file).unwrap();
        let tune = Path::new("/HVSC/MUSICIANS/F/Fanta/Lightforce.sid");
        let root = Some(Path::new("/HVSC"));

        assert_eq!(
            db.stil_notes(tune, root, 1),
            Some(StilNotes {
                comment: Some("Remixed for a compo.".into()),
                blocks: vec![StilBlock {
                    subtune: 1,
                    title: Some("Lightforce".into()),
                    artist: Some("Rob Hubbard".into()),
                    comment: Some("Based on /MUSICIANS/H/Hubbard_Rob/Lightforce.sid".into()),
                    ..StilBlock::default()
                }],
            })
        );
        let second = db.stil_notes(tune, root, 2).unwrap();
        assert_eq!(second.blocks.len(), 1);
        assert_eq!(second.blocks[0].comment.as_deref(), Some("An original."));
        assert_eq!(
            db.stil_notes(Path::new("/HVSC/Elsewhere.sid"), root, 1),
            None
        );
    }

    #[test]
    fn reflow_joins_wrapped_lines_and_keeps_deliberate_breaks() {
        // STIL's note on /MUSICIANS/D/Daglish_Ben/, as the parser keeps it.
        let parsed = "Comments from Ben Daglish are denoted (BD)\n\
            Q: Is it Ben or Benn?\n\
            A: \"Ben is my real name....Benn was a nick from Compu-Net days - the\n\
            double letter was all the rage...Ratt, Bogg etc. etc.\" (BD)\n\
            Sadly, Ben Daglish passed away on October 1st, 2018, at the age of 52,\n\
            due to complications from lung cancer.";
        assert_eq!(
            reflow(parsed),
            "Comments from Ben Daglish are denoted (BD)\n\
             Q: Is it Ben or Benn?\n\
             A: \"Ben is my real name....Benn was a nick from Compu-Net days - the \
             double letter was all the rage...Ratt, Bogg etc. etc.\" (BD)\n\
             Sadly, Ben Daglish passed away on October 1st, 2018, at the age of 52, \
             due to complications from lung cancer."
        );
    }

    #[test]
    fn reflow_joins_lines_wrapped_short_of_80_columns() {
        let parsed = "I rushed to buy it at some electronic store on 45th\nstreet in Manhattan.";
        assert_eq!(
            reflow(parsed),
            "I rushed to buy it at some electronic store on 45th street in Manhattan."
        );
    }

    #[test]
    fn reflow_keeps_lyrics_apart() {
        let lyrics = "I came, I saw, I Comm-o-dored,\nIt's plain to see\nYou Comm-o-dored me";
        assert_eq!(reflow(lyrics), lyrics);
    }
}
