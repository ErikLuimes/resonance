//! The HVSC Home view's metadata.
//!
//! Everything is read straight from the collection tree (`DOCUMENTS/` and a
//! walk of the category folders) plus Phosphor's `published_playlists/`
//! index, so the view shows what's actually on disk. `collect` is called on
//! the tokio blocking pool and cached in `PlayerCore` by
//! (root, tree revision), which the sync bumps.
//!
//! HVSC's own text files are ISO-8859-1 with CRLF endings; `lines()` wants
//! UTF-8, so bytes are mapped through Latin-1 first (one byte, one code
//! point, always valid).

use std::path::Path;

use uniffi::Record;

/// The newest dated entry of `DOCUMENTS/Update_Announcements`, parsed.
///
/// (Keep these doc comments free of C-style comment delimiters: the
/// generator wraps them in a Swift block comment, and Swift block comments
/// nest, so one inside would swallow the file.)
#[derive(Debug, Clone, PartialEq, Record)]
pub struct HvscUpdate {
    /// Update #85.
    pub number: u32,
    /// "June 28, 2026".
    pub date: Option<String>,
    /// "84" (from `Previous Version`).
    pub previous_version: Option<String>,
    /// "587 new SIDs".
    pub new_sids: Option<u32>,
    /// "42 fixed/better rips".
    pub fixed_rips: Option<u32>,
    /// "312 SID credit fixes".
    pub credit_fixes: Option<u32>,
    /// Tunes re-filed: the announcement's `N tunes moved out of ...` lines,
    /// summed.
    pub moved: Option<u32>,
    /// The whole announcement, for the full-text sheet.
    pub text: String,
}

/// One group of C64 disk images sitting in the collection root.
#[derive(Debug, Clone, PartialEq, Record)]
pub struct HvscDisk {
    /// "HVSC Intro" (the image stems, their trailing `_NN` dropped).
    pub name: String,
    pub images: u32,
}

/// One of Phosphor's published playlists, from `published_playlists/index.json`.
#[derive(Debug, Clone, PartialEq, Record)]
pub struct HvscPlaylist {
    pub name: String,
    /// The m3u's file name in `published_playlists/`.
    pub file: String,
    pub description: Option<String>,
    pub tracks: u32,
}

/// The parsed collection, for the HVSC Home view.
#[derive(Debug, Clone, PartialEq, Record)]
pub struct HvscInfo {
    /// The collection root, as resolved.
    pub root: String,
    /// The release number as a digit string, "85" (from HVSC.txt).
    pub version: Option<String>,
    /// "June 28, 2026".
    pub release_date: Option<String>,
    /// The HVSC.txt introduction paragraph, for the About card.
    pub summary: Option<String>,
    /// Every tune in the tree (`.sid` files in the three categories).
    pub total_tunes: u32,
    pub musician_tunes: u32,
    pub game_tunes: u32,
    pub demo_tunes: u32,
    /// Author folders in MUSICIANS (two levels deep).
    pub composers: u32,
    /// STIL.txt entries (lines that are file paths).
    pub stil_entries: u32,
    /// Songlengths.md5 entries (md5 lines).
    pub songlength_entries: u32,
    /// Top-level guides, specs and FAQs in DOCUMENTS (`.txt` / `.faq`,
    /// the update archives and databases excluded).
    pub documents: u32,
    pub update: Option<HvscUpdate>,
    pub disks: Vec<HvscDisk>,
    pub playlists: Vec<HvscPlaylist>,
}

/// Collect the metadata for the collection at `root`, or `None` when the
/// folder holds no collection (no MUSICIANS / GAMES / DEMOS directory).
///
/// Blocking: this walks the tree. Run it off the async runtime.
pub fn collect(root: &Path) -> Option<HvscInfo> {
    let playlists = crate::config::config_dir().map(|d| d.join("published_playlists"));
    collect_with(root, playlists.as_deref())
}

