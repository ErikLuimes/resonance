//! The reSIDfp player on a fake output that pulls ten times faster than
//! real time, playing the tiny PSIDs `residfp-sys` builds in memory.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender};
use residfp_sys::testing::tiny_psid;

use super::*;
use crate::viz::{lock, VizFeed};

const RATE: u32 = 48_000;

fn tune_file(chips: u8, tag: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "resonance-residfp-{}-{tag}-{chips}.sid",
        std::process::id()
    ));
    std::fs::write(&path, tiny_psid(chips)).unwrap();
    path
}

struct Rig {
    cmds: Sender<PlayerCmd>,
    statuses: Receiver<PlayerStatus>,
    feed: SharedFeed,
}

impl Rig {
    fn new() -> Self {
        Self::with_chip(Chip::ReSidFp)
    }

    fn with_chip(chip: Chip) -> Self {
        let feed = Arc::new(Mutex::new(VizFeed::new()));
        let (cmds, statuses, _device) = spawn_with(
            feed.clone(),
            chip,
            Output::Fake {
                rate: RATE,
                block: 480,
                period: Duration::from_millis(1),
            },
        );
        Self {
            cmds,
            statuses,
            feed,
        }
    }

    fn play(&self, path: &PathBuf, song: u16) {
        self.cmds
            .send(PlayerCmd::Play {
                path: path.clone(),
                song,
                force_stereo: false,
                pseudo_stereo: None,
                sid4_addr: 0,
                audio_port: None,
                restart_usb_on_load: false,
            })
            .unwrap();
    }

    /// The first status within `secs` that `pred` accepts.
    fn wait(&self, secs: f64, pred: impl Fn(&PlayerStatus) -> bool) -> PlayerStatus {
        let deadline = Instant::now() + Duration::from_secs_f64(secs);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let status = self.statuses.recv_timeout(left).expect("a status in time");
            if pred(&status) {
                return status;
            }
        }
    }
}

#[test]
fn plays_and_reports_elapsed_time() {
    let rig = Rig::new();
    let path = tune_file(1, "plays");
    rig.play(&path, 1);
    let first = rig.wait(5.0, |s| s.state == PlayState::Playing);
    let info = first.track_info.as_ref().expect("track info");
    assert_eq!(info.path, path);
    assert_eq!(info.name, "Resonance Test Tune");
    assert_eq!(info.author, "Resonance");
    assert_eq!((info.songs, info.current_song), (2, 1));
    assert!(info.is_pal && !info.is_rsid);
    assert_eq!((info.num_sids, info.sid_type.as_str()), (1, "Mono"));
    assert_eq!(info.sid_model, 1);
    assert_eq!(info.md5.len(), 32);

    // Ten times real time: a second of music within a couple of seconds.
    let later = rig.wait(5.0, |s| s.elapsed >= Duration::from_secs(1));
    assert_eq!(later.state, PlayState::Playing);
    assert_eq!(later.sid_regs[0x04], 0x21, "sawtooth, gate on");
    assert_eq!(later.sid_regs[0x18], 0x0F);
    assert_eq!(later.voice_levels.len(), 3);
    assert!((later.voice_levels[0] - 1.0).abs() < 0.01);
    assert!(later.error.is_none());
    // Silence detection sees the play routine's writes.
    rig.wait(2.0, |s| s.writes_per_frame > 0);
}

#[test]
fn subtune_switch_restarts_the_clock() {
    let rig = Rig::new();
    let path = tune_file(1, "subtune");
    rig.play(&path, 1);
    rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(500));
    rig.cmds.send(PlayerCmd::SetSubtune(2)).unwrap();
    let switched = rig.wait(5.0, |s| {
        s.track_info.as_ref().is_some_and(|t| t.current_song == 2)
    });
    assert!(
        switched.elapsed < Duration::from_millis(300),
        "{:?}",
        switched.elapsed
    );
    let later = rig.wait(5.0, |s| {
        s.track_info.as_ref().is_some_and(|t| t.current_song == 2)
            && s.elapsed >= Duration::from_millis(300)
    });
    assert_eq!(later.sid_regs[0x04], 0x41, "pulse in song 2");
    // Song 0 is the start song.
    rig.cmds.send(PlayerCmd::SetSubtune(0)).unwrap();
    rig.wait(5.0, |s| {
        s.track_info.as_ref().is_some_and(|t| t.current_song == 1)
    });
}

#[test]
fn feeds_the_visualizers() {
    let rig = Rig::new();
    let path = tune_file(1, "viz");
    rig.play(&path, 1);
    rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(600));
    // Frames are scheduled at the callback's time; the fake output runs
    // ahead of the wall clock, so "now" is well inside what's rendered.
    let now = Instant::now();
    let feed = lock(&rig.feed);
    let frame = feed.latest(now).expect("a frame being heard");
    assert_eq!(frame.num_chips, 1);
    assert!(frame.is_pal);
    assert_eq!(frame.chips[0].regs[0x04], 0x21);
    assert_eq!(frame.chips[0].env[0], 0xFF);
    assert_eq!(frame.chips[0].env_state[0], EnvState::DecaySustain);
    assert_eq!(frame.chips[0].env_state[1], EnvState::Release);
    // Video-frame sized, not buffer sized.
    let length = frame.end().saturating_sub(frame.start());
    assert!(
        length >= Duration::from_millis(19) && length < Duration::from_millis(45),
        "{length:?}"
    );
    assert!(feed.stats().frames >= 10, "{}", feed.stats().frames);
    assert!((feed.sample_rate() - 44_784.0).abs() < 1.0);
    let [v1, v2, _] = feed.scope(now, 0, 1024);
    assert_eq!(v1.len(), 1024);
    assert!(
        v1.iter().any(|s| s.abs() > 0.5),
        "the sawtooth is in the scope"
    );
    assert!(v2.iter().all(|&s| s == 0.0));
    let history = feed.history(now, 100);
    assert!(history.len() >= 10);
    assert!(history.windows(2).all(|w| w[1].index == w[0].index + 1));
}

