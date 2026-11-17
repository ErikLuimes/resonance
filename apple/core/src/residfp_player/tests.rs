//! The reSIDfp player on a fake output that pulls ten times faster than
//! real time, playing the tiny PSIDs `residfp-sys` builds in memory.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
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

/// Quits a player when its test ends and waits for its thread, so no test's
/// player is still rendering when the test process exits: the engine's
/// statics are gone by then, and a call into them aborts.
struct QuitAtEnd {
    cmds: Sender<PlayerCmd>,
    thread: Option<thread::JoinHandle<()>>,
}

impl QuitAtEnd {
    fn new(cmds: &Sender<PlayerCmd>, thread: thread::JoinHandle<()>) -> Self {
        Self {
            cmds: cmds.clone(),
            thread: Some(thread),
        }
    }
}

impl Drop for QuitAtEnd {
    fn drop(&mut self) {
        let _ = self.cmds.try_send(PlayerCmd::Quit);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

struct Rig {
    cmds: Sender<PlayerCmd>,
    statuses: Receiver<PlayerStatus>,
    feed: SharedFeed,
    seeker: Seeker,
    /// Every block the fake output was given.
    tap: Receiver<Vec<f32>>,
    _quit: QuitAtEnd,
}

impl Rig {
    fn new() -> Self {
        Self::with_chip(Chip::ReSidFp)
    }

    fn with_chip(chip: Chip) -> Self {
        let feed = Arc::new(Mutex::new(VizFeed::new()));
        let (tap_tx, tap) = crossbeam_channel::unbounded();
        let (cmds, statuses, _device, seeker, thread) = spawn_with(
            feed.clone(),
            chip,
            Output::Fake {
                rate: RATE,
                block: 480,
                period: Duration::from_millis(1),
                tap: Some(tap_tx),
            },
        );
        Self {
            _quit: QuitAtEnd::new(&cmds, thread),
            cmds,
            statuses,
            feed,
            seeker,
            tap,
        }
    }

    fn seek(&self, secs: f64) {
        self.seeker
            .targets
            .send(Duration::from_secs_f64(secs))
            .unwrap();
    }

    /// The left channel of everything the output has been given so far.
    fn heard(&self) -> Vec<f32> {
        self.tap
            .try_iter()
            .flat_map(|block| block.into_iter().step_by(2))
            .collect()
    }

    fn seeking(&self) -> bool {
        self.seeker.seeking.load(std::sync::atomic::Ordering::Relaxed)
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
fn seeks_forward_and_back() {
    let rig = Rig::new();
    let path = tune_file(1, "seek");
    rig.play(&path, 1);
    rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(300));

    // Forward: the clock jumps at once, then plays on from there.
    rig.seek(4.0);
    let jumped = rig.wait(2.0, |s| s.elapsed >= Duration::from_secs(4));
    assert_eq!(jumped.state, PlayState::Playing);
    let landed = rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(4300));
    assert!(!rig.seeking());
    // The worker reported its way there, ending at the target.
    let position = rig.seeker.position_ms.load(std::sync::atomic::Ordering::Relaxed);
    assert_eq!(position, 4000);
    assert!(landed.elapsed < Duration::from_secs(6), "{:?}", landed.elapsed);
    assert_eq!(landed.sid_regs[0x04], 0x21, "still the first song's sawtooth");
    assert!((landed.voice_levels[0] - 1.0).abs() < 0.01);

    // Back: a fresh instance from the top.
    rig.seek(1.0);
    rig.wait(2.0, |s| s.elapsed < Duration::from_secs(2));
    let later = rig.wait(5.0, |s| {
        s.elapsed >= Duration::from_millis(1300) && s.elapsed < Duration::from_secs(3)
    });
    assert_eq!(later.state, PlayState::Playing);
    assert!(!rig.seeking());
    assert_eq!(later.sid_regs[0x04], 0x21);

    // Seeking while paused lands paused, at the target.
    rig.cmds.send(PlayerCmd::TogglePause).unwrap();
    rig.wait(2.0, |s| s.state == PlayState::Paused);
    rig.seek(3.0);
    let at = rig.wait(5.0, |s| s.elapsed >= Duration::from_secs(3));
    assert_eq!(at.state, PlayState::Paused);
    std::thread::sleep(Duration::from_millis(400));
    let held = rig.wait(2.0, |s| s.state == PlayState::Paused);
    assert_eq!(held.elapsed, Duration::from_secs(3), "{:?}", held.elapsed);
    rig.cmds.send(PlayerCmd::TogglePause).unwrap();
    rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(3200));

    // A seek past a stop is ignored.
    rig.cmds.send(PlayerCmd::Stop).unwrap();
    rig.wait(2.0, |s| s.state == PlayState::Stopped);
    rig.seek(2.0);
    std::thread::sleep(Duration::from_millis(50));
    assert!(!rig.seeking());
}

#[test]
fn pause_holds_and_stop_clears() {
    let rig = Rig::new();
    let path = tune_file(1, "pause");
    rig.play(&path, 1);
    rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(300));
    rig.cmds.send(PlayerCmd::TogglePause).unwrap();
    rig.wait(2.0, |s| s.state == PlayState::Paused);
    // The fade out plays a last 10 ms of the tune.
    std::thread::sleep(Duration::from_millis(50));
    while rig.statuses.try_recv().is_ok() {}
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
    // A good tune afterward clears the error.
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

// ── Fades ────────────────────────────────────────────────────────────────────

/// `FADE` at the rig's rate.
const FADE_FRAMES: usize = 480;

/// The loudest sample in `samples`.
fn peak(samples: &[f32]) -> f32 {
    samples.iter().fold(0.0, |m, s| m.max(s.abs()))
}

/// `samples` end in silence, and the sound before it fades there: within
/// the fade's length of the silence no sample is above the raised cosine
/// at that distance, where a cut would leave one at the tune's full level.
/// Returns the index of the first silent sample.
fn assert_fades_out(samples: &[f32]) -> usize {
    let loud = peak(samples);
    assert!(loud > 0.05, "the tune is audible: {loud}");
    let silence = samples.iter().rposition(|&s| s != 0.0).expect("sound") + 1;
    assert!(silence < samples.len(), "it ends in silence");
    assert!(silence > 3 * FADE_FRAMES);
    for k in 1..=FADE_FRAMES {
        let limit = loud * fade_gain(k as u32, FADE_FRAMES as u32) + 1e-6;
        let s = samples[silence - k].abs();
        assert!(s <= limit, "{k} frames before silence: {s} > {limit}");
    }
    // The last step into silence is a sliver of the level, not the level.
    assert!(samples[silence - 1].abs() < loud * 1e-4);
    // And it was at full level just before the fade.
    let before = &samples[silence - 3 * FADE_FRAMES..silence - FADE_FRAMES];
    assert!(peak(before) > 0.5 * loud, "{} of {loud}", peak(before));
    silence
}

/// The same from the other side: `samples` start in silence and the sound
/// fades in, toward a tune whose loudest sample is `loud`.
fn assert_fades_in(samples: &[f32], loud: f32) {
    let start = samples.iter().position(|&s| s != 0.0).expect("sound");
    for k in 1..=FADE_FRAMES.min(samples.len() - start) {
        let limit = loud * fade_gain(k as u32, FADE_FRAMES as u32) + 1e-6;
        let s = samples[start + k - 1].abs();
        assert!(s <= limit, "{k} frames into the sound: {s} > {limit}");
    }
}

#[test]
fn stop_fades_to_silence() {
    let rig = Rig::new();
    let path = tune_file(1, "fade-stop");
    rig.play(&path, 1);
    rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(500));
    rig.cmds.send(PlayerCmd::Stop).unwrap();
    rig.wait(2.0, |s| s.state == PlayState::Stopped);
    std::thread::sleep(Duration::from_millis(50));
    assert_fades_out(&rig.heard());
}

