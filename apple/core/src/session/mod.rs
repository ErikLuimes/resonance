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

use std::collections::HashSet;
use std::path::{Path, PathBuf};
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
    /// Tunes played from the library: a temporary list that transport and
    /// auto-advance walk instead of the playlist, until something in the
    /// playlist is played. Never saved. Not in upstream, whose library adds
    /// what it plays to the playlist.
    pub(crate) queue: Option<Playlist>,
    /// The queue is Surprise Me's radio: random tunes from all of HVSC, one
    /// subtune each, kept one pick ahead of playback.
    radio: bool,
    /// Surprise Me pressed; the radio starts when the first pick arrives.
    radio_starting: bool,
    /// The radio ran out before its next pick arrived: play it on arrival.
    radio_waiting: bool,
    radio_pick: RadioPick,
    /// Every tune played since launch; Surprise Me doesn't pick these.
    heard: HashSet<PathBuf>,
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

/// Where Surprise Me's next pick stands. The driver does the picking (it
/// reads the disk); the session only says when it needs one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RadioPick {
    Idle,
    Wanted,
    Pending,
}

/// A pick the driver should make: any tune not in `exclude`.
pub struct RadioRequest {
    pub exclude: HashSet<PathBuf>,
    /// The first pick of a new radio (worth a progress message: with no
    /// index loaded yet it walks the disk).
    pub first: bool,
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
            queue: None,
            radio: false,
            radio_starting: false,
            radio_waiting: false,
            radio_pick: RadioPick::Idle,
            heard: HashSet::new(),
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
        match (status.track_info.as_ref(), self.current_entry()) {
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

    // ── Active list ───────────────────────────────────────────────────────

    /// The list transport works on: the queue while there is one, else the
    /// playlist.
    fn active(&self) -> &Playlist {
        self.queue.as_ref().unwrap_or(&self.playlist)
    }

    fn active_mut(&mut self) -> &mut Playlist {
        self.queue.as_mut().unwrap_or(&mut self.playlist)
    }

    /// Note a change to an entry of the active list. Only the playlist's
    /// changes are visible and saved; the queue's stay private.
    fn active_changed(&mut self) {
        if self.queue.is_none() {
            self.playlist_revision += 1;
        }
    }

    /// The playing (or last played) entry, in whichever list it's in.
    pub(crate) fn current_entry(&self) -> Option<&PlaylistEntry> {
        self.active().current_entry()
    }

    /// The playlist row that's playing; None while the queue plays.
    pub(crate) fn playlist_current(&self) -> Option<usize> {
        if self.queue.is_some() {
            None
        } else {
            self.playlist.current
        }
    }

    pub(crate) fn queue_active(&self) -> bool {
        self.queue.is_some()
    }

    /// The queue is Surprise Me's radio.
    pub(crate) fn radio_active(&self) -> bool {
        self.radio
    }

    // ── Transport ─────────────────────────────────────────────────────────

    /// main.rs `play_track`, minus the recently-played / heard / favourites
    /// bookkeeping, karaoke, tracker and STIL. Plays row `idx` of the active
    /// list; `play_index` is the entry point for playlist rows.
    ///
    /// Skip-RSID is a bounded loop rather than upstream's recursion
    /// (main.rs:4395), which never terminates when every entry is RSID and
    /// repeat is All.
    pub fn play_track(&mut self, idx: usize, now: Instant) {
        let mut idx = idx;
        for _ in 0..=self.active().len() {
            let Some(entry) = self.active().entries.get(idx) else {
                return;
            };
            let (path, song, is_rsid) = (entry.path.clone(), entry.selected_song, entry.is_rsid);
            if self.options.skip_rsid && is_rsid {
                eprintln!("[resonance] Skipping RSID tune: \"{}\"", entry.title);
                let list = self.active_mut();
                list.current = Some(idx);
                match list.next() {
                    Some(next) if next != idx => {
                        idx = next;
                        continue;
                    }
                    _ => break,
                }
            }

            self.heard.insert(path.clone());
            let cmd = self.play_cmd(path, song);
            self.active_mut().current = Some(idx);
            self.send(cmd);
            self.clear_advance_status(now);
            // Fresh track — the previous track's debounce must not gate
            // this one's first auto-advance (main.rs:4444-4446).
            self.last_advance_at = None;
            self.track_revision += 1;
            self.want_radio_pick();
            return;
        }
        // Nothing playable left.
        self.stop();
    }

    /// Play playlist row `idx`, ending the queue if one is playing.
    pub fn play_index(&mut self, idx: usize, now: Instant) {
        self.end_radio();
        self.queue = None;
        self.play_track(idx, now);
    }

    /// main.rs `Message::PlayPause`. When stopped, starts `fallback` (the
    /// playlist selection), else the active list's current entry, else its
    /// first.
    pub fn play_pause(&mut self, fallback: Option<usize>, now: Instant) {
        if self.status.state == PlayState::Stopped {
            if let Some(i) = fallback {
                self.play_index(i, now);
                return;
            }
            let list = self.active();
            if let Some(i) = list.current.or((!list.is_empty()).then_some(0)) {
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
        if let Some(idx) = self.active_mut().next() {
            self.play_track(idx, now);
        } else if self.radio {
            self.radio_ran_out();
        }
    }

    /// More than 3 s in restarts the current track, like most players
    /// (main.rs `Message::PrevTrack`).
    pub fn previous(&mut self, now: Instant) {
        if self.status.elapsed.as_secs() > 3 {
            if let Some(idx) = self.active().current {
                self.play_track(idx, now);
            }
        } else if let Some(idx) = self.active_mut().prev() {
            self.play_track(idx, now);
        }
    }

    // ── Queue ─────────────────────────────────────────────────────────────

    /// Play `entries` as a temporary list, starting at the one at `start`
    /// (else the first). Next, Previous and auto-advance stay inside it, it
    /// takes the playlist's shuffle and repeat, and the playlist itself is
    /// left alone. Replaces any earlier queue.
    pub fn play_queue(&mut self, entries: Vec<PlaylistEntry>, start: &Path, now: Instant) {
        if entries.is_empty() {
            return;
        }
        let mut queue = Playlist::new();
        queue.repeat = self.playlist.repeat;
        queue.add_entries(entries);
        if self.playlist.shuffle {
            queue.toggle_shuffle();
        }
        self.fill_lengths_of(&mut queue);
        let idx = queue
            .entries
            .iter()
            .position(|e| e.path == start)
            .unwrap_or(0);
        self.end_radio();
        self.queue = Some(queue);
        self.play_track(idx, now);
    }

    // ── Surprise Me ───────────────────────────────────────────────────────
    //
    // A radio over all of HVSC: a queue the session tops up one random pick
    // ahead of playback, so Next and auto-advance always have a fresh tune
    // and Previous walks back through what played. Each tune plays only its
    // default subtune and none repeats a tune heard since launch. Repeat One
    // still loops a tune; shuffle and Repeat All don't apply. Playing
    // anything else ends it. Upstream's Surprise Me plays one tune.

    /// Start the radio. It begins when the driver's first pick arrives.
    pub fn surprise(&mut self) {
        self.radio_starting = true;
        if self.radio_pick == RadioPick::Idle {
            self.radio_pick = RadioPick::Wanted;
        }
    }

    /// The pick the driver should make now, once per pick.
    pub fn take_radio_request(&mut self) -> Option<RadioRequest> {
        if self.radio_pick != RadioPick::Wanted {
            return None;
        }
        self.radio_pick = RadioPick::Pending;
        Some(RadioRequest {
            exclude: self.heard.clone(),
            first: self.radio_starting,
        })
    }

    /// The driver's pick (None when there was nothing to pick). Starts the
    /// radio, or joins it as the next tune and plays if it had run out.
    pub fn radio_picked(&mut self, pick: Option<PlaylistEntry>, now: Instant) {
        self.radio_pick = RadioPick::Idle;
        let Some(entry) = pick else {
            self.radio_starting = false;
            self.radio_waiting = false;
            return;
        };
        if self.options.skip_rsid && entry.is_rsid {
            // Pick again, and never this one.
            self.heard.insert(entry.path);
            if self.radio_starting || self.radio {
                self.radio_pick = RadioPick::Wanted;
            }
            return;
        }
        if std::mem::take(&mut self.radio_starting) {
            let mut queue = Playlist::new();
            queue.repeat = radio_repeat(self.playlist.repeat);
            queue.add_entries(vec![entry]);
            self.fill_lengths_of(&mut queue);
            self.queue = Some(queue);
            self.radio = true;
            self.radio_waiting = false;
            self.play_track(0, now);
            return;
        }
        if !self.radio {
            // The radio ended while this pick was on its way.
            return;
        }
        let mut queue = self.queue.take().expect("the radio is a queue");
        queue.add_entries(vec![entry]);
        self.fill_lengths_of(&mut queue);
        self.queue = Some(queue);
        if std::mem::take(&mut self.radio_waiting) {
            self.next(now);
        }
    }

    /// Keep the radio one pick ahead: on its last tune, ask for another.
    fn want_radio_pick(&mut self) {
        let on_last = self
            .queue
            .as_ref()
            .is_some_and(|q| q.current.is_some_and(|c| c + 1 >= q.len()));
        if self.radio && on_last && self.radio_pick == RadioPick::Idle {
            self.radio_pick = RadioPick::Wanted;
        }
    }

    /// Next or auto-advance reached the radio's end before the next pick
    /// did; it plays as soon as it arrives.
    fn radio_ran_out(&mut self) {
        self.radio_waiting = true;
        self.want_radio_pick();
    }

    fn end_radio(&mut self) {
        self.radio = false;
        self.radio_starting = false;
        self.radio_waiting = false;
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
        let Some(cur) = self.active().current else {
            return;
        };
        let md5 = self.active().entries.get(cur).and_then(|e| e.md5.clone());
        let duration = self.subtune_length(md5.as_deref(), song);
        if let Some(e) = self.active_mut().entries.get_mut(cur) {
            e.selected_song = song;
            e.duration_secs = duration;
        }
        self.active_changed();
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
    /// where they are. With `play_first`, starts the first of `entries` from
    /// the playlist.
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
                self.play_index(idx, now);
            }
        }
    }

    /// Remove rows; stops playback if the playing row is among them
    /// (main.rs `Message::RemoveSelected`). A playing queue plays on.
    pub fn remove(&mut self, mut indices: Vec<usize>) {
        indices.sort_unstable();
        indices.dedup();
        indices.retain(|&i| i < self.playlist.len());
        if indices.is_empty() {
            return;
        }
        if self
            .playlist_current()
            .is_some_and(|c| indices.contains(&c))
        {
            self.stop();
        }
        // Descending, so earlier removals don't shift later indices.
        for &i in indices.iter().rev() {
            self.playlist.remove(i);
        }
        self.playlist_revision += 1;
    }

    /// Empty the playlist; stops playback unless the queue is playing.
    pub fn clear(&mut self) {
        if self.queue.is_none() {
            self.stop();
        }
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

    /// The modes are global: they apply to the playlist and the queue alike,
    /// except that the radio never shuffles and only repeats one tune.
    pub fn set_shuffle(&mut self, on: bool) {
        let queue = self.queue.as_mut().filter(|_| !self.radio);
        for list in std::iter::once(&mut self.playlist).chain(queue) {
            if list.shuffle != on {
                list.toggle_shuffle();
            }
        }
    }

    pub fn set_repeat(&mut self, mode: RepeatMode) {
        self.playlist.repeat = mode;
        if let Some(queue) = &mut self.queue {
            queue.repeat = if self.radio { radio_repeat(mode) } else { mode };
        }
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
            if let Some(idx) = self.active().current {
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
        let default_secs = self.options.default_song_length_secs;
        if old.default_song_length_secs != default_secs {
            for list in std::iter::once(&mut self.playlist).chain(self.queue.as_mut()) {
                if default_secs > 0 {
                    apply_default_length(list, default_secs);
                } else {
                    clear_default_lengths(list);
                }
            }
            if default_secs == 0 {
                self.apply_songlengths();
            }
            self.playlist_revision += 1;
        }
        let stereo_changed = old.force_stereo_2sid != self.options.force_stereo_2sid
            || old.pseudo_stereo != self.options.pseudo_stereo;
        if stereo_changed && self.status.state == PlayState::Playing {
            if let Some(idx) = self.active().current {
                self.play_track(idx, now);
            }
        }
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

    /// `fill_lengths` with the session's databases and settings, for a list
    /// that isn't (yet) the session's.
    fn fill_lengths_of(&self, list: &mut Playlist) {
        fill_lengths(
            list,
            self.songlength_db.as_ref(),
            self.hvsc_root.as_deref(),
            self.options.default_song_length_secs,
        );
    }

    /// main.rs `apply_songlengths`, for the playlist and the queue.
    fn apply_songlengths(&mut self) {
        let db = self.songlength_db.as_ref();
        let root = self.hvsc_root.as_deref();
        let default_secs = self.options.default_song_length_secs;
        fill_lengths(&mut self.playlist, db, root, default_secs);
        if let Some(queue) = &mut self.queue {
            fill_lengths(queue, db, root, default_secs);
        }
    }
}

/// The radio only ever loops one tune: Repeat All would replay its history
/// instead of picking new tunes.
fn radio_repeat(mode: RepeatMode) -> RepeatMode {
    if mode == RepeatMode::Single {
        RepeatMode::Single
    } else {
        RepeatMode::Off
    }
}

/// main.rs `apply_songlengths` for one list: DB durations for entries that
/// have none, then the default length for whatever is still unknown.
fn fill_lengths(
    list: &mut Playlist,
    db: Option<&SonglengthDb>,
    hvsc_root: Option<&Path>,
    default_secs: u32,
) {
    if let Some(db) = db {
        db.apply_to_playlist(list, hvsc_root);
    }
    if default_secs > 0 {
        apply_default_length(list, default_secs);
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
