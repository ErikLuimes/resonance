//! The HVSC collection as the app browses it: categories → authors → tunes,
//! fuzzy search over a per-category index, and random picks.
//!
//! Wraps upstream's model (`hvsc_browser`, one `HvscBrowser` per category)
//! and its on-disk, self-validating index cache, which saves the 30–60 s
//! walk after the first build.
//!
//! Every method is async for the FFI layer: blocking disk work runs on the
//! tokio blocking pool, and the lock around the browsers is only held for
//! cheap steps (directory listings, scoring an index).

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use nucleo_matcher::pattern::{AtomKind, CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use rand::Rng;
use tokio::sync::watch;

use crate::databases::{self, SharedDatabases};
use crate::hvsc_browser::{
    self, HvscAuthor, HvscBrowser, HvscCategory, HvscIndexEntry, HvscQuery, HvscTune,
};
use crate::hvsc_index_cache;
use crate::playlist::PlaylistEntry;

pub(crate) const CATEGORIES: [HvscCategory; 3] = [
    HvscCategory::Musicians,
    HvscCategory::Games,
    HvscCategory::Demos,
];

/// Search shows at most this many hits (ranking still covers everything).
pub(crate) const MAX_RESULTS: usize = hvsc_browser::MAX_FLAT_RESULTS;

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum LibraryError {
    /// No HVSC folder is set.
    NoRoot,
    /// The folder has no MUSICIANS / GAMES / DEMOS directory, or a path
    /// isn't inside the collection.
    NotFound(String),
    Io(String),
}

pub(crate) struct SearchResults {
    pub hits: Vec<(HvscCategory, HvscIndexEntry)>,
    pub total_matches: usize,
    /// Tunes searched (the size of the indexes in scope).
    pub indexed: usize,
}

/// Clones share everything: the session thread holds one for Surprise Me.
#[derive(Clone)]
pub(crate) struct Library {
    inner: Arc<Mutex<Inner>>,
    databases: SharedDatabases,
    /// Bumped whenever an index is installed or the root changes, so
    /// `ensure_index` waiters re-check their category.
    index_changed: Arc<watch::Sender<u64>>,
    /// One bit per category (`slot`) while its index builds. Atomic so the
    /// 20 Hz snapshot never waits on the lock a search holds while scoring.
    building: Arc<AtomicU8>,
    /// Bumped when the root changes or the tree is refreshed in place, so
    /// the app drops its cached lists and re-checks the folder.
    tree_revision: Arc<AtomicU64>,
    /// Read and write Phosphor's index cache. Off in tests: the cache is one
    /// file per category whatever the root, so indexing a test tree would
    /// replace the real one.
    use_index_cache: bool,
    /// Every indexed tune's header author, for `crediting`.
    credits: Arc<Mutex<Option<Credits>>>,
}

/// An author folder's tunes at a glance, for the author list.
#[derive(Debug, Clone, Default)]
pub struct ComposerSummary {
    pub path: PathBuf,
    /// "Ari Yliaho" for Agemixer: the person their tunes' headers name.
    pub real_name: Option<String>,
    pub tunes: u32,
    pub first_year: Option<u16>,
    pub last_year: Option<u16>,
}

/// The SID header's author of every tune in the indexes, which keep only
/// the folder name. Read on first use; stale once an index changes.
struct Credits {
    /// The `index_changed` count it was read at.
    generation: u64,
    /// Per category (`slot`), in index order.
    authors: Vec<Vec<String>>,
}

struct Inner {
    root: Option<PathBuf>,
    /// One per category, in `CATEGORIES` order.
    browsers: Vec<HvscBrowser>,
}

impl Inner {
    fn browser(&mut self, category: HvscCategory) -> &mut HvscBrowser {
        let i = slot(category);
        &mut self.browsers[i]
    }

    fn index(&self, category: HvscCategory) -> &[HvscIndexEntry] {
        self.browsers[slot(category)].flat_index()
    }
}

fn slot(category: HvscCategory) -> usize {
    CATEGORIES
        .iter()
        .position(|&c| c == category)
        .expect("every category has a browser")
}

impl Library {
    pub fn new(root: Option<PathBuf>, databases: SharedDatabases) -> Self {
        let browsers = CATEGORIES
            .iter()
            .map(|&category| {
                let mut b = HvscBrowser::new(root.clone());
                b.set_category(category);
                b
            })
            .collect();
        Self {
            inner: Arc::new(Mutex::new(Inner { root, browsers })),
            databases,
            index_changed: Arc::new(watch::channel(0).0),
            building: Arc::new(AtomicU8::new(0)),
            tree_revision: Arc::new(AtomicU64::new(0)),
            use_index_cache: true,
            credits: Arc::new(Mutex::new(None)),
        }
    }

    #[cfg(test)]
    fn without_index_cache(mut self) -> Self {
        self.use_index_cache = false;
        self
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        lock(&self.inner)
    }

    pub fn root(&self) -> Option<PathBuf> {
        self.lock().root.clone()
    }

    /// Point the library at another folder. Clears every list and index; an
    /// index build already running for the old folder is discarded when it
    /// finishes (upstream's version stamp).
    pub fn set_root(&self, root: Option<PathBuf>) {
        {
            let mut inner = self.lock();
            if inner.root == root {
                return;
            }
            for b in &mut inner.browsers {
                b.set_root(root.clone());
            }
            inner.root = root;
        }
        self.index_changed.send_modify(|v| *v += 1);
        self.tree_revision.fetch_add(1, Ordering::Relaxed);
    }

    /// Re-read the tree in place: the root stays, but every browser resets
    /// and the indexes drop. For when the tree appeared or changed on disk
    /// without a root change — the first sync filling an empty folder.
    /// `HvscBrowser::set_root` ignores an unchanged root, so it round-trips
    /// through `None`.
    pub fn refresh(&self) {
        {
            let mut inner = self.lock();
            let root = inner.root.clone();
            for b in &mut inner.browsers {
                b.set_root(None);
                b.set_root(root.clone());
            }
        }
        self.index_changed.send_modify(|v| *v += 1);
        self.tree_revision.fetch_add(1, Ordering::Relaxed);
    }

    /// Changes whenever the root changes or `refresh()` runs; the app reads
    /// it in the snapshot and invalidates its caches on a bump.
    pub fn tree_revision(&self) -> u64 {
        self.tree_revision.load(Ordering::Relaxed)
    }

    /// Categories whose search index is being built right now.
    pub fn indexing(&self) -> Vec<HvscCategory> {
        let bits = self.building.load(Ordering::Relaxed);
        CATEGORIES
            .into_iter()
            .filter(|&c| bits & (1 << slot(c)) != 0)
            .collect()
    }

    /// Author folders (MUSICIANS) or alphabetical sections (GAMES, DEMOS),
    /// in folder order.
    pub async fn authors(&self, category: HvscCategory) -> Result<Vec<HvscAuthor>, LibraryError> {
        let inner = self.inner.clone();
        blocking(move || {
            let mut inner = lock(&inner);
            if inner.root.is_none() {
                return Err(LibraryError::NoRoot);
            }
            let b = inner.browser(category);
            b.load_authors_if_needed().map_err(LibraryError::NotFound)?;
            Ok(b.authors().to_vec())
        })
        .await?
    }

    /// The tunes in one author folder, with song lengths and STIL flags.
    pub async fn tunes(&self, author_path: PathBuf) -> Result<Vec<HvscTune>, LibraryError> {
        let root = self.root().ok_or(LibraryError::NoRoot)?;
        let category = category_of(&root, &author_path).ok_or_else(|| {
            LibraryError::NotFound(format!(
                "{} isn't in the HVSC folder",
                author_path.display()
            ))
        })?;
        let author = self
            .authors(category)
            .await?
            .into_iter()
            .find(|a| a.path == author_path)
            .ok_or_else(|| {
                LibraryError::NotFound(format!("No author folder {}", author_path.display()))
            })?;
        let db = databases::loaded(&self.databases).await;
        blocking(move || {
            // Upstream takes the databases by value (as Phosphor does on
            // every author click); cloning them costs a few milliseconds.
            hvsc_browser::load_author_tunes(
                author,
                Some(root),
                db.stil.clone(),
                db.songlengths.clone(),
            )
        })
        .await
    }

    /// STIL's entry on a tune or folder, as STIL.txt has it, after the
    /// entries of the folders it's in. None when STIL has nothing on it.
    pub async fn stil(&self, path: PathBuf) -> Option<String> {
        let db = databases::loaded(&self.databases).await;
        db.stil_text(&path, self.root().as_deref())
    }

    /// What HVSC's bugged-tunes list (DOCUMENTS/BUGlist.txt) reports on the
    /// tune at `path`; empty for most tunes.
    pub async fn bugs(&self, path: PathBuf) -> Vec<crate::buglist::Bug> {
        let Some(root) = self.root() else {
            return Vec::new();
        };
        let Some(hvsc_path) = databases::hvsc_path(&path, Some(&root)) else {
            return Vec::new();
        };
        blocking(move || crate::buglist::bugs(&root, &hvsc_path))
            .await
            .unwrap_or_default()
    }

    /// Fuzzy search over the given category, or all of them. Builds (or
    /// loads from cache) any index that isn't ready yet first.
    ///
    /// Scores with upstream's `score_entry` directly rather than the
    /// browser's memoised `recompute_search`: that merges categories into
    /// one ranking, and sidesteps the memo serving a result computed before
    /// the index finished.
    pub async fn search(
        &self,
        query: String,
        scope: Option<HvscCategory>,
    ) -> Result<SearchResults, LibraryError> {
        let categories: Vec<HvscCategory> = scope.map_or(CATEGORIES.to_vec(), |c| vec![c]);
        for &category in &categories {
            self.ensure_index(category).await?;
        }
        let inner = self.inner.clone();
        blocking(move || {
            let inner = lock(&inner);
            let indexed = categories.iter().map(|&c| inner.index(c).len()).sum();
            let query = query.trim();
            if query.is_empty() {
                return SearchResults {
                    hits: Vec::new(),
                    total_matches: 0,
                    indexed,
                };
            }
            // "second reality" finds "2nd Reality": each spelling is tried,
            // and an entry scores its best.
            let parsed: Vec<HvscQuery> = spellings(query).iter().map(|q| HvscQuery::parse(q)).collect();
            let mut matcher = Matcher::new(Config::DEFAULT);
            let mut buf = Vec::new();
            let mut scored = Vec::new();
            for &category in &categories {
                for (i, entry) in inner.index(category).iter().enumerate() {
                    let best = parsed
                        .iter()
                        .filter_map(|q| hvsc_browser::score_entry(q, entry, &mut matcher, &mut buf))
                        .max();
                    if let Some(score) = best {
                        scored.push((score, category, i));
                    }
                }
            }
            let total_matches = scored.len();
            // Best score first. Upstream breaks ties alphabetically, which
            // ranks "Bionic Commando" above "Commando" for "commando"; an
            // exact title, then a title starting with the query, go first.
            let wanted = query.to_lowercase();
            scored.sort_by_cached_key(|&(score, category, i)| {
                let title = inner.index(category)[i].title.to_lowercase();
                let closeness = if title == wanted {
                    0
                } else if title.starts_with(&wanted) {
                    1
                } else {
                    2
                };
                (std::cmp::Reverse(score), closeness, title)
            });
            scored.truncate(MAX_RESULTS);
            let hits = scored
                .into_iter()
                .map(|(_, category, i)| (category, inner.index(category)[i].clone()))
                .collect();
            SearchResults {
                hits,
                total_matches,
                indexed,
            }
        })
        .await
    }

    /// Read every tune's header author (`Credits`) unless it's current.
    async fn ensure_credits(&self) -> Result<(), LibraryError> {
        for &category in &CATEGORIES {
            self.ensure_index(category).await?;
        }
        let generation = *self.index_changed.borrow();
        let stale = lock_credits(&self.credits)
            .as_ref()
            .is_none_or(|c| c.generation != generation);
        if stale {
            // Read without holding the lock: searches go on meanwhile.
            let paths: Vec<Vec<PathBuf>> = {
                let inner = self.lock();
                CATEGORIES
                    .iter()
                    .map(|&c| inner.index(c).iter().map(|e| e.path.clone()).collect())
                    .collect()
            };
            let authors = blocking(move || {
                paths
                    .iter()
                    .map(|paths| paths.iter().map(|p| header_author(p)).collect())
                    .collect()
            })
            .await?;
            *lock_credits(&self.credits) = Some(Credits {
                generation,
                authors,
            });
        }
        Ok(())
    }

    /// Each author folder (or section) of `category`, in the author list's
    /// order, with how many tunes it holds, the years they came out, and
    /// (in MUSICIANS) the composer's name as their tunes' headers give it.
    pub async fn composers(&self, category: HvscCategory) -> Result<Vec<ComposerSummary>, LibraryError> {
        self.ensure_credits().await?;
        let authors = self.authors(category).await?;
        let inner = self.inner.clone();
        let credits = self.credits.clone();
        blocking(move || {
            let inner = lock(&inner);
            let credits = lock_credits(&credits);
            let headers = credits.as_ref().map(|c| &c.authors[slot(category)]);
            let folders: std::collections::HashMap<&Path, usize> =
                authors.iter().enumerate().map(|(i, a)| (a.path.as_path(), i)).collect();
            let mut out: Vec<ComposerSummary> = authors
                .iter()
                .map(|a| ComposerSummary { path: a.path.clone(), ..Default::default() })
                .collect();
            let mut names: Vec<std::collections::HashMap<String, u32>> = vec![Default::default(); authors.len()];
            for (k, entry) in inner.index(category).iter().enumerate() {
                let mut dir = entry.path.parent();
                let owner = loop {
                    match dir {
                        Some(d) => match folders.get(d) {
                            Some(&i) => break Some(i),
                            None => dir = d.parent(),
                        },
                        None => break None,
                    }
                };
                let Some(i) = owner else { continue };
                let summary = &mut out[i];
                summary.tunes += 1;
                if let Some(year) = release_year(&entry.released) {
                    summary.first_year = Some(summary.first_year.map_or(year, |y| y.min(year)));
                    summary.last_year = Some(summary.last_year.map_or(year, |y| y.max(year)));
                }
                if category == HvscCategory::Musicians {
                    if let Some(name) = headers.and_then(|h| h.get(k)).and_then(|a| real_name(a)) {
                        *names[i].entry(name).or_default() += 1;
                    }
                }
            }
            for ((summary, names), author) in out.iter_mut().zip(names).zip(&authors) {
                // The name most of their tunes give, unless it's just the
                // folder's.
                summary.real_name = names
                    .into_iter()
                    .max_by(|a, b| a.1.cmp(&b.1).then_with(|| b.0.cmp(&a.0)))
                    .map(|(name, _)| name)
                    .filter(|name| !same_name(name, &author.display_name));
            }
            out
        })
        .await
    }

    /// Tunes in all of HVSC whose header's author contains one of `names`,
    /// ignoring case and accents. The caller narrows them to exact credits
    /// ("Exos" in "Exos & Jeff", not in "Exoskeleton").
    ///
    /// The indexes have no header author, so the first call reads every
    /// tune's header (about a second for 60,000 when the disk cache is
    /// warm), and later ones reuse them until an index changes.
    pub async fn crediting(
        &self,
        names: Vec<String>,
    ) -> Result<Vec<(HvscCategory, HvscIndexEntry, String)>, LibraryError> {
        self.ensure_credits().await?;
        let inner = self.inner.clone();
        let credits = self.credits.clone();
        blocking(move || {
            let inner = lock(&inner);
            let credits = lock_credits(&credits);
            let Some(credits) = credits.as_ref() else {
                return Vec::new();
            };
            let patterns: Vec<Pattern> = names
                .iter()
                .filter(|n| !n.trim().is_empty())
                .map(|n| {
                    Pattern::new(
                        n,
                        CaseMatching::Ignore,
                        Normalization::Smart,
                        AtomKind::Substring,
                    )
                })
                .collect();
            let mut matcher = Matcher::new(Config::DEFAULT);
            let mut buf = Vec::new();
            let mut hits = Vec::new();
            for (slot, &category) in CATEGORIES.iter().enumerate() {
                // An index rebuilt since the read just misses its new tunes
                // until the next call.
                for (entry, author) in inner.index(category).iter().zip(&credits.authors[slot]) {
                    let haystack = Utf32Str::new(author, &mut buf);
                    if patterns
                        .iter()
                        .any(|p| p.score(haystack, &mut matcher).is_some())
                    {
                        hits.push((category, entry.clone(), author.clone()));
                    }
                }
            }
            hits
        })
        .await
    }

    /// The tunes at `paths` (files in the collection), in that order, with
    /// their index entries and header authors: a published playlist's
    /// rows. Paths that aren't in an index are left out.
    pub async fn tunes_at(
        &self,
        paths: Vec<PathBuf>,
    ) -> Result<Vec<(HvscCategory, HvscIndexEntry, String)>, LibraryError> {
        let root = self.root().ok_or(LibraryError::NoRoot)?;
        let wanted: Vec<HvscCategory> = CATEGORIES
            .into_iter()
            .filter(|&c| paths.iter().any(|p| category_of(&root, p) == Some(c)))
            .collect();
        for &category in &wanted {
            self.ensure_index(category).await?;
        }
        let inner = self.inner.clone();
        blocking(move || {
            let lookup: HashSet<&PathBuf> = paths.iter().collect();
            let mut found = std::collections::HashMap::new();
            {
                let inner = lock(&inner);
                for &category in &wanted {
                    for entry in inner.index(category) {
                        if lookup.contains(&entry.path) {
                            found.insert(entry.path.clone(), (category, entry.clone()));
                        }
                    }
                }
            }
            paths
                .iter()
                .filter_map(|p| found.get(p).cloned())
                .map(|(category, entry)| {
                    let author = header_author(&entry.path);
                    (category, entry, author)
                })
                .collect()
        })
        .await
    }

    /// The tunes played most recently (the play history),
    /// newest first, read from their headers with song lengths and STIL
    /// flags, and when each was played. Files no longer on disk are left
    /// out; tunes outside the collection have no category.
    pub async fn recent(
        &self,
    ) -> Result<Vec<(Option<HvscCategory>, PlaylistEntry, bool, u64)>, LibraryError> {
        let root = self.root();
        let db = databases::loaded(&self.databases).await;
        blocking(move || {
            crate::history::recent()
                .into_iter()
                .filter_map(|recent| {
                    let (category, entry, has_stil) = read_file(&recent.path, root.as_deref(), &db)?;
                    Some((category, entry, has_stil, recent.played_at))
                })
                .collect()
        })
        .await
    }

    /// The tunes at `paths`, in that order, read from their headers like
    /// `recent`: inside the collection or not. Files no longer on disk are
    /// left out.
    pub async fn files(
        &self,
        paths: Vec<PathBuf>,
    ) -> Vec<(Option<HvscCategory>, PlaylistEntry, bool)> {
        let root = self.root();
        let db = databases::loaded(&self.databases).await;
        blocking(move || paths.iter().filter_map(|p| read_file(p, root.as_deref(), &db)).collect())
            .await
            .unwrap_or_default()
    }

    /// A random tune: uniformly from the loaded indexes in scope, or by
    /// walking the folder when none is loaded yet.
    pub async fn surprise(
        &self,
        scope: Option<HvscCategory>,
    ) -> Result<Option<PathBuf>, LibraryError> {
        let root = self.root().ok_or(LibraryError::NoRoot)?;
        let categories: Vec<HvscCategory> = scope.map_or(CATEGORIES.to_vec(), |c| vec![c]);
        {
            let inner = self.lock();
            let total: usize = categories.iter().map(|&c| inner.index(c).len()).sum();
            if total > 0 {
                let mut pick = rand::thread_rng().gen_range(0..total);
                for &c in &categories {
                    let index = inner.index(c);
                    if pick < index.len() {
                        return Ok(Some(index[pick].path.clone()));
                    }
                    pick -= index.len();
                }
            }
        }
        // Cold: no index in scope. MUSICIANS holds ~90% of HVSC, so an
        // unscoped pick walks it.
        let category = scope.unwrap_or(HvscCategory::Musicians);
        blocking(move || hvsc_browser::random_hvsc_path_walk(root, category)).await
    }

    /// A random tune from all of HVSC that isn't in `exclude`, for Surprise
    /// Me. Blocking: call it off the UI's threads. Uniform over the loaded
    /// indexes; with none loaded, a cold walk of MUSICIANS (~90% of HVSC).
    pub fn pick_blocking(
        &self,
        exclude: &HashSet<PathBuf>,
    ) -> Result<Option<PathBuf>, LibraryError> {
        let root = self.root().ok_or(LibraryError::NoRoot)?;
        {
            let inner = self.lock();
            let total: usize = CATEGORIES.iter().map(|&c| inner.index(c).len()).sum();
            let mut rng = rand::thread_rng();
            // A session hears a sliver of ~60,000 tunes, so a few draws
            // always find a fresh one in practice.
            for _ in 0..(if total > 0 { 32 } else { 0 }) {
                let mut pick = rng.gen_range(0..total);
                for &c in &CATEGORIES {
                    let index = inner.index(c);
                    if pick < index.len() {
                        if !exclude.contains(&index[pick].path) {
                            return Ok(Some(index[pick].path.clone()));
                        }
                        break;
                    }
                    pick -= index.len();
                }
            }
        }
        Ok(walk_pick(&root, HvscCategory::Musicians, exclude))
    }

    /// Every indexed tune in a random order: Shuffle Collection's walk.
    /// Empty until an index is loaded.
    pub fn shuffled_paths(&self) -> Result<Vec<PathBuf>, LibraryError> {
        use rand::seq::SliceRandom;
        self.root().ok_or(LibraryError::NoRoot)?;
        let mut paths: Vec<PathBuf> = {
            let inner = self.lock();
            CATEGORIES
                .iter()
                .flat_map(|&c| inner.index(c).iter().map(|e| e.path.clone()))
                .collect()
        };
        paths.shuffle(&mut rand::thread_rng());
        Ok(paths)
    }

    /// Every indexed tune's path and subtune count, all categories (empty
    /// until `warm_indexes` has run).
    pub fn indexed_tunes(&self) -> Vec<(PathBuf, u16)> {
        let inner = self.lock();
        CATEGORIES
            .iter()
            .flat_map(|&c| inner.index(c).iter().map(|e| (e.path.clone(), e.songs)))
            .collect()
    }

    /// Each MUSICIANS tune's folder and header author, for reading composers'
    /// names and nicknames. The first call reads the headers; see `crediting`.
    pub async fn musician_credits(&self) -> Result<Vec<(String, String)>, LibraryError> {
        self.ensure_credits().await?;
        let inner = self.inner.clone();
        let credits = self.credits.clone();
        blocking(move || {
            let inner = lock(&inner);
            let credits = lock_credits(&credits);
            let Some(credits) = credits.as_ref() else { return Vec::new() };
            CATEGORIES
                .iter()
                .enumerate()
                .filter(|(_, &c)| c == HvscCategory::Musicians)
                .flat_map(|(slot, &c)| {
                    inner.index(c).iter().zip(&credits.authors[slot])
                        .map(|(entry, author)| (crate::smart::composer_folder(&entry.path, &entry.author_raw), author.clone()))
                        .collect::<Vec<_>>()
                })
                .collect()
        })
        .await
    }

    /// Every indexed tune with its category (empty until `warm_indexes` has
    /// run).
    pub fn all_entries(&self) -> Vec<(HvscCategory, HvscIndexEntry)> {
        let inner = self.lock();
        CATEGORIES
            .iter()
            .flat_map(|&c| inner.index(c).iter().map(move |e| (c, e.clone())))
            .collect()
    }

    /// Load (or build) every category's index, so `pick_blocking` covers all
    /// of HVSC and needs no walk.
    pub async fn warm_indexes(&self) {
        let _ = tokio::join!(
            self.ensure_index(HvscCategory::Musicians),
            self.ensure_index(HvscCategory::Games),
            self.ensure_index(HvscCategory::Demos),
        );
    }

    /// Wait until `category`'s search index is ready, starting a build if
    /// none is running. The build (cache load, else a full walk, then a
    /// cache save) runs detached: a cancelled caller can't leave the
    /// browser stuck in "building".
    pub async fn ensure_index(&self, category: HvscCategory) -> Result<(), LibraryError> {
        let db = databases::loaded(&self.databases).await;
        loop {
            // Subscribe before checking, so an install between the check
            // and the wait isn't missed.
            let mut changed = self.index_changed.subscribe();
            let build = {
                let mut inner = self.lock();
                if inner.root.is_none() {
                    return Err(LibraryError::NoRoot);
                }
                let b = inner.browser(category);
                if b.flat_index_loaded() {
                    return Ok(());
                }
                b.begin_flat_index_build()
            };
            if let Some((root, category, version)) = build {
                let inner = self.inner.clone();
                let notify = self.index_changed.clone();
                let db = db.clone();
                let use_cache = self.use_index_cache;
                let building = self.building.clone();
                let bit = 1 << slot(category);
                building.fetch_or(bit, Ordering::Relaxed);
                tokio::task::spawn_blocking(move || {
                    let index = load_or_build_index(&root, category, &db, use_cache);
                    lock(&inner)
                        .browser(category)
                        .install_flat_index(version, index);
                    building.fetch_and(!bit, Ordering::Relaxed);
                    notify.send_modify(|v| *v += 1);
                });
            }
            if changed.changed().await.is_err() {
                return Err(LibraryError::Io("library shut down".into()));
            }
        }
    }
}

/// Phosphor's index pipeline (main.rs:4486-4501): the shared cache when its
/// header still matches the tree, else a full walk saved for next time.
fn load_or_build_index(
    root: &Path,
    category: HvscCategory,
    db: &databases::Databases,
    use_cache: bool,
) -> Vec<HvscIndexEntry> {
    if use_cache {
        if let Some(cached) = hvsc_index_cache::load(root, category, db.hvsc_version) {
            return cached;
        }
    }
    let started = std::time::Instant::now();
    let index = hvsc_browser::build_flat_index_worker(
        root.to_path_buf(),
        category,
        db.stil.clone(),
        db.songlengths.clone(),
    );
    eprintln!(
        "[resonance] indexed {} {} tunes in {:.1}s",
        index.len(),
        category.label(),
        started.elapsed().as_secs_f32()
    );
    // Only a complete walk is saved; an empty one would look valid later.
    if use_cache && !index.is_empty() {
        hvsc_index_cache::save(root, category, db.hvsc_version, &index);
    }
    index
}

/// A uniformly random tune under `category` that isn't in `exclude`, by
/// walking the folder (reservoir sampling, like upstream's
/// `random_hvsc_path_walk`, which can't exclude).
fn walk_pick(root: &Path, category: HvscCategory, exclude: &HashSet<PathBuf>) -> Option<PathBuf> {
    let mut rng = rand::thread_rng();
    let mut chosen = None;
    let mut seen = 0u64;
    for entry in walkdir::WalkDir::new(root.join(category.dir_name()))
        .follow_links(true)
        .into_iter()
        .filter_map(Result::ok)
    {
        let path = entry.path();
        let is_tune = path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| crate::player::sid_file::is_sid_extension(&e.to_ascii_lowercase()));
        if !entry.file_type().is_file() || !is_tune || exclude.contains(path) {
            continue;
        }
        seen += 1;
        if rng.gen_range(0..seen) == 0 {
            chosen = Some(path.to_path_buf());
        }
    }
    chosen
}

