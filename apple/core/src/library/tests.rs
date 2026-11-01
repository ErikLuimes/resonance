use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;
use crate::databases::{self, Databases};

// ── A miniature HVSC tree ────────────────────────────────────────────────────

/// A fresh, empty HVSC root in the temp dir; removed on drop.
struct Tree(PathBuf);

impl Tree {
    fn new() -> Self {
        static N: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "resonance-hvsc-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn root(&self) -> PathBuf {
        self.0.clone()
    }

    /// Write a minimal PSID v2 file at `rel` (relative to the root).
    fn sid(&self, rel: &str, title: &str, author: &str, released: &str, songs: u16) -> PathBuf {
        let path = self.0.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut h = vec![0u8; 0x7C];
        h[0..4].copy_from_slice(b"PSID");
        h[4..6].copy_from_slice(&2u16.to_be_bytes()); // version
        h[6..8].copy_from_slice(&0x7Cu16.to_be_bytes()); // data offset
        h[8..10].copy_from_slice(&0x1000u16.to_be_bytes()); // load
        h[10..12].copy_from_slice(&0x1000u16.to_be_bytes()); // init
        h[12..14].copy_from_slice(&0x1003u16.to_be_bytes()); // play
        h[14..16].copy_from_slice(&songs.to_be_bytes());
        h[16..18].copy_from_slice(&1u16.to_be_bytes()); // start song
        for (offset, text) in [(0x16, title), (0x36, author), (0x56, released)] {
            h[offset..offset + text.len()].copy_from_slice(text.as_bytes());
        }
        h.extend_from_slice(&[0x60, 0x60, 0x60, 0x60]); // RTS…
        std::fs::write(&path, h).unwrap();
        path
    }

    /// Two MUSICIANS authors and a GAMES section.
    fn sample() -> Self {
        let t = Self::new();
        t.sid(
            "MUSICIANS/H/Hubbard_Rob/Commando.sid",
            "Commando",
            "Rob Hubbard",
            "1985 Elite",
            3,
        );
        t.sid(
            "MUSICIANS/H/Hubbard_Rob/Monty_on_the_Run.sid",
            "Monty on the Run",
            "Rob Hubbard",
            "1985 Gremlin",
            1,
        );
        t.sid(
            "MUSICIANS/G/Galway_Martin/Wizball.sid",
            "Wizball",
            "Martin Galway",
            "1987 Ocean",
            2,
        );
        t.sid(
            "GAMES/A-F/Bubble_Bobble.sid",
            "Bubble Bobble",
            "Peter Clarke",
            "1987 Firebird",
            1,
        );
        t
    }
}

