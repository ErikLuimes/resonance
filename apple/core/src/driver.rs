//! The session's home thread.
//!
//! One thread owns the `Session` and serializes everything that touches it —
//! FFI commands, player statuses, loader results and the advance tick — the
//! same single-threaded shape as the Iced app's `update()`. After every step
//! it publishes an immutable read model; FFI getters only clone an `Arc`, so
//! no call from the UI ever waits on the player or the disk.
//!
//! A second thread, the loader, parses files in FIFO order (folders and big
//! playlists can take seconds) and hands entries back to the session thread.

use std::collections::HashSet;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::{select, unbounded, Receiver, Sender};

use crate::databases::{self, Databases, SharedDatabases};
use crate::learned::{Analyzer, LearnedLengths};
use crate::library::{Library, LibraryError};
use crate::player::{self, PlayState, PlayerCmd, PlayerStatus};
use crate::playlist::{self, LoadingProgress, PlaylistEntry, RepeatMode};
use crate::residfp_player;
use crate::session::{persist, Engine, Options, RadioKind, Session};
use crate::viz::{SharedFeed, VizCapture, VizFeed};
use crate::audio_volume;

/// How often the advance check runs while playing (statuses also wake the
/// loop every frame) and while idle.
const TICK_PLAYING: Duration = Duration::from_millis(20);
const TICK_IDLE: Duration = Duration::from_millis(250);
/// Coalesce bursts of playlist edits into one session write.
const SAVE_DELAY: Duration = Duration::from_secs(1);

pub(crate) enum Command {
    AddPaths {
        paths: Vec<PathBuf>,
        play_first: bool,
    },
    Remove(Vec<usize>),
    Move {
        from: Vec<usize>,
        to: usize,
    },
    Clear,
    /// Play SID files as a temporary list, from `start`.
    PlayQueue {
        paths: Vec<PathBuf>,
        start: PathBuf,
    },
    PlayIndex(usize),
    /// Start Surprise Me's radio.
    Surprise,
    /// Start Shuffle Collection.
    ShuffleCollection,
    PlayPause {
        fallback: Option<usize>,
    },
    Stop,
    Next,
    Previous,
    SetSubtune(u16),
    NextSubtune,
    PrevSubtune,
    SetShuffle(bool),
    SetRepeat(RepeatMode),
    SetEngine(Engine),
    /// Go to this point in the playing subtune (the pull-driven engines).
    Seek(Duration),
    SetOptions(Options),
    SetHvscRoot(Option<PathBuf>),
    /// Save, stop the player and end the thread; acknowledged on the sender.
    Shutdown(Sender<()>),
}

/// Everything the UI reads, rebuilt by the session thread after each step.
pub(crate) struct Published {
    pub session: SessionView,
    /// Rebuilt only when `playlist_revision` changes.
    pub playlist: Arc<Vec<PlaylistEntry>>,
    pub loading: Option<String>,
    pub error: Option<String>,
}

/// The parts of `Session` the FFI layer turns into records.
#[derive(Clone)]
pub(crate) struct SessionView {
    pub status: PlayerStatus,
    /// Playlist row that's playing; None while the queue plays.
    pub current: Option<usize>,
    /// Length of the playing subtune, from whichever list it's in.
    pub current_duration_secs: Option<u32>,
    /// That length is one Resonance worked out.
    pub current_duration_is_estimate: bool,
    pub queue_active: bool,
    /// The queue is Surprise Me's radio.
    pub surprise_active: bool,
    /// The queue is Shuffle Collection.
    pub shuffle_collection_active: bool,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    pub engine: Engine,
    /// The engine can seek (it's pull-driven).
    pub can_seek: bool,
    /// A seek is running: the audio is silent until it lands.
    pub seeking: bool,
    /// While seeking, where the emulation has got to on its way there.
    pub seek_position: Option<Duration>,
    pub playlist_revision: u64,
    pub track_revision: u64,
}

pub(crate) struct StartConfig {
    pub engine: Engine,
    pub volume: f32,
    pub options: Options,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    pub session_path: PathBuf,
    pub hvsc_root: Option<PathBuf>,
    /// Filled by the loader; shared with the library.
    pub databases: SharedDatabases,
    /// Where Surprise Me's picks come from.
    pub library: Library,
    /// Lengths worked out for tunes the databases don't list.
    pub learned: Arc<LearnedLengths>,
}

