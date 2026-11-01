use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::*;
use crate::ffi::VizSidFrame;
use crate::player::{PlayState, PlayerStatus, TrackInfo};

const FRAME: Duration = Duration::from_millis(20);

fn track(path: &str, song: u16, num_sids: usize) -> TrackInfo {
    TrackInfo {
        path: PathBuf::from(path),
        name: String::new(),
        author: String::new(),
        released: String::new(),
        songs: 3,
        current_song: song,
        is_pal: true,
        is_rsid: false,
        num_sids,
        sid_type: "PSID".to_string(),
        sid_model: 2,
        md5: String::new(),
        mus_comments: Vec::new(),
    }
}

fn status(info: &TrackInfo, elapsed: Duration, chip0: [u8; 32]) -> PlayerStatus {
    let mut sid_regs = vec![0u8; 128];
    sid_regs[..32].copy_from_slice(&chip0);
    PlayerStatus {
        state: PlayState::Playing,
        track_info: Some(info.clone()),
        elapsed,
        sid_regs,
        ..PlayerStatus::default()
    }
}

/// Voice 1: A4, the given waveform/gate control byte and envelope.
fn voice1(control: u8, ad: u8, sr: u8) -> [u8; 32] {
    let mut regs = [0u8; 32];
    regs[0] = (7493 & 0xFF) as u8;
    regs[1] = (7493 >> 8) as u8;
    regs[2] = 0x00;
    regs[3] = 0x08;
    regs[4] = control;
    regs[5] = ad;
    regs[6] = sr;
    regs[0x18] = 0x0F;
    regs
}

struct Rig {
    feed: SharedFeed,
    capture: VizCapture,
    base: Instant,
    info: TrackInfo,
    frames: u32,
}

impl Rig {
    fn new() -> Self {
        let feed = Arc::new(Mutex::new(VizFeed::new()));
        Self {
            capture: VizCapture::new(feed.clone()),
            feed,
            base: Instant::now(),
            info: track("/hvsc/a.sid", 1, 1),
            frames: 0,
        }
    }

    /// Play `n` frames of `regs`, arriving exactly on time.
    fn play(&mut self, n: u32, regs: [u8; 32]) {
        for _ in 0..n {
            self.frames += 1;
            let elapsed = FRAME * self.frames;
            let s = status(&self.info, elapsed, regs);
            self.capture.ingest(&s, self.base + elapsed);
        }
    }

    /// When timeline position `pos` is heard, before any output latency:
    /// frames arrive on time, so the buffer holds the track-start lag.
    fn heard(&self, pos: Duration) -> Instant {
        self.base + pos + TRACK_START_LAG
    }

    /// The frame heard as the last one played ends.
    fn latest(&self) -> Frame {
        let now = self.heard(FRAME * self.frames);
        lock(&self.feed).latest(now).expect("a frame")
    }

    fn env(&self) -> u8 {
        self.latest().chips[0].env[0]
    }
}

#[test]
fn attack_zero_reaches_full_within_a_frame() {
    let mut rig = Rig::new();
    rig.play(1, voice1(0x21, 0x00, 0xF0));
    assert_eq!(rig.env(), 0xFF);
}

#[test]
fn decay_settles_on_the_sustain_level() {
    let mut rig = Rig::new();
    rig.play(5, voice1(0x21, 0x00, 0x80));
    assert_eq!(rig.env(), 0x88);
}

#[test]
fn release_zero_falls_to_silence() {
    let mut rig = Rig::new();
    rig.play(3, voice1(0x21, 0x00, 0xF0));
    rig.play(3, voice1(0x20, 0x00, 0xF0));
    assert_eq!(rig.env(), 0);
}

#[test]
fn slow_attack_is_partway_after_one_frame() {
    // Attack 8 takes 100 ms to full; one 20 ms frame gets about a fifth.
    let mut rig = Rig::new();
    rig.play(1, voice1(0x21, 0x80, 0xF0));
    let env = rig.env();
    assert!((30..80).contains(&env), "env {env}");
}