impl Drop for Tree {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn library(root: Option<PathBuf>) -> Library {
    let shared = databases::shared();
    databases::install(&shared, Databases::default());
    Library::new(root, shared).without_index_cache()
}

fn names(hits: &[(HvscCategory, HvscIndexEntry)]) -> Vec<&str> {
    hits.iter().map(|(_, e)| e.title.as_str()).collect()
}

// ── Browsing ─────────────────────────────────────────────────────────────────

#[tokio::test]
async fn lists_authors_in_folder_order_with_display_names() {
    let tree = Tree::sample();
    let lib = library(Some(tree.root()));

    let authors = lib.authors(HvscCategory::Musicians).await.unwrap();
    let shown: Vec<_> = authors
        .iter()
        .map(|a| (a.letter, a.display_name.as_str()))
        .collect();
    assert_eq!(shown, [('G', "Galway, Martin"), ('H', "Hubbard, Rob")]);

    let sections = lib.authors(HvscCategory::Games).await.unwrap();
    assert_eq!(sections.len(), 1);
    assert_eq!(sections[0].raw_name, "A-F");
}

#[tokio::test]
async fn lists_an_authors_tunes_with_their_headers() {
    let tree = Tree::sample();
    let lib = library(Some(tree.root()));
    let hubbard = tree.root().join("MUSICIANS/H/Hubbard_Rob");

    let tunes = lib.tunes(hubbard).await.unwrap();
    let rows: Vec<_> = tunes
        .iter()
        .map(|t| {
            (
                t.entry.title.as_str(),
                t.entry.author.as_str(),
                t.entry.songs,
            )
        })
        .collect();
    assert_eq!(
        rows,
        [
            ("Commando", "Rob Hubbard", 3),
            ("Monty on the Run", "Rob Hubbard", 1)
        ]
    );
}

#[tokio::test]
async fn author_notes_come_from_stil_folder_entries() {
    let tree = Tree::sample();
    let stil = tree.root().join("STIL.txt");
    std::fs::write(
        &stil,
        "/MUSICIANS/H/Hubbard_Rob/\n\
         COMMENT: People have often stolen Hubbard's routine causing some tunes to be\n         \
         falsely credited to him.\n\
         \n\
         /MUSICIANS/H/Hubbard_Rob/Commando.sid\n\
         COMMENT: Not about the composer.\n",
    )
    .unwrap();
    let shared = databases::shared();
    databases::install(
        &shared,
        Databases {
            stil: Some(crate::stil::StilDb::load(&stil).unwrap()),
            ..Databases::default()
        },
    );
    let lib = Library::new(Some(tree.root()), shared).without_index_cache();

    let hubbard = tree.root().join("MUSICIANS/H/Hubbard_Rob");
    assert_eq!(
        lib.author_note(hubbard).await.unwrap().as_deref(),
        Some("People have often stolen Hubbard's routine causing some tunes to be falsely credited to him.")
    );
    let galway = tree.root().join("MUSICIANS/G/Galway_Martin");
    assert_eq!(lib.author_note(galway).await.unwrap(), None);
}

#[tokio::test]
async fn tunes_outside_the_collection_are_rejected() {
    let tree = Tree::sample();
    let lib = library(Some(tree.root()));
    let err = lib
        .tunes(PathBuf::from("/tmp/elsewhere"))
        .await
        .unwrap_err();
    assert!(matches!(err, LibraryError::NotFound(_)), "{err:?}");
}

#[tokio::test]
async fn without_a_root_everything_reports_no_root() {
    let lib = library(None);
    assert_eq!(
        lib.authors(HvscCategory::Musicians).await.unwrap_err(),
        LibraryError::NoRoot
    );
    assert!(matches!(
        lib.search("x".into(), None).await,
        Err(LibraryError::NoRoot)
    ));
    assert!(matches!(
        lib.surprise(None).await,
        Err(LibraryError::NoRoot)
    ));
}

#[tokio::test]
async fn a_missing_category_folder_is_an_error() {
    let tree = Tree::sample(); // no DEMOS/
    let lib = library(Some(tree.root()));
    let err = lib.authors(HvscCategory::Demos).await.unwrap_err();
    assert!(matches!(err, LibraryError::NotFound(_)), "{err:?}");
}

#[tokio::test]
async fn changing_the_root_replaces_everything() {
    let a = Tree::sample();
    let b = Tree::new();
    b.sid(
        "MUSICIANS/T/Tel_Jeroen/Cybernoid.sid",
        "Cybernoid",
        "Jeroen Tel",
        "1988 Hewson",
        1,
    );
    let lib = library(Some(a.root()));
    lib.search("commando".into(), None).await.unwrap();

    lib.set_root(Some(b.root()));
    let authors = lib.authors(HvscCategory::Musicians).await.unwrap();
    assert_eq!(authors.len(), 1);
    assert_eq!(authors[0].display_name, "Tel, Jeroen");
    let found = lib.search("commando".into(), None).await.unwrap();
    assert!(found.hits.is_empty(), "old root's index is gone");
}

// ── Search ───────────────────────────────────────────────────────────────────

#[tokio::test]
async fn search_ranks_across_categories() {
    let tree = Tree::sample();
    let lib = library(Some(tree.root()));

    let all = lib.search("bubble".into(), None).await.unwrap();
    assert_eq!(names(&all.hits), ["Bubble Bobble"]);
    assert_eq!(all.hits[0].0, HvscCategory::Games);
    assert_eq!(all.indexed, 4);

    let musicians_only = lib
        .search("bubble".into(), Some(HvscCategory::Musicians))
        .await
        .unwrap();
    assert!(musicians_only.hits.is_empty());
    assert_eq!(musicians_only.indexed, 3);
}

#[tokio::test]
async fn search_matches_authors_folders_and_typos() {
    let tree = Tree::sample();
    let lib = library(Some(tree.root()));

    // By author folder: both Hubbard tunes, alphabetical on equal scores.
    let hubbard = lib.search("hubbard".into(), None).await.unwrap();
    assert_eq!(names(&hubbard.hits), ["Commando", "Monty on the Run"]);
    assert_eq!(hubbard.total_matches, 2);

    // Fuzzy: a dropped letter still finds the tune.
    let typo = lib.search("comando".into(), None).await.unwrap();
    assert_eq!(names(&typo.hits).first(), Some(&"Commando"));
}

#[tokio::test]
async fn exact_titles_rank_first_among_equal_scores() {
    let tree = Tree::sample();
    tree.sid(
        "MUSICIANS/F/Follin_Tim/Bionic_Commando.sid",
        "Bionic Commando",
        "Tim Follin",
        "1988 Go!",
        1,
    );
    tree.sid(
        "MUSICIANS/C/Cooksey_Mark/Commando_86.sid",
        "Commando 86",
        "Mark Cooksey",
        "1986",
        1,
    );
    let lib = library(Some(tree.root()));
    let r = lib.search("commando".into(), None).await.unwrap();
    assert_eq!(
        names(&r.hits),
        ["Commando", "Commando 86", "Bionic Commando"]
    );
}

#[tokio::test]
async fn an_empty_query_returns_nothing_but_reports_the_index_size() {
    let tree = Tree::sample();
    let lib = library(Some(tree.root()));
    let r = lib.search("   ".into(), None).await.unwrap();
    assert!(r.hits.is_empty());
    assert_eq!(r.total_matches, 0);
    assert_eq!(r.indexed, 4);
}

#[tokio::test]
async fn an_abandoned_index_build_still_completes() {
    let tree = Tree::sample();
    let lib = library(Some(tree.root()));
    // Start a build and drop the waiting future straight away (as a
    // cancelled Swift task would). The detached build must still install.
    tokio::select! {
        biased;
        _ = std::future::ready(()) => {}
        _ = lib.ensure_index(HvscCategory::Musicians) => {}
    }
    let r = lib
        .search("wizball".into(), Some(HvscCategory::Musicians))
        .await
        .unwrap();
    assert_eq!(names(&r.hits), ["Wizball"]);
    assert!(lib.indexing().is_empty());
}

#[tokio::test]
async fn index_builds_wait_for_the_databases() {
    let tree = Tree::sample();
    let shared = databases::shared();
    let lib = Library::new(Some(tree.root()), shared.clone()).without_index_cache();
    let search = lib.search("commando".into(), None);
    tokio::pin!(search);
    // Nothing is indexed while the databases are still loading…
    tokio::select! {
        biased;
        _ = &mut search => panic!("searched before the databases loaded"),
        _ = tokio::task::yield_now() => {}
    }
    assert!(lib.indexing().is_empty());
    // …and the search completes once they arrive.
    databases::install(&shared, Databases::default());
    let r = search.await.unwrap();
    assert_eq!(names(&r.hits), ["Commando"]);
}

// ── Surprise ─────────────────────────────────────────────────────────────────

#[tokio::test]
async fn radio_picks_skip_excluded_tunes_with_or_without_indexes() {
    let tree = Tree::sample();
    let lib = library(Some(tree.root()));
    let musicians: Vec<PathBuf> = [
        "MUSICIANS/H/Hubbard_Rob/Commando.sid",
        "MUSICIANS/H/Hubbard_Rob/Monty_on_the_Run.sid",
        "MUSICIANS/G/Galway_Martin/Wizball.sid",
    ]
    .iter()
    .map(|rel| tree.root().join(rel))
    .collect();

    // Cold: walks MUSICIANS, so with two of its three excluded only one is
    // left, and with all three nothing is.
    let exclude: HashSet<PathBuf> = musicians[..2].iter().cloned().collect();
    assert_eq!(lib.pick_blocking(&exclude), Ok(Some(musicians[2].clone())));
    let all: HashSet<PathBuf> = musicians.iter().cloned().collect();
    assert_eq!(lib.pick_blocking(&all), Ok(None));

    // Warm: every category's index, so GAMES is in reach too.
    lib.warm_indexes().await;
    for _ in 0..10 {
        let pick = lib.pick_blocking(&all).unwrap().unwrap();
        assert!(pick.ends_with("Bubble_Bobble.sid"), "{}", pick.display());
    }

    let lost = library(None);
    assert_eq!(
        lost.pick_blocking(&HashSet::new()),
        Err(LibraryError::NoRoot)
    );
}

#[tokio::test]
async fn surprise_picks_a_tune_in_scope_with_or_without_an_index() {
    let tree = Tree::sample();
    let lib = library(Some(tree.root()));
    let in_root =
        |p: &Path| p.starts_with(tree.root()) && p.extension().is_some_and(|e| e == "sid");

    // Cold: walks the folder.
    let cold = lib
        .surprise(Some(HvscCategory::Games))
        .await
        .unwrap()
        .unwrap();
    assert!(cold.ends_with("Bubble_Bobble.sid"), "{}", cold.display());

    // Warm: picks from the loaded index.
    lib.ensure_index(HvscCategory::Musicians).await.unwrap();
    for _ in 0..10 {
        let pick = lib
            .surprise(Some(HvscCategory::Musicians))
            .await
            .unwrap()
            .unwrap();
        assert!(
            in_root(&pick) && pick.to_string_lossy().contains("MUSICIANS"),
            "{}",
            pick.display()
        );
    }
}