pub(crate) struct Driver {
    pub commands: Sender<Command>,
    pub published: Arc<Mutex<Arc<Published>>>,
    /// The visualizers' frames, kept apart from `published` so the per-step
    /// publish never copies them.
    pub viz: SharedFeed,
}

impl Driver {
    pub fn start(start: StartConfig) -> Self {
        let (cmd_tx, cmd_rx) = unbounded();
        let published = Arc::new(Mutex::new(Arc::new(Published {
            session: SessionView {
                status: PlayerStatus::default(),
                current: None,
                current_duration_secs: None,
                current_duration_is_estimate: false,
                queue_active: false,
                surprise_active: false,
                shuffle_collection_active: false,
                shuffle: start.shuffle,
                repeat: start.repeat,
                engine: start.engine,
                can_seek: start.engine.is_pull_driven(),
                seeking: false,
                seek_position: None,
                playlist_revision: 0,
                track_revision: 0,
            },
            playlist: Arc::new(Vec::new()),
            loading: None,
            error: None,
        })));
        let viz = Arc::new(Mutex::new(VizFeed::new()));
        let out = published.clone();
        let capture = VizCapture::new(viz.clone());
        thread::Builder::new()
            .name("resonance-session".into())
            .spawn(move || run(start, cmd_rx, out, capture))
            .expect("failed to spawn the session thread");
        Self {
            commands: cmd_tx,
            published,
            viz,
        }
    }
}

// ── Loader ───────────────────────────────────────────────────────────────────

enum Job {
    Databases,
    RestoreSession(PathBuf),
    Paths {
        paths: Vec<PathBuf>,
        play_first: bool,
    },
    Queue {
        paths: Vec<PathBuf>,
        start: PathBuf,
    },
    /// The next tune for a radio: for Surprise Me a random one not in
    /// `exclude`, for Shuffle Collection the next of its order (a new
    /// order on its first pick).
    Pick {
        kind: RadioKind,
        exclude: HashSet<PathBuf>,
        first: bool,
    },
}

enum Loaded {
    /// Boxed: far larger than the other variants.
    Databases(Box<Databases>),
    SessionRestored(Vec<PlaylistEntry>),
    Entries {
        entries: Vec<PlaylistEntry>,
        play_first: bool,
    },
    Queue {
        entries: Vec<PlaylistEntry>,
        start: PathBuf,
    },
    /// Ok(None): HVSC had nothing left to pick.
    Picked(RadioKind, Result<Option<PlaylistEntry>, String>),
}

fn spawn_loader(progress: LoadingProgress, library: Library) -> (Sender<Job>, Receiver<Loaded>) {
    let (job_tx, job_rx) = unbounded::<Job>();
    let (done_tx, done_rx) = unbounded();
    thread::Builder::new()
        .name("resonance-loader".into())
        .spawn(move || {
            // Shuffle Collection's order, next tune last.
            let mut order: Vec<PathBuf> = Vec::new();
            for job in job_rx.iter() {
                let result = match job {
                    Job::Databases => {
                        Loaded::Databases(Box::new(Databases::load_with_tree(library.root().as_deref())))
                    }
                    Job::RestoreSession(path) => {
                        set_progress(&progress, "Restoring playlist…");
                        match persist::load(&path, progress.clone()) {
                            Ok(entries) => Loaded::SessionRestored(entries),
                            Err(e) => {
                                // Still unblock autosave, or the playlist
                                // could never be saved again.
                                eprintln!("[resonance] session restore failed: {e}");
                                Loaded::SessionRestored(Vec::new())
                            }
                        }
                    }
                    Job::Paths { paths, play_first } => Loaded::Entries {
                        entries: parse_paths(paths, &progress, library.root()),
                        play_first,
                    },
                    // Nothing is added, so no "Adding files" progress: a
                    // private counter keeps it out of the UI.
                    Job::Queue { paths, start } => Loaded::Queue {
                        entries: playlist::parse_files(paths, LoadingProgress::default()),
                        start,
                    },
                    Job::Pick { kind: RadioKind::Surprise, exclude, first } => {
                        if first {
                            set_progress(&progress, "Picking a surprise…");
                        }
                        Loaded::Picked(RadioKind::Surprise, pick_tune(&library, exclude))
                    }
                    Job::Pick { kind: RadioKind::Shuffle, first, .. } => {
                        if first {
                            set_progress(&progress, "Shuffling the collection…");
                            order.clear();
                        }
                        Loaded::Picked(RadioKind::Shuffle, next_in_order(&library, &mut order))
                    }
                };
                if job_rx.is_empty() {
                    set_progress(&progress, "");
                }
                if done_tx.send(result).is_err() {
                    break;
                }
            }
        })
        .expect("failed to spawn the loader thread");
    (job_tx, done_rx)
}