/// Which category folder `path` lies in.
fn category_of(root: &Path, path: &Path) -> Option<HvscCategory> {
    let first = path.strip_prefix(root).ok()?.components().next()?;
    let name = first.as_os_str().to_str()?;
    CATEGORIES.into_iter().find(|c| c.dir_name() == name)
}

/// The author field of the SID header at `path`; empty when it can't be
/// read.
fn header_author(path: &Path) -> String {
    use std::io::Read;
    let mut header = Vec::with_capacity(0x7C);
    let read = std::fs::File::open(path).and_then(|f| f.take(0x7C).read_to_end(&mut header));
    match read {
        Ok(_) => crate::player::sid_file::parse_header(&header)
            .map(|h| h.author)
            .unwrap_or_default(),
        Err(_) => String::new(),
    }
}

fn lock_credits(credits: &Mutex<Option<Credits>>) -> MutexGuard<'_, Option<Credits>> {
    credits
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn lock(inner: &Mutex<Inner>) -> MutexGuard<'_, Inner> {
    inner
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> T + Send + 'static,
) -> Result<T, LibraryError> {
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| LibraryError::Io(format!("library task failed: {e}")))
}


/// A tune file read from its header, with its song length and STIL flag,
/// and its category when it's in the collection at `root`.
fn read_file(
    path: &Path,
    root: Option<&Path>,
    db: &databases::Databases,
) -> Option<(Option<HvscCategory>, PlaylistEntry, bool)> {
    let mut entry = PlaylistEntry::from_path(path).ok()?;
    if entry.duration_secs.is_none() {
        entry.duration_secs = entry.md5.as_deref().and_then(|md5| {
            let song = entry.selected_song.saturating_sub(1) as usize;
            db.songlengths.as_ref()?.lookup(md5, song)
        });
    }
    let has_stil = db.stil.as_ref().is_some_and(|s| s.lookup(&entry.path, root).is_some());
    let category = root.and_then(|r| category_of(r, &entry.path));
    Some((category, entry, has_stil))
}