#[test]
fn pause_holds_and_stop_clears() {
    let rig = Rig::new();
    let path = tune_file(1, "pause");
    rig.play(&path, 1);
    rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(300));
    rig.cmds.send(PlayerCmd::TogglePause).unwrap();
    let paused = rig.wait(2.0, |s| s.state == PlayState::Paused);
    std::thread::sleep(Duration::from_millis(150));
    let held = rig.wait(2.0, |s| s.state == PlayState::Paused);
    assert_eq!(held.elapsed, paused.elapsed, "no time passes while paused");
    assert!(held.track_info.is_some());

    rig.cmds.send(PlayerCmd::TogglePause).unwrap();
    let resumed = rig.wait(5.0, |s| {
        s.elapsed > paused.elapsed + Duration::from_millis(100)
    });
    assert_eq!(resumed.state, PlayState::Playing);

    rig.cmds.send(PlayerCmd::Stop).unwrap();
    let stopped = rig.wait(2.0, |s| s.state == PlayState::Stopped);
    assert!(stopped.track_info.is_none());
    assert_eq!(stopped.elapsed, Duration::ZERO);
    std::thread::sleep(Duration::from_millis(20));
    assert!(lock(&rig.feed).latest(Instant::now()).is_none());
    // Idle statuses keep coming while stopped.
    rig.wait(1.0, |s| s.state == PlayState::Stopped);
}

#[test]
fn a_2sid_tune_plays_two_chips() {
    let rig = Rig::new();
    let path = tune_file(2, "2sid");
    rig.play(&path, 1);
    let status = rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(300));
    let info = status.track_info.as_ref().unwrap();
    assert_eq!((info.num_sids, info.sid_type.as_str()), (2, "2SID Stereo"));
    assert_eq!(status.sid_regs[0x20 + 0x04], 0x21, "chip 2 plays too");
    assert_eq!(status.voice_levels.len(), 6);
    let now = Instant::now();
    let feed = lock(&rig.feed);
    let frame = feed.latest(now).unwrap();
    assert_eq!(frame.num_chips, 2);
    assert_eq!(frame.chips[1].env[0], 0xFF);
    assert!(feed.scope(now, 1, 512)[0].iter().any(|s| s.abs() > 0.5));
    assert!(feed.scope(now, 2, 512)[0].is_empty());
}

#[test]
fn sidlite_direct_plays_through_the_same_player() {
    let rig = Rig::with_chip(Chip::SidLite);
    let path = tune_file(2, "sidlite");
    rig.play(&path, 2);
    let status = rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(400));
    let info = status.track_info.as_ref().unwrap();
    assert_eq!((info.num_sids, info.current_song), (2, 2));
    assert_eq!(status.sid_regs[0x04], 0x41, "pulse in song 2");
    assert_eq!(status.sid_regs[0x24], 0x41);
    let now = Instant::now();
    let feed = lock(&rig.feed);
    let frame = feed.latest(now).expect("a frame");
    assert_eq!(frame.num_chips, 2);
    assert_eq!(frame.chips[0].env[0], 0xFF);
    assert_eq!(frame.chips[0].env_state[0], EnvState::DecaySustain);
    let [v1, _, _] = feed.scope(now, 1, 1024);
    assert!(
        v1.iter().any(|s| s.abs() > 0.5),
        "the pulse is in chip 2's scope"
    );
    drop(feed);
    // SetEngine switches the chip for the next Play without a new thread.
    rig.cmds
        .send(PlayerCmd::SetEngine(
            "residfp".into(),
            String::new(),
            String::new(),
        ))
        .unwrap();
    let stopped = rig.wait(2.0, |s| s.state == PlayState::Stopped);
    assert!(stopped.track_info.is_none());
    rig.play(&path, 1);
    rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(300));
}

#[test]
fn an_unreadable_file_reports_an_error() {
    let rig = Rig::new();
    rig.play(&PathBuf::from("/nonexistent/resonance.sid"), 1);
    let status = rig.wait(5.0, |s| s.error.is_some());
    assert_eq!(status.state, PlayState::Stopped);
    assert!(status.track_info.is_none());
    assert!(status.error.unwrap().contains("Cannot read"));
    // A good tune afterwards clears the error.
    let path = tune_file(1, "after-error");
    rig.play(&path, 1);
    let ok = rig.wait(5.0, |s| s.state == PlayState::Playing);
    assert!(ok.error.is_none());
}

#[test]
fn quit_ends_the_thread() {
    let rig = Rig::new();
    let path = tune_file(1, "quit");
    rig.play(&path, 1);
    rig.wait(5.0, |s| s.state == PlayState::Playing);
    rig.cmds.send(PlayerCmd::Quit).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match rig.statuses.recv_timeout(Duration::from_millis(50)) {
            Ok(_) => {}
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                assert!(Instant::now() < deadline, "the player thread didn't exit");
            }
        }
    }
}
