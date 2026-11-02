//! The UniFFI surface Swift sees.
//!
//! Playback methods are non-blocking: commands are queued to the session
//! thread and reads clone the latest published read model. Swift polls
//! `snapshot()` (cheap), refetches `playlist()` when `playlist_revision`
//! changes, and reads `viz_frame()` once per display frame.
//!
//! The HVSC library methods are `async` (Swift `await`s them): they list
//! folders, read SID headers or build a search index, on tokio's blocking
//! pool.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crossbeam_channel::bounded;

use crate::databases;
use crate::driver::{Command, Driver, Published, StartConfig};
use crate::hvsc_browser::{self, HvscAuthor, HvscIndexEntry, HvscTune};
use crate::hvsc_info::{self, HvscInfo};
use crate::hvsc_sync::{self, HvscSyncEvent, HvscSyncHandle};
use crate::library::{Library, LibraryError};
use crate::player::pseudo_stereo::DetuneStrength;
use crate::player::{PlayState, TrackInfo};
use crate::playlist::{PlaylistEntry, RepeatMode};
use crate::session;
use crate::viz;

// ── Records and enums ────────────────────────────────────────────────────────

/// Software SID engines. USB and Ultimate 64 aren't part of this build.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Engine {
    /// libsidplayfp's SIDLite — picks the chip model from the tune header.
    SidLite,
    /// resid-rs emulation.
    ReSid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Repeat {
    Off,
    All,
    One,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PseudoStereo {
    Subtle,
    Medium,
    Wide,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlaybackState {
    Stopped,
    Playing,
    Paused,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PlaybackOptions {
    /// Skip RSID tunes (they need a full C64 and some don't play right).
    pub skip_rsid: bool,
    /// Length used when the Songlengths database has no entry; 0 = none
    /// (such tunes then end on silence).
    pub default_song_length_secs: u32,
    /// Play 2SID tunes mirrored to both channels.
    pub force_stereo_2sid: bool,
    /// Widen mono tunes by detuning a mirrored second SID; `None` = off.
    pub pseudo_stereo: Option<PseudoStereo>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CoreConfig {
    pub engine: Engine,
    /// Master volume, 0.0–1.0.
    pub volume: f32,
    pub options: PlaybackOptions,
    pub shuffle: bool,
    pub repeat: Repeat,
    /// Where the playlist is saved between launches.
    pub session_path: String,
    /// The HVSC collection's root folder (the one holding MUSICIANS/).
    pub hvsc_root: Option<String>,
}

/// Settings read from the Iced Phosphor app's config.json, for a one-time
/// "import from Phosphor".
#[derive(Debug, Clone, uniffi::Record)]
pub struct SharedDefaults {
    pub engine: Engine,
    pub volume: f32,
    pub options: PlaybackOptions,
    /// The HVSC folder, if Phosphor has one configured or synced.
    pub hvsc_root: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PlaylistItem {
    /// Absolute file path; unique within the playlist, so it doubles as the
    /// row identity.
    pub path: String,
    pub title: String,
    pub author: String,
    pub released: String,
    pub songs: u16,
    /// 1-based subtune that plays when the row is started.
    pub selected_song: u16,
    /// Length of the selected subtune, if known.
    pub duration_secs: Option<u32>,
    pub is_rsid: bool,
    pub is_pal: bool,
    pub num_sids: u32,
    pub md5: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TrackDetails {
    pub path: String,
    pub title: String,
    pub author: String,
    pub released: String,
    pub songs: u16,
    /// 1-based.
    pub current_song: u16,
    pub is_pal: bool,
    pub is_rsid: bool,
    pub num_sids: u32,
    /// "PSID" / "RSID" / "MUS".
    pub sid_type: String,
    /// From the file header: 0 unknown, 1 6581, 2 8580, 3 either.
    pub sid_model: u8,
    pub md5: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Snapshot {
    pub state: PlaybackState,
    /// Playlist row of the current track; None while a queue plays.
    pub current_index: Option<u32>,
    /// Playing from a temporary list (`play_queue`) rather than the playlist.
    pub queue_active: bool,
    /// That list is Surprise Me's radio (`surprise_me`).
    pub surprise_active: bool,
    /// That list is Shuffle Collection (`shuffle_collection`).
    pub shuffle_collection_active: bool,
    /// What the player reports it's playing.
    pub track: Option<TrackDetails>,
    pub elapsed_ms: u64,
    /// Length of the current subtune, if known.
    pub duration_ms: Option<u64>,
    pub shuffle: bool,
    pub repeat: Repeat,
    pub engine: Engine,
    /// Changes whenever `playlist()` would return something different.
    pub playlist_revision: u64,
    /// Changes on every track or subtune switch.
    pub track_revision: u64,
    /// Background loading progress, when files are being read.
    pub loading: Option<String>,
    pub error: Option<String>,
    /// HVSC categories whose search index is being built.
    pub hvsc_indexing: Vec<HvscCategory>,
    /// Changes when the collection folder changes on disk (a new root,
    /// or the first sync filling the current one); the app drops its
    /// cached lists on a change.
    pub hvsc_tree_revision: u64,
}

/// The HVSC collection's download: one archive, then extraction. `current`
/// is ready to show; the byte and file counters fill a progress bar (bytes
/// while the archive streams, files while it extracts — zero before their
/// phase).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HvscSyncStatus {
    /// Where the collection is being downloaded.
    pub root: String,
    /// False once the download has ended, success or failure.
    pub running: bool,
    /// Set when the download failed or was cancelled.
    pub error: Option<String>,
    pub current: String,
    /// Archive entries extracted, including those skipped as already
    /// present; `0` while the archive still downloads.
    pub files_done: u32,
    pub files_total: u32,
    /// Archive bytes received; `0` once extraction has started.
    pub bytes_done: u64,
    /// What the server announced; `0` when it didn't.
    pub bytes_total: u64,
}

/// One SID voice at the end of a player frame.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct VizVoice {
    /// The 16-bit frequency register.
    pub freq_reg: u16,
    pub hz: f64,
    /// Fractional MIDI note number (69 is A4); 0 while the frequency is 0.
    pub midi: f64,
    /// The nearest note, e.g. "C#4"; None while the frequency is 0. Set
    /// whether or not the gate is: a released note still sounds.
    pub note: Option<String>,
    pub gate: bool,
    /// The control register's high nibble: 1 triangle, 2 saw, 4 pulse, 8 noise.
    pub waveform: u8,
    pub test: bool,
    pub ring: bool,
    pub sync: bool,
    /// 12-bit.
    pub pulse_width: u16,
    pub attack: u8,
    pub decay: u8,
    pub sustain: u8,
    pub release: u8,
    /// The envelope, 0.0–1.0, from the visualizers' own reSID.
    pub env_level: f32,
    pub env_phase: EnvelopePhase,
}

/// Which part of its ADSR envelope a voice is in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EnvelopePhase {
    Attack,
    Decay,
    /// Holding at the sustain level until the gate closes.
    Sustain,
    /// Fading after the gate closed; also a voice that has gone silent.
    Release,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct VizChip {
    /// Always three.
    pub voices: Vec<VizVoice>,
    /// $00–$1C. OSC3 and ENV3 ($1B, $1C) come from the visualizers' reSID.
    pub registers: Vec<u8>,
    /// 11-bit.
    pub cutoff: u16,
    pub resonance: u8,
    /// Which inputs go through the filter. Bits 0–3: voices 1–3, external.
    pub filter_routing: u8,
    /// Bits 0–3: low-pass, band-pass, high-pass, voice 3 off.
    pub filter_mode: u8,
    pub volume: u8,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct VizSidFrame {
    /// Frames since the subtune started.
    pub index: u64,
    pub is_pal: bool,
    /// One per SID chip, up to four.
    pub chips: Vec<VizChip>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct VizScope {
    pub sample_rate: f32,
    /// Three voices, each −1…1 (waveform × envelope), oldest sample first.
    pub voices: Vec<Vec<f32>>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct VizStats {
    /// Frames the visualizers' reSID has emulated this subtune.
    pub frames: u64,
    /// Moving average of its time per frame.
    pub shadow_micros: f32,
    /// How far the engine's audio buffer has the sound trailing the
    /// emulation right now: about 100 ms after a track starts, near 0 after
    /// a pause.
    pub buffer_ms: f32,
    /// The output device's latency, as last set.
    pub output_latency_ms: u32,
    pub offset_ms: i32,
}

/// The top-level HVSC folders.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum HvscCategory {
    Musicians,
    Games,
    Demos,
}

/// An author folder (MUSICIANS) or an alphabetical section (GAMES, DEMOS).
#[derive(Debug, Clone, uniffi::Record)]
pub struct HvscAuthorItem {
    /// Folder name, e.g. "Hubbard_Rob".
    pub name: String,
    /// e.g. "Hubbard, Rob".
    pub display_name: String,
    /// The letter folder it lives in ("0" for 0-9).
    pub letter: String,
    pub path: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HvscTuneItem {
    pub path: String,
    pub title: String,
    /// The author from the tune header, or in search results the folder it
    /// lives in.
    pub author: String,
    pub released: String,
    pub songs: u16,
    /// The tune's default subtune (1-based).
    pub start_song: u16,
    /// Length of the start subtune, if the Songlengths database knows it.
    pub duration_secs: Option<u32>,
    pub has_stil: bool,
    /// Unknown in search results (the index doesn't store it).
    pub is_rsid: Option<bool>,
    pub category: HvscCategory,
}

/// A bug HVSC's bugged-tunes list reports on a tune.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TuneBug {
    /// "Falls out of synch at 2:50."
    pub text: String,
    /// Who reported it.
    pub reporter: Option<String>,
    /// The subtune it's about, when the list names one.
    pub subtune: Option<u16>,
}

/// A tune from the play history shared with Phosphor.
#[derive(Debug, Clone, uniffi::Record)]
pub struct RecentTune {
    pub item: HvscTuneItem,
    /// Unix time (seconds) it last started playing.
    pub played_at: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HvscSearchResult {
    /// Best matches first, at most 500.
    pub items: Vec<HvscTuneItem>,
    /// All matches, including those past the cap.
    pub total_matches: u32,
    /// How many tunes were searched.
    pub indexed: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Error)]
pub enum HvscError {
    /// No HVSC folder is set.
    NoRoot,
    /// A category folder or path isn't in the collection.
    NotFound {
        message: String,
    },
    Io {
        message: String,
    },
}

impl std::fmt::Display for HvscError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HvscError::NoRoot => f.write_str("No HVSC folder is set."),
            HvscError::NotFound { message } | HvscError::Io { message } => f.write_str(message),
        }
    }
}

impl std::error::Error for HvscError {}

// ── PlayerCore ───────────────────────────────────────────────────────────────

/// The collection download's state, updated from the worker's events as the
/// app polls `hvsc_sync_status()`.
struct SyncState {
    /// Where the tree is landing.
    root: PathBuf,
    status: HvscSyncStatus,
    /// The post-sync refresh (index cache, library, databases) has run.
    settled: bool,
}

/// The player. Create one per app; it owns the engine, playlist and session
/// file until `shutdown()` (or until it's released).
#[derive(uniffi::Object)]
pub struct PlayerCore {
    driver: Driver,
    library: Library,
    databases: databases::SharedDatabases,
    /// The in-progress collection download; `None` once it has ended.
    sync: Mutex<Option<HvscSyncHandle>>,
    /// The last download's state; `None` until one has been started.
    sync_state: Mutex<Option<SyncState>>,
    /// The HVSC Home's parsed metadata, keyed by the tree revision the sync
    /// and root changes bump; one collection walk per revision.
    hvsc_info_cache: Mutex<Option<HvscInfoCache>>,
}

/// The collection metadata behind the key, cloned into the cache.
struct HvscInfoCache {
    root: PathBuf,
    tree_revision: u64,
    info: HvscInfo,
}

#[uniffi::export]
impl PlayerCore {
    #[uniffi::constructor]
    pub fn new(config: CoreConfig) -> Arc<Self> {
        let hvsc_root = config.hvsc_root.map(PathBuf::from);
        let databases = databases::shared();
        let library = Library::new(hvsc_root.clone(), databases.clone());
        let driver = Driver::start(StartConfig {
            engine: config.engine.into(),
            volume: config.volume,
            options: config.options.into(),
            shuffle: config.shuffle,
            repeat: config.repeat.into(),
            session_path: PathBuf::from(config.session_path),
            hvsc_root,
            databases: databases.clone(),
            library: library.clone(),
        });
        Arc::new(Self {
            driver,
            library,
            databases,
            sync: Mutex::new(None),
            sync_state: Mutex::new(None),
            hvsc_info_cache: Mutex::new(None),
        })
    }

    // ── Playlist ──

    /// Add files, folders (scanned recursively) and M3U/PLS playlists, in
    /// order. With `play_first`, playback starts at the first added tune.
    pub fn add_paths(&self, paths: Vec<String>, play_first: bool) {
        let paths = paths.into_iter().map(PathBuf::from).collect();
        self.send(Command::AddPaths { paths, play_first });
    }

    pub fn remove(&self, indices: Vec<u32>) {
        self.send(Command::Remove(to_usize(indices)));
    }

    /// Move rows like Swift's `move(fromOffsets:toOffset:)`.
    pub fn move_entries(&self, from: Vec<u32>, to: u32) {
        self.send(Command::Move {
            from: to_usize(from),
            to: to as usize,
        });
    }

    pub fn clear(&self) {
        self.send(Command::Clear);
    }

    // ── Transport ──

    /// Play SID files as a temporary list, starting at `start` (one of
    /// `paths`): Next, Previous and auto-advance stay inside it and the
    /// playlist isn't touched. Playing a playlist row ends it.
    pub fn play_queue(&self, paths: Vec<String>, start: String) {
        let paths = paths.into_iter().map(PathBuf::from).collect();
        self.send(Command::PlayQueue {
            paths,
            start: PathBuf::from(start),
        });
    }

    /// Play playlist row `index` (ends a playing queue).
    pub fn play_index(&self, index: u32) {
        self.send(Command::PlayIndex(index as usize));
    }

    /// Pause / resume; when stopped, play `fallback` (e.g. the selected row),
    /// else the current track, else the first.
    pub fn play_pause(&self, fallback: Option<u32>) {
        self.send(Command::PlayPause {
            fallback: fallback.map(|i| i as usize),
        });
    }

    pub fn stop(&self) {
        self.send(Command::Stop);
    }

    pub fn next(&self) {
        self.send(Command::Next);
    }

    /// Restarts the track when more than 3 s in, else goes to the previous one.
    pub fn previous(&self) {
        self.send(Command::Previous);
    }

    /// 1-based; clamped to the tune's subtune count.
    pub fn set_subtune(&self, song: u16) {
        self.send(Command::SetSubtune(song));
    }

    pub fn next_subtune(&self) {
        self.send(Command::NextSubtune);
    }

    pub fn prev_subtune(&self) {
        self.send(Command::PrevSubtune);
    }

    // ── Modes and settings ──

    pub fn set_shuffle(&self, on: bool) {
        self.send(Command::SetShuffle(on));
    }

    pub fn set_repeat(&self, repeat: Repeat) {
        self.send(Command::SetRepeat(repeat.into()));
    }

    /// Takes effect immediately; no round trip through the session thread.
    pub fn set_volume(&self, volume: f32) {
        crate::audio_volume::set(volume);
    }

    pub fn set_engine(&self, engine: Engine) {
        self.send(Command::SetEngine(engine.into()));
    }

    pub fn set_options(&self, options: PlaybackOptions) {
        self.send(Command::SetOptions(options.into()));
    }

    /// Switch to another HVSC folder (or none). Clears the library's lists
    /// and indexes.
    pub fn set_hvsc_root(&self, root: Option<String>) {
        let root = root.map(PathBuf::from);
        self.library.set_root(root.clone());
        self.send(Command::SetHvscRoot(root));
    }

    // ── Reads ──

    pub fn snapshot(&self) -> Snapshot {
        let p = self.published();
        let view = &p.session;
        let status = &view.status;
        let duration_ms = view.current_duration_secs.map(|s| u64::from(s) * 1000);
        Snapshot {
            state: status.state.clone().into(),
            current_index: view.current.map(|i| i as u32),
            queue_active: view.queue_active,
            surprise_active: view.surprise_active,
            shuffle_collection_active: view.shuffle_collection_active,
            track: status.track_info.as_ref().map(TrackDetails::from),
            elapsed_ms: status.elapsed.as_millis() as u64,
            duration_ms,
            shuffle: view.shuffle,
            repeat: view.repeat.into(),
            engine: view.engine.into(),
            playlist_revision: view.playlist_revision,
            track_revision: view.track_revision,
            loading: p.loading.clone(),
            error: p.error.clone(),
            hvsc_indexing: self
                .library
                .indexing()
                .into_iter()
                .map(Into::into)
                .collect(),
            hvsc_tree_revision: self.library.tree_revision(),
        }
    }

    // ── HVSC collection download ──
    //
    // The worker is upstream's `HvscSyncHandle`: one archive from the
    // mirror, extracted into the collection folder, re-runnable (files
    // already present at the same size are skipped). Events stream over a
    // channel the app drains at its snapshot rate.

    /// Begin downloading the collection. It lands in the current HVSC
    /// folder, or in Phosphor's default folder when none is set (creating
    /// it); `hvsc_sync_status()` reports where. Returns immediately.
    pub fn start_hvsc_sync(&self) -> Result<(), HvscError> {
        let state = self.sync_state.lock().unwrap();
        if state.as_ref().is_some_and(|s| s.status.running) {
            return Err(HvscError::Io {
                message: "A download is already running.".to_string(),
            });
        }
        drop(state);
        let root = self
            .library
            .root()
            .or_else(hvsc_sync::default_hvsc_root)
            .ok_or(HvscError::NoRoot)?;
        let url = sync_archive_url();
        let handle = hvsc_sync::HvscSyncHandle::start_from_zip(&url, &root)
            .map_err(|message| HvscError::Io { message })?;
        *self.sync.lock().unwrap() = Some(handle);
        *self.sync_state.lock().unwrap() = Some(SyncState {
            root: root.clone(),
            status: HvscSyncStatus {
                root: root.to_string_lossy().into_owned(),
                running: true,
                error: None,
                current: "Starting…".to_string(),
                files_done: 0,
                files_total: 0,
                bytes_done: 0,
                bytes_total: 0,
            },
            settled: false,
        });
        Ok(())
    }

    /// The latest status, or `None` when no download has been started this
    /// launch. Cheap; poll it like the snapshot.
    pub fn hvsc_sync_status(&self) -> Option<HvscSyncStatus> {
        let mut events = Vec::new();
        if let Some(handle) = self.sync.lock().unwrap().as_ref() {
            while let Ok(event) = handle.rx.try_recv() {
                events.push(event);
            }
        }
        let mut state = self.sync_state.lock().unwrap();
        if let Some(state) = state.as_mut().filter(|s| s.status.running || !events.is_empty()) {
            for event in events {
                apply_event(&mut state.status, event);
            }
            if !state.status.running && !state.settled && state.status.error.is_none() {
                state.settled = true;
                self.apply_post_sync(&state.root);
            }
            Some(state.status.clone())
        } else {
            state.as_ref().map(|s| s.status.clone())
        }
    }

    /// Cancel a running download. The archive is re-fetched on the next
    /// start; the extraction's skip-if-present makes the resume quick.
    pub fn cancel_hvsc_sync(&self) {
        if let Some(handle) = self.sync.lock().unwrap().as_ref() {
            handle.cancel();
        }
    }

    pub fn playlist(&self) -> Vec<PlaylistItem> {
        self.published()
            .playlist
            .iter()
            .map(PlaylistItem::from)
            .collect()
    }

    // ── Visualizer feed ──
    //
    // Reads return what's being heard, which trails the emulation by the
    // engine's audio buffer and the output device (see viz.rs).

    /// The frame being heard now; None before the first one and while
    /// stopped.
    pub fn viz_latest(&self) -> Option<VizSidFrame> {
        let frame = viz::lock(&self.driver.viz).latest(Instant::now());
        frame.as_ref().map(VizSidFrame::from)
    }

    /// Up to `count` frames (at most about 10 s), oldest first, ending
    /// with the one being heard now.
    pub fn viz_history(&self, count: u32) -> Vec<VizSidFrame> {
        let frames = viz::lock(&self.driver.viz).history(Instant::now(), count as usize);
        frames.iter().map(VizSidFrame::from).collect()
    }

    /// The last `count` samples (at most 2048) of each of `chip`'s voices,
    /// up to what's being heard now. Fewer at the start of a subtune; empty
    /// while stopped or for a chip the tune doesn't have.
    pub fn viz_scope(&self, chip: u32, count: u32) -> VizScope {
        let feed = viz::lock(&self.driver.viz);
        let voices = feed.scope(Instant::now(), chip as usize, count as usize);
        VizScope {
            sample_rate: feed.sample_rate(),
            voices: voices.into(),
        }
    }

    pub fn viz_stats(&self) -> VizStats {
        let feed = viz::lock(&self.driver.viz);
        let stats = feed.stats();
        VizStats {
            frames: stats.frames,
            shadow_micros: stats.shadow_micros,
            buffer_ms: feed.buffered(Instant::now()).as_secs_f32() * 1000.0,
            output_latency_ms: feed.output_latency().as_millis() as u32,
            offset_ms: feed.offset_ms(),
        }
    }

    /// The output device's latency, which Rust can't see: the app reads it
    /// from Core Audio and sets it whenever the default output changes.
    pub fn set_viz_output_latency_ms(&self, ms: u32) {
        viz::lock(&self.driver.viz).set_output_latency(Duration::from_millis(ms.into()));
    }

    /// Fine-tuning on top of the modelled latency; positive shows frames
    /// later.
    pub fn set_viz_offset_ms(&self, ms: i32) {
        viz::lock(&self.driver.viz).set_offset_ms(ms);
    }

    /// Save the playlist and stop the engine. Blocks for at most about a
    /// second; call it when the app terminates.
    pub fn shutdown(&self) {
        let (ack_tx, ack_rx) = bounded(1);
        if self.driver.commands.send(Command::Shutdown(ack_tx)).is_ok() {
            let _ = ack_rx.recv_timeout(Duration::from_secs(1));
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl PlayerCore {
    /// Author folders (MUSICIANS) or alphabetical sections (GAMES, DEMOS),
    /// in folder order.
    pub async fn hvsc_authors(
        &self,
        category: HvscCategory,
    ) -> Result<Vec<HvscAuthorItem>, HvscError> {
        let authors = self.library.authors(category.into()).await?;
        Ok(authors.iter().map(HvscAuthorItem::from).collect())
    }

    /// The tunes in one author folder or section.
    pub async fn hvsc_tunes(&self, author_path: String) -> Result<Vec<HvscTuneItem>, HvscError> {
        let path = PathBuf::from(author_path);
        let root = self.library.root();
        let tunes = self.library.tunes(path).await?;
        Ok(tunes
            .iter()
            .map(|t| HvscTuneItem::from_tune(t, root.as_deref()))
            .collect())
    }

    /// STIL's entry on a tune or folder (a path on disk) as STIL.txt has
    /// it, after the entries of the folders it's in, which declare whose
    /// initials sign its comments. The app parses it. None when STIL has
    /// nothing on it.
    pub async fn hvsc_stil(&self, path: String) -> Option<String> {
        self.library.stil(PathBuf::from(path)).await
    }

    /// Fuzzy search by title, author, file name and release; `scope` limits
    /// it to one category. The first search in a category builds its index
    /// (or loads it from the cache shared with Phosphor).
    pub async fn hvsc_search(
        &self,
        query: String,
        scope: Option<HvscCategory>,
    ) -> Result<HvscSearchResult, HvscError> {
        let r = self.library.search(query, scope.map(Into::into)).await?;
        Ok(HvscSearchResult {
            items: r
                .hits
                .iter()
                .map(|(category, entry)| HvscTuneItem::from_index(entry, (*category).into()))
                .collect(),
            total_matches: r.total_matches as u32,
            indexed: r.indexed as u32,
        })
    }

    /// Tunes in all of HVSC whose header's author contains one of `names`
    /// (ignoring case and accents), with that author; the caller narrows
    /// them to exact credits. The first call reads every tune's header.
    pub async fn hvsc_tunes_crediting(
        &self,
        names: Vec<String>,
    ) -> Result<Vec<HvscTuneItem>, HvscError> {
        let hits = self.library.crediting(names).await?;
        Ok(hits
            .into_iter()
            .map(|(category, entry, author)| HvscTuneItem {
                author,
                ..HvscTuneItem::from_index(&entry, category.into())
            })
            .collect())
    }

    /// The tunes at `paths`, in that order, each with its header's author:
    /// the rows of one of Phosphor's published playlists. Paths outside
    /// the collection's indexes are left out.
    pub async fn hvsc_tunes_at(&self, paths: Vec<String>) -> Result<Vec<HvscTuneItem>, HvscError> {
        let hits = self
            .library
            .tunes_at(paths.into_iter().map(PathBuf::from).collect())
            .await?;
        Ok(hits
            .into_iter()
            .map(|(category, entry, author)| {
                let item = HvscTuneItem::from_index(&entry, category.into());
                // An unreadable header keeps the folder's name.
                if author.is_empty() { item } else { HvscTuneItem { author, ..item } }
            })
            .collect())
    }

    /// What HVSC's bugged-tunes list (DOCUMENTS/BUGlist.txt) reports on the
    /// tune at `path` (a file in the collection); usually nothing.
    pub async fn hvsc_bugs(&self, path: String) -> Vec<TuneBug> {
        self.library
            .bugs(PathBuf::from(path))
            .await
            .into_iter()
            .map(|b| TuneBug {
                text: b.text,
                reporter: b.reporter,
                subtune: b.subtune,
            })
            .collect()
    }

    /// The play history shared with Phosphor, newest first: the last 100
    /// different tunes either app played, those still on disk.
    pub async fn recently_played(&self) -> Result<Vec<RecentTune>, HvscError> {
        let hits = self.library.recent().await?;
        Ok(hits
            .into_iter()
            .map(|(category, e, has_stil, played_at)| RecentTune {
                item: HvscTuneItem {
                    path: e.path.to_string_lossy().into_owned(),
                    title: e.title,
                    author: e.author,
                    released: e.released,
                    songs: e.songs,
                    start_song: e.selected_song,
                    duration_secs: e.duration_secs,
                    has_stil,
                    is_rsid: Some(e.is_rsid),
                    // Outside the collection: filed with the musicians,
                    // where the inspector looks for a composer anyway.
                    category: category.unwrap_or(hvsc_browser::HvscCategory::Musicians).into(),
                },
                played_at,
            })
            .collect())
    }

    /// How many different tunes Phosphor and Resonance have ever played.
    pub async fn heard_count(&self) -> u32 {
        tokio::task::spawn_blocking(crate::history::heard_count)
            .await
            .unwrap_or(0) as u32
    }

    /// Surprise Me: an endless stream of random tunes from all of HVSC, one
    /// subtune each, never one played since launch. Next picks a new tune,
    /// Previous goes back; playing anything else ends it. Returns once the
    /// search indexes are loaded (until then, picks walk the disk).
    pub async fn surprise_me(&self) {
        self.send(Command::Surprise);
        self.library.warm_indexes().await;
    }

    /// Shuffle Collection: every tune in HVSC in a new random order, played
    /// one after another (one subtune each). Next walks the order, Previous
    /// goes back through what played, and every tune plays once before any
    /// comes round again; playing anything else ends it. Starts once the
    /// search indexes are loaded, since the order is made from them.
    pub async fn shuffle_collection(&self) {
        self.library.warm_indexes().await;
        self.send(Command::ShuffleCollection);
    }

    /// A random tune's path, from `scope` or the whole collection.
    pub async fn hvsc_surprise(
        &self,
        scope: Option<HvscCategory>,
    ) -> Result<Option<String>, HvscError> {
        let path = self.library.surprise(scope.map(Into::into)).await?;
        Ok(path.map(|p| p.to_string_lossy().into_owned()))
    }

    /// The parsed metadata for the HVSC Home view: the release, the latest
    /// update announcement, the tune and document counts, the disk images
    /// and Phosphor's published playlists. `None` when the current folder
    /// holds no collection. Cached until the tree's revision changes.
    pub async fn hvsc_info(&self) -> Option<HvscInfo> {
        let root = self.library.root()?;
        let tree_revision = self.library.tree_revision();
        {
            let cache = self.hvsc_info_cache.lock().unwrap();
            if let Some(c) = cache.as_ref() {
                if c.root == root && c.tree_revision == tree_revision {
                    return Some(c.info.clone());
                }
            }
        }
        let walk_root = root.clone();
        let info = tokio::task::spawn_blocking(move || hvsc_info::collect(&walk_root))
            .await
            .ok()
            .flatten()?;
        *self.hvsc_info_cache.lock().unwrap() = Some(HvscInfoCache {
            root,
            tree_revision,
            info: info.clone(),
        });
        Some(info)
    }
}

impl PlayerCore {
    /// Once the download has finished, the tree is new ground: drop the
    /// shared index cache, reset the library's browsers, and reload the
    /// databases (the sync brings in STIL.txt and Songlengths.md5 a fresh
    /// install has no remembered path for). Like Phosphor's
    /// `apply_post_hvsc_sync`, minus the writes to its config.
    fn apply_post_sync(&self, root: &Path) {
        crate::hvsc_index_cache::clear_all();
        self.library.refresh();
        let config = crate::config::Config::load();
        databases::install(
            &self.databases,
            databases::Databases::load_after_sync(&config, Some(root)),
        );
    }

    fn send(&self, cmd: Command) {
        // Only fails once the session thread has shut down.
        let _ = self.driver.commands.send(cmd);
    }

    fn published(&self) -> Arc<Published> {
        match self.driver.published.lock() {
            Ok(p) => p.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }
}

/// Phosphor's settings from its config.json (read-only), so Resonance can
/// offer to start from the same setup.
#[uniffi::export]
pub fn shared_defaults() -> SharedDefaults {
    let c = crate::config::Config::load();
    SharedDefaults {
        engine: if c.output_engine == "emulated" {
            Engine::ReSid
        } else {
            Engine::SidLite
        },
        volume: c.master_volume,
        options: PlaybackOptions {
            skip_rsid: c.skip_rsid,
            default_song_length_secs: c.default_song_length_secs,
            force_stereo_2sid: c.force_stereo_2sid,
            pseudo_stereo: c
                .pseudo_stereo_enabled
                .then(|| DetuneStrength::from_config_str(&c.pseudo_stereo_strength).into()),
        },
        hvsc_root: c.hvsc_root,
    }
}

/// The version of upstream Phosphor whose engine this build compiles in.
#[uniffi::export]
pub fn phosphor_version() -> String {
    env!("PHOSPHOR_VERSION").to_string()
}

fn to_usize(v: Vec<u32>) -> Vec<usize> {
    v.into_iter().map(|i| i as usize).collect()
}

/// The archive to download: an explicit `hvsc_zip_url` in Phosphor's
/// config wins, else the mirror's `<N>-all-of-them` archive at the tree's
/// known release. Mirrors upstream's `HvscZipSyncStart` resolution;
/// unlike it, an unrecognised mirror host falls back to brona.dk's, the
/// canonical mirror, rather than dead-ending (Resonance has no field to
/// paste an archive URL into).
fn sync_archive_url() -> String {
    let config = crate::config::Config::load();
    config
        .hvsc_zip_url
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| {
            hvsc_sync::default_hvsc_zip_url(&config.hvsc_mirror_url, config.hvsc_known_version.as_deref())
        })
        .unwrap_or_else(|| {
            hvsc_sync::default_hvsc_zip_url(crate::config::DEFAULT_HVSC_MIRROR_URL, None)
                .unwrap_or_else(|| "https://hvsc.brona.dk/HVSC/HVSC_85-all-of-them.7z".to_string())
        })
}

/// Fold one of the worker's events into the polled status.
fn apply_event(status: &mut HvscSyncStatus, event: HvscSyncEvent) {
    match event {
        HvscSyncEvent::Progress {
            files_done,
            files_total,
            bytes_done,
            bytes_total,
            current,
        } => {
            status.files_done = files_done;
            status.files_total = files_total;
            status.bytes_done = bytes_done;
            status.bytes_total = bytes_total;
            status.current = current;
        }
        HvscSyncEvent::Done(Ok(())) => {
            status.running = false;
        }
        HvscSyncEvent::Done(Err(message)) => {
            status.running = false;
            status.error = Some(message);
        }
    }
}

/// "Hubbard_Rob" → "Hubbard, Rob", other folder names with spaces. Mirrors
/// upstream's private `derive_display_name` (src/hvsc_browser.rs:1175), which
/// names authors in the browse lists.
fn display_name(folder: &str) -> String {
    match folder.split('_').collect::<Vec<_>>()[..] {
        [last, first] if first.starts_with(|c: char| c.is_ascii_uppercase()) => {
            format!("{last}, {first}")
        }
        _ => folder.replace('_', " "),
    }
}

// ── Conversions ──────────────────────────────────────────────────────────────

impl From<HvscCategory> for hvsc_browser::HvscCategory {
    fn from(c: HvscCategory) -> Self {
        match c {
            HvscCategory::Musicians => hvsc_browser::HvscCategory::Musicians,
            HvscCategory::Games => hvsc_browser::HvscCategory::Games,
            HvscCategory::Demos => hvsc_browser::HvscCategory::Demos,
        }
    }
}

impl From<hvsc_browser::HvscCategory> for HvscCategory {
    fn from(c: hvsc_browser::HvscCategory) -> Self {
        match c {
            hvsc_browser::HvscCategory::Musicians => HvscCategory::Musicians,
            hvsc_browser::HvscCategory::Games => HvscCategory::Games,
            hvsc_browser::HvscCategory::Demos => HvscCategory::Demos,
        }
    }
}

impl From<LibraryError> for HvscError {
    fn from(e: LibraryError) -> Self {
        match e {
            LibraryError::NoRoot => HvscError::NoRoot,
            LibraryError::NotFound(message) => HvscError::NotFound { message },
            LibraryError::Io(message) => HvscError::Io { message },
        }
    }
}

impl From<&HvscAuthor> for HvscAuthorItem {
    fn from(a: &HvscAuthor) -> Self {
        HvscAuthorItem {
            name: a.raw_name.clone(),
            display_name: a.display_name.clone(),
            letter: a.letter.to_string(),
            path: a.path.to_string_lossy().into_owned(),
        }
    }
}

impl HvscTuneItem {
    fn from_tune(t: &HvscTune, root: Option<&std::path::Path>) -> Self {
        let e = &t.entry;
        let category = root
            .and_then(|r| e.path.strip_prefix(r).ok())
            .and_then(|rel| rel.components().next())
            .and_then(|c| c.as_os_str().to_str())
            .and_then(|dir| {
                crate::library::CATEGORIES
                    .into_iter()
                    .find(|c| c.dir_name() == dir)
            })
            .unwrap_or(hvsc_browser::HvscCategory::Musicians);
        HvscTuneItem {
            path: e.path.to_string_lossy().into_owned(),
            title: e.title.clone(),
            author: e.author.clone(),
            released: e.released.clone(),
            songs: e.songs,
            start_song: e.selected_song,
            duration_secs: e.duration_secs,
            has_stil: t.has_stil,
            is_rsid: Some(e.is_rsid),
            category: category.into(),
        }
    }

    fn from_index(e: &HvscIndexEntry, category: HvscCategory) -> Self {
        HvscTuneItem {
            path: e.path.to_string_lossy().into_owned(),
            title: e.title.clone(),
            author: display_name(&e.author_raw),
            released: e.released.clone(),
            songs: e.songs,
            start_song: 1,
            duration_secs: e.duration_secs,
            has_stil: e.has_stil,
            is_rsid: None,
            category,
        }
    }
}

impl From<Engine> for session::Engine {
    fn from(e: Engine) -> Self {
        match e {
            Engine::SidLite => session::Engine::SidLite,
            Engine::ReSid => session::Engine::ReSid,
        }
    }
}

impl From<session::Engine> for Engine {
    fn from(e: session::Engine) -> Self {
        match e {
            session::Engine::SidLite => Engine::SidLite,
            session::Engine::ReSid => Engine::ReSid,
        }
    }
}

impl From<Repeat> for RepeatMode {
    fn from(r: Repeat) -> Self {
        match r {
            Repeat::Off => RepeatMode::Off,
            Repeat::All => RepeatMode::All,
            Repeat::One => RepeatMode::Single,
        }
    }
}

impl From<RepeatMode> for Repeat {
    fn from(r: RepeatMode) -> Self {
        match r {
            RepeatMode::Off => Repeat::Off,
            RepeatMode::All => Repeat::All,
            RepeatMode::Single => Repeat::One,
        }
    }
}

impl From<PseudoStereo> for DetuneStrength {
    fn from(p: PseudoStereo) -> Self {
        match p {
            PseudoStereo::Subtle => DetuneStrength::Subtle,
            PseudoStereo::Medium => DetuneStrength::Medium,
            PseudoStereo::Wide => DetuneStrength::Wide,
        }
    }
}

impl From<DetuneStrength> for PseudoStereo {
    fn from(d: DetuneStrength) -> Self {
        match d {
            DetuneStrength::Subtle => PseudoStereo::Subtle,
            DetuneStrength::Medium => PseudoStereo::Medium,
            DetuneStrength::Wide => PseudoStereo::Wide,
        }
    }
}

impl From<PlaybackOptions> for session::Options {
    fn from(o: PlaybackOptions) -> Self {
        session::Options {
            skip_rsid: o.skip_rsid,
            default_song_length_secs: o.default_song_length_secs,
            force_stereo_2sid: o.force_stereo_2sid,
            pseudo_stereo: o.pseudo_stereo.map(Into::into),
        }
    }
}

impl From<PlayState> for PlaybackState {
    fn from(s: PlayState) -> Self {
        match s {
            PlayState::Stopped => PlaybackState::Stopped,
            PlayState::Playing => PlaybackState::Playing,
            PlayState::Paused => PlaybackState::Paused,
        }
    }
}

impl From<&PlaylistEntry> for PlaylistItem {
    fn from(e: &PlaylistEntry) -> Self {
        PlaylistItem {
            path: e.path.to_string_lossy().into_owned(),
            title: e.title.clone(),
            author: e.author.clone(),
            released: e.released.clone(),
            songs: e.songs,
            selected_song: e.selected_song,
            duration_secs: e.duration_secs,
            is_rsid: e.is_rsid,
            is_pal: e.is_pal,
            num_sids: e.num_sids as u32,
            md5: e.md5.clone(),
        }
    }
}

impl From<&TrackInfo> for TrackDetails {
    fn from(t: &TrackInfo) -> Self {
        TrackDetails {
            path: t.path.to_string_lossy().into_owned(),
            title: t.name.clone(),
            author: t.author.clone(),
            released: t.released.clone(),
            songs: t.songs,
            current_song: t.current_song,
            is_pal: t.is_pal,
            is_rsid: t.is_rsid,
            num_sids: t.num_sids as u32,
            sid_type: t.sid_type.clone(),
            sid_model: t.sid_model,
            md5: t.md5.clone(),
        }
    }
}

impl From<&viz::Frame> for VizSidFrame {
    fn from(f: &viz::Frame) -> Self {
        let clock = viz::clock_hz(f.is_pal);
        VizSidFrame {
            index: f.index,
            is_pal: f.is_pal,
            chips: f.chips[..f.num_chips]
                .iter()
                .map(|chip| VizChip::decode(chip, clock))
                .collect(),
        }
    }
}

impl VizChip {
    fn decode(chip: &viz::ChipState, clock: f64) -> Self {
        let r = &chip.regs;
        VizChip {
            voices: (0..3)
                .map(|v| {
                    VizVoice::decode(&r[v * 7..v * 7 + 7], chip.env[v], chip.env_state[v], clock)
                })
                .collect(),
            registers: r.to_vec(),
            cutoff: (r[0x16] as u16) << 3 | (r[0x15] & 0x07) as u16,
            resonance: r[0x17] >> 4,
            filter_routing: r[0x17] & 0x0F,
            filter_mode: r[0x18] >> 4,
            volume: r[0x18] & 0x0F,
        }
    }
}

const NOTE_NAMES: [&str; 12] = [
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
];

impl VizVoice {
    /// `r`: the voice's seven registers.
    fn decode(r: &[u8], env: u8, state: viz::EnvState, clock: f64) -> Self {
        let freq_reg = r[0] as u16 | (r[1] as u16) << 8;
        let hz = freq_reg as f64 * clock / 16_777_216.0;
        let midi = if hz > 0.0 {
            69.0 + 12.0 * (hz / 440.0).log2()
        } else {
            0.0
        };
        let nearest = midi.round() as i32;
        let note = (hz > 0.0 && (0..=127).contains(&nearest))
            .then(|| format!("{}{}", NOTE_NAMES[nearest as usize % 12], nearest / 12 - 1));
        let control = r[4];
        VizVoice {
            freq_reg,
            hz,
            midi,
            note,
            gate: control & 0x01 != 0,
            waveform: control >> 4,
            test: control & 0x08 != 0,
            ring: control & 0x04 != 0,
            sync: control & 0x02 != 0,
            pulse_width: r[2] as u16 | ((r[3] & 0x0F) as u16) << 8,
            attack: r[5] >> 4,
            decay: r[5] & 0x0F,
            sustain: r[6] >> 4,
            release: r[6] & 0x0F,
            env_level: env as f32 / 255.0,
            env_phase: match state {
                viz::EnvState::Attack => EnvelopePhase::Attack,
                // The counter stops at the sustain level: $0–$F as $00–$FF.
                viz::EnvState::DecaySustain if env == (r[6] >> 4) * 0x11 => EnvelopePhase::Sustain,
                viz::EnvState::DecaySustain => EnvelopePhase::Decay,
                viz::EnvState::Release => EnvelopePhase::Release,
            },
        }
    }
}

#[cfg(test)]
mod sync_tests {
    use super::{apply_event, HvscSyncStatus};
    use crate::hvsc_sync::HvscSyncEvent;

    fn running() -> HvscSyncStatus {
        HvscSyncStatus {
            root: "/HVSC".into(),
            running: true,
            error: None,
            current: "Starting…".into(),
            files_done: 0,
            files_total: 0,
            bytes_done: 0,
            bytes_total: 0,
        }
    }

    #[test]
    fn events_fold_into_the_status() {
        let mut s = running();
        apply_event(
            &mut s,
            HvscSyncEvent::Progress {
                files_done: 0,
                files_total: 0,
                bytes_done: 10_000,
                bytes_total: 20_000,
                current: "Downloading archive… 1 MB / 2 MB".into(),
            },
        );
        assert!(s.running);
        assert_eq!((s.bytes_done, s.bytes_total), (10_000, 20_000));

        // Extraction resets the byte counters and counts files instead.
        apply_event(
            &mut s,
            HvscSyncEvent::Progress {
                files_done: 1,
                files_total: 2,
                bytes_done: 0,
                bytes_total: 0,
                current: "Extracting… 1 / 2".into(),
            },
        );
        assert_eq!((s.files_done, s.files_total), (1, 2));
        assert_eq!((s.bytes_done, s.bytes_total), (0, 0));

        apply_event(&mut s, HvscSyncEvent::Done(Ok(())));
        assert!(!s.running);
        assert!(s.error.is_none());

        let mut failed = running();
        apply_event(&mut failed, HvscSyncEvent::Done(Err("Cancelled".into())));
        assert!(!failed.running);
        assert_eq!(failed.error.as_deref(), Some("Cancelled"));
    }
}
