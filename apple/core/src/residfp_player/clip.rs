//! Clips: a stretch of a tune rendered offline for a video, with the
//! visualizers' feed to draw its frames from (design/clip-sharing).
//!
//! A clip builds its own engine, the same way the player builds a track
//! (`build`), runs it silently to where the clip's lead-in starts, as a seek
//! does, then renders one video frame at a time: each step makes exactly
//! that frame's audio, and pushes what the chips did into a feed of the
//! clip's own. The feed's reads take an instant, and the clip's instants
//! are its own clock: instant `base + t` is `t` into the subtune, with no
//! buffer and no output latency, so a frame drawn after a step shows the
//! sound that step made. Picture and sound share one sample count; nothing
//! about their sync is tuned.
//!
//! Sound is the engine's own samples at unity gain, without the player's
//! volume.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use super::{build, chip_for, chip_state, find_roms, nominal_frame, Live, CHUNK, SCOPE_CAP};
use crate::ffi::{Engine as FfiEngine, VizScopeSamples, VizSidFrame, VizStats};
use crate::session;
use crate::viz::{ChipState, Frame, VizFeed, MAX_CHIPS};

/// The last few tracks started, by the player or a clip, with their
/// power-on delays, so a clip of one starts the C64 the same way and sounds
/// the same. Without it a clip gets a random delay, as a fresh start does.
static STARTS: Mutex<Vec<(PathBuf, u16, u16)>> = Mutex::new(Vec::new());

/// How many tracks `STARTS` keeps.
const STARTS_KEPT: usize = 16;

pub(super) fn remember_start(path: &Path, song: u16, power_on_delay: u16) {
    if let Ok(mut starts) = STARTS.lock() {
        starts.retain(|(p, s, _)| !(p == path && *s == song));
        if starts.len() >= STARTS_KEPT {
            starts.remove(0);
        }
        starts.push((path.to_path_buf(), song, power_on_delay));
    }
}

fn power_on_delay_for(path: &Path, song: u16) -> Option<u16> {
    let starts = STARTS.lock().ok()?;
    starts.iter().rev().find(|(p, s, _)| p == path && *s == song).map(|(_, _, delay)| *delay)
}

/// What to render.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ClipConfig {
    pub path: String,
    /// The subtune, 1-based.
    pub subtune: u16,
    /// The player's engine. Upstream's engines can't render offline, so
    /// they're rendered through reSIDfp.
    pub engine: FfiEngine,
    /// Play 2SID tunes mirrored to both channels, as the player does.
    pub force_stereo_2sid: bool,
    /// Where rendering starts, from the subtune's start: the lead-in's
    /// first frame. The caller draws the lead-in without keeping it.
    pub from_ms: u64,
    pub frames_per_second: u32,
    pub sample_rate: u32,
}

/// A clip that couldn't be started.
#[derive(Debug, Clone, PartialEq, uniffi::Error)]
pub enum ClipError {
    Failed { message: String },
}

impl std::fmt::Display for ClipError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClipError::Failed { message } => f.write_str(message),
        }
    }
}

impl std::error::Error for ClipError {}

/// One video frame's audio.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ClipAudio {
    /// Interleaved stereo, −1…1, native-endian f32, packed like the scope.
    pub samples: Vec<u8>,
    /// Frames (sample pairs) in it.
    pub count: u32,
    /// The end of this video frame, in seconds from the subtune's start.
    pub position_secs: f64,
    /// False once the engine has stopped (an error); the samples are then
    /// silence.
    pub ok: bool,
}

/// A tune rendering offline into a clip, one video frame per `next_frame`.
#[derive(uniffi::Object)]
pub struct ClipRenderer {
    state: Mutex<State>,
}

