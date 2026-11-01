//! The session's home thread.
//!
//! One thread owns the `Session` and serialises everything that touches it —
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

use crate::databases::{self, Databases, SharedDatabases, StilNotes};
use crate::library::{Library, LibraryError};
use crate::player::{self, PlayState, PlayerCmd, PlayerStatus};
use crate::playlist::{self, LoadingProgress, PlaylistEntry, RepeatMode};
use crate::session::{persist, Engine, Options, Session};
use crate::{audio_volume, config};

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
    /// STIL on the playing tune's current subtune.
    pub stil: Option<StilNotes>,
}

/// The parts of `Session` the FFI layer turns into records.
#[derive(Clone)]
pub(crate) struct SessionView {
    pub status: PlayerStatus,
    /// Playlist row that's playing; None while the queue plays.
    pub current: Option<usize>,
    /// Length of the playing subtune, from whichever list it's in.
    pub current_duration_secs: Option<u32>,
    pub queue_active: bool,
    /// The queue is Surprise Me's radio.
    pub surprise_active: bool,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    pub engine: Engine,
    pub playlist_revision: u64,
    pub track_revision: u64,
    /// Bumped per player status, so the visualizer can tell new frames apart.
    pub status_seq: u64,
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
}

pub(crate) struct Driver {
    pub commands: Sender<Command>,
    pub published: Arc<Mutex<Arc<Published>>>,
}

