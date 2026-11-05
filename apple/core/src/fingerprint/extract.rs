//! A tune's sound fingerprint, from its SID register writes.
//!
//! `scan_tune` runs libsidplayfp's cycle-exact C64 with a capture-only SID
//! (no synthesis), so a subtune emulates far faster than real time. Each
//! video frame's cycle-stamped writes go to an `Extractor`, which keeps
//! every chip's registers and models each voice's envelope at frame rate
//! from the datasheet's ADSR times. That's coarse next to reSID's counters
//! but plenty for "how busy is this voice", and costs nothing.
//!
//! The extractor sees writes, not sound, so everything is about how the
//! player drives the chip: which waveforms sound, how often notes start,
//! how the pitch, pulse width and cutoff move, and how often `$D418` is hit.

use sidplayfp_sys::Player;

/// Time bins per voice lane, across the scanned stretch.
pub(crate) const BINS: usize = 128;
/// Chips the extractor follows (3SID is the most HVSC has).
pub(crate) const MAX_CHIPS: usize = 3;
const VOICES: usize = MAX_CHIPS * 3;

pub(crate) const PAL_CYCLES_PER_FRAME: u32 = 19_656;
pub(crate) const NTSC_CYCLES_PER_FRAME: u32 = 17_095;
const PAL_CLOCK: f64 = 985_248.0;
const NTSC_CLOCK: f64 = 1_022_727.0;

/// Attack times in seconds by the 4-bit rate (MOS 6581 datasheet); decay
/// and release take three times as long.
const ATTACK_SECS: [f32; 16] = [
    0.002, 0.008, 0.016, 0.024, 0.038, 0.056, 0.068, 0.080, 0.100, 0.250, 0.500, 0.800, 1.0, 3.0,
    5.0, 8.0,
];
/// Below this envelope level a voice counts as silent.
const AUDIBLE: f32 = 0.02;
/// `$D418` writes in one frame at or above this read as sample playback.
/// Ordinary players write it once or twice; even 8× multispeed stays under.
const DIGI_D418_PER_FRAME: u16 = 16;
/// Any single register hit this often in a frame reads as sample playback
/// too (pulse-width and test-bit digis).
const DIGI_REG_PER_FRAME: u16 = 32;

// Waveform bits in a control register.
const GATE: u8 = 0x01;
const SYNC: u8 = 0x02;
const RING: u8 = 0x04;
const TEST: u8 = 0x08;
const TRI: u8 = 0x10;
const SAW: u8 = 0x20;
const PUL: u8 = 0x40;
const NOI: u8 = 0x80;

/// Tag bits, in `Fingerprint::tags`.
pub(crate) mod tag {
    pub const ARPEGGIOS: u32 = 1 << 0;
    pub const FILTER_SWEEPS: u32 = 1 << 1;
    pub const NOISE_DRUMS: u32 = 1 << 2;
    pub const RING_MOD: u32 = 1 << 3;
    pub const SYNC_LEADS: u32 = 1 << 4;
    pub const DIGI: u32 = 1 << 5;
    pub const PULSE_BASS: u32 = 1 << 6;
    pub const VIBRATO: u32 = 1 << 7;
}

