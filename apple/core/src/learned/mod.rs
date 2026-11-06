//! Song lengths Resonance worked out itself, for tunes HVSC's Songlengths
//! database doesn't list: CSDb downloads, and tunes added from elsewhere.
//!
//! They're estimates (design/songlengths/README.md) and live in their own
//! file: an HVSC update replaces Songlengths.md5, and its lengths always win,
//! so a tune that later joins HVSC gets its official length. The file looks
//! like Songlengths.md5, with `-` for a subtune that gave no answer and `?`
//! for one not run yet.

mod detect;

pub use detect::{estimate_length, LengthEstimate, LengthMethod};

use std::collections::{HashMap, HashSet, VecDeque};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, RwLock};
use std::thread;

use crossbeam_channel::Sender;

/// Bump when the detection changes enough that old answers should be redone.
const DETECTOR_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Slot {
    NotRun,
    NoAnswer,
    Secs(u32),
}

/// The lengths worked out so far, by MD5.
#[derive(Debug, Default)]
pub(crate) struct LearnedLengths {
    /// No file: kept in memory only, for sessions in tests.
    path: Option<PathBuf>,
    tunes: RwLock<HashMap<String, Vec<Slot>>>,
}

impl LearnedLengths {
    pub fn load(path: PathBuf) -> Self {
        let tunes = std::fs::read_to_string(&path).map(|t| parse(&t)).unwrap_or_default();
        Self { path: Some(path), tunes: RwLock::new(tunes) }
    }

    /// Length of a subtune (0-based), as `SonglengthDb::lookup` gives it.
    pub fn lookup(&self, md5: &str, subtune: usize) -> Option<u32> {
        match self.tunes.read().ok()?.get(md5)?.get(subtune)? {
            Slot::Secs(secs) => Some(*secs),
            _ => None,
        }
    }

    /// Whether `duration` is this store's estimate for the subtune (1-based).
    pub fn is_estimate(&self, md5: Option<&str>, song: u16, duration: Option<u32>) -> bool {
        let subtune = song.saturating_sub(1) as usize;
        duration.is_some() && md5.and_then(|m| self.lookup(m, subtune)) == duration
    }

    /// The subtunes (1-based) still to run.
    fn not_run(&self, md5: &str, songs: u16) -> Vec<u16> {
        let tunes = self.tunes.read().ok();
        let slots = tunes.as_ref().and_then(|t| t.get(md5));
        (1..=songs)
            .filter(|&s| slots.and_then(|v| v.get(s as usize - 1)).is_none_or(|&x| x == Slot::NotRun))
            .collect()
    }

    pub fn is_complete(&self, md5: &str, songs: u16) -> bool {
        self.not_run(md5, songs).is_empty()
    }

    fn record(&self, md5: &str, songs: u16, song: u16, secs: Option<u32>) {
        let Ok(mut tunes) = self.tunes.write() else { return };
        let slots = tunes.entry(md5.to_string()).or_default();
        if slots.len() < songs as usize {
            slots.resize(songs as usize, Slot::NotRun);
        }
        if let Some(slot) = slots.get_mut(song as usize - 1) {
            *slot = secs.map_or(Slot::NoAnswer, Slot::Secs);
        }
        let Some(path) = &self.path else { return };
        // Written whole after every subtune, so a quit loses at most the one
        // running; these files stay small.
        if let Err(e) = save(path, &render(&tunes)) {
            eprintln!("[resonance] saving learned song lengths: {e}");
        }
    }

    #[cfg(test)]
    pub fn set_for_test(&self, md5: &str, lengths: &[Option<u32>]) {
        for (i, secs) in lengths.iter().enumerate() {
            self.record(md5, lengths.len() as u16, i as u16 + 1, *secs);
        }
    }
}

fn save(path: &Path, text: &str) -> std::io::Result<()> {
    let temp = path.with_extension("tmp");
    std::fs::write(&temp, text)?;
    std::fs::rename(&temp, path)
}

fn render(tunes: &HashMap<String, Vec<Slot>>) -> String {
    let mut lines: Vec<String> = tunes
        .iter()
        .map(|(md5, slots)| {
            let times: Vec<String> = slots
                .iter()
                .map(|slot| match slot {
                    Slot::NotRun => "?".to_string(),
                    Slot::NoAnswer => "-".to_string(),
                    Slot::Secs(secs) => format!("{}:{:02}", secs / 60, secs % 60),
                })
                .collect();
            format!("{md5}={}", times.join(" "))
        })
        .collect();
    lines.sort();
    format!(
        "# Song lengths worked out by Resonance, for tunes outside HVSC.\n# detector {DETECTOR_VERSION}\n{}\n",
        lines.join("\n")
    )
}

