use std::path::PathBuf;
use std::time::{Duration, Instant};

use crossbeam_channel::{bounded, Receiver};

use super::*;
use crate::player::{PlayState, PlayerCmd, PlayerStatus, TrackInfo};
use crate::playlist::{LoadingProgress, PlaylistEntry, RepeatMode};

// ── Fixtures ─────────────────────────────────────────────────────────────────

fn entry(name: &str, songs: u16, duration: Option<u32>) -> PlaylistEntry {
    PlaylistEntry {
        path: PathBuf::from(format!("/hvsc/{name}.sid")),
        title: name.to_string(),
        author: "Author".to_string(),
        released: "1987".to_string(),
        songs,
        selected_song: 1,
        is_pal: true,
        num_sids: 1,
        is_rsid: false,
        md5: Some(format!("md5-{name}")),
        duration_secs: duration,
        has_wds: false,
    }
}

fn rsid(name: &str) -> PlaylistEntry {
    PlaylistEntry {
        is_rsid: true,
        ..entry(name, 1, Some(60))
    }
}

struct Harness {
    session: Session,
    player: Receiver<PlayerCmd>,
    t0: Instant,
}

impl Harness {
    fn new(entries: Vec<PlaylistEntry>) -> Self {
        Self::with_options(entries, Options::default())
    }

    fn with_options(entries: Vec<PlaylistEntry>, options: Options) -> Self {
        let (tx, rx) = bounded(64);
        let t0 = Instant::now();
        let mut session = Session::new(tx, options, Engine::SidLite, None, t0);
        session.add_entries(entries, false, t0);
        Self {
            session,
            player: rx,
            t0,
        }
    }

    fn at(&self, secs: f64) -> Instant {
        self.t0 + Duration::from_secs_f64(secs)
    }

    /// Commands the session sent to the player since the last call.
    fn sent(&self) -> Vec<PlayerCmd> {
        self.player.try_iter().collect()
    }

    /// A status as the player would send it for `entry_idx` playing `song`.
    fn status(
        &self,
        entry_idx: usize,
        song: u16,
        elapsed_secs: u64,
        writes: usize,
    ) -> PlayerStatus {
        let e = &self.session.playlist.entries[entry_idx];
        PlayerStatus {
            state: PlayState::Playing,
            track_info: Some(TrackInfo {
                path: e.path.clone(),
                name: e.title.clone(),
                author: e.author.clone(),
                released: e.released.clone(),
                songs: e.songs,
                current_song: song,
                is_pal: e.is_pal,
                is_rsid: e.is_rsid,
                num_sids: e.num_sids,
                sid_type: "PSID".to_string(),
                sid_model: 1,
                md5: e.md5.clone().unwrap_or_default(),
                mus_comments: Vec::new(),
            }),
            elapsed: Duration::from_secs(elapsed_secs),
            writes_per_frame: writes,
            ..PlayerStatus::default()
        }
    }

    /// Feed one status at `secs` and run a tick.
    fn feed(&mut self, status: PlayerStatus, secs: f64) {
        let now = self.at(secs);
        self.session.ingest_statuses([status], now);
        self.session.tick(now);
    }
}

fn played(cmds: &[PlayerCmd]) -> Vec<(PathBuf, u16)> {
    cmds.iter()
        .filter_map(|c| match c {
            PlayerCmd::Play { path, song, .. } => Some((path.clone(), *song)),
            _ => None,
        })
        .collect()
}

fn subtunes(cmds: &[PlayerCmd]) -> Vec<u16> {
    cmds.iter()
        .filter_map(|c| match c {
            PlayerCmd::SetSubtune(s) => Some(*s),
            _ => None,
        })
        .collect()
}

fn stopped(cmds: &[PlayerCmd]) -> bool {
    cmds.iter().any(|c| matches!(c, PlayerCmd::Stop))
}

fn path(name: &str) -> PathBuf {
    PathBuf::from(format!("/hvsc/{name}.sid"))
}

// ── Auto-advance ─────────────────────────────────────────────────────────────

