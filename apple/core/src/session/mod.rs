//! Headless player session — the part of the Iced `App` (src/main.rs) that
//! turns the engine into a music player: playlist, transport, subtunes,
//! auto-advance and songlengths.
//!
//! `Session` is a plain state machine: no threads, no clock of its own, and
//! every method that cares about time takes `now`. The driver thread owns it
//! and feeds it commands, player statuses and ticks; tests drive it directly
//! with fake channels.
//!
//! Each ported block names its origin in main.rs so upstream changes there
//! can be carried over by hand.

mod advance;
pub(crate) mod persist;
#[cfg(test)]
mod tests;

use std::path::PathBuf;
use std::time::{Duration, Instant};

use crossbeam_channel::Sender;

use crate::player::pseudo_stereo::DetuneStrength;
use crate::player::{PlayState, PlayerCmd, PlayerStatus};
use crate::playlist::{Playlist, PlaylistEntry, RepeatMode, SonglengthDb};

/// Software engines only. "auto" and "usb" would make `create_engine` try
/// the USB bridge daemon (and its osascript install prompt) first; "u64" is
/// a later milestone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Engine {
    SidLite,
    ReSid,
}

impl Engine {
    /// The name `sid_device::create_engine` understands.
    pub fn as_engine_name(self) -> &'static str {
        match self {
            Engine::SidLite => "sidlite",
            Engine::ReSid => "emulated",
        }
    }
}

/// Playback settings that `play_cmd` and the songlength logic read. The
/// Iced app keeps these in `Config`; here they come from the Swift app's own
/// preferences so nothing is written back to the shared config.json.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Options {
    pub skip_rsid: bool,
    /// Seconds; 0 = no default (unknown lengths rely on silence detection).
    pub default_song_length_secs: u32,
    pub force_stereo_2sid: bool,
    pub pseudo_stereo: Option<DetuneStrength>,
}

pub struct Session {
    cmd_tx: Sender<PlayerCmd>,
    pub(crate) playlist: Playlist,
    /// Latest status from the player thread, with timing fields zeroed when
    /// it belongs to a track or subtune we've already moved away from.
    pub(crate) status: PlayerStatus,
    songlength_db: Option<SonglengthDb>,
    hvsc_root: Option<PathBuf>,
    pub(crate) options: Options,
    pub(crate) engine: Engine,

    /// Last time a fresh status reported SID register writes. Silence
    /// detection measures from here.
    last_writes_at: Instant,
    /// Debounce for auto-advance (main.rs `last_advance_at`).
    last_advance_at: Option<Instant>,

    /// Bumped whenever anything visible in the playlist changes (rows,
    /// order, selected subtune, durations). Drives Swift refetches and the
    /// session autosave.
    pub(crate) playlist_revision: u64,
    /// Bumped on every Play / subtune change (drives Now Playing updates).
    pub(crate) track_revision: u64,
}

impl Session {
    pub fn new(
        cmd_tx: Sender<PlayerCmd>,
        options: Options,
        engine: Engine,
        hvsc_root: Option<PathBuf>,
        now: Instant,
    ) -> Self {
        Self {
            cmd_tx,
            playlist: Playlist::new(),
            status: PlayerStatus::default(),
            songlength_db: None,
            hvsc_root,
            options,
            engine,
            last_writes_at: now,
            last_advance_at: None,
            playlist_revision: 0,
            track_revision: 0,
        }
    }

    // ── Player I/O ────────────────────────────────────────────────────────

    /// Point the session at a freshly spawned player thread (after the old
    /// one died). The new player starts out stopped.
    pub fn set_player(&mut self, cmd_tx: Sender<PlayerCmd>) {
        self.cmd_tx = cmd_tx;
        self.status = PlayerStatus::default();
        self.last_advance_at = None;
    }

    /// Queue a command without ever blocking (main.rs `send_cmd`). The
    /// channel only fills when the player thread is stalled; dropping beats
    /// freezing the caller.
    fn send(&self, cmd: PlayerCmd) {
        if let Err(e) = self.cmd_tx.try_send(cmd) {
            eprintln!("[resonance] player command dropped (player stalled?): {e:?}");
        }
    }