/// The collect with an overridable playlist index location, for tests.
pub(crate) fn collect_with(root: &Path, playlist_dir: Option<&Path>) -> Option<HvscInfo> {
    let has_tree = ["MUSICIANS", "GAMES", "DEMOS"]
        .iter()
        .any(|name| root.join(name).is_dir());
    if !has_tree {
        return None;
    }

    let docs = root.join("DOCUMENTS");
    let (version, release_date, summary) = read_latin1(&docs.join("HVSC.txt"))
        .map(|t| parse_hvsc_txt(&t))
        .unwrap_or_default();

    Some(HvscInfo {
        root: root.to_string_lossy().into_owned(),
        version,
        release_date,
        summary,
        total_tunes: 0, // filled in below; the sums are the same walk
        musician_tunes: count_sids(&root.join("MUSICIANS")),
        game_tunes: count_sids(&root.join("GAMES")),
        demo_tunes: count_sids(&root.join("DEMOS")),
        composers: count_composers(root),
        stil_entries: read_latin1(&docs.join("STIL.txt"))
            .as_deref()
            .map(count_stil)
            .unwrap_or(0),
        songlength_entries: read_latin1(&docs.join("Songlengths.md5"))
            .as_deref()
            .map(count_songlengths)
            .unwrap_or(0),
        documents: count_documents(&docs),
        update: latest_update(&docs),
        disks: collect_disks(root),
        playlists: playlist_dir.and_then(|d| load_playlists(&d.join("index.json"))).unwrap_or_default(),
    })
    .map(|mut i| {
        i.total_tunes = i.musician_tunes + i.game_tunes + i.demo_tunes;
        i
    })
}

// ── Text files ───────────────────────────────────────────────────────────────

/// Map ISO-8859-1 bytes to their code points: the whole range is
/// U+0000–U+00FF, so one byte is always one valid `char`.
fn latin1(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len());
    for &b in bytes {
        out.push(char::from_u32(b as u32).expect("a Latin-1 byte is always a code point"));
    }
    out
}

fn read_latin1(path: &Path) -> Option<String> {
    std::fs::read(path).ok().map(|bytes| latin1(&bytes))
}

const MONTHS: [&str; 12] = [
    "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December",
];

/// HVSC.txt's title page: `Release N`, the date line under it, and the
/// first paragraph of `[1-2] The HVSC Project`.
fn parse_hvsc_txt(text: &str) -> (Option<String>, Option<String>, Option<String>) {
    let lines: Vec<&str> = text.lines().map(str::trim).collect();
    let mut version = None;
    let mut date = None;
    let mut summary = None;

    for (i, line) in lines.iter().enumerate() {
        if version.is_none() && line.starts_with("Release ") {
            let digits: String = line
                .strip_prefix("Release ")
                .unwrap_or("")
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect();
            if !digits.is_empty() {
                version = Some(digits);
            }
            continue;
        }
        if version.is_some()
            && date.is_none()
            && !line.is_empty()
            && MONTHS.iter().any(|m| line.contains(m))
        {
            date = Some(line.to_string());
            continue;
        }
        if summary.is_none() && line.starts_with("The HVSC Project is") {
            // The paragraph: this line plus the following non-empty ones,
            // stopped at the next blank line pair or a new paragraph.
            let mut para = vec![line.to_string()];
            for next in lines.iter().skip(i + 1).take(12) {
                if next.is_empty() {
                    break;
                }
                para.push(next.to_string());
            }
            summary = Some(para.join(" "));
            break;
        }
    }
    (version, date, summary)
}

/// The newest dated announcement: file names are `YYYYMMDD.txt`, so the
/// lexicographic maximum is the latest.
fn latest_update(docs: &Path) -> Option<HvscUpdate> {
    let dir = docs.join("Update_Announcements");
    let latest = std::fs::read_dir(&dir)
        .ok()?
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().ends_with(".txt"))
        .map(|e| e.path())
        .max()?; // PathBuf compares by components
    let text = read_latin1(&latest)?;
    parse_update(&text)
}