/// Turn dropped / opened paths into entries, keeping their order: folders
/// are scanned, playlists expanded, anything else parsed as a SID / MUS file
/// (main.rs `Message::FileDropped`).
///
/// Published playlists hold HVSC-relative paths, which don't resolve next to
/// the dropped file; when that yields nothing they are retried against
/// `hvsc_root`.
fn parse_paths(
    paths: Vec<PathBuf>,
    progress: &LoadingProgress,
    hvsc_root: Option<PathBuf>,
) -> Vec<PlaylistEntry> {
    let mut out = Vec::new();
    let mut files = Vec::new();
    let flush = |files: &mut Vec<PathBuf>, out: &mut Vec<PlaylistEntry>| {
        if !files.is_empty() {
            out.extend(playlist::parse_files(
                std::mem::take(files),
                progress.clone(),
            ));
        }
    };
    for path in paths {
        if path.is_dir() {
            flush(&mut files, &mut out);
            out.extend(playlist::parse_directory(path, progress.clone()));
        } else if is_playlist_file(&path) {
            flush(&mut files, &mut out);
            match parse_playlist(path, progress, hvsc_root.as_ref()) {
                Ok(entries) => out.extend(entries),
                Err(e) => eprintln!("[resonance] {e}"),
            }
        } else {
            files.push(path);
        }
    }
    flush(&mut files, &mut out);
    out
}

/// A playlist's tunes: its paths taken as relative to its own folder, or,
/// when that misses some, to the collection if it finds more. (An exported
/// playlist can mix full paths with collection-relative ones; full paths
/// resolve against either.)
fn parse_playlist(
    path: PathBuf,
    progress: &LoadingProgress,
    hvsc_root: Option<&PathBuf>,
) -> Result<Vec<PlaylistEntry>, String> {
    let entries = playlist::parse_playlist_file(path.clone(), progress.clone())?;
    let missing = u32::try_from(entries.len()).unwrap_or(u32::MAX) < listed_in_playlist(&path);
    match hvsc_root {
        Some(root) if missing => {
            let from_root =
                playlist::parse_playlist_file_with_base(path, root.clone(), progress.clone())?;
            Ok(if from_root.len() > entries.len() { from_root } else { entries })
        }
        _ => Ok(entries),
    }
}

/// How many tunes a playlist file names, whether they exist or not.
fn listed_in_playlist(path: &Path) -> u32 {
    let Ok(content) = std::fs::read_to_string(path) else {
        return 0;
    };
    let is_pls = path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("pls"));
    let count = if is_pls {
        content
            .lines()
            .filter(|l| {
                let l = l.trim().to_ascii_lowercase();
                l.starts_with("file") && l.contains('=')
            })
            .count()
    } else {
        playlist::parse_m3u_preview(&content).len()
    };
    u32::try_from(count).unwrap_or(u32::MAX)
}

/// The tunes behind dropped paths, without touching any list.
#[derive(Debug, Default, PartialEq)]
pub(crate) struct ResolvedTunes {
    /// Each tune's file once, in order.
    pub files: Vec<PathBuf>,
    /// Tunes that loaded, repeats included, to set against `listed`.
    pub found: u32,
    /// Tunes asked for: a playlist's lines, a folder's playable files.
    pub listed: u32,
}