#[test]
fn frames_report_each_envelope_phase() {
    use crate::ffi::EnvelopePhase::*;
    let phase = |rig: &Rig| VizSidFrame::from(&rig.latest()).chips[0].voices[0].env_phase;
    let mut rig = Rig::new();
    // Attack 8 takes 100 ms: still climbing after one frame.
    rig.play(1, voice1(0x21, 0x8A, 0x80));
    assert_eq!(phase(&rig), Attack);
    // Decay A (1.5 s) from the top toward sustain 8: still falling.
    rig.play(7, voice1(0x21, 0x8A, 0x80));
    assert_eq!(phase(&rig), Decay);
    // A short decay reaches the sustain level and holds there.
    let mut rig = Rig::new();
    rig.play(5, voice1(0x21, 0x00, 0x80));
    assert_eq!(phase(&rig), Sustain);
    rig.play(1, voice1(0x20, 0x00, 0x80));
    assert_eq!(phase(&rig), Release);
}

#[test]
fn repeated_statuses_do_not_clock() {
    let mut rig = Rig::new();
    rig.play(2, voice1(0x21, 0x00, 0xF0));
    let again = status(&rig.info, FRAME * 2, voice1(0x21, 0x00, 0xF0));
    rig.capture.ingest(&again, rig.base + FRAME * 2);
    assert_eq!(lock(&rig.feed).stats().frames, 2);
}

#[test]
fn a_new_track_or_subtune_starts_over() {
    let mut rig = Rig::new();
    rig.play(4, voice1(0x21, 0x00, 0xF0));
    assert_eq!(rig.latest().index, 3);

    rig.info = track("/hvsc/a.sid", 2, 1);
    rig.frames = 0;
    rig.base = Instant::now();
    rig.play(1, voice1(0x11, 0x00, 0xF0));
    let frame = rig.latest();
    assert_eq!(frame.index, 0);
    assert_eq!(lock(&rig.feed).stats().frames, 1);
}

#[test]
fn stopping_clears_the_feed() {
    let mut rig = Rig::new();
    rig.play(2, voice1(0x21, 0x00, 0xF0));
    let stopped = PlayerStatus::default();
    rig.capture.ingest(&stopped, rig.base + FRAME * 3);
    let now = rig.heard(FRAME * 3);
    assert!(lock(&rig.feed).latest(now).is_none());
}

#[test]
fn history_keeps_the_last_512_frames() {
    let mut rig = Rig::new();
    rig.play(600, voice1(0x21, 0x00, 0xF0));
    let now = rig.heard(FRAME * rig.frames);
    let history = lock(&rig.feed).history(now, 1000);
    assert_eq!(history.len(), HISTORY_FRAMES);
    assert_eq!(history.last().unwrap().index, 599);
    assert_eq!(history.first().unwrap().index, 599 - 511);
}

#[test]
fn reads_trail_by_the_track_start_lag() {
    let mut rig = Rig::new();
    rig.play(20, voice1(0x21, 0x00, 0xF0));
    let feed = lock(&rig.feed);
    // 205 ms into the timeline: the frame covering 200–220 ms.
    let at = |ms| rig.heard(Duration::from_millis(ms));
    assert_eq!(feed.latest(at(205)).unwrap().index, 10);
    // The first frame is queued behind the engine's silence.
    assert!(feed.latest(rig.base + Duration::from_millis(60)).is_none());
    // Past the newest frame (paused, say): hold on it.
    assert_eq!(feed.latest(at(5_000)).unwrap().index, 19);
    // When the newest frame arrives, the buffer holds the lag.
    let buffered = feed.buffered(rig.base + FRAME * 20);
    assert!((buffered.as_secs_f64() - 0.1).abs() < 0.001, "{buffered:?}");
}

#[test]
fn a_long_pause_drains_the_buffer() {
    let mut rig = Rig::new();
    rig.play(10, voice1(0x21, 0x00, 0xF0));
    // Paused for two seconds: the buffer ran dry, so after resuming each
    // frame plays as soon as it's queued — no lag left.
    rig.base += Duration::from_secs(2);
    rig.play(10, voice1(0x21, 0x00, 0xF0));
    let feed = lock(&rig.feed);
    let now = rig.base + Duration::from_millis(305);
    assert_eq!(feed.latest(now).unwrap().index, 15);
    assert!(feed.buffered(rig.base + FRAME * 20) < Duration::from_millis(1));
}

