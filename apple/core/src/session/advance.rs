//! Auto-advance: main.rs `poll_status`, from the `PlayState::Playing` check
//! on (main.rs:4926-5072).

use std::time::{Duration, Instant};

use super::Session;
use crate::player::{PlayState, PlayerCmd};

/// No SID writes for this long counts as the tune having ended. Upstream
/// counts 90 ticks of its 33 ms UI timer; a wall-clock span doesn't depend
/// on how often the driver ticks.
pub(super) const SILENCE: Duration = Duration::from_secs(3);
/// Silence only counts after this much playback, so quiet intros survive.
pub(super) const SILENCE_MIN_ELAPSED_SECS: u64 = 5;
/// At most one auto-advance per window, bounding any stale-status race to
/// one skipped subtune (main.rs:4987-4995).
pub(super) const DEBOUNCE: Duration = Duration::from_millis(500);

impl Session {
    /// Advance to the next subtune or track when the current one has run
    /// its length or gone silent. Call after `ingest_statuses`, on every
    /// driver tick.
    pub fn tick(&mut self, now: Instant) {
        if self.status.state != PlayState::Playing {
            // Paused or stopped: no writes is expected, so the silence clock
            // restarts on resume instead of firing immediately.
            self.last_writes_at = now;
            return;
        }
        let Some(cur) = self.playlist.current else {
            return;
        };
        let Some(entry) = self.playlist.entries.get(cur) else {
            return;
        };

        let elapsed = self.status.elapsed.as_secs();
        let duration = entry.duration_secs;
        let duration_ended = duration.is_some_and(|d| elapsed >= u64::from(d));
        let silence_ended = now.duration_since(self.last_writes_at) >= SILENCE
            && elapsed > SILENCE_MIN_ELAPSED_SECS;
        if !(duration_ended || silence_ended) {
            return;
        }

        if self
            .last_advance_at
            .is_some_and(|t| now.duration_since(t) < DEBOUNCE)
        {
            return;
        }
        self.last_advance_at = Some(now);

        let (song, songs, md5) = (entry.selected_song, entry.songs, entry.md5.clone());
        eprintln!(
            "[resonance] advance: song {song}/{songs} elapsed={elapsed}s length={duration:?} trigger={}",
            if duration_ended { "duration" } else { "silence" }
        );

        if song < songs {
            // Next subtune of the same tune.
            let next = song + 1;
            let length = self.subtune_length(md5.as_deref(), next);
            self.send(PlayerCmd::SetSubtune(next));
            self.clear_advance_status(now);
            if let Some(e) = self.playlist.entries.get_mut(cur) {
                e.selected_song = next;
                e.duration_secs = length;
            }
            self.playlist_revision += 1;
            self.track_revision += 1;
        } else {
            // Last subtune: rewind this entry to its first subtune for the
            // next time round, then move on to the next track.
            let length = self.subtune_length(md5.as_deref(), 1);
            if let Some(e) = self.playlist.entries.get_mut(cur) {
                e.selected_song = 1;
                e.duration_secs = length;
            }
            self.playlist_revision += 1;
            match self.playlist.next() {
                Some(idx) => self.play_track(idx, now),
                None => self.stop(),
            }
        }
    }
}
