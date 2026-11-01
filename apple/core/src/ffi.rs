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

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use crossbeam_channel::bounded;

use crate::databases;
use crate::driver::{Command, Driver, Published, StartConfig};
use crate::hvsc_browser::{self, HvscAuthor, HvscIndexEntry, HvscTune};
use crate::library::{Library, LibraryError};
use crate::player::pseudo_stereo::DetuneStrength;
use crate::player::{PlayState, TrackInfo};
use crate::playlist::{PlaylistEntry, RepeatMode};
use crate::session;

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
    /// STIL on the playing tune's current subtune.
    pub stil: Option<TuneStil>,
}

/// What STIL says about one subtune, its text unwrapped.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TuneStil {
    /// About the whole file.
    pub comment: Option<String>,
    /// The whole tune's blocks, then the current subtune's.
    pub blocks: Vec<StilBlock>,
}

/// One STIL block: the piece a (sub)tune covers, and notes on it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct StilBlock {
    /// 0 for the whole tune.
    pub subtune: u16,
    /// The subtune's own name, e.g. its part in a game.
    pub name: Option<String>,
    /// The piece it covers.
    pub title: Option<String>,
    /// Who performed that piece.
    pub artist: Option<String>,
    /// Who wrote that piece.
    pub author: Option<String>,
    pub comment: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct VizFrame {
    /// Increases with every player status; equal values mean no new frame.
    pub seq: u64,
    /// Three envelope estimates (0.0–1.0) per SID chip.
    pub voice_levels: Vec<f32>,
    /// SID register shadow: 32 bytes per chip, up to four chips.
    pub sid_regs: Vec<u8>,
    pub num_sids: u32,
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

/// The player. Create one per app; it owns the engine, playlist and session
/// file until `shutdown()` (or until it's released).
#[derive(uniffi::Object)]
pub struct PlayerCore {
    driver: Driver,
    library: Library,
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
            databases,
            library: library.clone(),
        });
        Arc::new(Self { driver, library })
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
            stil: p.stil.as_ref().map(TuneStil::from),
        }
    }

    pub fn playlist(&self) -> Vec<PlaylistItem> {
        self.published()
            .playlist
            .iter()
            .map(PlaylistItem::from)
            .collect()
    }

    pub fn viz_frame(&self) -> VizFrame {
        let p = self.published();
        let status = &p.session.status;
        VizFrame {
            seq: p.session.status_seq,
            voice_levels: status.voice_levels.clone(),
            sid_regs: status.sid_regs.clone(),
            num_sids: status.track_info.as_ref().map_or(1, |t| t.num_sids as u32),
        }
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

    /// STIL's note on an author folder, if it has one, with STIL's hard line
    /// wrapping undone.
    pub async fn hvsc_author_note(&self, author_path: String) -> Result<Option<String>, HvscError> {
        Ok(self.library.author_note(PathBuf::from(author_path)).await?)
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

    /// Surprise Me: an endless stream of random tunes from all of HVSC, one
    /// subtune each, never one played since launch. Next picks a new tune,
    /// Previous goes back; playing anything else ends it. Returns once the
    /// search indexes are loaded (until then, picks walk the disk).
    pub async fn surprise_me(&self) {
        self.send(Command::Surprise);
        self.library.warm_indexes().await;
    }

    /// A random tune's path, from `scope` or the whole collection.
    pub async fn hvsc_surprise(
        &self,
        scope: Option<HvscCategory>,
    ) -> Result<Option<String>, HvscError> {
        let path = self.library.surprise(scope.map(Into::into)).await?;
        Ok(path.map(|p| p.to_string_lossy().into_owned()))
    }
}

impl PlayerCore {
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

impl From<&databases::StilNotes> for TuneStil {
    fn from(n: &databases::StilNotes) -> Self {
        TuneStil {
            comment: n.comment.clone(),
            blocks: n
                .blocks
                .iter()
                .map(|b| StilBlock {
                    subtune: b.subtune,
                    name: b.name.clone(),
                    title: b.title.clone(),
                    artist: b.artist.clone(),
                    author: b.author.clone(),
                    comment: b.comment.clone(),
                })
                .collect(),
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