/// What a subtune sounds like, as numbers. Rates are per second of the
/// scanned stretch; fractions are of the frames (or voice-frames) where
/// something sounds.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Fingerprint {
    /// Seconds emulated.
    pub scanned_secs: f32,
    pub is_pal: bool,
    pub num_chips: u8,
    /// SID 1's three voices: mean envelope level per bin, 0–255.
    pub activity: [[u8; BINS]; 3],
    /// Share of the sounding voice-frames per waveform: triangle, saw,
    /// pulse, noise (weighted by level; combined waveforms split evenly).
    pub mix: [f32; 4],
    /// Gate-on edges per second, all voices.
    pub notes_per_sec: f32,
    /// Pitch jumps of a semitone or more within a held note, per second.
    pub arp_rate: f32,
    /// Direction reversals of small pitch moves within a note, per second.
    pub vibrato_rate: f32,
    /// Share of the sounding frames with a voice routed through the filter.
    pub filter_usage: f32,
    /// Cutoff while filtering: mean and spread (0–1 of the 11-bit range),
    /// and how far it moves per second.
    pub cutoff_mean: f32,
    pub cutoff_spread: f32,
    pub cutoff_motion: f32,
    /// Share of the sounding voice-frames with ring modulation (on a
    /// triangle) or hard sync on.
    pub ring: f32,
    pub sync: f32,
    /// `$D418` writes per second, and the share of frames that look like
    /// sample playback.
    pub d418_rate: f32,
    pub digi: f32,
    /// Mean pulse-width sweep per note on pulse voices, 0–1 of the 12-bit range.
    pub pwm_depth: f32,
    /// Noise hits (a voice turning to noise, or a noise note starting) per second.
    pub noise_hits: f32,
    /// Share of the sounding voice-frames that are pulse below C3.
    pub pulse_bass: f32,
    /// Mean MIDI note of the tonal sounding voice-frames, and its spread.
    pub pitch_mean: f32,
    pub pitch_spread: f32,
    /// Mean level of each SID 1 voice over the whole scan, 0–1.
    pub voice_level: [f32; 3],
    /// `tag` bits.
    pub tags: u32,
    /// What's measured for "Sounds like" alone, in `Extras::finish` order.
    pub extra: [f32; EXTRA],
}

impl Fingerprint {
    pub fn is_silent(&self) -> bool {
        self.voice_level.iter().all(|&l| l < 0.005) && self.digi < 0.05
    }

    /// The vector "Sounds like" compares, before standardising. Rates are
    /// log-compressed so a few busy tunes don't swamp the scale.
    pub fn features(&self) -> [f32; FEATURES] {
        let ln = |x: f32| (1.0 + x.max(0.0)).ln();
        let mut levels = self.voice_level;
        levels.sort_by(|a, b| b.total_cmp(a));
        let base = [
            self.mix[0],
            self.mix[1],
            self.mix[2],
            self.mix[3],
            ln(self.notes_per_sec),
            ln(self.arp_rate),
            ln(self.vibrato_rate),
            self.filter_usage,
            self.cutoff_mean,
            self.cutoff_spread,
            ln(self.cutoff_motion * 10.0),
            self.ring,
            self.sync,
            self.digi,
            self.pwm_depth,
            ln(self.noise_hits),
            self.pulse_bass,
            self.pitch_mean / 12.0,
            self.pitch_spread / 12.0,
            levels[0],
            levels[1],
            levels[2],
        ];
        std::array::from_fn(|k| if k < BASE_FEATURES { base[k] } else { self.extra[k - BASE_FEATURES] })
    }
}

const BASE_FEATURES: usize = 22;
/// Instrument shape, filter character, chip and how notes move; see `Extras`.
pub(crate) const EXTRA: usize = 19;
pub(crate) const FEATURES: usize = BASE_FEATURES + EXTRA;

/// Traits the app draws, in `Fingerprint::traits` order.
pub(crate) const TRAITS: usize = 9;

impl Fingerprint {
    /// Nine traits on 0–1 for the glyphs: notes, arpeggios, vibrato,
    /// filter, ring, sync, digi, noise, pulse-width modulation. Each scale
    /// tops out around where HVSC's busiest tunes sit, so most tunes use
    /// the range and only outliers clip.
    pub fn traits(&self) -> [f32; TRAITS] {
        [
            self.notes_per_sec / 18.0,
            self.arp_rate / 50.0,
            self.vibrato_rate / 12.0,
            self.filter_usage,
            self.ring * 6.0,
            self.sync * 2.5,
            self.digi * 3.0,
            self.noise_hits / 12.0,
            self.pwm_depth * 3.0,
        ]
        .map(|x| x.clamp(0.0, 1.0))
    }
}