#[test]
fn pause_fades_out_and_resume_fades_in() {
    let rig = Rig::new();
    let path = tune_file(1, "fade-pause");
    rig.play(&path, 1);
    rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(500));
    rig.cmds.send(PlayerCmd::TogglePause).unwrap();
    rig.wait(2.0, |s| s.state == PlayState::Paused);
    std::thread::sleep(Duration::from_millis(50));
    let paused = rig.heard();
    let silence = assert_fades_out(&paused);
    assert!(paused.len() - silence > FADE_FRAMES, "it stays silent");

    rig.cmds.send(PlayerCmd::TogglePause).unwrap();
    rig.wait(2.0, |s| s.state == PlayState::Playing);
    std::thread::sleep(Duration::from_millis(50));
    let resumed = rig.heard();
    assert!(peak(&resumed) > 0.05);
    assert_fades_in(&resumed, peak(&paused));
}

#[test]
fn quit_fades_out_before_the_output_closes() {
    let rig = Rig::new();
    let path = tune_file(1, "fade-quit");
    rig.play(&path, 1);
    rig.wait(5.0, |s| s.elapsed >= Duration::from_millis(500));
    let began = Instant::now();
    rig.cmds.send(PlayerCmd::Quit).unwrap();
    // The output closes when the thread is done with it; then the tap ends.
    let mut heard = rig.heard();
    while let Ok(block) = rig.tap.recv_timeout(Duration::from_secs(3)) {
        heard.extend(block.into_iter().step_by(2));
    }
    assert!(began.elapsed() < Duration::from_secs(1), "{:?}", began.elapsed());
    // Everything the output was ever given ends faded out, in silence.
    assert_fades_out(&heard);
}