/// What the file says; nothing when an older detector wrote it, so its tunes
/// get run again.
fn parse(text: &str) -> HashMap<String, Vec<Slot>> {
    let current = format!("# detector {DETECTOR_VERSION}");
    if !text.lines().any(|line| line.trim() == current) {
        return HashMap::new();
    }
    text.lines()
        .filter(|line| !line.starts_with('#'))
        .filter_map(|line| {
            let (md5, times) = line.trim().split_once('=')?;
            let slots = times.split_whitespace().map(parse_slot).collect::<Option<Vec<_>>>()?;
            (md5.len() == 32).then(|| (md5.to_string(), slots))
        })
        .collect()
}

fn parse_slot(text: &str) -> Option<Slot> {
    match text {
        "?" => Some(Slot::NotRun),
        "-" => Some(Slot::NoAnswer),
        _ => {
            let (minutes, secs) = text.split_once(':')?;
            Some(Slot::Secs(minutes.parse::<u32>().ok()? * 60 + secs.parse::<u32>().ok()?))
        }
    }
}

/// The estimate as a length to play: to the second, plus the second
/// `SonglengthDb::load` adds to HVSC's.
fn playable_secs(estimate: LengthEstimate) -> u32 {
    estimate.secs.ceil() as u32 + 1
}

// ── The background job ───────────────────────────────────────────────────────

/// A tune for the analyzer: where it is and what it's known by.
pub(crate) struct LengthJob {
    pub path: PathBuf,
    pub md5: String,
    pub songs: u16,
    /// Run this subtune first: it's the one in the list.
    pub first_song: u16,
}

#[derive(Default)]
struct Queue {
    jobs: VecDeque<LengthJob>,
    /// Queued or running, so a tune is only taken on once.
    taken: HashSet<String>,
    running: bool,
    quit: bool,
}

#[derive(Default)]
struct Shared {
    queue: Mutex<Queue>,
    wake: Condvar,
}

/// Runs tunes one at a time on a low-priority thread, started when there's
/// first something to do, and says when a tune has a new answer.
pub(crate) struct Analyzer {
    store: Arc<LearnedLengths>,
    shared: Arc<Shared>,
    /// Gets the MD5 of a tune that has new answers.
    done: Sender<String>,
}

impl Analyzer {
    pub fn new(store: Arc<LearnedLengths>, done: Sender<String>) -> Self {
        Self { store, shared: Arc::default(), done }
    }

    /// Take a tune on, unless it's done or already in hand. `next`: ahead of
    /// the others, because it's playing.
    pub fn request(&self, job: LengthJob, next: bool) {
        if self.store.is_complete(&job.md5, job.songs) {
            return;
        }
        let Ok(mut queue) = self.shared.queue.lock() else { return };
        if !queue.taken.insert(job.md5.clone()) {
            if next {
                // Still waiting: move it up.
                if let Some(i) = queue.jobs.iter().position(|j| j.md5 == job.md5) {
                    if let Some(waiting) = queue.jobs.remove(i) {
                        queue.jobs.push_front(waiting);
                    }
                }
            }
            return;
        }
        if next {
            queue.jobs.push_front(job);
        } else {
            queue.jobs.push_back(job);
        }
        if !queue.running {
            queue.running = true;
            let (store, shared, done) = (self.store.clone(), self.shared.clone(), self.done.clone());
            let spawned = thread::Builder::new()
                .name("resonance-song-lengths".into())
                .spawn(move || work(&store, &shared, &done));
            if let Err(e) = spawned {
                eprintln!("[resonance] starting the song length thread: {e}");
                queue.running = false;
            }
        }
        self.shared.wake.notify_one();
    }
}

impl Drop for Analyzer {
    fn drop(&mut self) {
        if let Ok(mut queue) = self.shared.queue.lock() {
            queue.quit = true;
        }
        self.shared.wake.notify_all();
    }
}

fn work(store: &LearnedLengths, shared: &Shared, done: &Sender<String>) {
    lower_priority();
    let cancelled = || shared.queue.lock().map_or(true, |q| q.quit);
    loop {
        let job = {
            let Ok(mut queue) = shared.queue.lock() else { return };
            loop {
                if queue.quit {
                    return;
                }
                if let Some(job) = queue.jobs.pop_front() {
                    break job;
                }
                let Ok(woken) = shared.wake.wait(queue) else { return };
                queue = woken;
            }
        };
        // A tune the engine can't take is only that tune's problem.
        let outcome = catch_unwind(AssertUnwindSafe(|| run_job(&job, store, done, &cancelled)));
        if outcome.is_err() {
            eprintln!("[resonance] working out the length of {} panicked", job.path.display());
        }
        if let Ok(mut queue) = shared.queue.lock() {
            queue.taken.remove(&job.md5);
        }
    }
}