// ── Extras ───────────────────────────────────────────────────────────────────

/// A running mean and spread.
#[derive(Default)]
struct Running {
    n: f64,
    sum: f64,
    squares: f64,
}

impl Running {
    fn push(&mut self, x: f64) {
        self.n += 1.0;
        self.sum += x;
        self.squares += x * x;
    }

    fn mean(&self) -> f64 {
        if self.n > 0.0 {
            self.sum / self.n
        } else {
            0.0
        }
    }

    fn std(&self) -> f64 {
        if self.n > 1.0 {
            (self.squares / self.n - self.mean().powi(2)).max(0.0).sqrt()
        } else {
            0.0
        }
    }
}

const NOTE_TIME_BINS: usize = 8;

/// The measurements that made "Sounds like" better in the benchmark
/// (`design/similarity`), chiefly the voices' envelope settings at note start.
#[derive(Default)]
struct Extras {
    attack: Running,
    decay: Running,
    sustain: Running,
    release: Running,
    filter_frames: f64,
    filter_modes: [f64; 3],
    resonance: Running,
    sounding: f64,
    combined: f64,
    notes_in_bin: [f64; NOTE_TIME_BINS],
    last_note: [Option<u32>; VOICES],
    last_midi: [Option<f64>; VOICES],
    gaps: Running,
    intervals: [f64; 4],
}

impl Extras {
    /// One frame, after its writes: the registers now, and the voices whose
    /// gate came on during it.
    fn frame(
        &mut self,
        regs: &[[u8; 32]; MAX_CHIPS],
        chips: usize,
        started: &[bool; VOICES],
        frame: u32,
        frames: u32,
        clock: f64,
    ) {
        for (chip, r) in regs.iter().enumerate().take(chips) {
            if r[0x17] & 0x0F != 0 {
                self.filter_frames += 1.0;
                for (k, mode) in self.filter_modes.iter_mut().enumerate() {
                    *mode += ((r[0x18] >> (4 + k)) & 1) as f64;
                }
                self.resonance.push((r[0x17] >> 4) as f64 / 15.0);
            }
            for v in 0..3 {
                let base = v * 7;
                let id = chip * 3 + v;
                let waves = r[base + 4] >> 4;
                if r[base + 4] & 1 == 1 && waves != 0 {
                    self.sounding += 1.0;
                    self.combined += (waves.count_ones() > 1) as u8 as f64;
                }
                if !started[id] {
                    continue;
                }
                self.attack.push((r[base + 5] >> 4) as f64 / 15.0);
                self.decay.push((r[base + 5] & 15) as f64 / 15.0);
                self.sustain.push((r[base + 6] >> 4) as f64 / 15.0);
                self.release.push((r[base + 6] & 15) as f64 / 15.0);
                let bin = (frame as usize * NOTE_TIME_BINS / frames.max(1) as usize).min(NOTE_TIME_BINS - 1);
                self.notes_in_bin[bin] += 1.0;
                if let Some(last) = self.last_note[id] {
                    self.gaps.push((1.0 + (frame - last) as f64).ln());
                }
                self.last_note[id] = Some(frame);
                let freq = u16::from_le_bytes([r[base], r[base + 1]]) as f64 * clock / 16_777_216.0;
                if freq > 8.0 && waves & 8 == 0 {
                    let midi = 69.0 + 12.0 * (freq / 440.0).log2();
                    if let Some(last) = self.last_midi[id] {
                        let step = (midi - last).abs();
                        let bin = match step {
                            s if s < 0.5 => 0,
                            s if s < 2.5 => 1,
                            s if s < 7.5 => 2,
                            _ => 3,
                        };
                        self.intervals[bin] += 1.0;
                    }
                    self.last_midi[id] = Some(midi);
                }
            }
        }
    }