/// Expand files, folders and playlists as a drop into My Playlist does,
/// and report what they came to instead of adding it.
pub(crate) fn resolve_tunes(paths: Vec<PathBuf>, hvsc_root: Option<PathBuf>) -> ResolvedTunes {
    let progress = LoadingProgress::default();
    let mut resolved = ResolvedTunes::default();
    let mut seen = HashSet::new();
    for path in paths {
        let listed = if path.is_dir() {
            None
        } else if is_playlist_file(&path) {
            Some(listed_in_playlist(&path))
        } else {
            Some(1)
        };
        let entries = parse_paths(vec![path], &progress, hvsc_root.clone());
        let found = u32::try_from(entries.len()).unwrap_or(u32::MAX);
        resolved.found = resolved.found.saturating_add(found);
        resolved.listed = resolved.listed.saturating_add(listed.unwrap_or(found));
        for entry in entries {
            if seen.insert(entry.path.clone()) {
                resolved.files.push(entry.path);
            }
        }
    }
    resolved
}

/// A random HVSC tune, parsed. A file that won't parse is skipped for
/// another pick rather than ending the radio.
fn pick_tune(
    library: &Library,
    mut exclude: HashSet<PathBuf>,
) -> Result<Option<PlaylistEntry>, String> {
    for _ in 0..5 {
        let path = match library.pick_blocking(&exclude) {
            Ok(Some(path)) => path,
            Ok(None) => return Ok(None),
            Err(LibraryError::NoRoot) => return Err("Choose your HVSC folder in Settings.".into()),
            Err(LibraryError::NotFound(m) | LibraryError::Io(m)) => return Err(m),
        };
        match PlaylistEntry::from_path(&path) {
            Ok(entry) => return Ok(Some(entry)),
            Err(e) => {
                eprintln!("[resonance] surprise: skipping {}: {e}", path.display());
                exclude.insert(path);
            }
        }
    }
    Ok(None)
}

/// Shuffle Collection's next tune, parsed: the last of `order`, which is
/// refilled with a new shuffle of every indexed tune when it runs out (at
/// the start, and once all of HVSC has played). Files that won't parse are
/// skipped.
fn next_in_order(
    library: &Library,
    order: &mut Vec<PathBuf>,
) -> Result<Option<PlaylistEntry>, String> {
    for _ in 0..8 {
        if order.is_empty() {
            *order = library
                .shuffled_paths()
                .map_err(|e| match e {
                    LibraryError::NoRoot => "Choose your HVSC folder in Settings.".to_string(),
                    LibraryError::NotFound(m) | LibraryError::Io(m) => m,
                })?;
            if order.is_empty() {
                return Err("The collection isn't indexed yet. Try again in a moment.".into());
            }
        }
        let Some(path) = order.pop() else { break };
        match PlaylistEntry::from_path(&path) {
            Ok(entry) => return Ok(Some(entry)),
            Err(e) => eprintln!("[resonance] shuffle: skipping {}: {e}", path.display()),
        }
    }
    Ok(None)
}

fn is_playlist_file(path: &Path) -> bool {
    path.extension().and_then(|e| e.to_str()).is_some_and(|e| {
        ["m3u", "m3u8", "pls"]
            .iter()
            .any(|x| e.eq_ignore_ascii_case(x))
    })
}

/// Upstream's progress text without the "⏳" its Iced UI shows: the app
/// draws its own spinner.
fn progress_text(raw: &str) -> String {
    raw.trim_start_matches('⏳').trim().to_string()
}

fn set_progress(progress: &LoadingProgress, text: &str) {
    if let Ok(mut p) = progress.lock() {
        text.clone_into(&mut p);
    }
}

// ── Session thread ───────────────────────────────────────────────────────────

struct Player {
    commands: Sender<PlayerCmd>,
    statuses: Receiver<PlayerStatus>,
    device_events: Receiver<player::DeviceConfigEvent>,
    /// The pull-driven player's seek side; upstream's has none.
    seeker: Option<residfp_player::Seeker>,
}

impl Player {
    fn seeking(&self) -> bool {
        self.seeker
            .as_ref()
            .is_some_and(|s| s.seeking.load(std::sync::atomic::Ordering::Relaxed))
    }