fn parse_update(text: &str) -> Option<HvscUpdate> {
    let mut number = None;
    let mut date = None;
    let mut previous = None;
    let mut new_sids = None;
    let mut fixed = None;
    let mut credits = None;
    let mut moved = 0u32;
    let mut any_moved = false;

    for line in text.lines() {
        let line = line.trim();
        if number.is_none() {
            // "High Voltage SID Collection: Update #85"
            if let Some(pos) = line.find("Update #") {
                let digits: String = line[pos + "Update #".len()..]
                    .trim_start()
                    .chars()
                    .take_while(|c| c.is_ascii_digit())
                    .collect();
                number = digits.parse().ok();
            }
        }
        if date.is_none() {
            if let Some(d) = line.strip_prefix("Date:") {
                let d = d.trim();
                if !d.is_empty() {
                    date = Some(d.to_string());
                }
            }
        }
        if previous.is_none() {
            if let Some(p) = line.strip_prefix("Previous Version:") {
                let p = p.trim();
                if !p.is_empty() {
                    previous = Some(p.to_string());
                }
            }
        }
        if new_sids.is_none() {
            new_sids = number_before(line, "new SIDs");
        }
        if fixed.is_none() {
            fixed = number_before(line, "fixed");
        }
        if credits.is_none() {
            credits = number_before(line, "credit fixes");
        }
        if let Some(n) = number_before(line, "tunes moved out of") {
            moved = moved.saturating_add(n);
            any_moved = true;
        }
    }

    let number = number?; // an announcement that has no number is not one
    Some(HvscUpdate {
        number,
        date,
        previous_version: previous,
        new_sids,
        fixed_rips: fixed,
        credit_fixes: credits,
        moved: any_moved.then_some(moved),
        text: text.to_string(),
    })
}

/// The number a `suffix` line reports: the last digit run before the
/// keyword ("312 SID credit fixes" → 312), which must stand alone — a run
/// glued to letters ("C64") is not a count.
fn number_before(line: &str, suffix: &str) -> Option<u32> {
    let pos = line.find(suffix)?;
    let before = &line[..pos];
    let mut run: Option<(usize, usize)> = None;
    let mut i = 0;
    while i < before.len() {
        let ch = before[i..].chars().next().unwrap();
        if ch.is_ascii_digit() {
            let start = i;
            while i < before.len() && before[i..].chars().next().unwrap().is_ascii_digit() {
                i += 1;
            }
            run = Some((start, i));
        } else {
            i += ch.len_utf8();
        }
    }
    let (start, end) = run?;
    if start > 0 && before[..start].chars().last().unwrap().is_alphanumeric() {
        return None;
    }
    before[start..end].parse().ok()
}

// ── The tree itself ──────────────────────────────────────────────────────────

/// Every `.sid` file under `dir`, recursively.
fn count_sids(dir: &Path) -> u32 {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    let mut n = 0u32;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            n = n.saturating_add(count_sids(&path));
        } else if path
            .extension()
            .is_some_and(|e| e.eq_ignore_ascii_case("sid"))
        {
            n = n.saturating_add(1);
        }
    }
    n
}

/// Author folders sit one level under the letter folders:
/// `MUSICIANS/H/Hubbard_Rob/`.
fn count_composers(root: &Path) -> u32 {
    let musicians = root.join("MUSICIANS");
    let Some(letters) = std::fs::read_dir(musicians).ok() else {
        return 0;
    };
    let mut n = 0u32;
    for letter in letters.flatten() {
        if !letter.path().is_dir() {
            continue;
        }
        if let Ok(authors) = std::fs::read_dir(letter.path()) {
            n = n.saturating_add(
                authors
                    .flatten()
                    .filter(|a| a.path().is_dir())
                    .count() as u32,
            );
        }
    }
    n
}

fn count_documents(docs: &Path) -> u32 {
    std::fs::read_dir(docs)
        .map(|entries| {
            entries
                .flatten()
                .filter(|e| {
                    e.path()
                        .extension()
                        .is_some_and(|x| x == "txt" || x == "faq")
                })
                .count() as u32
        })
        .unwrap_or(0)
}

/// STIL entries are the lines that are file paths.
fn count_stil(text: &str) -> u32 {
    text.lines().filter(|l| l.starts_with('/')).count() as u32
}

