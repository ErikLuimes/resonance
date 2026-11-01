//! The visualizers' data source.
//!
//! The engines keep their reSID / SIDLite instances to themselves, inside
//! upstream files, so the chip that's actually playing can't tell us its
//! envelopes or per-voice waveforms. Instead the session thread runs a
//! visuals-only reSID `Synth` per chip, fed the register shadow from every
//! player status. Register changes land on frame boundaries, so a gate
//! cleared and set again inside one frame (hard restart) and `$D418` digis
//! don't show — fine for visuals, and the same on both engines.
//!
//! Frames sit on the player's emulated timeline (`elapsed`). Reads map
//! wall-clock time to the position being heard by modelling the engine's
//! audio buffer, which upstream doesn't expose:
//!
//! - At each track start the engine queues 150 ms of silence, then waits
//!   ~50 ms before its first frame, so the music trails the emulation by
//!   about 100 ms (`TRACK_START_LAG`).
//! - Each frame then adds its length to the buffer and playback drains it
//!   in real time, so the lag holds steady.
//! - While paused nothing is added and the buffer runs dry; after resuming,
//!   frames play as soon as they land.
//!
//! On top of that comes the output device's own latency (large for
//! Bluetooth), which the app reads from Core Audio, plus a fine-tune offset.

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use resid::synth::Synth;
use resid::ChipModel;

use crate::player::{PlayState, PlayerStatus, TrackInfo};

pub(crate) const MAX_CHIPS: usize = 4;
/// $D400–$D41C.
pub(crate) const FRAME_REGS: usize = 29;
/// About 10 s at 50 Hz.
pub(crate) const HISTORY_FRAMES: usize = 512;
/// The longest scope window a read returns.
pub(crate) const MAX_SCOPE_SAMPLES: usize = 2048;
/// How far a track's first frame trails its emulation: the engines'
/// 150 ms of silence (`prefill_silence` in sid_emulated.rs and
/// sid_sidlite.rs) minus the 50 ms `setup_playback` sleeps after it.
pub(crate) const TRACK_START_LAG: Duration = Duration::from_millis(100);

/// Per voice: the buffer lag plus a full scope window, with room to spare.
const SAMPLE_RING: usize = 16_384;
/// C64 cycles per scope sample: 44.8 kHz on PAL, 46.5 kHz on NTSC.
const CYCLES_PER_SAMPLE: u32 = 22;
const REGS_PER_CHIP: usize = 32;
/// The write-only registers, $00–$18.
const WRITE_REGS: usize = 0x19;
/// Each voice's control register; written after the others so a gate edge
/// sees the frame's new attack/decay and sustain/release.
const CONTROL_REGS: [usize; 3] = [0x04, 0x0B, 0x12];
const OSC3: usize = 0x1B;
const ENV3: usize = 0x1C;
/// Lateness below this is scheduling jitter, not the buffer running dry.
const UNDERRUN_SLACK: Duration = Duration::from_millis(2);

pub(crate) fn clock_hz(is_pal: bool) -> f64 {
    if is_pal {
        985_248.0
    } else {
        1_022_727.0
    }
}

/// One chip's state at the end of a player frame.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub(crate) struct ChipState {
    /// $00–$1C as the player left them; OSC3 and ENV3 from the shadow.
    pub regs: [u8; FRAME_REGS],
    /// The shadow's envelope counters, 0–255.
    pub env: [u8; 3],
    /// Where each voice's envelope generator is.
    pub env_state: [EnvState; 3],
}

/// resid's envelope generator states; decay and sustain share one.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) enum EnvState {
    Attack,
    DecaySustain,
    #[default]
    Release,
}