    fn finish(&self, chips: usize, is_8580: bool) -> [f32; EXTRA] {
        let filter_total = self.filter_frames.max(1.0);
        let bin_mean = self.notes_in_bin.iter().sum::<f64>() / NOTE_TIME_BINS as f64;
        let bin_spread = (self.notes_in_bin.iter().map(|n| (n - bin_mean).powi(2)).sum::<f64>()
            / NOTE_TIME_BINS as f64)
            .sqrt();
        let interval_total = self.intervals.iter().sum::<f64>().max(1.0);
        [
            self.attack.mean(),
            self.decay.mean(),
            self.sustain.mean(),
            self.release.mean(),
            self.attack.std(),
            self.release.std(),
            self.filter_modes[0] / filter_total,
            self.filter_modes[1] / filter_total,
            self.filter_modes[2] / filter_total,
            self.resonance.mean(),
            is_8580 as u8 as f64,
            chips as f64,
            self.combined / self.sounding.max(1.0),
            if bin_mean > 0.0 { bin_spread / bin_mean } else { 0.0 },
            self.gaps.std(),
            self.intervals[0] / interval_total,
            self.intervals[1] / interval_total,
            self.intervals[2] / interval_total,
            self.intervals[3] / interval_total,
        ]
        .map(|x| x as f32)
    }
}

// ── Extractor ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Attack,
    Decay,
    Release,
}

#[derive(Clone, Copy)]
struct Voice {
    phase: Phase,
    level: f32,
    /// Gate rose since the last frame ended (a hard restart counts).
    rose: bool,
    /// Last frame's tonal pitch, if it sounded.
    prev_midi: Option<f32>,
    /// Direction of the last small pitch move: −1, 0, +1.
    last_dir: i8,
    was_noise: bool,
    /// The current note's pulse-width range while it sounds as pulse.
    pw_min: u16,
    pw_max: u16,
    pw_frames: u32,
}

impl Default for Voice {
    fn default() -> Self {
        Self {
            phase: Phase::Release,
            level: 0.0,
            rose: false,
            prev_midi: None,
            last_dir: 0,
            was_noise: false,
            pw_min: u16::MAX,
            pw_max: 0,
            pw_frames: 0,
        }
    }
}

/// Running mean and variance (Welford).
#[derive(Default, Clone, Copy)]
struct Stat {
    n: f64,
    mean: f64,
    m2: f64,
}

impl Stat {
    fn push(&mut self, x: f64) {
        self.n += 1.0;
        let d = x - self.mean;
        self.mean += d / self.n;
        self.m2 += d * (x - self.mean);
    }

    fn std(&self) -> f64 {
        if self.n > 1.0 {
            (self.m2 / self.n).sqrt()
        } else {
            0.0
        }
    }
}

/// Folds frames of SID writes into a `Fingerprint`.
pub(crate) struct Extractor {
    is_pal: bool,
    num_chips: usize,
    frame_secs: f32,
    /// Frames the scan will feed, for binning.
    expected_frames: u32,
    regs: [[u8; 32]; MAX_CHIPS],
    voices: [Voice; VOICES],
    frames: u32,
    // Bins.
    bin_sum: [[f32; BINS]; 3],
    bin_count: [u32; BINS],
    level_sum: [f64; 3],
    // Voice-frame counters.
    sounding_frames: u32,
    voice_frames: f64,
    mix: [f64; 4],
    ring: f64,
    sync: f64,
    pulse_bass: f64,
    pitch: Stat,
    notes: u32,
    arp_jumps: u32,
    vibrato_turns: u32,
    noise_hits: u32,
    // Filter.
    filtered_frames: u32,
    cutoff: Stat,
    cutoff_motion: f64,
    cutoff_moves: u32,
    prev_cutoff: [Option<u16>; MAX_CHIPS],
    // Digis.
    d418_writes: u64,
    digi_frames: u32,
    // Pulse width.
    pwm_sum: f64,
    pwm_notes: u32,
    extras: Extras,
    is_8580: bool,
}

