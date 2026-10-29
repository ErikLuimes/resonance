//! The UniFFI surface Swift sees.
//!
//! Every method is non-blocking: commands are queued to the session thread
//! and reads clone the latest published read model. Swift polls
//! `snapshot()` (cheap), refetches `playlist()` when `playlist_revision`
//! changes, and reads `viz_frame()` once per display frame.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use crossbeam_channel::bounded;

use crate::driver::{Command, Driver, Published, StartConfig};
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
    /// Playlist row of the current track.
    pub current_index: Option<u32>,
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

// ── PlayerCore ───────────────────────────────────────────────────────────────

/// The player. Create one per app; it owns the engine, playlist and session
/// file until `shutdown()` (or until it's released).
#[derive(uniffi::Object)]
pub struct PlayerCore {
    driver: Driver,
}

#[uniffi::export]
impl PlayerCore {
    #[uniffi::constructor]
    pub fn new(config: CoreConfig) -> Arc<Self> {
        let driver = Driver::start(StartConfig {
            engine: config.engine.into(),
            volume: config.volume,
            options: config.options.into(),
            shuffle: config.shuffle,
            repeat: config.repeat.into(),
            session_path: PathBuf::from(config.session_path),
        });
        Arc::new(Self { driver })
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

    // ── Reads ──

    pub fn snapshot(&self) -> Snapshot {
        let p = self.published();
        let view = &p.session;
        let status = &view.status;
        let duration_ms = view
            .current
            .and_then(|i| p.playlist.get(i))
            .and_then(|e| e.duration_secs)
            .map(|s| u64::from(s) * 1000);
        Snapshot {
            state: status.state.clone().into(),
            current_index: view.current.map(|i| i as u32),
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

fn to_usize(v: Vec<u32>) -> Vec<usize> {
    v.into_iter().map(|i| i as usize).collect()
}

// ── Conversions ──────────────────────────────────────────────────────────────

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