/// Songlengths.md5 is `[Database]`, then per tune a `; /path` comment line
/// and an `md5=time` line: the entries are the `=` lines.
fn count_songlengths(text: &str) -> u32 {
    text.lines()
        .filter(|l| l.contains('=') && !l.trim_start().starts_with(';'))
        .count() as u32
}

const DISK_EXTENSIONS: [&str; 4] = ["d64", "d71", "d81", "dfi"];

/// The C64 disk images in the collection root, grouped by their stem with
/// the trailing `_NN` dropped (the Intro disks 41–44 become one group).
fn collect_disks(root: &Path) -> Vec<HvscDisk> {
    let Some(entries) = std::fs::read_dir(root).ok() else {
        return Vec::new();
    };
    let mut files = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let is_image = path
            .extension()
            .is_some_and(|e| DISK_EXTENSIONS.iter().any(|x| e.eq_ignore_ascii_case(x)));
        if is_image {
            if let Some(stem) = path.file_stem() {
                files.push(stem.to_string_lossy().into_owned());
            }
        }
    }
    files.sort();

    let mut disks: Vec<HvscDisk> = Vec::new();
    for stem in files {
        let base = stem
            .rsplit_once('_')
            .filter(|(_, rest)| rest.bytes().all(|b| b.is_ascii_digit()))
            .map(|(front, _)| front)
            .unwrap_or(&stem);
        if let Some(last) = disks.last_mut() {
            if last.name == base.replace('_', " ") {
                last.images += 1;
                continue;
            }
        }
        disks.push(HvscDisk {
            name: base.replace('_', " "),
            images: 1,
        });
    }
    disks
}

// ── Playlists ────────────────────────────────────────────────────────────────