#[test]
fn duration_end_advances_to_next_subtune() {
    let mut h = Harness::with_options(
        vec![entry("a", 3, Some(10))],
        Options {
            default_song_length_secs: 42,
            ..Options::default()
        },
    );
    h.session.play_track(0, h.t0);
    assert_eq!(played(&h.sent()), vec![(path("a"), 1)]);

    h.feed(h.status(0, 1, 9, 5), 9.0);
    assert!(h.sent().is_empty(), "nothing before the length is reached");

    h.feed(h.status(0, 1, 10, 5), 10.0);
    assert_eq!(subtunes(&h.sent()), vec![2]);
    let e = &h.session.playlist.entries[0];
    assert_eq!(e.selected_song, 2);
    // No songlength DB → the next subtune falls back to the default length.
    assert_eq!(e.duration_secs, Some(42));
}

#[test]
fn last_subtune_moves_to_next_track_and_rewinds_entry() {
    let mut a = entry("a", 2, Some(10));
    a.selected_song = 2;
    let mut h = Harness::new(vec![a, entry("b", 1, Some(10))]);
    h.session.play_track(0, h.t0);
    assert_eq!(played(&h.sent()), vec![(path("a"), 2)]);

    h.feed(h.status(0, 2, 10, 5), 10.0);
    assert_eq!(played(&h.sent()), vec![(path("b"), 1)]);
    assert_eq!(h.session.playlist.current, Some(1));
    assert_eq!(h.session.playlist.entries[0].selected_song, 1);
}

#[test]
fn end_of_playlist_stops() {
    let mut h = Harness::new(vec![entry("a", 1, Some(10))]);
    h.session.play_track(0, h.t0);
    h.sent();
    h.feed(h.status(0, 1, 10, 5), 10.0);
    let cmds = h.sent();
    assert!(stopped(&cmds));
    assert!(played(&cmds).is_empty());
}

#[test]
fn silence_advances_after_three_seconds_past_five_elapsed() {
    let mut h = Harness::new(vec![entry("a", 1, None), entry("b", 1, None)]);
    h.session.play_track(0, h.t0);
    h.sent();

    // Writes keep the tune alive.
    h.feed(h.status(0, 1, 6, 5), 6.0);
    // Then silence: 2.9 s isn't enough…
    h.feed(h.status(0, 1, 8, 0), 8.9);
    assert!(h.sent().is_empty());
    // …3 s is.
    h.feed(h.status(0, 1, 9, 0), 9.0);
    assert_eq!(played(&h.sent()), vec![(path("b"), 1)]);
}

#[test]
fn silence_during_intro_does_not_advance() {
    let mut h = Harness::new(vec![entry("a", 1, None), entry("b", 1, None)]);
    h.session.play_track(0, h.t0);
    h.sent();
    // Silent from the start, but only 5 s in.
    h.feed(h.status(0, 1, 5, 0), 5.0);
    assert!(h.sent().is_empty());
}

#[test]
fn pause_does_not_count_as_silence() {
    let mut h = Harness::new(vec![entry("a", 1, None), entry("b", 1, None)]);
    h.session.play_track(0, h.t0);
    h.feed(h.status(0, 1, 6, 5), 6.0);
    h.sent();

    let mut paused = h.status(0, 1, 6, 0);
    paused.state = PlayState::Paused;
    h.feed(paused, 60.0);
    // Resume: the first silent frame mustn't count the pause as silence.
    h.feed(h.status(0, 1, 6, 0), 60.1);
    assert!(h.sent().is_empty());
}

#[test]
fn debounce_allows_one_advance_per_half_second() {
    let mut h = Harness::with_options(
        vec![entry("a", 3, Some(10))],
        Options {
            default_song_length_secs: 10,
            ..Options::default()
        },
    );
    h.session.play_track(0, h.t0);
    h.sent();

    h.feed(h.status(0, 1, 10, 5), 10.0);
    assert_eq!(subtunes(&h.sent()), vec![2]);
    // A fresh subtune-2 status already past its length within 500 ms…
    h.feed(h.status(0, 2, 20, 5), 10.2);
    assert!(h.sent().is_empty(), "suppressed by the debounce");
    // …is honoured once the window has passed.
    h.feed(h.status(0, 2, 20, 5), 10.6);
    assert_eq!(subtunes(&h.sent()), vec![3]);
}

#[test]
fn status_from_previous_track_is_ignored() {
    let mut h = Harness::new(vec![entry("a", 1, Some(10)), entry("b", 1, Some(10))]);
    h.session.play_track(0, h.t0);
    h.session.play_track(1, h.at(5.0));
    h.sent();
    // Track a's last frame arrives after Play(b), with an elapsed past b's length.
    let late = h.status(0, 1, 30, 5);
    h.feed(late, 5.1);
    assert!(h.sent().is_empty());
    assert_eq!(h.session.status.elapsed, Duration::ZERO);
}