/// One player frame.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Frame {
    /// Frames since the subtune started.
    pub index: u64,
    pub is_pal: bool,
    pub num_chips: usize,
    pub chips: [ChipState; MAX_CHIPS],
    /// The stretch of emulated time it covers.
    start: Duration,
    end: Duration,
    /// Its scope samples, `sample_start..sample_start + sample_count`.
    sample_start: u64,
    sample_count: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub(crate) struct Stats {
    /// Frames emulated this subtune.
    pub frames: u64,
    /// Moving average of the shadow's time per frame.
    pub shadow_micros: f32,
}

pub(crate) type SharedFeed = Arc<Mutex<VizFeed>>;

pub(crate) fn lock(feed: &SharedFeed) -> MutexGuard<'_, VizFeed> {
    match feed.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

// ── Read side ────────────────────────────────────────────────────────────────

/// What the UI reads: written by the session thread, read by FFI calls,
/// which hold the lock only to copy what they asked for.
pub(crate) struct VizFeed {
    frames: VecDeque<Frame>,
    /// `MAX_CHIPS × 3` rings of `SAMPLE_RING` samples, −1…1.
    samples: Vec<f32>,
    /// Samples written per voice since the subtune started.
    written: u64,
    sample_rate: f32,
    /// When the newest frame's start leaves the engine's buffer: (instant,
    /// timeline position). Earlier and later positions follow in real time.
    audible: Option<(Instant, Duration)>,
    /// The output device's latency, from Core Audio.
    output_latency: Duration,
    /// Fine-tuning on top, in milliseconds; positive shows frames later.
    offset_ms: i32,
    stats: Stats,
}

impl VizFeed {
    pub fn new() -> Self {
        Self {
            frames: VecDeque::with_capacity(HISTORY_FRAMES),
            samples: vec![0.0; MAX_CHIPS * 3 * SAMPLE_RING],
            written: 0,
            sample_rate: (clock_hz(true) / CYCLES_PER_SAMPLE as f64) as f32,
            audible: None,
            output_latency: Duration::ZERO,
            offset_ms: 0,
            stats: Stats::default(),
        }
    }

    pub fn output_latency(&self) -> Duration {
        self.output_latency
    }

    pub fn set_output_latency(&mut self, latency: Duration) {
        self.output_latency = latency;
    }

    pub fn offset_ms(&self) -> i32 {
        self.offset_ms
    }

    pub fn set_offset_ms(&mut self, ms: i32) {
        self.offset_ms = ms;
    }

    pub fn stats(&self) -> Stats {
        self.stats
    }

    /// How far the engine's buffer has the newest frame trailing its
    /// emulation, as of `now`.
    pub fn buffered(&self, now: Instant) -> Duration {
        match (self.audible, self.frames.back()) {
            (Some((at, pos)), Some(last)) => {
                (at + last.end.saturating_sub(pos)).saturating_duration_since(now)
            }
            _ => Duration::ZERO,
        }
    }

    pub fn sample_rate(&self) -> f32 {
        self.sample_rate
    }

    /// The frame being heard now, or None before the first one has made it
    /// through the buffer and while stopped.
    pub fn latest(&self, now: Instant) -> Option<Frame> {
        self.playhead(now).map(|(i, _)| self.frames[i])
    }

    /// Up to `count` frames, oldest first, ending with the one being heard.
    pub fn history(&self, now: Instant, count: usize) -> Vec<Frame> {
        let Some((i, _)) = self.playhead(now) else {
            return Vec::new();
        };
        let from = (i + 1).saturating_sub(count);
        self.frames.range(from..=i).copied().collect()
    }