struct State {
    live: Box<Live>,
    feed: VizFeed,
    /// The clip's clock: instant `base + t` is `t` into the subtune.
    base: Instant,
    fps: u32,
    /// Video frames rendered, and the sample the first one starts at.
    video_frames: u64,
    first_sample: u64,
    is_pal: bool,
    chips: usize,
    failed: bool,
    scratch: Vec<i16>,
    scope: Vec<f32>,
    // The feed frame being gathered, one per C64 frame, as the player's
    // control thread does it.
    frame_index: u64,
    frame_start: Duration,
    frame_scope: Vec<Vec<f32>>,
    frame_chips: [ChipState; MAX_CHIPS],
}

#[uniffi::export]
impl ClipRenderer {
    #[uniffi::constructor]
    pub fn new(config: ClipConfig) -> Result<Arc<Self>, ClipError> {
        let fail = |message: String| ClipError::Failed { message };
        if config.frames_per_second == 0 || config.sample_rate == 0 {
            return Err(fail("A clip needs a frame rate and a sample rate.".into()));
        }
        let path = PathBuf::from(&config.path);
        let chip = chip_for(session::Engine::from(config.engine)).unwrap_or(residfp_sys::Chip::ReSidFp);
        let built = build(
            &find_roms(),
            chip,
            &path,
            config.subtune,
            config.force_stereo_2sid,
            config.sample_rate,
            power_on_delay_for(&path, config.subtune),
        )
        .map_err(fail)?;
        let started = built.started;
        // A tune that isn't playing keeps the delay its first clip drew,
        // so its clips agree with each other (until it plays).
        if power_on_delay_for(&path, config.subtune).is_none() {
            remember_start(&path, config.subtune, started.power_on_delay);
        }
        let chips = started.chips.min(MAX_CHIPS);
        let mut live = Box::new(Live {
            engine: built.engine,
            id: 0,
            chips: started.chips,
            samples: 0,
            rate: config.sample_rate,
            cpu_hz: started.cpu_hz,
            out: None,
        });
        let from = Duration::from_millis(config.from_ms);
        if !from.is_zero() {
            let progress = std::sync::atomic::AtomicU64::new(0);
            live.skip_to(Duration::ZERO, from, &progress);
        }
        // What the chips logged on the way there isn't the clip's.
        let mut drain = vec![0f32; 3 * SCOPE_CAP];
        for c in 0..chips {
            while live.engine.take_scope(c, &mut drain) == SCOPE_CAP {}
            let _ = live.engine.take_writes(c, &mut []);
        }
        let mut feed = VizFeed::new();
        feed.begin_track(started.is_pal);
        let first_sample = live.samples;
        let start = Duration::from_secs_f64(first_sample as f64 / config.sample_rate as f64);
        Ok(Arc::new(Self {
            state: Mutex::new(State {
                live,
                feed,
                base: Instant::now(),
                fps: config.frames_per_second,
                video_frames: 0,
                first_sample,
                is_pal: started.is_pal,
                chips,
                failed: false,
                scratch: vec![0; CHUNK * 2],
                scope: drain,
                frame_index: 0,
                frame_start: start,
                frame_scope: (0..chips * 3).map(|_| Vec::with_capacity(2048)).collect(),
                frame_chips: [ChipState::default(); MAX_CHIPS],
            }),
        }))
    }

    /// Render the next video frame's audio, and what the chips did in it
    /// into the clip's feed.
    pub fn next_frame(&self) -> ClipAudio {
        self.lock().render_frame()
    }

    /// The end of the last frame rendered, in seconds from the subtune's
    /// start.
    pub fn position_secs(&self) -> f64 {
        self.lock().position().as_secs_f64()
    }

    // The feed's reads, with the same names and shapes as `PlayerCore`'s,
    // so the app's visualizers read a clip as they read the player.

    pub fn viz_latest(&self) -> Option<VizSidFrame> {
        let s = self.lock();
        s.feed.latest(s.now()).as_ref().map(VizSidFrame::from)
    }

    pub fn viz_heard_secs(&self) -> Option<f64> {
        let s = self.lock();
        s.feed.heard(s.now()).map(|heard| heard.as_secs_f64())
    }