#[test]
fn status_from_previous_subtune_is_ignored() {
    let mut h = Harness::new(vec![entry("a", 3, Some(10))]);
    h.session.play_track(0, h.t0);
    h.feed(h.status(0, 1, 2, 5), 2.0);
    h.session.set_subtune(2, h.at(2.0));
    h.sent();
    // A subtune-1 status (mid-frame when SetSubtune was queued) past the length.
    h.feed(h.status(0, 1, 30, 5), 2.1);
    assert!(h.sent().is_empty());
}

// ── Transport ────────────────────────────────────────────────────────────────

#[test]
fn skip_rsid_jumps_to_next_psid() {
    let mut h = Harness::with_options(
        vec![rsid("r"), entry("p", 1, Some(10))],
        Options {
            skip_rsid: true,
            ..Options::default()
        },
    );
    h.session.play_track(0, h.t0);
    assert_eq!(played(&h.sent()), vec![(path("p"), 1)]);
}

#[test]
fn skip_rsid_terminates_when_everything_is_rsid_with_repeat_all() {
    let mut h = Harness::with_options(
        vec![rsid("r1"), rsid("r2")],
        Options {
            skip_rsid: true,
            ..Options::default()
        },
    );
    h.session.set_repeat(RepeatMode::All);
    h.session.play_track(0, h.t0);
    let cmds = h.sent();
    assert!(played(&cmds).is_empty());
    assert!(stopped(&cmds));
}

#[test]
fn repeat_single_replays_current() {
    let mut h = Harness::new(vec![entry("a", 1, Some(10)), entry("b", 1, Some(10))]);
    h.session.set_repeat(RepeatMode::Single);
    h.session.play_track(0, h.t0);
    h.sent();
    h.feed(h.status(0, 1, 10, 5), 10.0);
    assert_eq!(played(&h.sent()), vec![(path("a"), 1)]);
}

#[test]
fn shuffle_never_repeats_within_a_cycle_and_ends_with_repeat_off() {
    let names = ["a", "b", "c", "d", "e"];
    let mut h = Harness::new(names.iter().map(|n| entry(n, 1, Some(10))).collect());
    h.session.set_shuffle(true);
    let mut seen = Vec::new();
    for _ in 0..names.len() {
        h.session.next(h.t0);
        seen.extend(played(&h.sent()));
    }
    // Upstream's shuffle cursor starts on the user's pick, so a cycle that
    // starts from `next()` covers the other n-1 tracks before ending.
    assert_eq!(seen.len(), names.len() - 1);
    let mut unique = seen.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), seen.len(), "no track repeats: {seen:?}");
}

#[test]
fn previous_restarts_after_three_seconds_else_goes_back() {
    let mut h = Harness::new(vec![entry("a", 1, Some(60)), entry("b", 1, Some(60))]);
    h.session.play_track(1, h.t0);
    h.feed(h.status(1, 1, 10, 5), 10.0);
    h.sent();
    h.session.previous(h.at(10.0));
    assert_eq!(played(&h.sent()), vec![(path("b"), 1)]);

    h.feed(h.status(1, 1, 2, 5), 12.0);
    h.session.previous(h.at(12.0));
    assert_eq!(played(&h.sent()), vec![(path("a"), 1)]);
}

#[test]
fn play_pause_when_stopped_plays_fallback() {
    let mut h = Harness::new(vec![entry("a", 1, None), entry("b", 1, None)]);
    h.session.play_pause(Some(1), h.t0);
    assert_eq!(played(&h.sent()), vec![(path("b"), 1)]);

    h.feed(h.status(1, 1, 1, 5), 1.0);
    h.session.play_pause(None, h.at(1.0));
    assert!(matches!(h.sent().as_slice(), [PlayerCmd::TogglePause]));
}

#[test]
fn subtune_changes_are_clamped() {
    let mut h = Harness::new(vec![entry("a", 3, None)]);
    h.session.play_track(0, h.t0);
    h.feed(h.status(0, 3, 1, 5), 1.0);
    h.sent();
    h.session.next_subtune(h.at(1.0));
    assert!(
        subtunes(&h.sent()).is_empty(),
        "already on the last subtune"
    );
    h.session.set_subtune(0, h.at(1.0));
    assert_eq!(subtunes(&h.sent()), vec![1]);
}