impl Driver {
    pub fn start(start: StartConfig) -> Self {
        let (cmd_tx, cmd_rx) = unbounded();
        let published = Arc::new(Mutex::new(Arc::new(Published {
            session: SessionView {
                status: PlayerStatus::default(),
                current: None,
                current_duration_secs: None,
                queue_active: false,
                surprise_active: false,
                shuffle: start.shuffle,
                repeat: start.repeat,
                engine: start.engine,
                playlist_revision: 0,
                track_revision: 0,
                status_seq: 0,
            },
            playlist: Arc::new(Vec::new()),
            loading: None,
            error: None,
            stil: None,
        })));
        let out = published.clone();
        thread::Builder::new()
            .name("resonance-session".into())
            .spawn(move || run(start, cmd_rx, out))
            .expect("failed to spawn the session thread");
        Self {
            commands: cmd_tx,
            published,
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
    /// A random tune for Surprise Me, not one of `exclude`.
    Pick {
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
    Picked(Result<Option<PlaylistEntry>, String>),
}

fn spawn_loader(progress: LoadingProgress, library: Library) -> (Sender<Job>, Receiver<Loaded>) {
    let (job_tx, job_rx) = unbounded::<Job>();
    let (done_tx, done_rx) = unbounded();
    thread::Builder::new()
        .name("resonance-loader".into())
        .spawn(move || {
            for job in job_rx.iter() {
                let result = match job {
                    Job::Databases => {
                        // Read-only: Resonance never writes Phosphor's config.json.
                        Loaded::Databases(Box::new(Databases::load(&config::Config::load())))
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
                        entries: parse_paths(paths, &progress),
                        play_first,
                    },
                    // Nothing is added, so no "Adding files" progress: a
                    // private counter keeps it out of the UI.
                    Job::Queue { paths, start } => Loaded::Queue {
                        entries: playlist::parse_files(paths, LoadingProgress::default()),
                        start,
                    },
                    Job::Pick { exclude, first } => {
                        if first {
                            set_progress(&progress, "Picking a surprise…");
                        }
                        Loaded::Picked(pick_tune(&library, exclude))
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
fn parse_paths(paths: Vec<PathBuf>, progress: &LoadingProgress) -> Vec<PlaylistEntry> {
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
            match playlist::parse_playlist_file(path, progress.clone()) {
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
}

/// The bridge mode argument is ignored: without the `usb` feature no USB
/// engine exists to consult it.
fn spawn_player(engine: Engine) -> Player {
    let (commands, statuses, device_events) = player::spawn_player(
        engine.as_engine_name().to_string(),
        String::new(),
        String::new(),
        "bridge".to_string(),
    );
    Player {
        commands,
        statuses,
        device_events,
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
    status_seq: u64,
    error: Option<String>,
    published_playlist: (u64, Arc<Vec<PlaylistEntry>>),
    databases: SharedDatabases,
    /// STIL keyed by the (path, subtune) it was looked up for.
    published_stil: Option<((PathBuf, u16), Option<StilNotes>)>,
}

fn run(start: StartConfig, commands: Receiver<Command>, out: Arc<Mutex<Arc<Published>>>) {
    let now = Instant::now();
    audio_volume::set(start.volume);

    let player = spawn_player(start.engine);
    let mut session = Session::new(
        player.commands.clone(),
        start.options,
        start.engine,
        start.hvsc_root,
        now,
    );
    session.set_shuffle(start.shuffle);
    session.set_repeat(start.repeat);

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
        status_seq: 0,
        error: None,
        published_playlist: (u64::MAX, Arc::new(Vec::new())),
        databases: start.databases,
        published_stil: None,
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
                    }
                }
                default(wait) => {}
            }
            let now = Instant::now();
            // Device-config replies only come from USB engines; drop them.
            for _ in st.player.device_events.try_iter() {}
            st.session.tick(now);
            if let Some(request) = st.session.take_radio_request() {
                let _ = st.loader.send(Job::Pick {
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
        // A new action supersedes the previous loader / internal error.
        self.error = None;
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
            Command::PlayPause { fallback } => s.play_pause(fallback, now),
            Command::Stop => s.stop(),
            Command::Next => s.next(now),
            Command::Previous => s.previous(now),
            Command::SetSubtune(song) => s.set_subtune(song, now),
            Command::NextSubtune => s.next_subtune(now),
            Command::PrevSubtune => s.prev_subtune(now),
            Command::SetShuffle(on) => s.set_shuffle(on),
            Command::SetRepeat(mode) => s.set_repeat(mode),
            Command::SetEngine(engine) => s.set_engine(engine, now),
            Command::SetOptions(options) => s.set_options(options, now),
            Command::SetHvscRoot(root) => {
                s.set_hvsc_root(root);
                self.published_stil = None;
            }
            Command::Shutdown(_) => unreachable!("handled by the loop"),
        }
    }

    fn ingest(&mut self, first: PlayerStatus) {
        let rest: Vec<_> = self.player.statuses.try_iter().collect();
        self.status_seq += 1 + rest.len() as u64;
        self.session
            .ingest_statuses(std::iter::once(first).chain(rest), Instant::now());
    }

    fn apply_loaded(&mut self, result: Loaded) {
        let now = Instant::now();
        match result {
            Loaded::Databases(db) => {
                if let Some(songlengths) = &db.songlengths {
                    self.session.set_songlength_db(songlengths.clone());
                }
                databases::install(&self.databases, *db);
                self.published_stil = None;
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
            Loaded::Picked(result) => {
                let pick = result.unwrap_or_else(|e| {
                    self.error = Some(e);
                    None
                });
                self.session.radio_picked(pick, now);
            }
        }
    }

    /// The player thread died (its status channel disconnected): start a
    /// fresh one on the same engine so the app keeps working.
    fn respawn_player(&mut self) {
        eprintln!("[resonance] player thread exited — restarting it");
        self.player = spawn_player(self.session.engine);
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

    /// STIL on what's playing, looked up again only when the tune or
    /// subtune changes.
    fn current_stil(&mut self) -> Option<StilNotes> {
        let info = self.session.status.track_info.as_ref()?;
        let key = (info.path.clone(), info.current_song);
        if let Some((cached_key, notes)) = &self.published_stil {
            if *cached_key == key {
                return notes.clone();
            }
        }
        let db = databases::current(&self.databases);
        let notes = db.stil_notes(&key.0, self.session.hvsc_root(), key.1);
        self.published_stil = Some((key, notes.clone()));
        notes
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
        let stil = self.current_stil();
        let s = &self.session;
        let published = Published {
            session: SessionView {
                status: s.status.clone(),
                current: s.playlist_current(),
                current_duration_secs: s.current_entry().and_then(|e| e.duration_secs),
                queue_active: s.queue_active(),
                surprise_active: s.radio_active(),
                shuffle: s.playlist.shuffle,
                repeat: s.playlist.repeat,
                engine: s.engine,
                playlist_revision: s.playlist_revision,
                track_revision: s.track_revision,
                status_seq: self.status_seq,
            },
            playlist: self.published_playlist.1.clone(),
            loading,
            error: self.error.clone().or_else(|| s.status.error.clone()),
            stil,
        };
        if let Ok(mut slot) = out.lock() {
            *slot = Arc::new(published);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::progress_text;

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