    fn seek_position(&self) -> Option<Duration> {
        let seeker = self.seeker.as_ref().filter(|_| self.seeking())?;
        Some(Duration::from_millis(
            seeker.position_ms.load(std::sync::atomic::Ordering::Relaxed),
        ))
    }
}

/// Upstream's player thread for its engines; the reSIDfp player for
/// `Engine::ReSidFp`, which writes the visualizer feed itself. The bridge
/// mode argument is ignored: without the `usb` feature no USB engine
/// exists to consult it.
fn spawn_player(engine: Engine, viz: &SharedFeed) -> Player {
    let (commands, statuses, device_events, seeker) = if engine.is_pull_driven() {
        let (c, s, d, seeker) = residfp_player::spawn(viz.clone(), engine);
        (c, s, d, Some(seeker))
    } else {
        let (c, s, d) = player::spawn_player(
            engine.as_engine_name().to_string(),
            String::new(),
            String::new(),
            "bridge".to_string(),
        );
        (c, s, d, None)
    };
    Player {
        commands,
        statuses,
        device_events,
        seeker,
    }
}

struct State {
    session: Session,
    player: Player,
    loader: Sender<Job>,
    progress: LoadingProgress,
    session_path: PathBuf,
    /// False until the saved session has been restored — saving before that
    /// would overwrite it with an empty or partial playlist.
    session_loaded: bool,
    saved_revision: u64,
    dirty_since: Option<Instant>,
    error: Option<String>,
    published_playlist: (u64, Arc<Vec<PlaylistEntry>>),
    databases: SharedDatabases,
    viz: VizCapture,
    analyzer: Analyzer,
}

fn run(
    start: StartConfig,
    commands: Receiver<Command>,
    out: Arc<Mutex<Arc<Published>>>,
    viz: VizCapture,
) {
    let now = Instant::now();
    audio_volume::set(start.volume);

    let player = spawn_player(start.engine, viz.feed());
    let mut session = Session::new(
        player.commands.clone(),
        start.options,
        start.engine,
        start.hvsc_root,
        now,
    );
    session.records_history = true;
    session.set_shuffle(start.shuffle);
    session.set_repeat(start.repeat);
    session.set_learned(start.learned.clone());
    let (learned_tx, learned_rx) = unbounded();

    let progress = LoadingProgress::default();
    let (loader, loaded) = spawn_loader(progress.clone(), start.library);
    // FIFO: the songlengths land before any file the user adds, so a default
    // length can't claim tunes the database knows.
    let _ = loader.send(Job::Databases);
    let _ = loader.send(Job::RestoreSession(start.session_path.clone()));

    let mut st = State {
        session,
        player,
        loader,
        progress,
        session_path: start.session_path,
        session_loaded: false,
        saved_revision: 0,
        dirty_since: None,
        error: None,
        published_playlist: (u64::MAX, Arc::new(Vec::new())),
        databases: start.databases,
        viz,
        analyzer: Analyzer::new(start.learned, learned_tx),
    };

    loop {
        let wait = if st.session.status.state == PlayState::Playing {
            TICK_PLAYING
        } else {
            TICK_IDLE
        };
        let statuses = st.player.statuses.clone();
        let step = catch_unwind(AssertUnwindSafe(|| -> bool {
            select! {
                recv(commands) -> msg => match msg {
                    Ok(Command::Shutdown(ack)) => {
                        st.shutdown();
                        let _ = ack.send(());
                        return false;
                    }
                    Ok(cmd) => st.handle(cmd),
                    // Every PlayerCore handle is gone.
                    Err(_) => {
                        st.shutdown();
                        return false;
                    }
                },
                recv(statuses) -> msg => match msg {
                    Ok(first) => st.ingest(first),
                    Err(_) => st.respawn_player(),
                },
                recv(loaded) -> msg => {
                    if let Ok(result) = msg {
                        st.apply_loaded(result);
                        st.analyze_new_tunes();
                    }
                }
                recv(learned_rx) -> msg => {
                    if let Ok(md5) = msg {
                        st.session.learned_length_arrived(&md5);
                    }
                }
                default(wait) => {}
            }
            let now = Instant::now();
            // Device-config replies only come from USB engines; drop them.
            for _ in st.player.device_events.try_iter() {}
            if st.player.seeking() {
                // Silent on purpose: no writes reach the chips meanwhile.
                st.session.hold_silence(now);
            }
            st.session.tick(now);
            if let Some(request) = st.session.take_radio_request() {
                let _ = st.loader.send(Job::Pick {
                    kind: request.kind,
                    exclude: request.exclude,
                    first: request.first,
                });
            }
            st.maybe_save(now);
            true
        }));
        match step {
            Ok(true) => {}
            Ok(false) => break,
            Err(panic) => {
                let msg = panic
                    .downcast_ref::<String>()
                    .cloned()
                    .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                    .unwrap_or_else(|| "unknown panic".into());
                eprintln!("[resonance] session step panicked: {msg}");
                st.error = Some(format!("Internal error: {msg}"));
            }
        }
        st.publish(&out);
    }
    st.publish(&out);
}