    /// Take in every status drained from the player since the last call
    /// (main.rs `poll_status`, first half). The last one wins; any fresh one
    /// with SID writes resets the silence clock.
    pub fn ingest_statuses(
        &mut self,
        statuses: impl IntoIterator<Item = PlayerStatus>,
        now: Instant,
    ) {
        let mut latest = None;
        for status in statuses {
            if status.writes_per_frame > 0 && !self.is_stale(&status) {
                self.last_writes_at = now;
            }
            latest = Some(status);
        }
        let Some(mut status) = latest else { return };

        // Drop timing from statuses produced before our latest Play /
        // SetSubtune reached the player (main.rs:4839-4868). Upstream only
        // compares the subtune; comparing the path as well also catches the
        // previous track's last frames arriving after a Play, which would
        // otherwise advance straight past the new track.
        if self.is_stale(&status) {
            status.elapsed = Duration::ZERO;
            status.writes_per_frame = 0;
            status.u64_screen_elapsed_secs = None;
            status.u64_screen_read_at = None;
            status.u64_screen_total_secs = None;
        }
        self.status = status;
    }

    fn is_stale(&self, status: &PlayerStatus) -> bool {
        match (status.track_info.as_ref(), self.playlist.current_entry()) {
            (Some(info), Some(entry)) => {
                info.path != entry.path || info.current_song != entry.selected_song
            }
            _ => false,
        }
    }

    /// Reset everything auto-advance reads (main.rs `clear_advance_status`).
    /// Must follow every Play / SetSubtune so the previous song's elapsed
    /// time can't trigger another advance before the player catches up.
    fn clear_advance_status(&mut self, now: Instant) {
        self.status.elapsed = Duration::ZERO;
        self.status.writes_per_frame = 0;
        self.status.u64_screen_elapsed_secs = None;
        self.status.u64_screen_read_at = None;
        self.status.u64_screen_total_secs = None;
        self.last_writes_at = now;
    }

    /// Build `PlayerCmd::Play` from the current options (main.rs `play_cmd`).
    /// The USB / U64 / `--sid4` fields have no meaning for software engines.
    fn play_cmd(&self, path: PathBuf, song: u16) -> PlayerCmd {
        PlayerCmd::Play {
            path,
            song,
            force_stereo: self.options.force_stereo_2sid,
            pseudo_stereo: self.options.pseudo_stereo,
            sid4_addr: 0,
            audio_port: None,
            restart_usb_on_load: false,
        }
    }

    // ── Transport ─────────────────────────────────────────────────────────

    /// main.rs `play_track`, minus the recently-played / heard / favourites
    /// bookkeeping, karaoke, tracker and STIL.
    ///
    /// Skip-RSID is a bounded loop rather than upstream's recursion
    /// (main.rs:4395), which never terminates when every entry is RSID and
    /// repeat is All.
    pub fn play_track(&mut self, idx: usize, now: Instant) {
        let mut idx = idx;
        for _ in 0..=self.playlist.len() {
            let Some(entry) = self.playlist.entries.get(idx) else {
                return;
            };
            if self.options.skip_rsid && entry.is_rsid {
                eprintln!("[resonance] Skipping RSID tune: \"{}\"", entry.title);
                self.playlist.current = Some(idx);
                match self.playlist.next() {
                    Some(next) if next != idx => {
                        idx = next;
                        continue;
                    }
                    _ => break,
                }
            }

            let cmd = self.play_cmd(entry.path.clone(), entry.selected_song);
            self.playlist.current = Some(idx);
            self.send(cmd);
            self.clear_advance_status(now);
            // Fresh track — the previous track's debounce must not gate
            // this one's first auto-advance (main.rs:4444-4446).
            self.last_advance_at = None;
            self.track_revision += 1;
            return;
        }
        // Nothing playable left.
        self.stop();
    }

    /// main.rs `Message::PlayPause`. When stopped, starts `fallback` (the
    /// UI's selection), else the current entry, else the first.
    pub fn play_pause(&mut self, fallback: Option<usize>, now: Instant) {
        if self.status.state == PlayState::Stopped {
            let idx = fallback
                .or(self.playlist.current)
                .or((!self.playlist.is_empty()).then_some(0));
            if let Some(i) = idx {
                self.play_track(i, now);
            }
        } else {
            self.send(PlayerCmd::TogglePause);
            // A stale pre-pause timestamp must not gate the first advance
            // after resuming.
            self.last_advance_at = None;
        }
    }

    pub fn stop(&mut self) {
        self.send(PlayerCmd::Stop);
        self.last_advance_at = None;
    }