fn run_job(job: &LengthJob, store: &LearnedLengths, done: &Sender<String>, cancelled: &dyn Fn() -> bool) {
    let Ok(data) = std::fs::read(&job.path) else { return };
    let mut songs = store.not_run(&job.md5, job.songs);
    songs.sort_by_key(|&song| song != job.first_song);
    for song in songs {
        let secs = match estimate_length(&data, song, cancelled) {
            Ok(estimate) => estimate.map(playable_secs),
            Err(e) => {
                eprintln!("[resonance] working out the length of {}: {e}", job.path.display());
                None
            }
        };
        // Stopped halfway, which says nothing about the tune.
        if cancelled() {
            return;
        }
        store.record(&job.md5, job.songs, song, secs);
        let _ = done.send(job.md5.clone());
    }
}

/// Keep this off the performance cores' backs while music plays.
fn lower_priority() {
    #[cfg(target_vendor = "apple")]
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_UTILITY, 0);
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    const MD5: &str = "0123456789abcdef0123456789abcdef";

    fn temp_file(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("resonance-learned-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("learned_songlengths.md5")
    }

    #[test]
    fn answers_survive_a_restart() {
        let path = temp_file("restart");
        let store = LearnedLengths::load(path.clone());
        store.record(MD5, 3, 1, Some(125));
        store.record(MD5, 3, 2, None);

        let store = LearnedLengths::load(path);
        assert_eq!(store.lookup(MD5, 0), Some(125));
        assert_eq!(store.lookup(MD5, 1), None);
        // No answer is an answer: only the one not run is still to do.
        assert_eq!(store.not_run(MD5, 3), vec![3]);
        assert!(!store.is_complete(MD5, 3));
        store.record(MD5, 3, 3, Some(9));
        assert!(store.is_complete(MD5, 3));
    }

    #[test]
    fn a_tune_it_has_never_seen_is_all_still_to_run() {
        let store = LearnedLengths::default();
        assert_eq!(store.not_run(MD5, 2), vec![1, 2]);
        assert_eq!(store.lookup(MD5, 0), None);
    }

    #[test]
    fn an_older_detectors_answers_get_redone() {
        let path = temp_file("older");
        std::fs::write(&path, format!("# detector 0\n{MD5}=1:00\n")).unwrap();
        assert_eq!(LearnedLengths::load(path).lookup(MD5, 0), None);
    }

    #[test]
    fn a_damaged_line_costs_only_itself() {
        let text = format!("# detector {DETECTOR_VERSION}\n{MD5}=1:00\nnonsense\nabc=1:00\nffffffffffffffffffffffffffffffff=x\n");
        let tunes = parse(&text);
        assert_eq!(tunes.len(), 1);
        assert_eq!(tunes[MD5], vec![Slot::Secs(60)]);
    }

    #[test]
    fn only_the_stores_own_length_is_an_estimate() {
        let store = LearnedLengths::default();
        store.record(MD5, 2, 2, Some(90));
        assert!(store.is_estimate(Some(MD5), 2, Some(90)));
        assert!(!store.is_estimate(Some(MD5), 2, Some(120)), "the default length");
        assert!(!store.is_estimate(Some(MD5), 2, None));
        assert!(!store.is_estimate(Some(MD5), 1, Some(90)), "another subtune");
        assert!(!store.is_estimate(None, 2, Some(90)));
    }

    #[test]
    fn an_estimate_plays_a_little_past_it() {
        let estimate = |secs| LengthEstimate { secs, method: LengthMethod::Loop };
        assert_eq!(playable_secs(estimate(120.0)), 121);
        assert_eq!(playable_secs(estimate(120.2)), 122);
    }

    #[test]
    fn the_analyzer_runs_every_subtune_and_says_so() {
        let path = temp_file("analyzer");
        let tune = path.with_file_name("tune.sid");
        std::fs::write(&tune, residfp_sys::testing::tiny_psid(1)).unwrap();
        let store = Arc::new(LearnedLengths::load(path.clone()));
        let (tx, rx) = crossbeam_channel::unbounded();
        let analyzer = Analyzer::new(store.clone(), tx);
        let job = || LengthJob { path: tune.clone(), md5: MD5.into(), songs: 2, first_song: 2 };
        analyzer.request(job(), false);
        analyzer.request(job(), true);

        for _ in 0..2 {
            assert_eq!(rx.recv_timeout(Duration::from_secs(60)).unwrap(), MD5);
        }
        assert!(store.is_complete(MD5, 2));
        assert!(store.lookup(MD5, 0).is_some() && store.lookup(MD5, 1).is_some());
        assert!(LearnedLengths::load(path).is_complete(MD5, 2));

        // Done: asking again runs nothing.
        analyzer.request(job(), true);
        assert!(rx.recv_timeout(Duration::from_millis(200)).is_err());
    }
}