/// Words a title may spell either way: "second" or "2nd", "two" or "2",
/// "and" or "&".
const SPELLINGS: &[(&str, &str)] = &[
    ("first", "1st"), ("second", "2nd"), ("third", "3rd"), ("fourth", "4th"), ("fifth", "5th"),
    ("sixth", "6th"), ("seventh", "7th"), ("eighth", "8th"), ("ninth", "9th"), ("tenth", "10th"),
    ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"), ("five", "5"), ("six", "6"),
    ("seven", "7"), ("eight", "8"), ("nine", "9"), ("ten", "10"), ("and", "&"),
];

/// `query` as typed, with its number words written as digits, and with its
/// digits written as words: the spellings a search tries.
pub(crate) fn spellings(query: &str) -> Vec<String> {
    let respell = |to_digits: bool| -> String {
        query
            .split_whitespace()
            .map(|word| {
                let lower = word.to_lowercase();
                SPELLINGS
                    .iter()
                    .find_map(|&(words, digits)| {
                        let (from, to) = if to_digits { (words, digits) } else { (digits, words) };
                        (lower == from).then(|| to.to_string())
                    })
                    .unwrap_or_else(|| word.to_string())
            })
            .collect::<Vec<_>>()
            .join(" ")
    };
    let mut out = vec![query.to_string()];
    for spelled in [respell(true), respell(false)] {
        if !out.contains(&spelled) {
            out.push(spelled);
        }
    }
    out
}


/// The year a SID's released field starts with ("1987 Ocean"); None for
/// "19??" and the like.
fn release_year(released: &str) -> Option<u16> {
    let digits: String = released.trim().chars().take(4).collect();
    let year: u16 = digits.parse().ok()?;
    (1980..=2100).contains(&year).then_some(year)
}

/// The person a header's author names: "Ari Yliaho (Agemixer)" gives
/// "Ari Yliaho". None for unknowns ("<?>") and for groups of people.
fn real_name(author: &str) -> Option<String> {
    let name = author.split(" (").next()?.trim();
    let unknown = name.is_empty() || name.contains('?') || name.contains('<');
    let several = name.contains('&') || name.contains(',') || name.contains(" and ");
    (!unknown && !several).then(|| name.to_string())
}

/// Whether a real name only repeats the folder's ("Hubbard, Rob" and
/// "Rob Hubbard").
fn same_name(name: &str, display: &str) -> bool {
    let words = |s: &str| {
        let mut w: Vec<String> = s
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| !w.is_empty())
            .map(str::to_lowercase)
            .collect();
        w.sort();
        w
    };
    words(name) == words(display)
}

#[cfg(test)]
mod tests;