    /// The last `count` samples (at most `MAX_SCOPE_SAMPLES`) of each of
    /// `chip`'s voices, oldest first, up to the playhead. Shorter at the
    /// start of a subtune; empty when nothing is playing.
    pub fn scope(&self, now: Instant, chip: usize, count: usize) -> [Vec<f32>; 3] {
        let Some((i, t)) = self.playhead(now) else {
            return Default::default();
        };
        let frame = &self.frames[i];
        if chip >= frame.num_chips {
            return Default::default();
        }
        let end = frame.sample_start + (frame.sample_count as f64 * t) as u64;
        let oldest = self.written.saturating_sub(SAMPLE_RING as u64);
        let start = end
            .saturating_sub(count.min(MAX_SCOPE_SAMPLES) as u64)
            .max(oldest);
        std::array::from_fn(|voice| {
            let ring = self.ring(chip, voice);
            (start..end)
                .map(|n| ring[(n % SAMPLE_RING as u64) as usize])
                .collect()
        })
    }

    /// The frame being heard and how far through it (0–1). Past the newest
    /// frame — paused, or the player stalled — it holds on that frame's end.
    fn playhead(&self, now: Instant) -> Option<(usize, f64)> {
        let (at, anchor) = self.audible?;
        let first = self.frames.front()?;
        let last = self.frames.back()?;
        let since = if now >= at {
            (now - at).as_secs_f64()
        } else {
            -(at - now).as_secs_f64()
        };
        let lag = self.output_latency.as_secs_f64() + self.offset_ms as f64 / 1000.0;
        let pos = anchor.as_secs_f64() + since - lag;
        if pos < first.start.as_secs_f64() {
            return None;
        }
        let pos = Duration::from_secs_f64(pos).min(last.end);
        let i = self.frames.partition_point(|f| f.start <= pos) - 1;
        let frame = &self.frames[i];
        let length = frame.end.saturating_sub(frame.start).as_secs_f64();
        let t = if length > 0.0 {
            ((pos - frame.start).as_secs_f64() / length).min(1.0)
        } else {
            1.0
        };
        Some((i, t))
    }

    fn ring(&self, chip: usize, voice: usize) -> &[f32] {
        &self.samples[(chip * 3 + voice) * SAMPLE_RING..][..SAMPLE_RING]
    }

    // ── Write side, from the session thread ──

    fn clear(&mut self, sample_rate: f32) {
        self.frames.clear();
        self.written = 0;
        self.audible = None;
        self.stats = Stats::default();
        self.sample_rate = sample_rate;
    }

    /// Append a frame and its samples: one slice per chip and voice, in
    /// chip order, all the same length.
    fn push(&mut self, mut frame: Frame, samples: &[Vec<f32>], now: Instant, took: Duration) {
        let count = samples.first().map_or(0, Vec::len);
        frame.sample_start = self.written;
        frame.sample_count = count as u32;
        for (k, voice) in samples.iter().enumerate() {
            let ring = &mut self.samples[k * SAMPLE_RING..][..SAMPLE_RING];
            for (n, &s) in voice.iter().enumerate() {
                ring[((self.written + n as u64) % SAMPLE_RING as u64) as usize] = s;
            }
        }
        self.written += count as u64;

        if self.frames.len() == HISTORY_FRAMES {
            self.frames.pop_front();
        }
        self.frames.push_back(frame);
        self.schedule(&frame, now);

        let micros = took.as_secs_f32() * 1e6;
        self.stats.shadow_micros = if self.stats.frames == 0 {
            micros
        } else {
            self.stats.shadow_micros * 0.95 + micros * 0.05
        };
        self.stats.frames += 1;
    }

    /// When `frame` will leave the engine's buffer. The player sends a
    /// frame's status after pacing out the frame it just queued, so the
    /// samples went in one frame length before `now`.
    fn schedule(&mut self, frame: &Frame, now: Instant) {
        let queued = now
            .checked_sub(frame.end.saturating_sub(frame.start))
            .unwrap_or(now);
        let at = match self.audible {
            _ if frame.index == 0 => queued + TRACK_START_LAG,
            Some((at, pos)) => {
                let due = at + frame.start.saturating_sub(pos);
                // Landing after its turn means the buffer ran dry (a pause):
                // it plays as soon as it's queued.
                if queued > due + UNDERRUN_SLACK {
                    queued
                } else {
                    due
                }
            }
            None => queued,
        };
        self.audible = Some((at, frame.start));
    }
}