/// Phosphor's `published_playlists/index.json`: a `playlists` array of
/// `{ name, description, file, sha256, tracks }`.
fn load_playlists(index: &Path) -> Option<Vec<HvscPlaylist>> {
    let raw = std::fs::read_to_string(index).ok()?;
    let value: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let list = value.get("playlists")?.as_array()?;
    let mut out = Vec::new();
    for entry in list {
        let name = entry.get("name")?.as_str()?.to_string();
        let file = entry
            .get("file")
            .and_then(|f| f.as_str())
            .unwrap_or("")
            .to_string();
        let description = entry
            .get("description")
            .and_then(|d| d.as_str())
            .filter(|d| !d.is_empty())
            .map(str::to_string);
        let tracks = entry.get("tracks").and_then(|t| t.as_u64()).unwrap_or(0) as u32;
        out.push(HvscPlaylist { name, file, description, tracks });
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// A small fake tree with everything `collect` reads.
    fn test_tree(root: &Path) {
        for dir in [
            "MUSICIANS/A/Author_A",
            "MUSICIANS/B/Author_B",
            "GAMES/A",
            "DEMOS/0-9",
            "DOCUMENTS/Update_Announcements",
        ] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        for file in [
            "MUSICIANS/A/Author_A/one.sid",
            "MUSICIANS/A/Author_A/two.sid",
            "MUSICIANS/B/Author_B/three.sid",
            "GAMES/A/four.sid",
            "DEMOS/0-9/five.sid",
            "DEMOS/0-9/six.sid",
            "HVSC_Intro_41.d64",
            "HVSC_Intro_42.d64",
            "Ten_Years_1.d64",
            "Ten_Years.dfi",
        ] {
            std::fs::write(root.join(file), b"").unwrap();
        }
        std::fs::write(
            root.join("DOCUMENTS/HVSC.txt"),
            "Release 85\r\n\r\nJune 28, 2026\r\n\r\n[1-2] The HVSC Project\r\n\
             The HVSC Project is an attempt to accurately archive the most\r\n\
             popular C64 SIDs into one complete collection.  The project was\r\n\
             started in May 1996\r\n\r\nSome other paragraph.\r\n",
        )
        .unwrap();
        std::fs::write(
            root.join("DOCUMENTS/STIL.txt"),
            "/DEMOS/0-9/five.sid\n  TITLE: x\n\n/MUSICIANS/A/Author_A/one.sid\n ARTIST: A\n",
        )
        .unwrap();
        std::fs::write(
            root.join("DOCUMENTS/Songlengths.md5"),
            "[Database]\n; /DEMOS/0-9/five.sid\naa=1:17\n; /DEMOS/0-9/six.sid\nbb=0:56\n\
             ccc=1:00\n",
        )
        .unwrap();
        std::fs::write(
            root.join("DOCUMENTS/Update_Announcements/20260628.txt"),
            "High Voltage SID Collection: Update #85\nDate: June 28, 2026\n\n\
             Resulting Version: 85\n Previous Version: 84\n\n\
             This update features (all approximates):\n\
             \n     587 new SIDs\n      42 fixed/better rips\n     312 SID credit fixes\n\
             \n      12 tunes moved out of /DEMOS/ to their composers' directories\n\
             \n       8 tunes moved out of /GAMES/ to their composers' directories\n",
        )
        .unwrap();
    }

    fn temp_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "resonance-hvsc-info-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        root
    }

    #[test]
    fn parses_documents_and_counts() {
        let root = temp_root("docs");
        test_tree(&root);
        let info = collect_with(&root, None).expect("the tree has a collection");

        assert_eq!(info.version.as_deref(), Some("85"));
        assert_eq!(info.release_date.as_deref(), Some("June 28, 2026"));
        let summary = info.summary.as_deref().unwrap();
        assert!(summary.starts_with("The HVSC Project is an attempt"));
        assert!(summary.contains("started in May 1996"));

        assert_eq!((info.musician_tunes, info.game_tunes, info.demo_tunes), (3, 1, 2));
        assert_eq!(info.total_tunes, 6);
        assert_eq!(info.composers, 2);
        assert_eq!(info.stil_entries, 2);
        assert_eq!(info.songlength_entries, 3);

        let update = info.update.as_ref().expect("an announcement");
        assert_eq!(update.number, 85);
        assert_eq!(update.date.as_deref(), Some("June 28, 2026"));
        assert_eq!(update.previous_version.as_deref(), Some("84"));
        assert_eq!(update.new_sids, Some(587));
        assert_eq!(update.fixed_rips, Some(42));
        assert_eq!(update.credit_fixes, Some(312));
        assert_eq!(update.moved, Some(20));

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn groups_disks_by_stem() {
        let root = temp_root("disks");
        test_tree(&root);
        let info = collect_with(&root, None).unwrap();
        let names: Vec<(&str, u32)> = info
            .disks
            .iter()
            .map(|d| (d.name.as_str(), d.images))
            .collect();
        assert_eq!(names, vec![("HVSC Intro", 2), ("Ten Years", 2)]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn empty_folder_is_no_collection() {
        let root = temp_root("empty");
        std::fs::create_dir_all(&root).unwrap();
        assert!(collect_with(&root, None).is_none());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn reads_playlist_index() {
        let root = temp_root("playlists");
        test_tree(&root);
        let playlists = root.join("playlists");
        std::fs::create_dir_all(&playlists).unwrap();
        std::fs::write(
            playlists.join("index.json"),
            r#"{"playlists":[{"name":"Top 100","description":"","file":"top.m3u","sha256":"x","tracks":100},{"name":"Encore","description":"Encore!","file":"encore.m3u","sha256":"y","tracks":13}]}"#,
        )
        .unwrap();

        let info = collect_with(&root, Some(&playlists)).unwrap();
        assert_eq!(info.playlists.len(), 2);
        assert_eq!(info.playlists[0].name, "Top 100");
        assert_eq!(info.playlists[0].file, "top.m3u");
        assert_eq!(info.playlists[0].tracks, 100);
        assert!(info.playlists[0].description.is_none());
        assert_eq!(info.playlists[1].description.as_deref(), Some("Encore!"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn latin1_maps_high_bytes() {
        assert_eq!(latin1(&[0x68, 0x69, 0xE9, 0xA9]), "hi\u{e9}\u{a9}");
    }
}
