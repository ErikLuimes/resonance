//! The HVSC collection as the app browses it: categories → authors → tunes,
//! fuzzy search over a per-category index, and random picks.
//!
//! Wraps upstream's model (`hvsc_browser`, one `HvscBrowser` per category)
//! and its on-disk index cache, which is shared with Phosphor — both apps
//! build identical, self-validating indexes, so either one's build saves
//! the other the 30–60 s walk.
//!
//! Every method is async for the FFI layer: blocking disk work runs on the
//! tokio blocking pool, and the lock around the browsers is only held for
//! cheap steps (directory listings, scoring an index).

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use nucleo_matcher::{Config, Matcher};
use rand::Rng;
use tokio::sync::watch;

use crate::databases::{self, SharedDatabases};
use crate::hvsc_browser::{
    self, HvscAuthor, HvscBrowser, HvscCategory, HvscIndexEntry, HvscQuery, HvscTune,
};
use crate::hvsc_index_cache;

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
    /// Read and write Phosphor's index cache. Off in tests: the cache is one
    /// file per category whatever the root, so indexing a test tree would
    /// replace the real one.
    use_index_cache: bool,
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
            use_index_cache: true,
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
            let parsed = HvscQuery::parse(query);
            let mut matcher = Matcher::new(Config::DEFAULT);
            let mut buf = Vec::new();
            let mut scored = Vec::new();
            for &category in &categories {
                for (i, entry) in inner.index(category).iter().enumerate() {
                    if let Some(score) =
                        hvsc_browser::score_entry(&parsed, entry, &mut matcher, &mut buf)
                    {
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

#[cfg(test)]
mod tests;