// ── Write side ───────────────────────────────────────────────────────────────

/// The session thread's half: a shadow reSID per chip, fed every status.
pub(crate) struct VizCapture {
    feed: SharedFeed,
    /// The (path, subtune) the shadows are emulating.
    track: Option<(PathBuf, u16)>,
    is_pal: bool,
    shadows: Vec<Shadow>,
    /// Emulated time at the end of the last frame; None before the first.
    elapsed: Option<Duration>,
    index: u64,
    /// Cycles since the last scope sample, carried across frames.
    phase: u32,
    /// The frame's samples per chip and voice, reused.
    scratch: Vec<Vec<f32>>,
}

impl VizCapture {
    pub fn new(feed: SharedFeed) -> Self {
        Self {
            feed,
            track: None,
            is_pal: true,
            shadows: Vec::new(),
            elapsed: None,
            index: 0,
            phase: 0,
            scratch: (0..MAX_CHIPS * 3)
                .map(|_| Vec::with_capacity(1024))
                .collect(),
        }
    }

    pub fn ingest(&mut self, status: &PlayerStatus, now: Instant) {
        match status.state {
            PlayState::Playing => {}
            // Hold the last frames so a paused visualizer stays put.
            PlayState::Paused => return,
            PlayState::Stopped => {
                if self.track.take().is_some() {
                    let rate = self.sample_rate();
                    lock(&self.feed).clear(rate);
                }
                return;
            }
        }
        let Some(info) = status.track_info.as_ref() else {
            return;
        };
        let rewound = self.elapsed.is_some_and(|e| status.elapsed < e);
        let same_track = self
            .track
            .as_ref()
            .is_some_and(|(path, song)| *path == info.path && *song == info.current_song);
        if rewound || !same_track {
            self.start(info);
        }

        // Upstream also sends statuses on commands and idle ticks; only one
        // whose elapsed time moved on carries a new frame.
        let start = self
            .elapsed
            .unwrap_or_else(|| status.elapsed.saturating_sub(self.nominal_frame()));
        if status.elapsed <= start {
            self.elapsed = Some(status.elapsed);
            return;
        }
        let clock = clock_hz(self.is_pal);
        let max_cycles = 3 * (self.nominal_frame().as_secs_f64() * clock) as u32;
        let cycles =
            (((status.elapsed - start).as_secs_f64() * clock).round() as u32).clamp(1, max_cycles);

        let began = Instant::now();
        let mut chips = [ChipState::default(); MAX_CHIPS];
        let mut phase = self.phase;
        for (c, shadow) in self.shadows.iter_mut().enumerate() {
            let Some(regs) = status
                .sid_regs
                .get(c * REGS_PER_CHIP..(c + 1) * REGS_PER_CHIP)
            else {
                break;
            };
            shadow.load(regs);
            let out = &mut self.scratch[c * 3..c * 3 + 3];
            out.iter_mut().for_each(Vec::clear);
            phase = shadow.run(cycles, self.phase, out);
            chips[c] = shadow.state(regs);
        }
        self.phase = phase;
        let took = began.elapsed();

        let frame = Frame {
            index: self.index,
            is_pal: self.is_pal,
            num_chips: self.shadows.len(),
            chips,
            start,
            end: status.elapsed,
            sample_start: 0,
            sample_count: 0,
        };
        self.index += 1;
        self.elapsed = Some(status.elapsed);
        let samples = &self.scratch[..self.shadows.len() * 3];
        lock(&self.feed).push(frame, samples, now, took);
    }