impl Extractor {
    pub fn new(is_pal: bool, num_chips: usize, expected_frames: u32) -> Self {
        let fps = if is_pal {
            PAL_CLOCK / PAL_CYCLES_PER_FRAME as f64
        } else {
            NTSC_CLOCK / NTSC_CYCLES_PER_FRAME as f64
        };
        Self {
            is_pal,
            num_chips: num_chips.clamp(1, MAX_CHIPS),
            frame_secs: (1.0 / fps) as f32,
            expected_frames: expected_frames.max(1),
            regs: [[0; 32]; MAX_CHIPS],
            voices: [Voice::default(); VOICES],
            frames: 0,
            bin_sum: [[0.0; BINS]; 3],
            bin_count: [0; BINS],
            level_sum: [0.0; 3],
            sounding_frames: 0,
            voice_frames: 0.0,
            mix: [0.0; 4],
            ring: 0.0,
            sync: 0.0,
            pulse_bass: 0.0,
            pitch: Stat::default(),
            notes: 0,
            arp_jumps: 0,
            vibrato_turns: 0,
            noise_hits: 0,
            filtered_frames: 0,
            cutoff: Stat::default(),
            cutoff_motion: 0.0,
            cutoff_moves: 0,
            prev_cutoff: [None; MAX_CHIPS],
            d418_writes: 0,
            digi_frames: 0,
            pwm_sum: 0.0,
            pwm_notes: 0,
            extras: Extras::default(),
            is_8580: false,
        }
    }

    /// Whether the tune's header asks for an 8580.
    pub fn set_8580(&mut self, is_8580: bool) {
        self.is_8580 = is_8580;
    }

    /// One video frame's writes, in order: `(cycle, chip * 0x20 + reg, value)`.
    pub fn frame(&mut self, writes: &[(u32, u8, u8)]) {
        let mut hits = [[0u16; 32]; MAX_CHIPS];
        let mut started = [false; VOICES];
        for &(_, mapped, value) in writes {
            let chip = (mapped >> 5) as usize;
            let reg = (mapped & 0x1F) as usize;
            if chip >= self.num_chips {
                continue;
            }
            hits[chip][reg] = hits[chip][reg].saturating_add(1);
            if let Some(v) = (reg < 0x15 && reg % 7 == 4).then_some(reg / 7) {
                started[chip * 3 + v] |= self.regs[chip][reg] & 1 == 0 && value & 1 == 1;
                self.control(chip * 3 + v, self.regs[chip][reg], value);
            }
            self.regs[chip][reg] = value;
        }

        // Digis.
        let mut digi = false;
        for chip in &hits[..self.num_chips] {
            self.d418_writes += chip[0x18] as u64;
            digi |= chip[0x18] >= DIGI_D418_PER_FRAME;
            digi |= chip[..0x19].iter().any(|&n| n >= DIGI_REG_PER_FRAME);
        }
        self.digi_frames += digi as u32;

        let clock = if self.is_pal { PAL_CLOCK } else { NTSC_CLOCK };
        self.extras.frame(&self.regs, self.num_chips, &started, self.frames, self.expected_frames, clock);
        self.advance_envelopes();
        self.measure();
        self.frames += 1;
    }

    /// A control register write: gate edges drive the envelope.
    fn control(&mut self, v: usize, old: u8, new: u8) {
        let voice = &mut self.voices[v];
        if old & GATE == 0 && new & GATE != 0 {
            voice.phase = Phase::Attack;
            voice.rose = true;
        } else if old & GATE != 0 && new & GATE == 0 {
            voice.phase = Phase::Release;
        }
    }