#[test]
fn a_short_pause_plays_on_from_the_buffer() {
    let mut rig = Rig::new();
    rig.play(10, voice1(0x21, 0x00, 0xF0));
    // 50 ms is less than the buffer held: the sound never stopped, and the
    // frames after the pause queue up behind it.
    let base = rig.base;
    rig.base += Duration::from_millis(50);
    rig.play(10, voice1(0x21, 0x00, 0xF0));
    let now = base + Duration::from_millis(305) + TRACK_START_LAG;
    assert_eq!(lock(&rig.feed).latest(now).unwrap().index, 15);
}

#[test]
fn output_latency_and_offset_shift_reads_later() {
    let mut rig = Rig::new();
    rig.play(20, voice1(0x21, 0x00, 0xF0));
    let mut feed = lock(&rig.feed);
    feed.set_output_latency(Duration::from_millis(20));
    feed.set_offset_ms(20);
    let now = rig.heard(Duration::from_millis(205));
    assert_eq!(feed.latest(now).unwrap().index, 8);
    feed.set_offset_ms(-40);
    assert_eq!(feed.latest(now).unwrap().index, 11);
}

#[test]
fn scope_returns_each_voice_up_to_the_playhead() {
    let mut rig = Rig::new();
    rig.play(10, voice1(0x21, 0x00, 0xF0));
    let now = rig.heard(FRAME * rig.frames);
    let feed = lock(&rig.feed);
    let [v1, v2, v3] = feed.scope(now, 0, 2048);
    assert_eq!(v1.len(), 2048);
    assert_eq!(v2.len(), 2048);
    assert!(v1.iter().all(|s| (-1.0..=1.0).contains(s)));
    // A full-envelope saw sweeps most of the range; the silent voices don't.
    let (lo, hi) = v1
        .iter()
        .fold((1f32, -1f32), |(lo, hi), &s| (lo.min(s), hi.max(s)));
    assert!(lo < -0.9 && hi > 0.9, "{lo}..{hi}");
    assert!(v2.iter().chain(&v3).all(|&s| s == 0.0));
    // About 44.8 kHz: one 20 ms frame is ~896 samples.
    assert!((feed.sample_rate() - 44_784.0).abs() < 1.0);
    assert!(feed.scope(now, 1, 2048)[0].is_empty());
}

#[test]
fn frames_decode_for_the_ui() {
    let mut rig = Rig::new();
    let mut regs = voice1(0x41 | 0x04, 0x9A, 0x5C);
    regs[0x15] = 0x05;
    regs[0x16] = 0x80;
    regs[0x17] = 0xA3;
    regs[0x18] = 0x1F;
    rig.play(1, regs);
    let frame = VizSidFrame::from(&rig.latest());
    assert_eq!(frame.chips.len(), 1);
    let chip = &frame.chips[0];
    let v = &chip.voices[0];
    assert_eq!(v.note.as_deref(), Some("A4"));
    assert!((v.hz - 440.0).abs() < 0.1, "{}", v.hz);
    assert!(v.gate && v.ring && !v.sync && !v.test);
    assert_eq!(v.waveform, 0x4);
    assert_eq!(v.pulse_width, 0x800);
    assert_eq!((v.attack, v.decay, v.sustain, v.release), (9, 10, 5, 12));
    assert!(chip.voices[1].note.is_none() && !chip.voices[1].gate);
    assert_eq!(chip.cutoff, (0x80 << 3) | 0x05);
    assert_eq!(chip.resonance, 0xA);
    assert_eq!(chip.filter_routing, 0x3);
    assert_eq!(chip.filter_mode, 0x1);
    assert_eq!(chip.volume, 0xF);
    assert_eq!(chip.registers.len(), FRAME_REGS);
}
