//! Shared tune links: finding a shared tune in this collection, and the
//! index the share server reads its preview cards from.
//!
//! A link names a tune by the MD5 HVSC's Songlengths.md5 keys it by, which
//! stays the same when a release moves the file. The receiver looks the MD5
//! up in its own Songlengths.md5; when that release doesn't list it (an
//! older collection, or the tune was re-ripped), the HVSC path the server
//! adds to the app's link is tried instead.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::databases::Databases;
use crate::player::sid_file;

/// How a shared tune was found in this collection.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SharedTuneMatch {
    /// The tune's file, when this collection has it.
    pub path: Option<String>,
    /// True when found by the MD5 (the same file the sender played);
    /// false when only its HVSC path matched.
    pub same_file: bool,
    /// This collection's HVSC release, if any collection is loaded.
    pub installed_hvsc: Option<u32>,
}

/// A tune that can be shared: one HVSC lists. Its MD5 is the link's key.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ShareableTune {
    pub md5: String,
    /// "/MUSICIANS/H/Hubbard_Rob/Commando.sid", when the file is in an
    /// HVSC tree.
    pub hvsc_path: Option<String>,
}

/// The file at `path` as a shareable tune, when this collection's
/// Songlengths.md5 lists its MD5: a file outside HVSC (or changed) would
/// make a link nobody else can play.
pub(crate) fn shareable(root: Option<&Path>, db: &Databases, path: &Path) -> Option<ShareableTune> {
    let bytes = std::fs::read(path).ok()?;
    let md5 = sid_file::compute_hvsc_md5(&sid_file::load_sid(&bytes).ok()?);
    db.songlengths.as_ref()?.entries.contains_key(&md5).then(|| ShareableTune {
        md5,
        hvsc_path: crate::databases::hvsc_path(path, root),
    })
}

/// Find the tune `key` names under `root`, else the file at `hvsc_path`
/// ("/MUSICIANS/H/Hubbard_Rob/Commando.sid"). `key` is its MD5 or its
/// 12-character share code (`short_code`), as web links carry it.
pub(crate) fn find(
    root: Option<&Path>,
    db: &Databases,
    key: &str,
    hvsc_path: Option<&str>,
) -> SharedTuneMatch {
    let installed_hvsc = db.hvsc_version;
    let none = SharedTuneMatch { path: None, same_file: false, installed_hvsc };
    let Some(root) = root else { return none };
    let key = key.trim();
    let md5 = if key.len() == CODE_LEN {
        // One full scan of Songlengths (~60,000 keys, a millisecond); a code
        // two tunes share names neither.
        let mut matches = db
            .songlengths
            .iter()
            .flat_map(|s| s.md5_to_path.keys())
            .filter(|md5| short_code(md5).as_deref() == Some(key));
        match (matches.next(), matches.next()) {
            (Some(md5), None) => md5.clone(),
            _ => String::new(),
        }
    } else {
        key.to_ascii_lowercase()
    };
    let by_md5 = db
        .songlengths
        .as_ref()
        .and_then(|s| s.md5_to_path.get(&md5))
        .and_then(|rel| resolve_case(root, rel));
    if let Some(path) = by_md5 {
        return SharedTuneMatch { path: Some(path_string(&path)), same_file: true, installed_hvsc };
    }
    let Some(file) = hvsc_path.and_then(|p| resolve_case(root, p)) else { return none };
    // The file at that path may still be the very same tune: Songlengths
    // can lag the tree, or be missing altogether.
    let same_file = std::fs::read(&file)
        .ok()
        .and_then(|bytes| sid_file::load_sid(&bytes).ok())
        .is_some_and(|sid| sid_file::compute_hvsc_md5(&sid) == md5);
    SharedTuneMatch { path: Some(path_string(&file)), same_file, installed_hvsc }
}

const CODE_LEN: usize = 12;