// ── Playlist editing ─────────────────────────────────────────────────────────

#[test]
fn removing_the_playing_track_stops() {
    let mut h = Harness::new(vec![
        entry("a", 1, None),
        entry("b", 1, None),
        entry("c", 1, None),
    ]);
    h.session.play_track(1, h.t0);
    h.sent();
    h.session.remove(vec![2, 1]);
    assert!(stopped(&h.sent()));
    assert_eq!(h.session.playlist.len(), 1);
    assert_eq!(h.session.playlist.current, None);
}

#[test]
fn move_matches_swift_semantics_and_keeps_current() {
    let mut h = Harness::new(
        ["a", "b", "c", "d"]
            .iter()
            .map(|n| entry(n, 1, None))
            .collect(),
    );
    h.session.play_track(0, h.t0);
    // Swift: ["a","b","c","d"].move(fromOffsets: [0, 1], toOffset: 3) == ["c","a","b","d"]
    h.session.move_entries(vec![0, 1], 3);
    let order: Vec<_> = h
        .session
        .playlist
        .entries
        .iter()
        .map(|e| e.title.as_str())
        .collect();
    assert_eq!(order, ["c", "a", "b", "d"]);
    assert_eq!(
        h.session.playlist.current,
        Some(1),
        "playing track followed its row"
    );
}

#[test]
fn add_entries_can_start_playback() {
    let mut h = Harness::new(vec![entry("a", 1, None)]);
    let rev = h.session.playlist_revision;
    h.session
        .add_entries(vec![entry("b", 1, None), entry("c", 1, None)], true, h.t0);
    assert!(h.session.playlist_revision > rev);
    assert_eq!(played(&h.sent()), vec![(path("b"), 1)]);
}

#[test]
fn default_length_fills_and_clears() {
    let mut h = Harness::new(vec![entry("a", 1, None), entry("b", 1, Some(99))]);
    let now = h.t0;
    h.session.set_options(
        Options {
            default_song_length_secs: 30,
            ..Options::default()
        },
        now,
    );
    let lengths: Vec<_> = h
        .session
        .playlist
        .entries
        .iter()
        .map(|e| e.duration_secs)
        .collect();
    assert_eq!(lengths, [Some(30), Some(99)]);

    h.session.set_options(Options::default(), now);
    assert_eq!(h.session.playlist.entries[0].duration_secs, None);
}

// ── Persistence ──────────────────────────────────────────────────────────────

#[test]
fn session_round_trips_through_m3u() {
    let dir = std::env::temp_dir().join(format!("resonance-test-{}", std::process::id()));
    let file = dir.join("session.m3u");
    let mut b = entry("b", 4, Some(77));
    b.selected_song = 3;
    let h = Harness::new(vec![entry("a", 1, None), b]);

    persist::save(&h.session.playlist, &file).unwrap();
    let progress: LoadingProgress = Default::default();
    let loaded = persist::load(&file, progress).unwrap();
    std::fs::remove_dir_all(&dir).unwrap();

    assert_eq!(loaded.len(), 2);
    assert_eq!(loaded[0].path, path("a"));
    assert_eq!(loaded[0].duration_secs, None);
    assert_eq!(loaded[1].title, "b");
    assert_eq!(loaded[1].author, "Author");
    assert_eq!(loaded[1].songs, 4);
    assert_eq!(loaded[1].selected_song, 3);
    assert_eq!(loaded[1].duration_secs, Some(77));
    assert_eq!(loaded[1].md5.as_deref(), Some("md5-b"));
}

#[test]
fn saving_an_empty_playlist_removes_the_file() {
    let dir = std::env::temp_dir().join(format!("resonance-test-empty-{}", std::process::id()));
    let file = dir.join("session.m3u");
    let h = Harness::new(vec![entry("a", 1, None)]);
    persist::save(&h.session.playlist, &file).unwrap();
    assert!(file.exists());
    let empty = Harness::new(Vec::new());
    persist::save(&empty.session.playlist, &file).unwrap();
    assert!(!file.exists());
    std::fs::remove_dir_all(&dir).unwrap();
}