    /// Honours shuffle and repeat via `Playlist::next` — unlike the HTTP
    /// remote's `cur + 1` (main.rs:5301).
    pub fn next(&mut self, now: Instant) {
        if let Some(idx) = self.playlist.next() {
            self.play_track(idx, now);
        }
    }

    /// More than 3 s in restarts the current track, like most players
    /// (main.rs `Message::PrevTrack`).
    pub fn previous(&mut self, now: Instant) {
        if self.status.elapsed.as_secs() > 3 {
            if let Some(idx) = self.playlist.current {
                self.play_track(idx, now);
            }
        } else if let Some(idx) = self.playlist.prev() {
            self.play_track(idx, now);
        }
    }

    // ── Subtunes ──────────────────────────────────────────────────────────

    /// Jump to `song` (1-based) of the playing tune, clamped to its range
    /// (main.rs `Message::Next/PrevSubtune`).
    pub fn set_subtune(&mut self, song: u16, now: Instant) {
        let Some(info) = self.status.track_info.as_ref() else {
            return;
        };
        let song = song.clamp(1, info.songs.max(1));
        if song == info.current_song {
            return;
        }
        self.send(PlayerCmd::SetSubtune(song));
        self.clear_advance_status(now);
        self.update_entry_subtune(song);
        self.track_revision += 1;
    }

    pub fn next_subtune(&mut self, now: Instant) {
        if let Some(info) = self.status.track_info.as_ref() {
            self.set_subtune(info.current_song.saturating_add(1), now);
        }
    }

    pub fn prev_subtune(&mut self, now: Instant) {
        if let Some(info) = self.status.track_info.as_ref() {
            self.set_subtune(info.current_song.saturating_sub(1), now);
        }
    }

    /// Record the playing entry's new subtune and its length
    /// (main.rs `update_entry_subtune`).
    fn update_entry_subtune(&mut self, song: u16) {
        let Some(cur) = self.playlist.current else {
            return;
        };
        let md5 = self.playlist.entries.get(cur).and_then(|e| e.md5.clone());
        let duration = self.subtune_length(md5.as_deref(), song);
        if let Some(e) = self.playlist.entries.get_mut(cur) {
            e.selected_song = song;
            e.duration_secs = duration;
        }
        self.playlist_revision += 1;
    }

    /// Songlength DB entry for `song` (1-based), else the default length.
    /// The lookup + fallback that main.rs repeats in three places.
    fn subtune_length(&self, md5: Option<&str>, song: u16) -> Option<u32> {
        let subtune = song.saturating_sub(1) as usize;
        md5.and_then(|m| self.songlength_db.as_ref()?.lookup(m, subtune))
            .or_else(|| {
                let d = self.options.default_song_length_secs;
                (d > 0).then_some(d)
            })
    }

    // ── Playlist editing ──────────────────────────────────────────────────

    /// Append parsed entries (main.rs `ProcessPendingEntries` +
    /// `FinalizePendingEntries`). Entries already in the playlist are kept
    /// where they are. With `play_first`, starts the first of `entries`.
    pub fn add_entries(&mut self, entries: Vec<PlaylistEntry>, play_first: bool, now: Instant) {
        let Some(first_path) = entries.first().map(|e| e.path.clone()) else {
            return;
        };
        self.playlist.add_entries(entries);
        self.apply_songlengths();
        self.playlist_revision += 1;
        if play_first {
            if let Some(idx) = self
                .playlist
                .entries
                .iter()
                .position(|e| e.path == first_path)
            {
                self.play_track(idx, now);
            }
        }
    }

    /// Remove rows; stops playback if the playing row is among them
    /// (main.rs `Message::RemoveSelected`).
    pub fn remove(&mut self, mut indices: Vec<usize>) {
        indices.sort_unstable();
        indices.dedup();
        indices.retain(|&i| i < self.playlist.len());
        if indices.is_empty() {
            return;
        }
        if self.playlist.current.is_some_and(|c| indices.contains(&c)) {
            self.stop();
        }
        // Descending, so earlier removals don't shift later indices.
        for &i in indices.iter().rev() {
            self.playlist.remove(i);
        }
        self.playlist_revision += 1;
    }

    pub fn clear(&mut self) {
        self.stop();
        self.playlist.clear();
        self.playlist_revision += 1;
    }