/// A tune's share code: the first 72 bits of its MD5 in base64url, 12
/// characters, as share links carry it. The share server (`tune.rs`) and
/// the app (`SharedTuneLink.shortCode`) make the same.
pub(crate) fn short_code(md5: &str) -> Option<String> {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    if md5.len() != 32 {
        return None;
    }
    let bytes: Vec<u8> = (0..9).map(|i| u8::from_str_radix(md5.get(i * 2..i * 2 + 2)?, 16).ok()).collect::<Option<_>>()?;
    let mut code = String::with_capacity(CODE_LEN);
    for chunk in bytes.chunks(3) {
        let n = u32::from(chunk[0]) << 16 | u32::from(chunk[1]) << 8 | u32::from(chunk[2]);
        for shift in [18, 12, 6, 0] {
            code.push(ALPHABET[(n >> shift & 63) as usize] as char);
        }
    }
    Some(code)
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// `rel` (an HVSC path, any case, with or without its leading slash) under
/// `root`, spelled as on disk. Songlengths.md5's paths are lowercased by
/// the parser; the library and its reveal compare paths as written.
pub(crate) fn resolve_case(root: &Path, rel: &str) -> Option<PathBuf> {
    let mut path = root.to_path_buf();
    for part in rel.split('/').filter(|p| !p.is_empty()) {
        if part == "." || part == ".." {
            return None;
        }
        let exact = path.join(part);
        if exact.exists() && name_matches(&exact, part) {
            path = exact;
            continue;
        }
        let found = std::fs::read_dir(&path)
            .ok()?
            .filter_map(Result::ok)
            .find(|e| e.file_name().to_string_lossy().eq_ignore_ascii_case(part))?;
        path = path.join(found.file_name());
    }
    path.is_file().then_some(path)
}

/// On a case-insensitive volume `exists` says yes to any spelling; only
/// take the name as given when the folder lists it so.
fn name_matches(path: &Path, part: &str) -> bool {
    let Some(parent) = path.parent() else { return true };
    std::fs::read_dir(parent)
        .map(|entries| entries.filter_map(Result::ok).any(|e| e.file_name().to_string_lossy() == part))
        .unwrap_or(false)
}

// MARK: The share server's index

/// One tune's preview: what the card shows. Short keys: the index holds
/// every tune in HVSC.
#[derive(Debug, Serialize, PartialEq)]
pub struct ShareIndexTune {
    /// HVSC path, "/MUSICIANS/H/Hubbard_Rob/Commando.sid".
    pub p: String,
    /// Title, author and released, from the SID header.
    pub t: String,
    pub a: String,
    pub r: String,
    /// Subtunes and the start song.
    pub n: u16,
    pub s: u16,
    /// Each subtune's length in seconds, from Songlengths.md5.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub l: Vec<u32>,
    /// SID chip model, as in the header: 0 unknown, 1 6581, 2 8580, 3 both.
    pub m: u8,
    /// The nine sound traits per scanned subtune, as percentages, in the
    /// app's order (notes, arpeggios, vibrato, filter, ring, sync, digi,
    /// noise, pulse width).
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub f: BTreeMap<u16, [u8; 9]>,
    /// The waveform mix per scanned subtune, as percentages: triangle,
    /// saw, pulse, noise. With the traits it makes the fingerprint sphere.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub w: BTreeMap<u16, [u8; 4]>,
}

#[derive(Debug, Serialize)]
pub struct ShareIndex {
    /// The HVSC release the index was built from.
    pub hvsc: Option<u32>,
    pub tunes: BTreeMap<String, ShareIndexTune>,
}

/// Build the share server's index from a collection: every tune
/// Songlengths.md5 lists, with its header fields, lengths, and the traits
/// in `fingerprints` (a fingerprint store file, such as the published set),
/// when given. Tunes Songlengths doesn't list aren't shareable anyway.
pub fn build_share_index(root: &Path, fingerprints: Option<&Path>) -> Result<ShareIndex, String> {
    let db = Databases::load_with_tree(Some(root));
    let lengths = db
        .songlengths
        .as_ref()
        .ok_or_else(|| format!("No DOCUMENTS/Songlengths.md5 in {}", root.display()))?;
    let traits = match fingerprints {
        Some(path) => crate::fingerprint::traits_by_md5(path)?,
        None => Default::default(),
    };
    let mut tunes = BTreeMap::new();
    for (md5, rel) in &lengths.md5_to_path {
        let Some(file) = resolve_case(root, rel) else { continue };
        let Ok(bytes) = std::fs::read(&file) else { continue };
        let Ok(header) = sid_file::parse_header(&bytes) else { continue };
        let Some(path) = crate::databases::hvsc_path(&file, Some(root)) else { continue };
        let looks = traits.get(md5);
        tunes.insert(
            md5.clone(),
            ShareIndexTune {
                p: path,
                t: header.name,
                a: header.author,
                r: header.released,
                n: header.songs,
                s: header.start_song,
                l: lengths.entries.get(md5).cloned().unwrap_or_default(),
                m: header.sid_model,
                f: looks.map(|l| l.iter().map(|(&s, (t, _))| (s, *t)).collect()).unwrap_or_default(),
                w: looks.map(|l| l.iter().map(|(&s, (_, m))| (s, *m)).collect()).unwrap_or_default(),
            },
        );
    }
    Ok(ShareIndex { hvsc: db.hvsc_version, tunes })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::playlist::SonglengthDb;

    /// A PSID v2 file: the header fields `parse_header` reads, no code.
    fn psid(name: &str, author: &str, released: &str) -> Vec<u8> {
        let mut buf = vec![0u8; 0x7C + 2];
        buf[0..4].copy_from_slice(b"PSID");
        buf[5] = 2;
        buf[7] = 0x7C;
        buf[0x0F] = 3; // songs
        buf[0x11] = 2; // start song
        for (at, text) in [(0x16, name), (0x36, author), (0x56, released)] {
            buf[at..at + text.len()].copy_from_slice(text.as_bytes());
        }
        buf
    }

    fn tree() -> (tempdir::Dir, String) {
        let dir = tempdir::Dir::new();
        let folder = dir.0.join("MUSICIANS/H/Hubbard_Rob");
        std::fs::create_dir_all(&folder).unwrap();
        let bytes = psid("Commando", "Rob Hubbard", "1985 Elite");
        std::fs::write(folder.join("Commando.sid"), &bytes).unwrap();
        let md5 = sid_file::compute_hvsc_md5(&sid_file::load_sid(&bytes).unwrap());
        (dir, md5)
    }

    fn databases(md5: &str, rel: &str) -> Databases {
        let mut lengths = SonglengthDb::new();
        lengths.md5_to_path.insert(md5.to_string(), rel.to_string());
        lengths.entries.insert(md5.to_string(), vec![312, 20, 5]);
        Databases { songlengths: Some(lengths), hvsc_version: Some(84), ..Default::default() }
    }

    #[test]
    fn finds_by_md5_with_the_case_on_disk() {
        let (dir, md5) = tree();
        let db = databases(&md5, "musicians/h/hubbard_rob/commando.sid");
        let found = find(Some(&dir.0), &db, &md5.to_uppercase(), None);
        assert_eq!(
            found.path.as_deref(),
            Some(dir.0.join("MUSICIANS/H/Hubbard_Rob/Commando.sid").to_str().unwrap())
        );
        assert!(found.same_file);
        assert_eq!(found.installed_hvsc, Some(84));
    }

    #[test]
    fn share_codes_match_the_servers_and_find_the_tune() {
        // The same examples as the share server's and the app's tests.
        assert_eq!(short_code("6d019ecba831a9f853675aac29a61c10").as_deref(), Some("bQGey6gxqfhT"));
        assert_eq!(short_code("ffffffffffffffffffffffffffffffff").as_deref(), Some("____________"));
        assert_eq!(short_code("nope"), None);
        let (dir, md5) = tree();
        let db = databases(&md5, "musicians/h/hubbard_rob/commando.sid");
        let code = short_code(&md5).unwrap();
        assert!(find(Some(&dir.0), &db, &code, None).same_file);
        assert_eq!(find(Some(&dir.0), &db, "AAAAAAAAAAAA", None).path, None);
    }

    #[test]
    fn falls_back_to_the_path_and_checks_the_file() {
        let (dir, md5) = tree();
        // This release's Songlengths doesn't list it.
        let db = databases("0000", "musicians/x/other.sid");
        let path = Some("/MUSICIANS/H/Hubbard_Rob/Commando.sid");
        let same = find(Some(&dir.0), &db, &md5, path);
        assert!(same.path.is_some());
        assert!(same.same_file, "the file there is the shared one");
        let other = find(Some(&dir.0), &db, "ffff", path);
        assert!(other.path.is_some());
        assert!(!other.same_file, "a re-rip at the same path");
        assert_eq!(find(Some(&dir.0), &db, "ffff", Some("/MUSICIANS/H/Hubbard_Rob/Delta.sid")).path, None);
        assert_eq!(find(None, &db, &md5, path).path, None);
    }

    #[test]
    fn only_tunes_hvsc_lists_are_shareable() {
        let (dir, md5) = tree();
        let file = dir.0.join("MUSICIANS/H/Hubbard_Rob/Commando.sid");
        let db = databases(&md5, "musicians/h/hubbard_rob/commando.sid");
        assert_eq!(
            shareable(Some(&dir.0), &db, &file),
            Some(ShareableTune { md5: md5.clone(), hvsc_path: Some("/MUSICIANS/H/Hubbard_Rob/Commando.sid".into()) })
        );
        assert_eq!(shareable(Some(&dir.0), &databases("0000", "x.sid"), &file), None);
        assert_eq!(shareable(Some(&dir.0), &db, &dir.0.join("missing.sid")), None);
    }

    #[test]
    fn paths_stay_inside_the_collection() {
        let (dir, _) = tree();
        assert_eq!(resolve_case(&dir.0, "/MUSICIANS/../MUSICIANS/H/Hubbard_Rob/Commando.sid"), None);
        assert_eq!(resolve_case(&dir.0, "/MUSICIANS/H/Hubbard_Rob"), None, "folders aren't tunes");
    }

    #[test]
    fn index_holds_header_lengths_and_path() {
        let (dir, md5) = tree();
        let documents = dir.0.join("DOCUMENTS");
        std::fs::create_dir_all(&documents).unwrap();
        std::fs::write(
            documents.join("Songlengths.md5"),
            format!("[Database]\n; /MUSICIANS/H/Hubbard_Rob/Commando.sid\n{md5}=5:12 0:20 0:05\n"),
        )
        .unwrap();
        let index = build_share_index(&dir.0, None).unwrap();
        let tune = &index.tunes[&md5];
        assert_eq!(tune.p, "/MUSICIANS/H/Hubbard_Rob/Commando.sid");
        assert_eq!((tune.t.as_str(), tune.a.as_str(), tune.r.as_str()), ("Commando", "Rob Hubbard", "1985 Elite"));
        assert_eq!((tune.n, tune.s), (3, 2));
        // As the player times them: upstream rounds each length up a second.
        assert_eq!(tune.l, vec![313, 21, 6]);
        let json = serde_json::to_string(&index).unwrap();
        assert!(!json.contains("\"f\""), "no traits without fingerprints: {json}");
    }

    /// A folder in the temp dir, removed afterward.
    mod tempdir {
        use std::path::PathBuf;
        use std::sync::atomic::{AtomicU32, Ordering};

        pub struct Dir(pub PathBuf);

        impl Dir {
            pub fn new() -> Self {
                static N: AtomicU32 = AtomicU32::new(0);
                let path = std::env::temp_dir().join(format!(
                    "resonance-share-{}-{}",
                    std::process::id(),
                    N.fetch_add(1, Ordering::Relaxed)
                ));
                let _ = std::fs::remove_dir_all(&path);
                std::fs::create_dir_all(&path).unwrap();
                Self(path)
            }
        }

        impl Drop for Dir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }
}