    pub fn viz_history(&self, count: u32) -> Vec<VizSidFrame> {
        let s = self.lock();
        s.feed.history(s.now(), count as usize).iter().map(VizSidFrame::from).collect()
    }

    pub fn viz_scope(&self, chip: u32, count: u32) -> VizScopeSamples {
        let s = self.lock();
        let voices = s.feed.scope(s.now(), chip as usize, count as usize);
        VizScopeSamples::pack(s.feed.sample_rate(), &voices)
    }

    pub fn viz_stats(&self) -> VizStats {
        let s = self.lock();
        let stats = s.feed.stats();
        VizStats {
            frames: stats.frames,
            shadow_micros: stats.shadow_micros,
            buffer_ms: 0.0,
            output_latency_ms: 0,
            offset_ms: 0,
        }
    }

    /// A clip has no output device: nothing to set.
    pub fn set_viz_output_latency_ms(&self, _ms: u32) {}

    pub fn set_viz_offset_ms(&self, _ms: i32) {}
}

impl ClipRenderer {
    fn lock(&self) -> MutexGuard<'_, State> {
        match self.state.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

impl State {
    fn rate(&self) -> u32 {
        self.live.rate
    }

    fn position(&self) -> Duration {
        Duration::from_secs_f64(self.live.samples as f64 / self.rate() as f64)
    }

    /// The clip's "now": its position on the clip's clock.
    fn now(&self) -> Instant {
        self.base + self.position()
    }

    /// The sample video frame `k` starts at, exactly, so the frames never
    /// drift from the audio, whatever the rates.
    fn sample_at(&self, k: u64) -> u64 {
        self.first_sample + k * self.rate() as u64 / self.fps as u64
    }

    fn render_frame(&mut self) -> ClipAudio {
        let want = (self.sample_at(self.video_frames + 1) - self.sample_at(self.video_frames)) as usize;
        self.video_frames += 1;
        let mut out = Vec::with_capacity(want * 2 * 4);
        let gain = 1.0 / 32768.0;
        let mut done = 0;
        while done < want {
            // Up to the end of the C64 frame being gathered at most, so the
            // feed gets one frame per C64 frame, as live, not one per video
            // frame.
            let frame_end = (self.frame_start + nominal_frame(self.is_pal)).as_secs_f64() * self.rate() as f64;
            let to_boundary = (frame_end.ceil() as u64).saturating_sub(self.live.samples).max(1) as usize;
            let n = (want - done).min(CHUNK).min(to_boundary);
            let got = if self.failed { 0 } else { self.live.engine.render(&mut self.scratch[..n * 2]) };
            for &s in &self.scratch[..got * 2] {
                out.extend_from_slice(&(s as f32 * gain).to_ne_bytes());
            }
            self.live.samples += got as u64;
            if got < n {
                // Silence from here on; the frames keep their length.
                self.failed = true;
                let missing = n - got;
                out.resize(out.len() + missing * 2 * 4, 0);
                self.live.samples += missing as u64;
            }
            done += n;
            self.capture();
        }
        ClipAudio {
            samples: out,
            count: want as u32,
            position_secs: self.position().as_secs_f64(),
            ok: !self.failed,
        }
    }