    fn advance_envelopes(&mut self) {
        let dt = self.frame_secs;
        for v in 0..self.num_chips * 3 {
            let r = &self.regs[v / 3][(v % 3) * 7..];
            let (attack, decay) = (r[5] >> 4, r[5] & 0x0F);
            let (sustain, release) = ((r[6] >> 4) as f32 / 15.0, r[6] & 0x0F);
            let voice = &mut self.voices[v];
            match voice.phase {
                Phase::Attack => {
                    voice.level += dt / ATTACK_SECS[attack as usize];
                    if voice.level >= 1.0 {
                        voice.level = 1.0;
                        voice.phase = Phase::Decay;
                    }
                }
                Phase::Decay => {
                    if voice.level > sustain {
                        voice.level =
                            (voice.level - dt / (3.0 * ATTACK_SECS[decay as usize])).max(sustain);
                    }
                }
                Phase::Release => {
                    voice.level =
                        (voice.level - dt / (3.0 * ATTACK_SECS[release as usize])).max(0.0);
                }
            }
        }
    }

    fn measure(&mut self) {
        let clock = if self.is_pal { PAL_CLOCK } else { NTSC_CLOCK };
        let bin = (self.frames as u64 * BINS as u64 / self.expected_frames as u64)
            .min(BINS as u64 - 1) as usize;
        self.bin_count[bin] += 1;
        let mut any_sounding = false;

        for chip in 0..self.num_chips {
            let regs = self.regs[chip];
            let mode_vol = regs[0x18];
            let volume = mode_vol & 0x0F;
            let routing = regs[0x17] & 0x07;
            let filter_mode = mode_vol & 0x70;
            let mut filtering = false;

            for i in 0..3 {
                let v = chip * 3 + i;
                let r = &regs[i * 7..i * 7 + 7];
                let ctrl = r[4];
                let freq = u16::from_le_bytes([r[0], r[1]]);
                let pw = u16::from_le_bytes([r[2], r[3] & 0x0F]);
                let wave = ctrl & 0xF0;
                let voice3_off = i == 2 && mode_vol & 0x80 != 0 && routing & 0x04 == 0;
                let level = self.voices[v].level;
                let sounds = level >= AUDIBLE
                    && wave != 0
                    && ctrl & TEST == 0
                    && volume != 0
                    && !voice3_off;
                let level = if sounds { level } else { 0.0 };
                if chip == 0 {
                    self.bin_sum[i][bin] += level;
                    self.level_sum[i] += level as f64;
                }

                let voice = &mut self.voices[v];
                let rose = std::mem::take(&mut voice.rose);
                if rose {
                    self.notes += 1;
                    // A new note closes the last one's pulse-width window.
                    if voice.pw_frames >= 3 {
                        self.pwm_sum += (voice.pw_max - voice.pw_min) as f64 / 4095.0;
                        self.pwm_notes += 1;
                    }
                    voice.pw_min = u16::MAX;
                    voice.pw_max = 0;
                    voice.pw_frames = 0;
                }
                if !sounds {
                    voice.prev_midi = None;
                    voice.was_noise = false;
                    continue;
                }
                any_sounding = true;
                filtering |= routing & (1 << i) != 0 && filter_mode != 0;

                let lw = level as f64;
                self.voice_frames += lw;
                let bits = [TRI, SAW, PUL, NOI];
                let n = bits.iter().filter(|&&b| wave & b != 0).count() as f64;
                for (k, &b) in bits.iter().enumerate() {
                    if wave & b != 0 {
                        self.mix[k] += lw / n;
                    }
                }
                if ctrl & RING != 0 && wave & TRI != 0 {
                    self.ring += lw;
                }
                if ctrl & SYNC != 0 {
                    self.sync += lw;
                }

                let noise = wave & NOI != 0;
                if noise && (rose || !voice.was_noise) {
                    self.noise_hits += 1;
                }
                voice.was_noise = noise;

                if wave & PUL != 0 {
                    voice.pw_min = voice.pw_min.min(pw);
                    voice.pw_max = voice.pw_max.max(pw);
                    voice.pw_frames += 1;
                }

                if noise || freq == 0 {
                    voice.prev_midi = None;
                    continue;
                }
                let hz = freq as f64 * clock / 16_777_216.0;
                let midi = (69.0 + 12.0 * (hz / 440.0).log2()) as f32;
                self.pitch.push(midi as f64);
                if wave & PUL != 0 && midi < 48.0 {
                    self.pulse_bass += lw;
                }
                if let (Some(prev), false) = (voice.prev_midi, rose) {
                    let d = midi - prev;
                    if (0.9..=24.0).contains(&d.abs()) {
                        self.arp_jumps += 1;
                    } else if (0.02..0.9).contains(&d.abs()) {
                        let dir = d.signum() as i8;
                        if voice.last_dir != 0 && dir != voice.last_dir {
                            self.vibrato_turns += 1;
                        }
                        voice.last_dir = dir;
                    }
                }
                if rose {
                    voice.last_dir = 0;
                }
                voice.prev_midi = Some(midi);
            }

            if filtering {
                let cutoff = (regs[0x15] & 0x07) as u16 | (regs[0x16] as u16) << 3;
                self.cutoff.push(cutoff as f64 / 2047.0);
                if let Some(prev) = self.prev_cutoff[chip] {
                    self.cutoff_motion += (cutoff as f64 - prev as f64).abs() / 2047.0;
                    self.cutoff_moves += 1;
                }
                self.prev_cutoff[chip] = Some(cutoff);
            } else {
                self.prev_cutoff[chip] = None;
            }
            if filtering && chip == 0 {
                self.filtered_frames += 1;
            }
        }
        self.sounding_frames += any_sounding as u32;
    }