    fn start(&mut self, info: &TrackInfo) {
        self.track = Some((info.path.clone(), info.current_song));
        self.is_pal = info.is_pal;
        // Header flag: 2 is 8580; unknown and "both" play as a 6581.
        let model = if info.sid_model == 2 {
            ChipModel::Mos8580
        } else {
            ChipModel::Mos6581
        };
        let chips = info.num_sids.clamp(1, MAX_CHIPS);
        self.shadows = (0..chips).map(|_| Shadow::new(model)).collect();
        self.elapsed = None;
        self.index = 0;
        self.phase = 0;
        let rate = self.sample_rate();
        lock(&self.feed).clear(rate);
    }

    /// One video frame; CIA-timed tunes call their player more often, which
    /// the elapsed time between statuses already accounts for.
    fn nominal_frame(&self) -> Duration {
        let cycles = if self.is_pal { 19_656.0 } else { 17_095.0 };
        Duration::from_secs_f64(cycles / clock_hz(self.is_pal))
    }

    fn sample_rate(&self) -> f32 {
        (clock_hz(self.is_pal) / CYCLES_PER_SAMPLE as f64) as f32
    }
}

/// One visuals-only chip. Its filters are off: the scope wants each voice's
/// raw output, and skipping them saves most of the cost.
struct Shadow {
    synth: Synth,
    /// The registers last written to it.
    regs: [u8; REGS_PER_CHIP],
}

impl Shadow {
    fn new(model: ChipModel) -> Self {
        let mut synth = Synth::new(model);
        synth.filter.set_enabled(false);
        synth.ext_filter.set_enabled(false);
        Self {
            synth,
            regs: [0; REGS_PER_CHIP],
        }
    }

    /// Write the registers that changed, control registers last.
    fn load(&mut self, regs: &[u8]) {
        for control in [false, true] {
            for r in 0..WRITE_REGS {
                if CONTROL_REGS.contains(&r) == control && regs[r] != self.regs[r] {
                    self.synth.write(r as u8, regs[r]);
                    self.regs[r] = regs[r];
                }
            }
        }
    }

    /// Clock `cycles`, pushing a sample per voice every `CYCLES_PER_SAMPLE`
    /// cycles, counting from `phase`. Returns the new phase.
    fn run(&mut self, cycles: u32, mut phase: u32, out: &mut [Vec<f32>]) -> u32 {
        let waveforms = CONTROL_REGS.map(|r| self.regs[r] >> 4);
        let mut left = cycles;
        while left > 0 {
            let step = (CYCLES_PER_SAMPLE - phase).min(left);
            self.synth.clock_delta(step);
            phase += step;
            left -= step;
            if phase == CYCLES_PER_SAMPLE {
                phase = 0;
                for (voice, samples) in out.iter_mut().enumerate() {
                    samples.push(self.sample(voice, waveforms[voice]));
                }
            }
        }
        phase
    }

    /// Waveform × envelope, −1…1, without the chip's DC offsets.
    fn sample(&self, voice: usize, waveform: u8) -> f32 {
        if waveform == 0 {
            return 0.0;
        }
        let osc = self.synth.syncable_voice(voice).wave();
        let wave = osc.main.output(Some(osc.sync_source)) as f32 / 2047.5 - 1.0;
        wave * self.synth.voices[voice].envelope.output() as f32 / 255.0
    }

    fn state(&self, regs: &[u8]) -> ChipState {
        let mut state = ChipState {
            env: std::array::from_fn(|v| self.synth.voices[v].envelope.envelope_counter),
            env_state: std::array::from_fn(|v| match self.synth.voices[v].envelope.state {
                resid::envelope::State::Attack => EnvState::Attack,
                resid::envelope::State::DecaySustain => EnvState::DecaySustain,
                resid::envelope::State::Release => EnvState::Release,
            }),
            ..ChipState::default()
        };
        state.regs.copy_from_slice(&regs[..FRAME_REGS]);
        state.regs[OSC3] = self.synth.read(OSC3 as u8, 0);
        state.regs[ENV3] = self.synth.read(ENV3 as u8, 0);
        state
    }
}

#[cfg(test)]
mod tests;