    /// Move the rows at `from` so they land before row `to`, with the same
    /// semantics as Swift's `Array.move(fromOffsets:toOffset:)`. The playing
    /// track keeps playing (`apply_permutation` carries `current`).
    pub fn move_entries(&mut self, mut from: Vec<usize>, to: usize) {
        let n = self.playlist.len();
        from.sort_unstable();
        from.dedup();
        from.retain(|&i| i < n);
        if from.is_empty() {
            return;
        }
        let to = to.min(n);
        let rest: Vec<usize> = (0..n).filter(|i| from.binary_search(i).is_err()).collect();
        let insert_at = to - from.iter().filter(|&&i| i < to).count();
        let mut perm = Vec::with_capacity(n);
        perm.extend_from_slice(&rest[..insert_at]);
        perm.extend_from_slice(&from);
        perm.extend_from_slice(&rest[insert_at..]);
        if perm.iter().enumerate().all(|(new, &old)| new == old) {
            return;
        }
        self.playlist.apply_permutation(&perm);
        self.playlist_revision += 1;
    }

    // ── Modes and settings ────────────────────────────────────────────────

    pub fn set_shuffle(&mut self, on: bool) {
        if self.playlist.shuffle != on {
            self.playlist.toggle_shuffle();
        }
    }

    pub fn set_repeat(&mut self, mode: RepeatMode) {
        self.playlist.repeat = mode;
    }

    /// Switch engine and resume the current track on it
    /// (main.rs `Message::SetOutputEngine`).
    pub fn set_engine(&mut self, engine: Engine, now: Instant) {
        if engine == self.engine {
            return;
        }
        self.engine = engine;
        let was_playing = self.status.state == PlayState::Playing;
        self.send(PlayerCmd::SetEngine(
            engine.as_engine_name().to_string(),
            String::new(),
            String::new(),
        ));
        if was_playing {
            if let Some(idx) = self.playlist.current {
                self.play_track(idx, now);
            }
        }
    }

    /// Apply new playback options. A default-length change re-derives the
    /// durations (main.rs `DefaultSongLengthChanged`); a stereo change
    /// restarts the playing tune so it's audible now
    /// (main.rs `restart_current_track_if_playing`).
    pub fn set_options(&mut self, options: Options, now: Instant) {
        let old = std::mem::replace(&mut self.options, options);
        if old.default_song_length_secs != self.options.default_song_length_secs {
            if self.options.default_song_length_secs > 0 {
                apply_default_length(&mut self.playlist, self.options.default_song_length_secs);
            } else {
                clear_default_lengths(&mut self.playlist);
                self.apply_songlengths();
            }
            self.playlist_revision += 1;
        }
        let stereo_changed = old.force_stereo_2sid != self.options.force_stereo_2sid
            || old.pseudo_stereo != self.options.pseudo_stereo;
        if stereo_changed && self.status.state == PlayState::Playing {
            if let Some(idx) = self.playlist.current {
                self.play_track(idx, now);
            }
        }
    }

    /// The HVSC folder, used to look up song lengths and STIL by HVSC path
    /// when a file's bytes differ from what the databases were built from.
    pub fn hvsc_root(&self) -> Option<&std::path::Path> {
        self.hvsc_root.as_deref()
    }

    pub fn set_hvsc_root(&mut self, root: Option<PathBuf>) {
        self.hvsc_root = root;
    }

    /// Install a freshly loaded Songlengths DB and apply it.
    pub fn set_songlength_db(&mut self, db: SonglengthDb) {
        self.songlength_db = Some(db);
        self.apply_songlengths();
        self.playlist_revision += 1;
    }

    /// main.rs `apply_songlengths`: DB durations for entries that have none,
    /// then the default length for whatever is still unknown.
    fn apply_songlengths(&mut self) {
        if let Some(db) = &self.songlength_db {
            db.apply_to_playlist(&mut self.playlist, self.hvsc_root.as_deref());
        }
        if self.options.default_song_length_secs > 0 {
            apply_default_length(&mut self.playlist, self.options.default_song_length_secs);
        }
    }
}

/// main.rs `apply_default_length`. MUS files are skipped — their endings
/// come from silence detection.
fn apply_default_length(playlist: &mut Playlist, default_secs: u32) {
    for entry in &mut playlist.entries {
        if entry.duration_secs.is_none() && !is_mus(&entry.path) {
            entry.duration_secs = Some(default_secs);
        }
    }
}

/// main.rs `clear_default_lengths`.
fn clear_default_lengths(playlist: &mut Playlist) {
    for entry in &mut playlist.entries {
        entry.duration_secs = None;
    }
}

fn is_mus(path: &std::path::Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("mus"))
}