    #[cfg(test)]
    pub fn level(&self, voice: usize) -> f32 {
        self.voices[voice].level
    }

    pub fn finish(mut self) -> Fingerprint {
        // Close the notes still sounding.
        for voice in &self.voices {
            if voice.pw_frames >= 3 {
                self.pwm_sum += (voice.pw_max - voice.pw_min) as f64 / 4095.0;
                self.pwm_notes += 1;
            }
        }
        let secs = (self.frames as f32 * self.frame_secs).max(self.frame_secs);
        let per_sec = |n: u32| n as f32 / secs;
        let share = |x: f64| {
            if self.voice_frames > 0.0 {
                (x / self.voice_frames) as f32
            } else {
                0.0
            }
        };

        let mut activity = [[0u8; BINS]; 3];
        for (lane, sums) in activity.iter_mut().zip(&self.bin_sum) {
            for (b, cell) in lane.iter_mut().enumerate() {
                let n = self.bin_count[b];
                if n > 0 {
                    *cell = (sums[b] / n as f32 * 255.0).round().clamp(0.0, 255.0) as u8;
                }
            }
        }
        let frames = self.frames.max(1) as f64;
        let voice_level = std::array::from_fn(|i| (self.level_sum[i] / frames) as f32);

        let mut fp = Fingerprint {
            scanned_secs: self.frames as f32 * self.frame_secs,
            is_pal: self.is_pal,
            num_chips: self.num_chips as u8,
            activity,
            mix: std::array::from_fn(|k| share(self.mix[k])),
            notes_per_sec: per_sec(self.notes),
            arp_rate: per_sec(self.arp_jumps),
            vibrato_rate: per_sec(self.vibrato_turns),
            filter_usage: if self.sounding_frames > 0 {
                (self.filtered_frames as f32 / self.sounding_frames as f32).min(1.0)
            } else {
                0.0
            },
            cutoff_mean: self.cutoff.mean as f32,
            cutoff_spread: self.cutoff.std() as f32,
            cutoff_motion: if self.cutoff_moves > 0 {
                (self.cutoff_motion / self.cutoff_moves as f64) as f32 / self.frame_secs
            } else {
                0.0
            },
            ring: share(self.ring),
            sync: share(self.sync),
            d418_rate: self.d418_writes as f32 / secs,
            digi: self.digi_frames as f32 / frames as f32,
            pwm_depth: if self.pwm_notes > 0 {
                (self.pwm_sum / self.pwm_notes as f64) as f32
            } else {
                0.0
            },
            noise_hits: per_sec(self.noise_hits),
            pulse_bass: share(self.pulse_bass),
            pitch_mean: self.pitch.mean as f32,
            pitch_spread: self.pitch.std() as f32,
            voice_level,
            tags: 0,
            extra: self.extras.finish(self.num_chips, self.is_8580),
        };
        fp.tags = tags(&fp);
        fp
    }
}