    /// What the chips did since the last call, into the frame being
    /// gathered; a finished C64 frame goes into the feed.
    fn capture(&mut self) {
        let cap = self.scope.len() / 3;
        for c in 0..self.chips {
            if let Some(raw) = self.live.engine.chip_state(c) {
                self.frame_chips[c] = chip_state(&raw);
            }
            let len = self.live.engine.take_scope(c, &mut self.scope);
            for v in 0..3 {
                self.frame_scope[c * 3 + v].extend_from_slice(&self.scope[v * cap..v * cap + len]);
            }
            let _ = self.live.engine.take_writes(c, &mut []);
        }
        let elapsed = self.position();
        if elapsed.saturating_sub(self.frame_start) >= nominal_frame(self.is_pal) {
            let frame = Frame::rendered(
                self.frame_index,
                self.is_pal,
                self.chips,
                self.frame_chips,
                self.frame_start,
                elapsed,
            );
            let mut refs: [&[f32]; MAX_CHIPS * 3] = [&[]; MAX_CHIPS * 3];
            for (slot, voice) in refs.iter_mut().zip(&self.frame_scope) {
                *slot = voice;
            }
            let audible_at = self.base + self.frame_start;
            self.feed.push_rendered(frame, &refs[..self.chips * 3], audible_at, Duration::ZERO, None);
            self.frame_index += 1;
            self.frame_start = elapsed;
            self.frame_scope.iter_mut().for_each(Vec::clear);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tiny PSID, as the player's tests play.
    fn tune(tag: &str) -> Option<String> {
        let path = std::env::temp_dir().join(format!("resonance-clip-{}-{tag}.sid", std::process::id()));
        std::fs::write(&path, residfp_sys::testing::tiny_psid(1)).ok()?;
        Some(path.to_string_lossy().into_owned())
    }

    fn clip(path: String, from_ms: u64) -> Arc<ClipRenderer> {
        ClipRenderer::new(ClipConfig {
            path,
            subtune: 1,
            engine: FfiEngine::ReSidFp,
            force_stereo_2sid: false,
            from_ms,
            frames_per_second: 60,
            sample_rate: 48_000,
        })
        .expect("clip")
    }

    #[test]
    fn frames_carry_exactly_their_share_of_samples() {
        let Some(path) = tune("share") else { return };
        let clip = clip(path, 0);
        let mut total = 0u64;
        for k in 1..=120u64 {
            let audio = clip.next_frame();
            assert_eq!(audio.count, 800);
            assert_eq!(audio.samples.len(), 800 * 2 * 4);
            total += audio.count as u64;
            assert!((audio.position_secs - k as f64 / 60.0).abs() < 1e-9);
        }
        assert_eq!(total, 96_000);
    }

    #[test]
    fn the_feed_follows_the_clip_clock() {
        let Some(path) = tune("clock") else { return };
        let clip = clip(path, 3_000);
        assert!(clip.viz_latest().is_none() || clip.viz_heard_secs().unwrap() <= 3.0);
        for _ in 0..60 {
            clip.next_frame();
        }
        // One second of frames on from 3 s: what's heard ends within a C64
        // frame of the clip's position.
        let heard = clip.viz_heard_secs().expect("heard");
        assert!((clip.position_secs() - 4.0).abs() < 0.001);
        assert!(heard <= 4.0 && heard > 4.0 - 0.021, "heard {heard}");
        // PAL: 50 C64 frames in the second.
        let history = clip.viz_history(64);
        assert!((49..=50).contains(&history.len()), "{} frames", history.len());
        assert!(clip.viz_scope(0, 2048).count > 0);
    }

    #[test]
    fn a_clip_of_the_playing_track_sounds_like_it() {
        let Some(path) = tune("same") else { return };
        // The same start twice gives the same sound: the power-on delay the
        // player used is reused.
        remember_start(Path::new(&path), 1, 0x1234);
        let a = clip(path.clone(), 0);
        let b = clip(path, 0);
        // reSIDfp dithers its output, so not bit for bit: within 2 LSB.
        for _ in 0..30 {
            let (x, y) = (a.next_frame().samples, b.next_frame().samples);
            assert_eq!(x.len(), y.len());
            for (p, q) in x.chunks_exact(4).zip(y.chunks_exact(4)) {
                let (p, q) = (f32::from_ne_bytes(p.try_into().unwrap()), f32::from_ne_bytes(q.try_into().unwrap()));
                assert!((p - q).abs() <= 2.0 / 32768.0 + 1e-7, "{p} vs {q}");
            }
        }
    }
}