#[test]
fn quit_does_not_wait_for_an_output_that_stopped_asking() {
    // A device that asks once a minute: the fade never gets rendered.
    let feed = Arc::new(Mutex::new(VizFeed::new()));
    let (cmds, statuses, _device, _seeker, thread) = spawn_with(
        feed,
        Chip::ReSidFp,
        Output::Fake {
            rate: RATE,
            block: 480,
            period: Duration::from_secs(60),
            tap: None,
        },
    );
    let _quit = QuitAtEnd::new(&cmds, thread);
    let path = tune_file(1, "fade-stuck");
    cmds.send(PlayerCmd::Play {
        path,
        song: 1,
        force_stereo: false,
        pseudo_stereo: None,
        sid4_addr: 0,
        audio_port: None,
        restart_usb_on_load: false,
    })
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while statuses.recv_deadline(deadline).expect("a status").state != PlayState::Playing {}
    let began = Instant::now();
    cmds.send(PlayerCmd::Quit).unwrap();
    while statuses.recv_timeout(Duration::from_secs(3)).is_ok() {}
    let took = began.elapsed();
    assert!(took >= FADE_WAIT, "it gave the fade its chance: {took:?}");
    assert!(took < FADE_WAIT + Duration::from_millis(300), "{took:?}");
}

// ── Listening on a device ──

/// Opus frames from the listener, decoded: (first sample, left channel).
fn listen_for(device: &crate::listen::testing::Device, secs: f64) -> Vec<(u64, Vec<f32>)> {
    let mut decoder = opus::Decoder::new(crate::listen::RATE, opus::Channels::Stereo).unwrap();
    let deadline = Instant::now() + Duration::from_secs_f64(secs);
    let mut frames = Vec::new();
    let mut pcm = vec![0f32; crate::listen::FRAME * 2];
    while Instant::now() < deadline {
        let Some((kind, body)) = device.receive() else { continue };
        if kind != crate::listen::AUDIO {
            continue;
        }
        let first = u64::from_le_bytes(body[4..12].try_into().unwrap());
        let n = decoder.decode_float(&body[30..], &mut pcm, false).unwrap();
        frames.push((first, pcm[..n * 2].iter().step_by(2).copied().collect()));
    }
    frames
}