impl State {
    fn handle(&mut self, cmd: Command) {
        let now = Instant::now();
        // A new action supersedes the previous loader / internal error, and
        // the session's note about a failed load.
        self.error = None;
        self.session.notice = None;
        let s = &mut self.session;
        match cmd {
            Command::AddPaths { paths, play_first } => {
                let _ = self.loader.send(Job::Paths { paths, play_first });
            }
            Command::Remove(indices) => s.remove(indices),
            Command::Move { from, to } => s.move_entries(from, to),
            Command::Clear => s.clear(),
            Command::PlayQueue { paths, start } => {
                let _ = self.loader.send(Job::Queue { paths, start });
            }
            Command::PlayIndex(i) => s.play_index(i, now),
            Command::Surprise => s.surprise(),
            Command::ShuffleCollection => s.shuffle_collection(),
            Command::PlayPause { fallback } => s.play_pause(fallback, now),
            Command::Stop => s.stop(),
            Command::Next => s.next(now),
            Command::Previous => s.previous(now),
            Command::SetSubtune(song) => s.set_subtune(song, now),
            Command::NextSubtune => s.next_subtune(now),
            Command::PrevSubtune => s.prev_subtune(now),
            Command::SetShuffle(on) => s.set_shuffle(on),
            Command::SetRepeat(mode) => s.set_repeat(mode),
            Command::SetEngine(engine) if engine.is_pull_driven() != s.engine.is_pull_driven() => {
                self.swap_player(engine, now)
            }
            Command::SetEngine(engine) => s.set_engine(engine, now),
            Command::Seek(target) => {
                if let Some(seeker) = &self.player.seeker {
                    // Short of the end by a second, so the last second plays
                    // before the session advances.
                    let end = s
                        .current_entry()
                        .and_then(|e| e.duration_secs)
                        .map(|d| Duration::from_secs(u64::from(d)).saturating_sub(Duration::from_secs(1)));
                    let target = end.map_or(target, |end| target.min(end));
                    let _ = seeker.targets.try_send(target);
                }
            }
            Command::SetOptions(options) => s.set_options(options, now),
            Command::SetHvscRoot(root) => s.set_hvsc_root(root),
            Command::Shutdown(_) => unreachable!("handled by the loop"),
        }
    }

    fn ingest(&mut self, first: PlayerStatus) {
        let rest: Vec<_> = self.player.statuses.try_iter().collect();
        let now = Instant::now();
        // Every status, not just the latest: each carries one frame. The
        // reSIDfp player feeds the visualizers itself.
        if !self.session.engine.is_pull_driven() {
            for status in std::iter::once(&first).chain(&rest) {
                self.viz.ingest(status, now);
            }
        }
        self.session
            .ingest_statuses(std::iter::once(first).chain(rest), now);
    }

    /// Switch between upstream's player thread and the reSIDfp one: end
    /// the old thread, start the new, and let the session resume on it.
    fn swap_player(&mut self, engine: Engine, now: Instant) {
        let _ = self.player.commands.try_send(PlayerCmd::Stop);
        let _ = self.player.commands.try_send(PlayerCmd::Quit);
        self.viz.reset();
        self.player = spawn_player(engine, self.viz.feed());
        self.session
            .switch_player(self.player.commands.clone(), engine, now);
    }

