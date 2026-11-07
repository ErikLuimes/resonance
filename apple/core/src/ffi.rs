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
use crate::share::{ShareableTune, SharedTuneMatch};
use crate::fingerprint::{self, Fingerprints, ScanTune};
use crate::driver::{Command, Driver, Published, StartConfig};
use crate::hvsc_browser::{self, HvscAuthor, HvscIndexEntry, HvscTune};
use crate::hvsc_info::{self, HvscInfo};
use crate::hvsc_sync::{self, HvscSyncEvent, HvscSyncHandle};
use crate::learned::LearnedLengths;
use crate::library::{Library, LibraryError};
use crate::player::pseudo_stereo::DetuneStrength;
use crate::player::{PlayState, TrackInfo};
use crate::playlist::{PlaylistEntry, RepeatMode};
use crate::session;
use crate::smart;
use crate::viz;

// ── Records and enums ────────────────────────────────────────────────────────

/// Software SID engines. USB and Ultimate 64 aren't part of this build.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Engine {
    /// libsidplayfp's SIDLite — picks the chip model from the tune header.
    SidLite,
    /// resid-rs emulation.
    ReSid,
    /// libsidplayfp with reSIDfp (libresidfp), the reference emulation,
    /// rendered from the audio output callback.
    ReSidFp,
    /// libsidplayfp's own SIDLite, rendered the same way: the lightest.
    SidLiteDirect,
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

/// What `import_from_phosphor` added to Resonance's favourites and play
/// history.
/// The tunes behind dropped files, folders and playlists.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct ResolvedFiles {
    /// Each tune's absolute path once, in order.
    pub paths: Vec<String>,
    /// Tunes that loaded, repeats included.
    pub found: u32,
    /// Tunes asked for; more than `found` when some are missing.
    pub listed: u32,
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
    /// `duration_secs` is one Resonance worked out, not HVSC's.
    #[uniffi(default = false)]
    pub duration_is_estimate: bool,
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
    /// That length is one Resonance worked out, not HVSC's.
    #[uniffi(default = false)]
    pub duration_is_estimate: bool,
    pub shuffle: bool,
    pub repeat: Repeat,
    pub engine: Engine,
    /// The engine can seek within a tune (reSIDfp and SIDLite direct).
    pub can_seek: bool,
    /// A seek is in progress: `elapsed_ms` already says where, the audio
    /// is silent until the emulation has caught up.
    pub seeking: bool,
    /// While seeking: how far the emulation has got on its way to
    /// `elapsed_ms` (from the top for a backward seek, from where it was
    /// for a forward one), updated every tenth of a second of tune.
    pub seek_position_ms: Option<u64>,
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
/// The newest HVSC release on the mirror, and the one installed.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HvscVersionCheck {
    pub latest: u32,
    /// From the collection's STIL; nil when there's none yet.
    pub installed: Option<u32>,
}

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

/// A scope read, packed: the UI reads one every display frame, and a
/// `bytes` field crosses the FFI as a single copy where a `sequence<f32>`
/// is lifted a float at a time.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct VizScopeSamples {
    pub sample_rate: f32,
    /// Samples per voice.
    pub count: u32,
    /// Three voices' samples, voice after voice, each −1…1 (waveform ×
    /// envelope), oldest first, as native-endian f32.
    pub samples: Vec<u8>,
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

/// An author folder at a glance, for the author list and composer card.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HvscComposer {
    pub path: String,
    /// "Ari Yliaho" for Agemixer; nil when the headers only repeat the
    /// folder's name, or outside MUSICIANS.
    pub real_name: Option<String>,
    pub tunes: u32,
    pub first_year: Option<u16>,
    pub last_year: Option<u16>,
}

/// A composer who sounds like another, by the average of their tunes.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SimilarComposer {
    /// The MUSICIANS folder.
    pub path: String,
    /// Cosine similarity, −1…1.
    pub score: f32,
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
    /// Length of the start subtune, if the Songlengths database knows it,
    /// or for a tune outside it, if Resonance has worked it out.
    pub duration_secs: Option<u32>,
    pub has_stil: bool,
    /// Unknown in search results (the index doesn't store it).
    pub is_rsid: Option<bool>,
    pub category: HvscCategory,
    /// `duration_secs` is one Resonance worked out, not HVSC's.
    #[uniffi(default = false)]
    pub duration_is_estimate: bool,
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

/// A tune from the play history.
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

/// What a tune's sound is known for, from its fingerprint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SoundTag {
    Arpeggios,
    FilterSweeps,
    NoiseDrums,
    RingMod,
    SyncLeads,
    DigiSamples,
    PulseBass,
    VibratoLeads,
}

/// How common a sound is across the collection.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SoundTagShare {
    pub tag: SoundTag,
    /// The share of the fingerprinted tunes' start songs that have it, 0–1.
    pub share: f32,
}

/// Share of the sounding time per waveform, 0–1; they sum to 1 (or 0 for
/// a silent tune).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WaveformMix {
    pub triangle: f32,
    pub saw: f32,
    pub pulse: f32,
    pub noise: f32,
}

/// A subtune's sound fingerprint, from the background scan.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TuneFingerprint {
    pub subtune: u16,
    /// Seconds of the subtune the scan covered (at most three minutes).
    pub scanned_secs: f32,
    /// SID 1's three voices, `bins` levels each (0–255), voice 1 first:
    /// how loud each voice is across the scanned stretch.
    pub activity: Vec<u8>,
    pub bins: u32,
    pub mix: WaveformMix,
    pub tags: Vec<SoundTag>,
    /// Notes started per second, all voices.
    pub notes_per_sec: f32,
    /// Semitone-or-more pitch jumps within held notes, per second.
    pub arpeggio_rate: f32,
    /// Share of the sounding time with a voice through the filter, 0–1.
    pub filter_usage: f32,
    /// Share of the sounding time with ring modulation or hard sync, 0–1.
    pub ring_mod: f32,
    pub sync: f32,
    /// Share of the frames that play samples through the chip, 0–1.
    pub digi: f32,
    /// Mean pulse-width sweep per note on pulse voices, 0–1.
    pub pulse_width_depth: f32,
    /// Vibrato-like pitch wobbles and noise hits (drums), per second.
    pub vibrato_rate: f32,
    pub noise_hits: f32,
    /// The nine traits the glyphs draw, each 0–1, in this order: notes,
    /// arpeggios, vibrato, filter, ring modulation, sync, digi, noise,
    /// pulse-width modulation.
    pub traits: Vec<f32>,
    /// SID chips the tune uses.
    pub chips: u8,
    /// Nothing sounds in the scanned stretch.
    pub silent: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FingerprintScanStatus {
    pub running: bool,
    pub paused: bool,
    /// Every subtune has been scanned (or given up on).
    pub finished: bool,
    /// 1 while scanning each tune's start song, 2 for the other subtunes.
    pub pass: u8,
    /// Subtunes in the collection, and how many have been scanned or
    /// couldn't be.
    pub total: u32,
    pub done: u32,
    pub failed: u32,
    /// Changes whenever new fingerprints are saved: refetch visible ones.
    pub revision: u64,
    pub error: Option<String>,
}

/// A tune like another, for "Sounds like".
#[derive(Debug, Clone, uniffi::Record)]
pub struct SimilarTune {
    pub item: HvscTuneItem,
    /// The subtune that matched best.
    pub subtune: u16,
    /// Cosine similarity of the two fingerprints, −1…1.
    pub score: f32,
}