fn switch_to_a_listener(rate: u32) {
    let feed = Arc::new(Mutex::new(VizFeed::new()));
    let (cmds, statuses, _device, seeker, thread) = spawn_with(
        feed.clone(),
        Chip::ReSidFp,
        Output::Fake {
            rate,
            block: 480,
            period: Duration::from_millis(10),
            tap: None,
        },
    );
    let _quit = QuitAtEnd::new(&cmds, thread);
    let rig_statuses = statuses.clone();
    let path = tune_file(1, &format!("listen-{rate}"));
    cmds.send(PlayerCmd::Play {
        path,
        song: 1,
        force_stereo: false,
        pseudo_stereo: None,
        sid4_addr: 0,
        audio_port: None,
        restart_usb_on_load: false,
    })
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while rig_statuses.recv_deadline(deadline).expect("a status").elapsed < Duration::from_millis(300) {}
    // A minute in: building an engine at the new rate and running it here
    // would take about a second.
    seeker.targets.send(Duration::from_secs(60)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut before = Duration::ZERO;
    while before < Duration::from_secs(60) || seeker.seeking.load(Ordering::Relaxed) {
        before = rig_statuses.recv_deadline(deadline).expect("a status").elapsed;
    }

    let key = [9u8; 32];
    let listener = crate::listen::Listener::open(&key).unwrap();
    let mut device = crate::listen::testing::Device::new(&key);
    let hello = device.packet(crate::listen::HELLO, &[]);
    device.send(&hello, listener.port());
    let switched = Instant::now();
    seeker.listen.send(Some(listener)).unwrap();
    // The first audible frame, played straight on (or converted).
    let mut decoder = opus::Decoder::new(crate::listen::RATE, opus::Channels::Stereo).unwrap();
    let mut pcm = vec![0f32; crate::listen::FRAME * 2];
    let heard = loop {
        assert!(switched.elapsed() < Duration::from_secs(3), "nothing audible on the device");
        let Some((kind, body)) = device.receive() else { continue };
        if kind != crate::listen::AUDIO {
            continue;
        }
        let n = decoder.decode_float(&body[30..], &mut pcm, false).unwrap();
        if pcm[..n * 2].iter().any(|s| s.abs() > 0.01) {
            break switched.elapsed();
        }
    };
    assert!(heard < Duration::from_millis(150), "the switch took {heard:?}");

    crate::viz::lock(&feed).take_remote();
    let frames = listen_for(&device, 1.0);
    assert!((60..=105).contains(&frames.len()), "100 frames a second, at real time: {}", frames.len());

    // The remote's visualizer frames sit on the stream's samples: one per
    // PAL frame (19.95 ms, 958 samples at 48 kHz), near the audio just sent.
    let (visuals, scope) = {
        let mut feed = crate::viz::lock(&feed);
        let visuals = feed.take_remote();
        let scope = feed.remote_scope(&visuals.last().unwrap().0);
        (visuals, scope)
    };
    // A frame's scope: three voices, every second sample. A frame is 20 ms
    // (894 samples) or a buffer more, when the buffers don't divide it.
    assert!((3 * 440..=3 * 680).contains(&scope.len()), "scope bytes: {}", scope.len());
    assert!(scope.iter().any(|&b| (b as i8).unsigned_abs() > 2), "the scope has the tune in it");
    let stamps: Vec<u64> = visuals.iter().filter_map(|(_, at)| *at).collect();
    assert!(stamps.len() >= 30, "frames stamped while listening: {} of {}", stamps.len(), visuals.len());
    for pair in stamps.windows(2).skip(1) {
        let step = pair[1] as i64 - pair[0] as i64;
        assert!((900..=1500).contains(&step), "a frame's length in stream samples: {step}");
    }
    let newest_audio = frames.last().unwrap().0 as i64;
    let newest_frame = *stamps.last().unwrap() as i64;
    assert!((newest_frame - newest_audio).abs() < 4_800, "frame at {newest_frame}, audio at {newest_audio}");
    assert!(frames.windows(2).all(|w| w[1].0 == w[0].0 + crate::listen::FRAME as u64), "no gaps once it runs");
    let loud = frames.iter().flat_map(|(_, l)| l).fold(0f32, |m, s| m.max(s.abs()));
    assert!(loud > 0.01, "the tune reached the device: {loud}");

    // It kept going from where it was, not from the top.
    let mut after = Duration::ZERO;
    while let Ok(status) = rig_statuses.try_recv() {
        after = status.elapsed;
    }
    assert!(after >= before, "{after:?} < {before:?}");
    cmds.send(PlayerCmd::Quit).unwrap();
}

#[test]
fn a_playing_tune_moves_to_a_listening_device() {
    switch_to_a_listener(48_000);
}

/// The speakers at 44.1 kHz: the engine keeps playing, converted to 48 kHz.
#[test]
fn a_tune_at_another_rate_moves_to_a_listening_device() {
    switch_to_a_listener(44_100);
}

/// Paused while listening, then played again: the device hears the tune
/// again, and a seek made while paused is heard from its new place.
#[test]
fn a_listening_device_hears_the_tune_again_after_a_pause() {
    let feed = Arc::new(Mutex::new(VizFeed::new()));
    let (cmds, statuses, _device, seeker, thread) = spawn_with(
        feed,
        Chip::ReSidFp,
        Output::Fake { rate: 48_000, block: 480, period: Duration::from_millis(10), tap: None },
    );
    let _quit = QuitAtEnd::new(&cmds, thread);
    cmds.send(PlayerCmd::Play {
        path: tune_file(1, "listen-pause"),
        song: 1,
        force_stereo: false,
        pseudo_stereo: None,
        sid4_addr: 0,
        audio_port: None,
        restart_usb_on_load: false,
    })
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while statuses.recv_deadline(deadline).expect("a status").elapsed < Duration::from_millis(300) {}

    let key = [9u8; 32];
    let listener = crate::listen::Listener::open(&key).unwrap();
    let mut device = crate::listen::testing::Device::new(&key);
    let hello = device.packet(crate::listen::HELLO, &[]);
    device.send(&hello, listener.port());
    seeker.listen.send(Some(listener)).unwrap();
    let loudest = |frames: &[(u64, Vec<f32>)]| frames.iter().flat_map(|(_, l)| l).fold(0f32, |m, s| m.max(s.abs()));
    assert!(loudest(&listen_for(&device, 0.5)) > 0.01, "playing before the pause");

    cmds.send(PlayerCmd::SetPaused(true)).unwrap();
    listen_for(&device, 0.2);
    let paused = listen_for(&device, 0.3);
    assert!(!paused.is_empty(), "silence keeps coming while paused");
    assert!(loudest(&paused) < 0.001, "quiet while paused: {}", loudest(&paused));

    cmds.send(PlayerCmd::SetPaused(false)).unwrap();
    listen_for(&device, 0.1);
    assert!(loudest(&listen_for(&device, 0.5)) > 0.01, "heard again after the pause");

    cmds.send(PlayerCmd::SetPaused(true)).unwrap();
    listen_for(&device, 0.3);
    seeker.targets.send(Duration::from_secs(2)).unwrap();
    listen_for(&device, 0.5);
    cmds.send(PlayerCmd::SetPaused(false)).unwrap();
    listen_for(&device, 0.2);
    assert!(loudest(&listen_for(&device, 0.5)) > 0.01, "heard again after seeking while paused");
    cmds.send(PlayerCmd::Quit).unwrap();
}

/// Another tune while listening: its visualizer frames keep coming, on
/// the stream's samples, after the last tune's.
#[test]
fn visualizer_frames_follow_a_new_tune_while_listening() {
    let feed = Arc::new(Mutex::new(VizFeed::new()));
    let (cmds, statuses, _device, seeker, thread) = spawn_with(
        feed.clone(),
        Chip::ReSidFp,
        Output::Fake { rate: 48_000, block: 480, period: Duration::from_millis(10), tap: None },
    );
    let _quit = QuitAtEnd::new(&cmds, thread);
    let play = |tag: &str| PlayerCmd::Play {
        path: tune_file(1, tag),
        song: 1,
        force_stereo: false,
        pseudo_stereo: None,
        sid4_addr: 0,
        audio_port: None,
        restart_usb_on_load: false,
    };
    cmds.send(play("viz-a")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while statuses.recv_deadline(deadline).expect("a status").elapsed < Duration::from_millis(300) {}

    let key = [9u8; 32];
    let listener = crate::listen::Listener::open(&key).unwrap();
    let mut device = crate::listen::testing::Device::new(&key);
    let hello = device.packet(crate::listen::HELLO, &[]);
    device.send(&hello, listener.port());
    seeker.listen.send(Some(listener)).unwrap();
    listen_for(&device, 0.5);
    let first: Vec<u64> = crate::viz::lock(&feed).take_remote().iter().filter_map(|(_, s)| *s).collect();
    assert!(!first.is_empty(), "frames stamped for the first tune");

    cmds.send(play("viz-b")).unwrap();
    let audio = listen_for(&device, 1.0);
    let after = crate::viz::lock(&feed).take_remote();
    let stamped: Vec<u64> = after.iter().filter_map(|(_, s)| *s).collect();
    assert!(stamped.len() >= 30, "frames stamped for the next tune: {} of {}", stamped.len(), after.len());
    assert!(stamped[0] > *first.last().unwrap(), "after the last tune's");
    let newest_audio = audio.last().unwrap().0 as i64;
    assert!((*stamped.last().unwrap() as i64 - newest_audio).abs() < 4_800, "near the audio");
    cmds.send(PlayerCmd::Quit).unwrap();
}