    fn apply_loaded(&mut self, result: Loaded) {
        let now = Instant::now();
        match result {
            Loaded::Databases(db) => {
                if let Some(songlengths) = &db.songlengths {
                    self.session.set_songlength_db(songlengths.clone());
                }
                databases::install(&self.databases, *db);
            }
            Loaded::SessionRestored(entries) => {
                // Restored entries go first, ahead of anything the user added
                // while the restore was running (those are queued behind it).
                self.session.add_entries(entries, false, now);
                self.session_loaded = true;
                self.saved_revision = self.session.playlist_revision;
            }
            Loaded::Entries {
                entries,
                play_first,
            } => {
                if entries.is_empty() {
                    self.error = Some("No playable SID files found.".into());
                }
                self.session.add_entries(entries, play_first, now);
            }
            Loaded::Queue { entries, start } => {
                if entries.is_empty() {
                    self.error = Some("No playable SID files found.".into());
                }
                self.session.play_queue(entries, &start, now);
            }
            Loaded::Picked(kind, result) => {
                let pick = result.unwrap_or_else(|e| {
                    self.error = Some(e);
                    None
                });
                self.session.radio_picked(kind, pick, now);
            }
        }
    }

    /// Have the lengths worked out of whatever just landed in the lists.
    fn analyze_new_tunes(&mut self) {
        for (job, playing) in self.session.tunes_to_analyze() {
            self.analyzer.request(job, playing);
        }
    }

    /// The player thread died (its status channel disconnected): start a
    /// fresh one on the same engine so the app keeps working.
    fn respawn_player(&mut self) {
        eprintln!("[resonance] player thread exited — restarting it");
        self.player = spawn_player(self.session.engine, self.viz.feed());
        self.session.set_player(self.player.commands.clone());
        self.error = Some("The player stopped unexpectedly and was restarted.".into());
    }

    /// Debounced autosave (main.rs `maybe_save_session`).
    fn maybe_save(&mut self, now: Instant) {
        if !self.session_loaded || self.session.playlist_revision == self.saved_revision {
            self.dirty_since = None;
            return;
        }
        let since = *self.dirty_since.get_or_insert(now);
        if now.duration_since(since) >= SAVE_DELAY {
            self.save();
        }
    }

    fn save(&mut self) {
        if let Err(e) = persist::save(&self.session.playlist, &self.session_path) {
            eprintln!("[resonance] session save failed: {e}");
        }
        self.saved_revision = self.session.playlist_revision;
        self.dirty_since = None;
    }

    /// main.rs `Drop for App`: save, stop, give the stop a moment to reach
    /// the device, then end the player thread.
    fn shutdown(&mut self) {
        if self.session_loaded && self.session.playlist_revision != self.saved_revision {
            self.save();
        }
        let _ = self.player.commands.try_send(PlayerCmd::Stop);
        thread::sleep(Duration::from_millis(100));
        let _ = self.player.commands.try_send(PlayerCmd::Quit);
    }