/// Which chips the tags name. Thresholds sit where the HVSC distribution
/// separates tunes that clearly do the thing from those that touch it in
/// passing (see `examples/fingerprint.rs --stats`).
pub(crate) fn tags(fp: &Fingerprint) -> u32 {
    let mut t = 0;
    if fp.arp_rate >= 6.0 {
        t |= tag::ARPEGGIOS;
    }
    if fp.filter_usage >= 0.25 && fp.cutoff_motion >= 0.05 {
        t |= tag::FILTER_SWEEPS;
    }
    if fp.noise_hits >= 1.0 && fp.mix[3] >= 0.03 {
        t |= tag::NOISE_DRUMS;
    }
    if fp.ring >= 0.05 {
        t |= tag::RING_MOD;
    }
    if fp.sync >= 0.05 {
        t |= tag::SYNC_LEADS;
    }
    if fp.digi >= 0.1 {
        t |= tag::DIGI;
    }
    if fp.pulse_bass >= 0.15 {
        t |= tag::PULSE_BASS;
    }
    if fp.vibrato_rate >= 3.0 {
        t |= tag::VIBRATO;
    }
    t
}

// ── Emulation ────────────────────────────────────────────────────────────────

fn header_asks_for_8580(data: &[u8]) -> bool {
    let word = |at: usize| data.get(at..at + 2).map(|b| u16::from_be_bytes([b[0], b[1]]));
    word(4).is_some_and(|version| version >= 2) && word(0x76).is_some_and(|flags| (flags >> 4) & 3 == 2)
}

/// Emulate `subtune` (1-based) of a SID file for `secs` and fingerprint it.
/// `cancelled` is polled every few seconds of emulated time; Ok(None) when
/// it stopped the scan.
pub(crate) fn scan_tune(
    data: &[u8],
    subtune: u16,
    secs: f32,
    cancelled: &dyn Fn() -> bool,
) -> Result<Option<Fingerprint>, String> {
    let mut player = Player::new()?;
    // No ROMs: libsidplayfp's built-in stubs cover PSIDs and most RSIDs.
    player.set_roms(None, None, None);
    player.load(data, subtune)?;
    let is_pal = player.is_pal();
    let cycles = if is_pal {
        PAL_CYCLES_PER_FRAME
    } else {
        NTSC_CYCLES_PER_FRAME
    };
    let clock = if is_pal { PAL_CLOCK } else { NTSC_CLOCK };
    let frames = (secs as f64 * clock / cycles as f64).ceil().max(1.0) as u32;
    let mut extractor = Extractor::new(is_pal, player.num_sids(), frames);
    extractor.set_8580(header_asks_for_8580(data));
    let mut writes = Vec::with_capacity(256);
    for frame in 0..frames {
        if frame % 256 == 0 && cancelled() {
            return Ok(None);
        }
        player.play(cycles)?;
        writes.clear();
        writes.extend(
            player
                .get_writes()
                .iter()
                .map(|w| (w.cycle, w.sid_num * 0x20 + (w.reg & 0x1F), w.val)),
        );
        extractor.frame(&writes);
    }
    Ok(Some(extractor.finish()))
}