/// How a smart playlist chooses and orders its tunes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SmartKind {
    /// The closest to `seed`, closest first.
    Like,
    /// Shuffled.
    Shuffle,
    /// Chill, then rising in intensity.
    Rising,
    /// Intense, then winding down.
    Falling,
    /// Taking turns between calm and intense.
    Alternating,
    /// Different from what's been played, shuffled.
    Different,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SmartEnergy {
    Any,
    Calm,
    Medium,
    Intense,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SmartSection {
    Any,
    Games,
    Demos,
    NotGames,
    NotDemos,
}

/// A sound a tune can have plenty of. In `smart::SOUNDS` order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SmartSound {
    Arpeggios,
    Filter,
    Drums,
    Bass,
    PulseWidth,
    Samples,
    RingMod,
    Sync,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SmartChip {
    Any,
    Mos6581,
    Mos8580,
}

/// A composer's name and MUSICIANS folder, for reading sentences.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SmartComposer {
    /// As their tunes' headers give it, without a nickname: "Johan Åstrand".
    pub name: String,
    pub folder: String,
    /// What else they go by: "Zyron".
    pub aliases: Vec<String>,
    /// How many tunes they have, which settles who a shared name means.
    pub tunes: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SmartRecipe {
    pub kind: SmartKind,
    /// The tunes `Like` starts from: more than one take turns.
    pub seeds: Vec<String>,
    /// How far down the list of closest tunes `Like` goes.
    pub top: u32,
    /// `Like` also takes the other tunes with the seed's name.
    pub other_versions: bool,
    /// Shortest tune, in seconds; 0 for any.
    pub min_secs: u32,
    pub only_unheard: bool,
    /// How long it plays, in seconds; None for every tune that fits.
    pub total_secs: Option<u32>,
    /// Only titles with these words.
    pub title_words: Option<String>,
    /// Only these MUSICIANS folders, "Hubbard_Rob".
    pub composers: Vec<String>,
    /// Has plenty of each of these.
    pub sounds: Vec<SmartSound>,
    pub chip: SmartChip,
    /// Uses at least and at most this many SID chips.
    pub min_chips: Option<u8>,
    pub max_chips: Option<u8>,
    /// How many tunes at most.
    pub max_tunes: Option<u32>,
    pub from_year: Option<u16>,
    pub to_year: Option<u16>,
    pub section: SmartSection,
    /// How energetic the list is throughout (`Shuffle`).
    pub energy: SmartEnergy,
    /// A different number gives a different pick.
    pub shuffle: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SmartTune {
    pub item: HvscTuneItem,
    /// Here for its name, as another version of the seed, not for its sound.
    pub is_version: bool,
    pub heard: bool,
    /// How intense against the rest, 0–1, where a recipe worked it out.
    pub intensity: Option<f32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SmartPlaylist {
    pub tunes: Vec<SmartTune>,
    pub total_secs: u64,
    /// How many tunes the recipe chose from.
    pub pool: u32,
    /// How many different tunes have been played.
    pub heard: u32,
    /// `Different` can't say yet: too little has been played.
    pub needs_more_history: bool,
    /// The scan hasn't reached `seed` yet.
    pub seed_not_scanned: bool,
}

/// Folders and header authors into composers. A header like "Johan Åstrand
/// (Zyron)" gives a name and a nickname; one crediting several people, like
/// "A & B", says nothing about either. Other names in a folder are mostly the
/// credits of covers, and a nickname on a few tunes a one-off, so a nickname
/// counts from a tenth of the folder's tunes.
fn smart_composers_from(credits: &[(String, String)]) -> Vec<SmartComposer> {
    use std::collections::BTreeMap;
    #[derive(Default)]
    struct Folder {
        tunes: u32,
        names: BTreeMap<String, u32>,
        nicknames: BTreeMap<String, u32>,
    }
    let mut folders: BTreeMap<&str, Folder> = BTreeMap::new();
    for (folder, author) in credits {
        let entry = folders.entry(folder).or_default();
        entry.tunes += 1;
        if author.is_empty() || author.contains(['&', ',', '<', '?']) {
            continue;
        }
        let (name, nickname) = match author.split_once('(') {
            Some((name, rest)) => (name.trim(), rest.split(')').next().map(str::trim)),
            None => (author.trim(), None),
        };
        if !name.is_empty() {
            *entry.names.entry(name.to_string()).or_insert(0) += 1;
        }
        if let Some(nickname) = nickname.filter(|n| !n.is_empty()) {
            *entry.nicknames.entry(nickname.to_string()).or_insert(0) += 1;
        }
    }
    folders
        .into_iter()
        .map(|(folder, entry)| {
            let name = entry.names.iter().max_by_key(|(_, &n)| n).map(|(n, _)| n.clone());
            let mut aliases: Vec<String> = entry
                .nicknames
                .iter()
                .filter(|(_, &n)| n * 10 >= entry.tunes)
                .map(|(nickname, _)| nickname.clone())
                .collect();
            // The folder's own spelling too: "Huelsbeck, Chris" is "Hülsbeck".
            aliases.push(display_name(folder));
            SmartComposer {
                name: name.unwrap_or_else(|| display_name(folder)),
                folder: folder.to_string(),
                aliases,
                tunes: entry.tunes,
            }
        })
        .collect()
}

struct SmartPick {
    path: String,
    subtune: Option<u16>,
    is_version: bool,
    heard: bool,
    intensity: Option<f32>,
}

#[derive(Default)]
struct SmartChoice {
    picks: Vec<SmartPick>,
    pool: usize,
    heard: usize,
    needs_more_history: bool,
    seed_not_scanned: bool,
}

/// Every tune in the indexes, with what the fingerprints and the heard list
/// know about it.
fn smart_tunes(
    root: &Path,
    library: &Library,
    fps: &fingerprint::Fingerprints,
    seed: Option<&str>,
) -> (Vec<smart::Tune>, std::collections::HashSet<String>) {
    use fingerprint::{feature_index as fi, Index};
    let index: std::sync::Arc<Index> = fps.index_for(seed);
    let md5s = fps.md5_by_path();
    let heard_md5 = crate::history::heard_set();
    let heard: std::collections::HashSet<String> =
        md5s.iter().filter(|(_, m)| heard_md5.contains(*m)).map(|(p, _)| p.clone()).collect();
    let heard_paths: Vec<&str> = heard.iter().map(String::as_str).collect();
    let to_heard = index.likeness_to_group(&heard_paths);
    let features: std::collections::HashMap<&str, &[f32; fingerprint::FEATURES]> =
        index.start_songs().into_iter().collect();
    let tunes = library
        .all_entries()
        .iter()
        .filter_map(|(_, entry)| {
            let path = collection_path(root, &entry.path)?;
            let found = features.get(path.as_str());
            let mut tune = smart::Tune {
                title: entry.title.clone(),
                author: entry.author_raw.clone(),
                folder: smart::composer_folder(&entry.path, &entry.author_raw),
                year: entry.released.get(..4).and_then(|y| y.parse().ok()),
                secs: entry.duration_secs.unwrap_or(0),
                heard: heard.contains(&path),
                scanned: found.is_some(),
                to_heard: to_heard.get(path.as_str()).copied().unwrap_or(0.0),
                ..smart::Tune::default()
            };
            if let Some(f) = found {
                tune.notes = f[fi::NOTES].exp() - 1.0;
                tune.arps = f[fi::ARPS].exp() - 1.0;
                tune.drums = f[fi::NOISE].exp() - 1.0;
                tune.digi = f[fi::DIGI];
                tune.peak = f[fi::LEVELS];
                tune.loudness = f[fi::LEVELS] + f[fi::LEVELS + 1] + f[fi::LEVELS + 2];
                tune.is_8580 = f[fi::IS_8580] > 0.5;
                tune.chips = f[fi::CHIPS].round() as u8;
                tune.sounds = [
                    f[fi::ARPS], f[fi::FILTER], f[fi::NOISE], f[fi::PULSE_BASS],
                    f[fi::PULSE_WIDTH], f[fi::DIGI], f[fi::RING], f[fi::SYNC],
                ];
            }
            tune.path = path;
            Some(tune)
        })
        .collect();
    (tunes, heard)
}

fn smart_choose(
    recipe: &SmartRecipe,
    root: &Path,
    seed: Option<&str>,
    library: &Library,
    fps: &fingerprint::Fingerprints,
    similar: &[SimilarTune],
) -> SmartChoice {
    use rand::SeedableRng;
    let (mut tunes, heard) = smart_tunes(root, library, fps, seed);
    let index = fps.index_for(seed);
    // Each tune leading into the next, for lists small enough to be listened
    // through; comparing every pair of 60,000 wouldn't be noticed anyway.
    let arrange = |order: Vec<usize>, tunes: &[smart::Tune]| -> Vec<usize> {
        if order.len() > 500 {
            return order;
        }
        let sounds: Vec<Option<&[f32]>> =
            order.iter().map(|&i| index.sound_of(&tunes[i].path).map(|s| s.as_slice())).collect();
        let authors: Vec<&str> = order.iter().map(|&i| tunes[i].author.as_str()).collect();
        smart::flow(&sounds, &authors).into_iter().map(|k| order[k]).collect()
    };
    let mut rng = rand::rngs::StdRng::seed_from_u64(recipe.shuffle);
    let mut choice = SmartChoice { heard: heard.len(), ..SmartChoice::default() };
    let title_words = recipe.title_words.as_deref().map(smart::name_words);
    let plenty = smart::plenty(&tunes, !recipe.composers.is_empty());
    let wanted_sounds: Vec<usize> = recipe
        .sounds
        .iter()
        .map(|s| match s {
            SmartSound::Arpeggios => 0,
            SmartSound::Filter => 1,
            SmartSound::Drums => 2,
            SmartSound::Bass => 3,
            SmartSound::PulseWidth => 4,
            SmartSound::Samples => 5,
            SmartSound::RingMod => 6,
            SmartSound::Sync => 7,
        })
        .collect();
    let fits = |t: &smart::Tune| {
        t.secs >= recipe.min_secs
            && (wanted_sounds.is_empty() || (t.scanned && wanted_sounds.iter().all(|&k| t.sounds[k] >= plenty[k].max(1e-6))))
            && recipe.min_chips.is_none_or(|n| t.scanned && t.chips >= n)
            && recipe.max_chips.is_none_or(|n| t.scanned && t.chips <= n)
            && match recipe.chip {
                SmartChip::Any => true,
                SmartChip::Mos6581 => t.scanned && !t.is_8580,
                SmartChip::Mos8580 => t.scanned && t.is_8580,
            }
            && title_words.as_ref().is_none_or(|w| smart::title_has(&t.title, w))
            && (!recipe.only_unheard || !t.heard)
            && (recipe.composers.is_empty() || (t.path.starts_with("MUSICIANS/") && recipe.composers.contains(&t.folder)))
            && recipe.from_year.is_none_or(|y| t.year.is_some_and(|tune| tune >= y))
            && recipe.to_year.is_none_or(|y| t.year.is_some_and(|tune| tune <= y))
            && match recipe.section {
                SmartSection::Any => true,
                SmartSection::Games => t.path.starts_with("GAMES/"),
                SmartSection::Demos => t.path.starts_with("DEMOS/"),
                SmartSection::NotGames => !t.path.starts_with("GAMES/"),
                SmartSection::NotDemos => !t.path.starts_with("DEMOS/"),
            }
    };
    let energy = match recipe.energy {
        SmartEnergy::Any => smart::Energy::Any,
        SmartEnergy::Calm => smart::Energy::Calm,
        SmartEnergy::Medium => smart::Energy::Medium,
        SmartEnergy::Intense => smart::Energy::Intense,
    };
    let pick = |t: &smart::Tune, rated: bool| SmartPick {
        path: t.path.clone(),
        subtune: None,
        is_version: false,
        heard: t.heard,
        intensity: rated.then_some(t.intensity),
    };
    match recipe.kind {
        SmartKind::Like => {
            let Some(seed) = seed else { return choice };
            if similar.is_empty() {
                choice.seed_not_scanned = true;
            }
            // Against the seed, so "slower" means slower than that tune.
            if energy != smart::Energy::Any {
                let pool = smart::music(&tunes);
                smart::rate_intensity(&mut tunes, &pool);
            }
            let seed_intensity = tunes.iter().find(|t| t.path == seed).map_or(0.5, |t| t.intensity);
            let suits = |t: &smart::Tune| match energy {
                smart::Energy::Any => true,
                smart::Energy::Calm => t.scanned && t.intensity < seed_intensity,
                smart::Energy::Intense => t.scanned && t.intensity > seed_intensity,
                smart::Energy::Medium => t.scanned && t.fits_energy(energy),
            };
            if recipe.other_versions {
                let title = tunes.iter().find(|t| t.path == seed).map(|t| t.title.clone()).unwrap_or_default();
                for version in smart::versions(&title, seed, &tunes) {
                    // Found by name, but what was asked for still holds.
                    if fits(version) && suits(version) {
                        choice.picks.push(SmartPick { is_version: true, ..pick(version, false) });
                    }
                }
            }
            let by_path: std::collections::HashMap<&str, &smart::Tune> =
                tunes.iter().map(|t| (t.path.as_str(), t)).collect();
            let already: std::collections::HashSet<String> = choice.picks.iter().map(|p| p.path.clone()).collect();
            for found in similar {
                let Some(rel) = collection_path(root, Path::new(&found.item.path)) else { continue };
                let Some(tune) = by_path.get(rel.as_str()) else { continue };
                if fits(tune) && suits(tune) && !already.contains(&rel) {
                    choice.picks.push(SmartPick { subtune: Some(found.subtune), ..pick(tune, false) });
                    if choice.picks.len() >= recipe.top as usize {
                        break;
                    }
                }
            }
            choice.pool = similar.len();
            if let Some(total) = recipe.total_secs {
                let mut elapsed = 0u32;
                choice.picks.retain(|p| {
                    let more = elapsed < total;
                    elapsed += by_path.get(p.path.as_str()).map_or(0, |t| t.secs);
                    more
                });
            }
        }
        SmartKind::Shuffle => {
            use rand::seq::SliceRandom;
            let rated = energy != smart::Energy::Any;
            if rated {
                let pool = smart::music(&tunes);
                smart::rate_intensity(&mut tunes, &pool);
            }
            let mut order: Vec<usize> = (0..tunes.len())
                .filter(|&i| fits(&tunes[i]) && (!rated || (tunes[i].scanned && tunes[i].fits_energy(energy))))
                .filter(|&i| recipe.total_secs.is_none() || !smart::is_slight(&tunes[i]))
                .collect();
            choice.pool = order.len();
            order.shuffle(&mut rng);
            // One composer's fast tunes read best fastest first.
            let by_title = recipe.title_words.as_deref();
            let ranked = by_title.is_some() || (rated && !recipe.composers.is_empty());
            if let Some(wanted) = by_title {
                order.sort_by_key(|&i| smart::title_rank(&tunes[i], wanted));
            } else if ranked {
                order.sort_by(|&a, &b| {
                    let ordered = tunes[a].intensity.total_cmp(&tunes[b].intensity);
                    if energy == smart::Energy::Intense { ordered.reverse() } else { ordered }
                });
            }
            let order = smart::fill(order, &tunes, recipe.total_secs);
            let order = if ranked { order } else { arrange(order, &tunes) };
            choice.picks = order.into_iter().map(|i| pick(&tunes[i], rated)).collect();
        }
        SmartKind::Alternating => {
            let total = recipe.total_secs.or(recipe.max_tunes.map(|n| n * 240)).unwrap_or(3600);
            let (order, pool) = smart::alternating(&mut tunes, total, &fits, &mut rng);
            choice.pool = pool;
            choice.picks = order.into_iter().map(|i| pick(&tunes[i], true)).collect();
        }
        SmartKind::Rising | SmartKind::Falling => {
            let total = recipe.total_secs.or(recipe.max_tunes.map(|n| n * 240)).unwrap_or(3600);
            let (order, pool) = smart::rising(&mut tunes, total, &fits, &mut rng);
            // The calm stretch has no order of its own, so it can flow; the
            // climb's order is the point.
            let calm = order.iter().take_while(|&&i| tunes[i].intensity < 0.2).count();
            let mut order: Vec<usize> =
                arrange(order[..calm].to_vec(), &tunes).into_iter().chain(order[calm..].iter().copied()).collect();
            if recipe.kind == SmartKind::Falling {
                order.reverse();
            }
            choice.pool = pool;
            choice.picks = order.into_iter().map(|i| pick(&tunes[i], true)).collect();
        }
        SmartKind::Different => {
            use rand::seq::SliceRandom;
            if heard.len() < smart::MIN_HISTORY {
                choice.needs_more_history = true;
                return choice;
            }
            let mut order = smart::different(&tunes);
            order.retain(|&i| fits(&tunes[i]));
            choice.pool = order.len();
            order.shuffle(&mut rng);
            let order = arrange(smart::fill(order, &tunes, recipe.total_secs), &tunes);
            choice.picks = order.into_iter().map(|i| pick(&tunes[i], false)).collect();
        }
    }
    if let Some(most) = recipe.max_tunes {
        choice.picks.truncate(most as usize);
    }
    choice
}

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
    /// The newest release `check_hvsc_update` found on the mirror, which
    /// the download fetches. Kept here rather than in Phosphor's config,
    /// which Resonance only reads.
    latest_hvsc: Mutex<Option<u32>>,
    /// The sound fingerprints, in `fingerprints.sqlite` next to the session.
    fingerprints: Arc<Fingerprints>,
    /// Lengths worked out for tunes outside HVSC, next to the session too.
    learned: Arc<LearnedLengths>,
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
        // The engine's files (favourites, history, the search index) go
        // next to the session playlist, in Resonance's own folder.
        if let Some(dir) = Path::new(&config.session_path).parent() {
            crate::config::set_data_dir(dir.to_path_buf());
        }
        let hvsc_root = config.hvsc_root.map(PathBuf::from);
        let fingerprints = Arc::new(Fingerprints::new(
            Path::new(&config.session_path).with_file_name("fingerprints.sqlite"),
        ));
        let learned = Arc::new(LearnedLengths::load(
            Path::new(&config.session_path).with_file_name("learned_songlengths.md5"),
        ));
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
            learned: learned.clone(),
        });
        Arc::new(Self {
            driver,
            library,
            databases,
            sync: Mutex::new(None),
            sync_state: Mutex::new(None),
            hvsc_info_cache: Mutex::new(None),
            latest_hvsc: Mutex::new(None),
            fingerprints,
            learned,
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

    /// Go to `position_ms` in the playing subtune. Only the engines with
    /// `can_seek` do; the others ignore it. The audio goes silent while the
    /// emulation runs there (about a sixtieth of the distance on reSIDfp)
    /// and `seeking` says so.
    pub fn seek(&self, position_ms: u64) {
        self.send(Command::Seek(Duration::from_millis(position_ms)));
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
        if root != self.library.root() {
            // Its tune list is the old folder's; `start_fingerprint_scan`
            // again picks up the new one.
            self.fingerprints.scanner().stop();
        }
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
            duration_is_estimate: view.current_duration_is_estimate,
            shuffle: view.shuffle,
            repeat: view.repeat.into(),
            engine: view.engine.into(),
            can_seek: view.can_seek,
            seeking: view.seeking,
            seek_position_ms: view.seek_position.map(|d| d.as_millis() as u64),
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
    /// folder, or in `HVSC` in Resonance's folder when none is set
    /// (creating it); `hvsc_sync_status()` reports where. Returns
    /// immediately.
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
            .or_else(|| crate::config::config_dir().map(|d| d.join("HVSC")))
            .ok_or(HvscError::NoRoot)?;
        let url = sync_archive_url(*self.latest_hvsc.lock().unwrap());
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

    /// The collection folder was removed on disk (Settings moved it to the
    /// Trash): drop the lists, indexes, song lengths and STIL read from it.
    pub fn reload_hvsc(&self) {
        self.fingerprints.scanner().stop();
        if let Some(root) = self.library.root() {
            self.apply_post_sync(&root);
        }
    }

    // ── Fingerprints ──

    /// The background scan's progress. Cheap; poll it like the snapshot.
    pub fn fingerprint_scan_status(&self) -> FingerprintScanStatus {
        let p = self.fingerprints.scanner().progress();
        FingerprintScanStatus {
            running: p.running,
            paused: p.paused,
            finished: p.finished,
            pass: p.pass,
            total: p.total,
            done: p.done,
            failed: p.failed,
            revision: p.revision,
            error: p.error,
        }
    }

    /// Pause or resume the scan; a paused scan holds its place.
    pub fn set_fingerprint_scan_paused(&self, paused: bool) {
        self.fingerprints.scanner().set_paused(paused);
    }

    /// Stop the scan; `start_fingerprint_scan` resumes where it stopped.
    pub fn stop_fingerprint_scan(&self) {
        self.fingerprints.scanner().stop();
    }

    pub fn playlist(&self) -> Vec<PlaylistItem> {
        self.published()
            .playlist
            .iter()
            .map(|e| PlaylistItem {
                duration_is_estimate: self.learned.is_estimate(e.md5.as_deref(), e.selected_song, e.duration_secs),
                ..PlaylistItem::from(e)
            })
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

    /// How far into the subtune what's being heard is, in seconds: after the engine's
    /// buffer and the output device. None before the first frame and while stopped.
    pub fn viz_heard_secs(&self) -> Option<f64> {
        viz::lock(&self.driver.viz).heard(Instant::now()).map(|heard| heard.as_secs_f64())
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
    pub fn viz_scope(&self, chip: u32, count: u32) -> VizScopeSamples {
        let feed = viz::lock(&self.driver.viz);
        let voices = feed.scope(Instant::now(), chip as usize, count as usize);
        let sample_rate = feed.sample_rate();
        drop(feed);
        let count = voices[0].len();
        let mut samples = Vec::with_capacity(voices.len() * count * 4);
        for voice in &voices {
            for s in voice {
                samples.extend_from_slice(&s.to_ne_bytes());
            }
        }
        VizScopeSamples {
            sample_rate,
            count: count as u32,
            samples,
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
        self.fingerprints.scanner().cancel();
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

    /// Every author folder (or section) of `category` at a glance: tune
    /// count, years, and the composer's real name. The first call reads
    /// every tune's header (a second or so), later ones reuse it.
    pub async fn hvsc_composers(&self, category: HvscCategory) -> Result<Vec<HvscComposer>, HvscError> {
        let found = self.library.composers(category.into()).await?;
        Ok(found
            .into_iter()
            .map(|c| HvscComposer {
                path: c.path.to_string_lossy().into_owned(),
                real_name: c.real_name,
                tunes: c.tunes,
                first_year: c.first_year,
                last_year: c.last_year,
            })
            .collect())
    }

    /// The composers who sound most like the one in MUSICIANS folder
    /// `author_path`, best first; empty until enough of their tunes are
    /// fingerprinted.
    pub async fn similar_composers(&self, author_path: String, limit: u32) -> Vec<SimilarComposer> {
        let Some(root) = self.library.root() else { return Vec::new() };
        let Some(folder) = collection_path(&root, Path::new(&author_path)) else { return Vec::new() };
        let fps = self.fingerprints.clone();
        tokio::task::spawn_blocking(move || {
            fps.index_for(None)
                .similar_composers(&folder, 3, limit as usize)
                .into_iter()
                .map(|(f, score)| SimilarComposer { path: root.join(f).to_string_lossy().into_owned(), score })
                .collect()
        })
        .await
        .unwrap_or_default()
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
    /// (or loads it from the index cache).
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

    /// Every tune in the collection, for Spotlight. Waits for the search
    /// indexes; empty without a collection.
    pub async fn hvsc_all_tunes(&self) -> Vec<HvscTuneItem> {
        self.library.warm_indexes().await;
        self.library
            .all_entries()
            .iter()
            .map(|(category, entry)| HvscTuneItem::from_index(entry, (*category).into()))
            .collect()
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

    /// The play history, newest first: the last 100 different tunes
    /// played, those still on disk.
    pub async fn recently_played(&self) -> Result<Vec<RecentTune>, HvscError> {
        let hits = self.library.recent().await?;
        Ok(hits
            .into_iter()
            .map(|(category, e, has_stil, played_at)| RecentTune {
                item: HvscTuneItem::from_file(category, e, has_stil, &self.learned),
                played_at,
            })
            .collect())
    }

    /// The tunes at `paths` (a playlist's files), in that order, inside
    /// the collection or not; files no longer on disk are left out.
    pub async fn tunes_from_files(&self, paths: Vec<String>) -> Vec<HvscTuneItem> {
        self.library
            .files(paths.into_iter().map(PathBuf::from).collect())
            .await
            .into_iter()
            .map(|(category, e, has_stil)| HvscTuneItem::from_file(category, e, has_stil, &self.learned))
            .collect()
    }

    /// Expand files, folders and M3U/PLS playlists into their tunes,
    /// without adding them anywhere. A playlist's relative paths are tried
    /// next to it, then in the collection.
    pub async fn resolve_files(&self, paths: Vec<String>) -> ResolvedFiles {
        let root = self.library.root();
        tokio::task::spawn_blocking(move || {
            let paths = paths.into_iter().map(PathBuf::from).collect();
            let resolved = crate::driver::resolve_tunes(paths, root);
            ResolvedFiles {
                paths: resolved
                    .files
                    .iter()
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect(),
                found: resolved.found,
                listed: resolved.listed,
            }
        })
        .await
        .unwrap_or_default()
    }

    // ── Favourites (favorites.json, in Phosphor's format) ──

    /// The favourite tunes' files, newest first. A file that moved is
    /// found again by its MD5 in the collection (Phosphor's fallback), and
    /// the healed path saved; favourites found nowhere are left out.
    pub async fn favorite_paths(&self) -> Vec<String> {
        let db = databases::loaded(&self.databases).await;
        let root = self.library.root();
        tokio::task::spawn_blocking(move || {
            let mut favorites = crate::favorites::FavoritesDb::load();
            let before: Vec<_> = favorites.entries.iter().map(|e| e.path.clone()).collect();
            let paths: Vec<String> = (0..favorites.entries.len())
                .filter_map(|i| favorites.resolve(i, db.songlengths.as_ref(), root.as_deref()))
                .map(|p| p.to_string_lossy().into_owned())
                .collect();
            if favorites.entries.iter().map(|e| &e.path).ne(before.iter()) {
                favorites.save();
            }
            paths
        })
        .await
        .unwrap_or_default()
    }

    /// Make the tune at `path` a favourite, or not.
    pub async fn set_favorite(&self, path: String, favorite: bool) -> Result<(), HvscError> {
        tokio::task::spawn_blocking(move || {
            let entry = PlaylistEntry::from_path(Path::new(&path)).map_err(|message| HvscError::Io { message })?;
            let mut favorites = crate::favorites::FavoritesDb::load();
            if favorite {
                favorites.upsert(&entry);
            } else if let Some(md5) = entry.md5.as_deref() {
                favorites.remove(&md5.to_lowercase());
            }
            favorites.save();
            Ok(())
        })
        .await
        .map_err(|e| HvscError::Io { message: e.to_string() })?
    }

    /// How many different tunes have ever been played.
    pub async fn heard_count(&self) -> u32 {
        tokio::task::spawn_blocking(crate::history::heard_count)
            .await
            .unwrap_or(0) as u32
    }

    /// Empty the play history.
    pub async fn clear_recently_played(&self) {
        let _ = tokio::task::spawn_blocking(crate::history::clear_recent).await;
    }

    /// Forget every tune played, for the heard count.
    pub async fn reset_heard(&self) {
        let _ = tokio::task::spawn_blocking(crate::history::reset_heard).await;
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

    /// Fingerprint every tune in the collection in the background: start
    /// songs first, then the other subtunes, skipping what earlier scans
    /// saved. Returns once the scan has started (after the search indexes
    /// load); a no-op while one runs.
    pub async fn start_fingerprint_scan(&self) -> Result<(), HvscError> {
        let root = self.library.root().ok_or(HvscError::NoRoot)?;
        let scanner = self.fingerprints.scanner();
        // A stopped scan still winding down gets replaced.
        if scanner.is_running() && !scanner.is_stopping() {
            return Ok(());
        }
        self.library.warm_indexes().await;
        let db = databases::loaded(&self.databases).await;
        let indexed = self.library.indexed_tunes();
        let songs = indexed.iter().map(|(_, n)| (*n).max(1) as u32).sum();
        let tunes = indexed
            .into_iter()
            .filter_map(|(path, _)| {
                let rel = collection_path(&root, &path)?;
                Some(ScanTune { path, rel })
            })
            .collect();
        self.fingerprints.scanner().start(tunes, songs, db);
        Ok(())
    }

    /// Scan the tunes the scan gave up on again: forgets them and restarts
    /// the scan.
    pub async fn retry_failed_fingerprints(&self) -> Result<(), HvscError> {
        self.forget_fingerprints(true).await?;
        self.start_fingerprint_scan().await
    }

    /// Throw every fingerprint away and scan the collection from the start.
    pub async fn rebuild_fingerprints(&self) -> Result<(), HvscError> {
        self.forget_fingerprints(false).await?;
        self.start_fingerprint_scan().await
    }

    /// Merge a fingerprint set (a fingerprints.sqlite, like the one
    /// Resonance publishes) into this Mac's, then scan what's still
    /// missing. Returns how many fingerprints were added.
    pub async fn import_fingerprints(&self, path: String) -> Result<u32, HvscError> {
        let fps = self.fingerprints.clone();
        let added = tokio::task::spawn_blocking(move || fps.import(Path::new(&path)))
            .await
            .map_err(|e| HvscError::Io { message: e.to_string() })?
            .map_err(|message| HvscError::Io { message })?;
        // The fingerprints are in even if there's no collection to scan.
        let _ = self.start_fingerprint_scan().await;
        Ok(added as u32)
    }

    /// Download the published fingerprint set for this extractor (a zip
    /// holding fingerprints.sqlite, about 42 MB) and merge it in, so Sounds
    /// Like works without hours of scanning; the scan then fills in the
    /// rest. Returns how many fingerprints were added.
    pub async fn download_fingerprints(&self) -> Result<u32, HvscError> {
        let url = format!(
            "https://github.com/ErikLuimes/resonance/releases/download/fingerprints/fingerprints-x{}.zip",
            fingerprint::EXTRACTOR_VERSION
        );
        let seed = download_store_file(&self.fingerprints, &url, "fingerprints.sqlite").await?;
        let added = self.import_fingerprints(seed.to_string_lossy().into_owned()).await;
        remove_store_file(&seed);
        added
    }

    /// Whether the published audio embeddings are here.
    pub async fn has_embeddings(&self) -> bool {
        let fps = self.fingerprints.clone();
        tokio::task::spawn_blocking(move || fps.has_embeddings()).await.unwrap_or(false)
    }

    /// Download the published audio embeddings (the release asset
    /// embeddings-e<N>.zip, about 11 MB) for "Sounds like". Without them it
    /// goes by the fingerprints alone.
    pub async fn download_embeddings(&self) -> Result<u32, HvscError> {
        let url = format!(
            "https://github.com/ErikLuimes/resonance/releases/download/fingerprints/embeddings-e{}.zip",
            fingerprint::EMBEDDING_SET
        );
        let seed = download_store_file(&self.fingerprints, &url, "embeddings.sqlite").await?;
        let fps = self.fingerprints.clone();
        let path = seed.clone();
        let added = tokio::task::spawn_blocking(move || fps.import_embeddings(&path))
            .await
            .map_err(|e| HvscError::Io { message: e.to_string() })?;
        remove_store_file(&seed);
        added.map(|n| n as u32).map_err(|message| HvscError::Io { message })
    }

    /// Fingerprints for the tunes at `paths` (files in the collection),
    /// in that order: each one's start song, or None where the scan hasn't
    /// reached it.
    pub async fn fingerprints(&self, paths: Vec<String>) -> Vec<Option<TuneFingerprint>> {
        let root = self.library.root();
        let fps = self.fingerprints.clone();
        tokio::task::spawn_blocking(move || {
            paths
                .iter()
                .map(|p| {
                    let rel = collection_path(root.as_deref()?, Path::new(p))?;
                    fps.lookup(&rel, None).map(|(sub, fp)| TuneFingerprint::new(sub, &fp))
                })
                .collect()
        })
        .await
        .unwrap_or_default()
    }

    /// How common each sound is across the collection's fingerprinted tunes;
    /// empty while none are.
    pub async fn sound_tag_shares(&self) -> Vec<SoundTagShare> {
        let fps = self.fingerprints.clone();
        tokio::task::spawn_blocking(move || {
            let counts = fps.tag_counts();
            let total: u32 = counts.iter().map(|(_, tunes)| tunes).sum();
            if total == 0 {
                return Vec::new();
            }
            sound_tag_bits()
                .into_iter()
                .map(|(bit, tag)| {
                    let with: u32 = counts.iter().filter(|(tags, _)| tags & bit != 0).map(|(_, tunes)| tunes).sum();
                    SoundTagShare { tag, share: with as f32 / total as f32 }
                })
                .collect()
        })
        .await
        .unwrap_or_default()
    }

    /// One subtune's fingerprint (the start song when `subtune` is None).
    pub async fn fingerprint(&self, path: String, subtune: Option<u16>) -> Option<TuneFingerprint> {
        let rel = collection_path(&self.library.root()?, Path::new(&path))?;
        let fps = self.fingerprints.clone();
        tokio::task::spawn_blocking(move || {
            fps.lookup(&rel, subtune).map(|(sub, fp)| TuneFingerprint::new(sub, &fp))
        })
        .await
        .ok()
        .flatten()
    }

    /// How alike each tune at `paths` sounds to the one at `seed` (start
    /// songs), −1…1, in that order; None where either isn't scanned yet.
    /// For sorting a list by sound.
    pub async fn similarity(&self, seed: String, paths: Vec<String>) -> Vec<Option<f32>> {
        let Some(root) = self.library.root() else {
            return vec![None; paths.len()];
        };
        let fps = self.fingerprints.clone();
        tokio::task::spawn_blocking(move || {
            let seed = collection_path(&root, Path::new(&seed));
            let index = fps.index_for(seed.as_deref());
            paths
                .iter()
                .map(|p| {
                    let rel = collection_path(&root, Path::new(p))?;
                    index.score(seed.as_deref()?, &rel)
                })
                .collect()
        })
        .await
        .unwrap_or_default()
    }

    /// "Sounds like": up to `limit` tunes whose fingerprints are closest to
    /// the one at `path` (`subtune`, or its start song), best first, one
    /// subtune per file. Empty until the scan has reached the tune.
    pub async fn similar_tunes(
        &self,
        path: String,
        subtune: Option<u16>,
        limit: u32,
    ) -> Result<Vec<SimilarTune>, HvscError> {
        let root = self.library.root().ok_or(HvscError::NoRoot)?;
        let Some(rel) = collection_path(&root, Path::new(&path)) else {
            return Ok(Vec::new());
        };
        let fps = self.fingerprints.clone();
        // A few spare, for files the indexes no longer have.
        let want = limit as usize;
        let matches: Vec<(PathBuf, u16, f32)> = tokio::task::spawn_blocking(move || {
            let index = fps.index_for(Some(&rel));
            index
                .similar(&rel, subtune, want + 8)
                .into_iter()
                .map(|m| (root.join(m.path), m.subtune, m.score))
                .collect()
        })
        .await
        .map_err(|e| HvscError::Io { message: e.to_string() })?;

        let items = self
            .library
            .tunes_at(matches.iter().map(|(p, _, _)| p.clone()).collect())
            .await?;
        let mut by_path: std::collections::HashMap<PathBuf, HvscTuneItem> = items
            .into_iter()
            .map(|(category, entry, author)| {
                let item = HvscTuneItem::from_index(&entry, category.into());
                let item = if author.is_empty() { item } else { HvscTuneItem { author, ..item } };
                (entry.path, item)
            })
            .collect();
        Ok(matches
            .into_iter()
            .filter_map(|(path, subtune, score)| {
                let mut item = by_path.remove(&path)?;
                item.start_song = subtune;
                Some(SimilarTune { item, subtune, score })
            })
            .take(want)
            .collect())
    }

    /// A tune as a tracker would show it, rebuilt from what its player writes: `secs` of
    /// it, one chip's voices. Runs it once at about 200× speed, away from the player.
    pub async fn tracker_song(&self, path: String, subtune: u16, secs: f64, chip: u32) -> Result<crate::tracker::TrackerSong, HvscError> {
        tokio::task::spawn_blocking(move || {
            let data = std::fs::read(&path).map_err(|e| HvscError::Io { message: e.to_string() })?;
            let made = crate::tracker::tracker_song(&data, subtune, secs, chip as usize, &|| false);
            match made {
                Ok(Some(song)) => Ok(song),
                Ok(None) => Err(HvscError::Io { message: "Stopped.".into() }),
                Err(message) => Err(HvscError::Io { message }),
            }
        })
        .await
        .map_err(|e| HvscError::Io { message: e.to_string() })?
    }

    /// Make a smart playlist. Song lengths, the fingerprints and the heard
    /// list decide; nothing leaves the Mac.
    pub async fn smart_playlist(&self, recipe: SmartRecipe) -> Result<SmartPlaylist, HvscError> {
        let root = self.library.root().ok_or(HvscError::NoRoot)?;
        self.library.warm_indexes().await;
        let library = self.library.clone();
        let fps = self.fingerprints.clone();
        let seed_rel = recipe.seeds.first().and_then(|s| collection_path(&root, Path::new(s)));
        // Narrowing happens after, so it needs the whole list to narrow.
        let narrows = !recipe.composers.is_empty()
            || !recipe.sounds.is_empty()
            || recipe.energy != SmartEnergy::Any
            || recipe.chip != SmartChip::Any
            || recipe.min_chips.is_some()
            || recipe.max_chips.is_some()
            || recipe.section != SmartSection::Any
            || recipe.only_unheard
            || recipe.min_secs > 0;
        let wanted = if narrows { 100_000 } else { recipe.top };
        let mut similar = Vec::new();
        if recipe.kind == SmartKind::Like {
            let mut lists = Vec::new();
            for seed in &recipe.seeds {
                lists.push(self.similar_tunes(seed.clone(), None, wanted).await?.into_iter());
            }
            // Taking turns, closest first, so each seed is heard.
            let mut seen = std::collections::HashSet::new();
            loop {
                let mut any = false;
                for list in &mut lists {
                    if let Some(tune) = list.next() {
                        any = true;
                        if seen.insert(tune.item.path.clone()) {
                            similar.push(tune);
                        }
                    }
                }
                if !any {
                    break;
                }
            }
        }
        let root_for_tunes = root.clone();
        let chosen = tokio::task::spawn_blocking(move || {
            smart_choose(&recipe, &root_for_tunes, seed_rel.as_deref(), &library, &fps, &similar)
        })
        .await
        .map_err(|e| HvscError::Io { message: e.to_string() })?;
        let paths: Vec<PathBuf> = chosen.picks.iter().map(|p| root.join(&p.path)).collect();
        let items = self.library.tunes_at(paths).await?;
        let mut by_path: std::collections::HashMap<PathBuf, HvscTuneItem> = items
            .into_iter()
            .map(|(category, entry, author)| {
                let item = HvscTuneItem::from_index(&entry, category.into());
                let item = if author.is_empty() { item } else { HvscTuneItem { author, ..item } };
                (entry.path, item)
            })
            .collect();
        let tunes: Vec<SmartTune> = chosen
            .picks
            .into_iter()
            .filter_map(|p| {
                let mut item = by_path.remove(&root.join(&p.path))?;
                if let Some(subtune) = p.subtune {
                    item.start_song = subtune;
                }
                Some(SmartTune { item, is_version: p.is_version, heard: p.heard, intensity: p.intensity })
            })
            .collect();
        let total_secs = tunes.iter().map(|t| u64::from(t.item.duration_secs.unwrap_or(0))).sum();
        Ok(SmartPlaylist {
            tunes,
            total_secs,
            pool: chosen.pool as u32,
            heard: chosen.heard as u32,
            needs_more_history: chosen.needs_more_history,
            seed_not_scanned: chosen.seed_not_scanned,
        })
    }

    /// Every composer with a MUSICIANS folder, for reading sentences: the
    /// name their tunes' headers give most, and any nickname those hold.
    pub async fn smart_composers(&self) -> Vec<SmartComposer> {
        let credits = self.library.musician_credits().await.unwrap_or_default();
        tokio::task::spawn_blocking(move || smart_composers_from(&credits)).await.unwrap_or_default()
    }

    /// Every distinct title, for recognising one in a sentence.
    pub async fn smart_titles(&self) -> Vec<String> {
        self.library.warm_indexes().await;
        let library = self.library.clone();
        tokio::task::spawn_blocking(move || {
            let titles: std::collections::BTreeSet<String> =
                library.all_entries().iter().map(|(_, e)| e.title.clone()).collect();
            titles.into_iter().collect()
        })
        .await
        .unwrap_or_default()
    }

    /// Tunes whose title holds every word of `name`, for picking a tune by
    /// name ("Second Reality" finds "2nd Reality").
    pub async fn smart_find_tunes(&self, name: String, limit: u32) -> Vec<HvscTuneItem> {
        self.library.warm_indexes().await;
        let library = self.library.clone();
        let paths: Vec<PathBuf> = tokio::task::spawn_blocking(move || {
            let tunes: Vec<smart::Tune> = library
                .all_entries()
                .iter()
                .map(|(_, e)| smart::Tune {
                    path: e.path.to_string_lossy().into_owned(),
                    title: e.title.clone(),
                    author: e.author_raw.clone(),
                    year: e.released.get(..4).and_then(|y| y.parse().ok()),
                    ..smart::Tune::default()
                })
                .collect();
            smart::find_by_name(&name, &tunes, limit as usize).iter().map(|t| PathBuf::from(&t.path)).collect()
        })
        .await
        .unwrap_or_default();
        let items = self.library.tunes_at(paths).await.unwrap_or_default();
        items
            .into_iter()
            .map(|(category, entry, author)| {
                let item = HvscTuneItem::from_index(&entry, category.into());
                if author.is_empty() { item } else { HvscTuneItem { author, ..item } }
            })
            .collect()
    }

    /// The tune at `path` as something to share (its MD5 and HVSC path),
    /// or nil when HVSC doesn't list it.
    pub async fn shareable_tune(&self, path: String) -> Option<ShareableTune> {
        let db = databases::loaded(&self.databases).await;
        let root = self.library.root();
        tokio::task::spawn_blocking(move || crate::share::shareable(root.as_deref(), &db, Path::new(&path)))
            .await
            .ok()
            .flatten()
    }

    /// Find a shared tune in this collection: by `md5` (Songlengths.md5's
    /// key, the same file in any release, or the 12-character share code
    /// web links carry), else by `hvsc_path` ("/MUSICIANS/…"), which the
    /// app's link carries for older releases.
    pub async fn find_shared_tune(&self, md5: String, hvsc_path: Option<String>) -> SharedTuneMatch {
        let db = databases::loaded(&self.databases).await;
        let root = self.library.root();
        tokio::task::spawn_blocking(move || {
            crate::share::find(root.as_deref(), &db, &md5, hvsc_path.as_deref())
        })
        .await
        .unwrap_or(SharedTuneMatch { path: None, same_file: false, installed_hvsc: None })
    }

    /// Ask the mirror for its newest HVSC release (the version in the
    /// first kilobyte of its STIL.txt, as Phosphor checks), and remember it
    /// for the next download.
    pub async fn check_hvsc_update(&self) -> Result<HvscVersionCheck, HvscError> {
        let mirror = crate::config::DEFAULT_HVSC_MIRROR_URL;
        let latest = crate::stil::check_hvsc_update(&mirror)
            .await
            .map_err(|message| HvscError::Io { message })?
            .remote_version;
        *self.latest_hvsc.lock().unwrap() = Some(latest);
        let installed = databases::loaded(&self.databases).await.hvsc_version;
        Ok(HvscVersionCheck { latest, installed })
    }

    /// Bring the curated playlists up to date from Resonance's repository
    /// (see `curated`), as Phosphor does at every launch. `bundled` is the
    /// app's own copy, which fills an empty cache first, so the playlists
    /// are there on the first launch even offline. Returns how many
    /// playlists were downloaded.
    pub async fn sync_published_playlists(&self, bundled: Option<String>) -> Result<u32, HvscError> {
        let io = |message: String| HvscError::Io { message };
        let dir = crate::published_playlists::cache_dir().ok_or_else(|| io("No config folder.".to_string()))?;
        if let Some(bundled) = bundled {
            let seeded = tokio::task::spawn_blocking({
                let dir = dir.clone();
                move || crate::curated::seed(std::path::Path::new(&bundled), &dir)
            })
            .await
            .map_err(|e| io(e.to_string()))?
            .map_err(|e| io(e.to_string()))?;
            if seeded {
                // The Home's metadata lists them.
                *self.hvsc_info_cache.lock().unwrap() = None;
            }
        }
        let downloaded = crate::curated::sync(&dir).await.map_err(io)?;
        if downloaded > 0 {
            *self.hvsc_info_cache.lock().unwrap() = None;
        }
        Ok(downloaded)
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
    async fn forget_fingerprints(&self, failed_only: bool) -> Result<(), HvscError> {
        let fps = self.fingerprints.clone();
        tokio::task::spawn_blocking(move || fps.forget(failed_only))
            .await
            .map_err(|e| HvscError::Io { message: e.to_string() })?
            .map_err(|e| HvscError::Io { message: e.to_string() })
    }

    fn apply_post_sync(&self, root: &Path) {
        crate::hvsc_index_cache::clear_all();
        self.library.refresh();
        databases::install(&self.databases, databases::Databases::load_with_tree(Some(root)));
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

/// The version of upstream Phosphor whose engine this build compiles in.
#[uniffi::export]
pub fn phosphor_version() -> String {
    env!("PHOSPHOR_VERSION").to_string()
}

fn to_usize(v: Vec<u32>) -> Vec<usize> {
    v.into_iter().map(|i| i as usize).collect()
}

/// The archive to download: the default mirror's `<N>-all-of-them`
/// archive at `latest` (the release the update check found). Follows
/// upstream's `HvscZipSyncStart` resolution with its default settings;
/// unlike it, an unrecognised mirror host falls back to brona.dk's, the
/// canonical mirror, rather than dead-ending.
fn sync_archive_url(latest: Option<u32>) -> String {
    // Upstream's defaults: Resonance doesn't read Phosphor's config.json.
    let config = crate::config::Config::default();
    let latest = latest.map(|v| format!("v{v}"));
    config
        .hvsc_zip_url
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| {
            hvsc_sync::default_hvsc_zip_url(
                &config.hvsc_mirror_url,
                latest.as_deref().or(config.hvsc_known_version.as_deref()),
            )
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
    /// A tune read from its file (`Library::files`, the history).
    fn from_file(
        category: Option<hvsc_browser::HvscCategory>,
        e: PlaylistEntry,
        has_stil: bool,
        learned: &LearnedLengths,
    ) -> Self {
        let subtune = e.selected_song.saturating_sub(1) as usize;
        let duration_secs = e
            .duration_secs
            .or_else(|| learned.lookup(e.md5.as_deref()?, subtune));
        HvscTuneItem {
            path: e.path.to_string_lossy().into_owned(),
            title: e.title,
            author: e.author,
            released: e.released,
            songs: e.songs,
            start_song: e.selected_song,
            duration_secs,
            duration_is_estimate: learned.is_estimate(e.md5.as_deref(), e.selected_song, duration_secs),
            has_stil,
            is_rsid: Some(e.is_rsid),
            // Outside the collection: filed with the musicians, where the
            // inspector looks for a composer anyway.
            category: category.unwrap_or(hvsc_browser::HvscCategory::Musicians).into(),
        }
    }

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
            duration_is_estimate: false,
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
            duration_is_estimate: false,
            has_stil: e.has_stil,
            is_rsid: None,
            category,
        }
    }
}

/// `path` relative to the collection root, '/'-separated, as the
/// fingerprint store keys it.
fn collection_path(root: &Path, path: &Path) -> Option<String> {
    let rel = path.strip_prefix(root).ok()?;
    let parts: Vec<&str> = rel.components().filter_map(|c| c.as_os_str().to_str()).collect();
    (!parts.is_empty()).then(|| parts.join("/"))
}

/// Each sound tag with its bit in a stored fingerprint.
fn sound_tag_bits() -> [(u32, SoundTag); 8] {
    use fingerprint::tag;
    [
        (tag::ARPEGGIOS, SoundTag::Arpeggios),
        (tag::FILTER_SWEEPS, SoundTag::FilterSweeps),
        (tag::NOISE_DRUMS, SoundTag::NoiseDrums),
        (tag::RING_MOD, SoundTag::RingMod),
        (tag::SYNC_LEADS, SoundTag::SyncLeads),
        (tag::DIGI, SoundTag::DigiSamples),
        (tag::PULSE_BASS, SoundTag::PulseBass),
        (tag::VIBRATO, SoundTag::VibratoLeads),
    ]
}

impl TuneFingerprint {
    fn new(subtune: u16, fp: &fingerprint::Fingerprint) -> Self {
        let tags = sound_tag_bits()
            .into_iter()
        .filter(|(bit, _)| fp.tags & bit != 0)
        .map(|(_, t)| t)
        .collect();
        TuneFingerprint {
            subtune,
            scanned_secs: fp.scanned_secs,
            activity: fp.activity.iter().flatten().copied().collect(),
            bins: fingerprint::BINS as u32,
            mix: WaveformMix {
                triangle: fp.mix[0],
                saw: fp.mix[1],
                pulse: fp.mix[2],
                noise: fp.mix[3],
            },
            tags,
            notes_per_sec: fp.notes_per_sec,
            arpeggio_rate: fp.arp_rate,
            filter_usage: fp.filter_usage,
            ring_mod: fp.ring,
            sync: fp.sync,
            digi: fp.digi,
            pulse_width_depth: fp.pwm_depth,
            vibrato_rate: fp.vibrato_rate,
            noise_hits: fp.noise_hits,
            traits: fp.traits().to_vec(),
            chips: fp.num_chips,
            silent: fp.is_silent(),
        }
    }
}

impl From<Engine> for session::Engine {
    fn from(e: Engine) -> Self {
        match e {
            Engine::SidLite => session::Engine::SidLite,
            Engine::ReSid => session::Engine::ReSid,
            Engine::ReSidFp => session::Engine::ReSidFp,
            Engine::SidLiteDirect => session::Engine::SidLiteDirect,
        }
    }
}

impl From<session::Engine> for Engine {
    fn from(e: session::Engine) -> Self {
        match e {
            session::Engine::SidLite => Engine::SidLite,
            session::Engine::ReSid => Engine::ReSid,
            session::Engine::ReSidFp => Engine::ReSidFp,
            session::Engine::SidLiteDirect => Engine::SidLiteDirect,
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
            duration_is_estimate: false,
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

/// Fetch a zip from a release and unpack its `entry` next to the store.
async fn download_store_file(
    fingerprints: &fingerprint::Fingerprints,
    url: &str,
    entry: &str,
) -> Result<PathBuf, HvscError> {
    let io = |message: String| HvscError::Io { message };
    let dir = fingerprints
        .scanner()
        .db_path()
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| io("No folder for the fingerprints.".to_string()))?;
    let builder = reqwest::Client::builder().user_agent("Resonance").timeout(Duration::from_secs(300));
    let client = crate::config::apply_proxy(builder).build().map_err(|e| io(e.to_string()))?;
    let response = client.get(url).send().await.map_err(|e| io(format!("Couldn't reach GitHub: {e}")))?;
    if !response.status().is_success() {
        return Err(io(format!("The fingerprint set isn't available ({}).", response.status())));
    }
    let zip = response.bytes().await.map_err(|e| io(format!("The download stopped: {e}")))?;
    let seed = dir.join(format!("download-{entry}"));
    let unpacked = seed.clone();
    let entry = entry.to_string();
    tokio::task::spawn_blocking(move || -> Result<(), String> {
        // The zip checks each file's CRC as it's read.
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip)).map_err(|e| e.to_string())?;
        let mut entry = archive.by_name(&entry).map_err(|e| e.to_string())?;
        let mut out = std::fs::File::create(&unpacked).map_err(|e| e.to_string())?;
        std::io::copy(&mut entry, &mut out).map_err(|e| format!("The download is damaged: {e}"))?;
        Ok(())
    })
    .await
    .map_err(|e| io(e.to_string()))?
    .map_err(io)?;
    Ok(seed)
}

fn remove_store_file(seed: &Path) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", seed.display()));
    }
}