    fn publish(&mut self, out: &Mutex<Arc<Published>>) {
        let s = &self.session;
        if self.published_playlist.0 != s.playlist_revision {
            self.published_playlist = (s.playlist_revision, Arc::new(s.playlist.entries.clone()));
        }
        let loading = self
            .progress
            .lock()
            .ok()
            .map(|p| progress_text(&p))
            .filter(|p| !p.is_empty());
        let published = Published {
            session: SessionView {
                status: s.status.clone(),
                current: s.playlist_current(),
                current_duration_secs: s.current_entry().and_then(|e| e.duration_secs),
                current_duration_is_estimate: s.current_length_is_estimate(),
                queue_active: s.queue_active(),
                surprise_active: s.radio_active(),
                shuffle_collection_active: s.shuffle_collection_active(),
                shuffle: s.playlist.shuffle,
                repeat: s.playlist.repeat,
                engine: s.engine,
                can_seek: self.player.seeker.is_some(),
                seeking: self.player.seeking(),
                seek_position: self.player.seek_position(),
                playlist_revision: s.playlist_revision,
                track_revision: s.track_revision,
            },
            playlist: self.published_playlist.1.clone(),
            loading,
            error: self
                .error
                .clone()
                .or_else(|| s.notice.clone())
                .or_else(|| s.status.error.clone()),
        };
        if let Ok(mut slot) = out.lock() {
            *slot = Arc::new(published);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{progress_text, resolve_tunes};
    use std::path::{Path, PathBuf};

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "resonance-resolve-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A minimal PSID v2 file.
    fn write_sid(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut h = vec![0u8; 0x7C];
        h[0..4].copy_from_slice(b"PSID");
        h[4..6].copy_from_slice(&2u16.to_be_bytes());
        h[6..8].copy_from_slice(&0x7Cu16.to_be_bytes());
        h[8..10].copy_from_slice(&0x1000u16.to_be_bytes());
        h[10..12].copy_from_slice(&0x1000u16.to_be_bytes());
        h[12..14].copy_from_slice(&0x1003u16.to_be_bytes());
        h[14..16].copy_from_slice(&1u16.to_be_bytes());
        h[16..18].copy_from_slice(&1u16.to_be_bytes());
        h.extend_from_slice(&[0x60, 0x60, 0x60, 0x60]);
        std::fs::write(path, h).unwrap();
    }

    #[test]
    fn a_playlist_of_collection_paths_resolves_against_the_collection() {
        let root = temp_dir("root");
        let tune = root.join("MUSICIANS/A/Ann/One.sid");
        write_sid(&tune);
        let elsewhere = temp_dir("elsewhere");
        let list = elsewhere.join("List.m3u");
        std::fs::write(
            &list,
            "#EXTM3U\nMUSICIANS/A/Ann/One.sid\nMUSICIANS/A/Ann/Gone.sid\nMUSICIANS/A/Ann/One.sid\n",
        )
        .unwrap();

        let resolved = resolve_tunes(vec![list.clone()], Some(root.clone()));
        assert_eq!(resolved.files, vec![tune], "each file once");
        assert_eq!(resolved.found, 2, "repeats count as found");
        assert_eq!(resolved.listed, 3, "the missing line counts as listed");

        let without_root = resolve_tunes(vec![list], None);
        assert!(without_root.files.is_empty());
        assert_eq!(without_root.listed, 3);
    }

    #[test]
    fn an_exported_playlist_mixing_full_and_collection_paths_finds_both() {
        let root = temp_dir("mixed-root");
        let inside = root.join("MUSICIANS/A/Ann/One.sid");
        write_sid(&inside);
        let elsewhere = temp_dir("mixed-elsewhere");
        let outside = elsewhere.join("Mine.sid");
        write_sid(&outside);
        let list = elsewhere.join("Export.m3u");
        std::fs::write(
            &list,
            format!("#EXTM3U\nMUSICIANS/A/Ann/One.sid\n{}\n", outside.display()),
        )
        .unwrap();

        let resolved = resolve_tunes(vec![list], Some(root));
        assert_eq!(resolved.files, vec![inside, outside]);
        assert_eq!(resolved.found, 2);
        assert_eq!(resolved.listed, 2);
    }

    #[test]
    fn loose_files_and_folders_count_what_they_hold() {
        let dir = temp_dir("loose");
        let inside = dir.join("Folder/Two.sid");
        write_sid(&inside);
        let not_a_tune = dir.join("Notes.sid");
        std::fs::write(&not_a_tune, "not a tune").unwrap();

        let resolved = resolve_tunes(vec![dir.join("Folder"), not_a_tune], None);
        assert_eq!(resolved.files, vec![inside]);
        assert_eq!(resolved.found, 1);
        assert_eq!(resolved.listed, 2, "the bad file was asked for and didn't load");
    }

    #[test]
    fn progress_text_drops_upstreams_hourglass() {
        assert_eq!(
            progress_text("⏳ Adding files: 3 / 9"),
            "Adding files: 3 / 9"
        );
        assert_eq!(progress_text("Picking a surprise…"), "Picking a surprise…");
        assert_eq!(progress_text(""), "");
    }
}
