//! libsidplayfp with libresidfp (reSIDfp) as a pull-driven SID player.
//!
//! [`Player`] loads a tune, starts a song and renders stereo audio on
//! demand, so an audio output callback can drive the emulation directly.
//! For the visualizers it reports each chip's registers, envelopes and
//! waveform samples, and the register writes with cycle stamps.
//!
//! The C++ sources (libsidplayfp 3.1.2, libresidfp 1.2.3) are vendored in
//! `csrc/`; see README.md.

#![allow(non_camel_case_types)]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_uint};
use std::path::Path;

// ── Raw FFI ──────────────────────────────────────────────────────────────────

mod raw {
    use std::os::raw::{c_char, c_int, c_uint};

    #[repr(C)]
    pub struct rsfp_player {
        _opaque: [u8; 0],
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct rsfp_config {
        pub sample_rate: u32,
        pub sampling: u8,
        pub default_clock: u8,
        pub force_clock: u8,
        pub default_model: u8,
        pub force_model: u8,
        pub digi_boost: u8,
        pub mono_2sid: u8,
        pub scope_cycles: u8,
        pub chip: u8,
        pub power_on_delay: u16,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct rsfp_tune_info {
        pub songs: u16,
        pub start_song: u16,
        pub current_song: u16,
        pub chips: u8,
        pub clock: u8,
        pub model: [u8; 3],
        pub compatibility: u8,
        pub speed_cia: u8,
        pub chip_base: [u16; 3],
        pub load_addr: u16,
        pub init_addr: u16,
        pub play_addr: u16,
        pub data_len: u32,
        pub info_strings: u8,
        pub comment_strings: u8,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct rsfp_play_info {
        pub song: u16,
        pub is_pal: u8,
        pub chips: u8,
        pub model: [u8; 3],
        pub cia1_timer_a: u16,
        pub cpu_hz: f64,
        pub power_on_delay: u16,
    }

    extern "C" {
        pub fn rsfp_new() -> *mut rsfp_player;
        pub fn rsfp_free(p: *mut rsfp_player);
        pub fn rsfp_error(p: *const rsfp_player) -> *const c_char;
        pub fn rsfp_version() -> *const c_char;
        pub fn rsfp_set_roms(
            p: *mut rsfp_player,
            kernal: *const u8,
            basic: *const u8,
            chargen: *const u8,
        );
        pub fn rsfp_load_bytes(p: *mut rsfp_player, data: *const u8, len: u32) -> c_int;
        pub fn rsfp_load_path(p: *mut rsfp_player, path: *const c_char) -> c_int;
        pub fn rsfp_tune_info(p: *const rsfp_player, out: *mut rsfp_tune_info) -> c_int;
        pub fn rsfp_info_string(p: *const rsfp_player, i: c_uint) -> *const c_char;
        pub fn rsfp_comment_string(p: *const rsfp_player, i: c_uint) -> *const c_char;
        pub fn rsfp_format_string(p: *const rsfp_player) -> *const c_char;
        pub fn rsfp_md5(p: *const rsfp_player, out: *mut c_char) -> c_int;
        pub fn rsfp_start(
            p: *mut rsfp_player,
            song: c_uint,
            cfg: *const rsfp_config,
            out: *mut rsfp_play_info,
        ) -> c_int;
        pub fn rsfp_render(p: *mut rsfp_player, stereo: *mut i16, frames: u32) -> u32;
        pub fn rsfp_cycles(p: *const rsfp_player) -> u64;
        pub fn rsfp_chips(p: *const rsfp_player) -> c_uint;
        pub fn rsfp_chip_state(
            p: *const rsfp_player,
            chip: c_uint,
            out: *mut super::ChipState,
        ) -> c_int;
        pub fn rsfp_take_scope(p: *mut rsfp_player, chip: c_uint, out: *mut f32, cap: u32) -> u32;
        pub fn rsfp_take_writes(
            p: *mut rsfp_player,
            chip: c_uint,
            out: *mut super::Write,
            cap: u32,
            total: *mut u32,
        ) -> u32;
        pub fn rsfp_mute(p: *mut rsfp_player, chip: c_uint, voice: c_uint, mute: c_int);
        pub fn rsfp_filter(p: *mut rsfp_player, chip: c_uint, enable: c_int);
        pub fn rsfp_skip(p: *mut rsfp_player, cycles: u64, mode: c_int) -> u64;
    }
}

// ── Public types ─────────────────────────────────────────────────────────────

/// Which chip emulation plays.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Chip {
    /// libresidfp: the accurate one.
    #[default]
    ReSidFp,
    /// libsidplayfp's SIDLite (cRSID-based): far cheaper, output rates up
    /// to 48 kHz, its resampler fixed.
    SidLite,
}

/// reSIDfp's resamplers, by SidConfig's names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SamplingMethod {
    /// Zero-order resampling: cheap, libsidplayfp's default.
    #[default]
    Interpolate,
    /// Two-pass sinc resampling: the accurate one, several times the cost.
    Resample,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Clock {
    #[default]
    Pal,
    Ntsc,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ChipModel {
    #[default]
    Mos6581,
    Mos8580,
}

/// How to run a song.
#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    /// 8000–192000.
    pub sample_rate: u32,
    pub sampling: SamplingMethod,
    /// Used when the tune's header doesn't say, or always when forced.
    pub default_clock: Clock,
    pub force_clock: bool,
    /// Used when the tune's header doesn't say, or always when forced.
    pub default_model: ChipModel,
    pub force_model: bool,
    /// 8580 digi boost.
    pub digi_boost: bool,
    /// Mix a 2SID tune to both channels instead of left and right.
    pub mono_2sid: bool,
    /// C64 cycles per visualizer scope sample; 0 keeps no scope.
    pub scope_cycles: u8,
    pub chip: Chip,
    /// C64 cycles between power-on and the tune's init, 0–8191; `None`
    /// lets libsidplayfp pick one at random, as it does on its own. Two
    /// instances of a tune line up only with the same delay.
    pub power_on_delay: Option<u16>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            sample_rate: 48_000,
            sampling: SamplingMethod::Interpolate,
            default_clock: Clock::Pal,
            force_clock: false,
            default_model: ChipModel::Mos6581,
            force_model: false,
            digi_boost: false,
            mono_2sid: false,
            scope_cycles: 0,
            chip: Chip::ReSidFp,
            power_on_delay: None,
        }
    }
}

/// What a tune's header says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Compatibility {
    C64,
    Psid,
    /// Real C64 only (RSID).
    R64,
    /// Needs the BASIC ROM.
    Basic,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TuneInfo {
    pub songs: u16,
    pub start_song: u16,
    /// The selected song, 1-based.
    pub current_song: u16,
    /// SIDs the tune uses, 1–3.
    pub chips: usize,
    /// Header flag: 0 unknown, 1 PAL, 2 NTSC, 3 either.
    pub clock: u8,
    /// Header flag per chip: 0 unknown, 1 6581, 2 8580, 3 either.
    pub models: [u8; 3],
    pub compatibility: Compatibility,
    /// The song runs off CIA timer A rather than the VBI.
    pub speed_cia: bool,
    /// `$D400` and the extra chips' addresses.
    pub chip_bases: [u16; 3],
    pub load_addr: u16,
    pub init_addr: u16,
    pub play_addr: u16,
    pub data_len: u32,
    pub title: String,
    pub author: String,
    pub released: String,
    /// MUS credit lines.
    pub comments: Vec<String>,
    /// "PlaySID one-file format (PSID)", "Real C64 one-file format (RSID)", …
    pub format: String,
}

impl TuneInfo {
    pub fn is_rsid(&self) -> bool {
        matches!(
            self.compatibility,
            Compatibility::R64 | Compatibility::Basic
        ) || self.format.contains("RSID")
    }
}

/// What the engine chose when a song started.
#[derive(Debug, Clone, PartialEq)]
pub struct Started {
    /// 1-based.
    pub song: u16,
    pub is_pal: bool,
    pub cpu_hz: f64,
    /// SIDs installed, 1–3.
    pub chips: usize,
    pub models: [ChipModel; 3],
    pub cia1_timer_a: u16,
    /// The power-on delay used (see [`Config::power_on_delay`]).
    pub power_on_delay: u16,
}

/// Where a voice's envelope generator is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnvPhase {
    Attack,
    DecaySustain,
    Release,
}

/// One chip, now.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ChipState {
    /// The last value written to each register.
    pub regs: [u8; 32],
    /// Envelope counters, 0–255.
    pub env: [u8; 3],
    /// 0 attack, 1 decay/sustain, 2 release; see [`ChipState::phase`].
    pub env_phase: [u8; 3],
    pub osc3: u8,
    pub env3: u8,
}

impl Default for ChipState {
    fn default() -> Self {
        Self {
            regs: [0; 32],
            env: [0; 3],
            env_phase: [2; 3],
            osc3: 0,
            env3: 0,
        }
    }
}

impl ChipState {
    pub fn phase(&self, voice: usize) -> EnvPhase {
        match self.env_phase[voice] {
            0 => EnvPhase::Attack,
            1 => EnvPhase::DecaySustain,
            _ => EnvPhase::Release,
        }
    }
}

/// A register write.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Write {
    /// C64 cycles since the song started.
    pub cycle: u32,
    pub reg: u8,
    pub val: u8,
}

pub fn version() -> &'static str {
    unsafe { CStr::from_ptr(raw::rsfp_version()) }
        .to_str()
        .unwrap_or("libsidplayfp")
}

/// How [`Player::skip`] clocks the chips.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkipMode {
    /// As when playing, with the audio dropped.
    Render,
    /// reSIDfp's oscillators and envelopes only, not its filter and
    /// resampler; SIDLite renders as `Render`.
    Digital,
    /// The chips aren't clocked at all: only the C64 runs.
    None,
}

// ── Player ───────────────────────────────────────────────────────────────────

/// One libsidplayfp instance with reSIDfp chips.
pub struct Player {
    ptr: *mut raw::rsfp_player,
    chips: usize,
}

// The C++ objects are only ever touched through this handle.
unsafe impl Send for Player {}

impl Player {
    pub fn new() -> Result<Self, String> {
        let ptr = unsafe { raw::rsfp_new() };
        if ptr.is_null() {
            return Err("could not create the libsidplayfp player".into());
        }
        Ok(Self { ptr, chips: 0 })
    }

    /// ROM images, or `None` for libsidplayfp's built-in stubs. Images of
    /// the wrong size are ignored. Call before loading a tune.
    pub fn set_roms(
        &mut self,
        kernal: Option<&[u8]>,
        basic: Option<&[u8]>,
        chargen: Option<&[u8]>,
    ) {
        let sized = |rom: Option<&[u8]>, len: usize| {
            rom.filter(|r| r.len() == len)
                .map_or(std::ptr::null(), |r| r.as_ptr())
        };
        unsafe {
            raw::rsfp_set_roms(
                self.ptr,
                sized(kernal, 8192),
                sized(basic, 8192),
                sized(chargen, 4096),
            );
        }
    }

    /// Load a PSID / RSID / MUS tune from memory.
    pub fn load_bytes(&mut self, data: &[u8]) -> Result<TuneInfo, String> {
        self.chips = 0;
        let len = u32::try_from(data.len()).map_err(|_| "tune too large".to_string())?;
        if unsafe { raw::rsfp_load_bytes(self.ptr, data.as_ptr(), len) } == 0 {
            return Err(self.error());
        }
        self.tune_info().ok_or_else(|| self.error())
    }

    /// Load a tune from a file; a MUS file's companion `.str` is found next
    /// to it.
    pub fn load_path(&mut self, path: &Path) -> Result<TuneInfo, String> {
        self.chips = 0;
        let path = path.to_str().ok_or("path is not UTF-8")?;
        let cpath = CString::new(path).map_err(|_| "path contains a NUL byte".to_string())?;
        if unsafe { raw::rsfp_load_path(self.ptr, cpath.as_ptr()) } == 0 {
            return Err(self.error());
        }
        self.tune_info().ok_or_else(|| self.error())
    }

    /// The loaded tune's header, for its selected song.
    pub fn tune_info(&self) -> Option<TuneInfo> {
        let mut info = raw::rsfp_tune_info::default();
        if unsafe { raw::rsfp_tune_info(self.ptr, &mut info) } == 0 {
            return None;
        }
        let string = |i: u32| unsafe { cstr(raw::rsfp_info_string(self.ptr, i)) };
        let comments = (0..u32::from(info.comment_strings))
            .map(|i| unsafe { cstr(raw::rsfp_comment_string(self.ptr, i)) })
            .collect();
        Some(TuneInfo {
            songs: info.songs,
            start_song: info.start_song,
            current_song: info.current_song,
            chips: info.chips.clamp(1, 3) as usize,
            clock: info.clock,
            models: info.model,
            compatibility: match info.compatibility {
                1 => Compatibility::Psid,
                2 => Compatibility::R64,
                3 => Compatibility::Basic,
                _ => Compatibility::C64,
            },
            speed_cia: info.speed_cia != 0,
            chip_bases: info.chip_base,
            load_addr: info.load_addr,
            init_addr: info.init_addr,
            play_addr: info.play_addr,
            data_len: info.data_len,
            title: string(0),
            author: string(1),
            released: string(2),
            comments,
            format: unsafe { cstr(raw::rsfp_format_string(self.ptr)) },
        })
    }

    /// The HVSC MD5 of the loaded tune (Songlengths.md5's key).
    pub fn md5(&self) -> Option<String> {
        let mut buf = [0 as c_char; 33];
        if unsafe { raw::rsfp_md5(self.ptr, buf.as_mut_ptr()) } == 0 {
            return None;
        }
        Some(unsafe { cstr(buf.as_ptr()) })
    }

    /// Select `song` (1-based; 0 = the tune's start song), configure the
    /// machine and run the tune's init. Rendering may begin afterwards.
    pub fn start(&mut self, song: u16, cfg: &Config) -> Result<Started, String> {
        let c = raw::rsfp_config {
            sample_rate: cfg.sample_rate,
            sampling: match cfg.sampling {
                SamplingMethod::Interpolate => 0,
                SamplingMethod::Resample => 1,
            },
            default_clock: match cfg.default_clock {
                Clock::Pal => 0,
                Clock::Ntsc => 1,
            },
            force_clock: cfg.force_clock as u8,
            default_model: match cfg.default_model {
                ChipModel::Mos6581 => 0,
                ChipModel::Mos8580 => 1,
            },
            force_model: cfg.force_model as u8,
            digi_boost: cfg.digi_boost as u8,
            mono_2sid: cfg.mono_2sid as u8,
            scope_cycles: cfg.scope_cycles,
            chip: match cfg.chip {
                Chip::ReSidFp => 0,
                Chip::SidLite => 1,
            },
            power_on_delay: cfg.power_on_delay.unwrap_or(u16::MAX),
        };
        let mut out = raw::rsfp_play_info::default();
        if unsafe { raw::rsfp_start(self.ptr, c_uint::from(song), &c, &mut out) } == 0 {
            self.chips = 0;
            return Err(self.error());
        }
        self.chips = out.chips as usize;
        let model = |m: u8| {
            if m == 1 {
                ChipModel::Mos8580
            } else {
                ChipModel::Mos6581
            }
        };
        Ok(Started {
            song: out.song,
            is_pal: out.is_pal != 0,
            cpu_hz: out.cpu_hz,
            chips: self.chips,
            models: out.model.map(model),
            cia1_timer_a: out.cia1_timer_a,
            power_on_delay: out.power_on_delay,
        })
    }

    /// Render interleaved stereo frames into `stereo` (an even length).
    /// Returns the frames rendered; fewer than asked means the emulation
    /// stopped (see [`Player::error`]) and the rest is silence.
    pub fn render(&mut self, stereo: &mut [i16]) -> usize {
        let frames = (stereo.len() / 2) as u32;
        unsafe { raw::rsfp_render(self.ptr, stereo.as_mut_ptr(), frames) as usize }
    }

    /// C64 cycles emulated since the song started.
    pub fn cycles(&self) -> u64 {
        unsafe { raw::rsfp_cycles(self.ptr) }
    }

    /// SIDs installed for the started song.
    pub fn chips(&self) -> usize {
        unsafe { raw::rsfp_chips(self.ptr) as usize }
    }

    pub fn chip_state(&self, chip: usize) -> Option<ChipState> {
        let mut state = ChipState::default();
        (unsafe { raw::rsfp_chip_state(self.ptr, chip as c_uint, &mut state) } != 0)
            .then_some(state)
    }

    /// Take the scope samples (waveform × envelope, −1…1) recorded since the
    /// last call. `out` holds three equal parts, one per voice; returns the
    /// count filled in each.
    pub fn take_scope(&mut self, chip: usize, out: &mut [f32]) -> usize {
        let cap = (out.len() / 3) as u32;
        unsafe { raw::rsfp_take_scope(self.ptr, chip as c_uint, out.as_mut_ptr(), cap) as usize }
    }

    /// Take the register writes since the last call, as many as fit in
    /// `out`. Returns (copied, happened).
    pub fn take_writes(&mut self, chip: usize, out: &mut [Write]) -> (usize, u32) {
        let mut total = 0u32;
        let copied = unsafe {
            raw::rsfp_take_writes(
                self.ptr,
                chip as c_uint,
                out.as_mut_ptr(),
                out.len() as u32,
                &mut total,
            )
        };
        (copied as usize, total)
    }

    pub fn mute(&mut self, chip: usize, voice: usize, mute: bool) {
        unsafe { raw::rsfp_mute(self.ptr, chip as c_uint, voice as c_uint, mute as c_int) }
    }

    pub fn filter(&mut self, chip: usize, enable: bool) {
        unsafe { raw::rsfp_filter(self.ptr, chip as c_uint, enable as c_int) }
    }

    /// Run `cycles` C64 cycles ahead without producing audio. Returns the
    /// cycles run: `cycles` or a few more, or fewer when the emulation
    /// stopped (see [`Player::error`]).
    pub fn skip(&mut self, cycles: u64, mode: SkipMode) -> u64 {
        let m = match mode {
            SkipMode::Render => 0,
            SkipMode::Digital => 1,
            SkipMode::None => 2,
        };
        unsafe { raw::rsfp_skip(self.ptr, cycles, m) }
    }

    pub fn error(&self) -> String {
        unsafe { cstr(raw::rsfp_error(self.ptr)) }
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        unsafe { raw::rsfp_free(self.ptr) }
    }
}

unsafe fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        String::new()
    } else {
        CStr::from_ptr(p).to_string_lossy().into_owned()
    }
}

// ── Test tunes ───────────────────────────────────────────────────────────────

/// Tiny PSID files for tests, built in memory: no HVSC needed.
pub mod testing {
    /// A two-song PSID: voice 1 plays A4 with an instant attack and full
    /// sustain, a sawtooth in song 1 and a pulse in song 2, and the play
    /// routine bumps the frequency's low byte every frame (one register
    /// write per frame). With `chips == 2` a second SID at `$D420` plays
    /// the same, so the tune is a 2SID.
    pub fn tiny_psid(chips: u8) -> Vec<u8> {
        assert!(chips == 1 || chips == 2);
        let bases: Vec<u16> = if chips == 2 {
            vec![0xD400, 0xD420]
        } else {
            vec![0xD400]
        };
        let mut code: Vec<u8> = vec![0x00, 0x10]; // load address $1000
        let sta = |code: &mut Vec<u8>, addr: u16| {
            code.extend_from_slice(&[0x8D, (addr & 0xFF) as u8, (addr >> 8) as u8]);
        };
        let lda_sta = |code: &mut Vec<u8>, value: u8, addr: u16| {
            code.extend_from_slice(&[0xA9, value]);
            sta(code, addr);
        };
        // init: A = song index
        code.push(0xAA); // TAX
        for &base in &bases {
            lda_sta(&mut code, 0x0F, base + 0x18); // volume
            lda_sta(&mut code, 0x00, base + 0x05); // attack 0, decay 0
            lda_sta(&mut code, 0xF0, base + 0x06); // sustain F, release 0
            lda_sta(&mut code, 0x1D, base + 0x01); // A4 = $1D45
            lda_sta(&mut code, 0x45, base + 0x00);
            lda_sta(&mut code, 0x08, base + 0x03); // pulse width 50 %
        }
        code.extend_from_slice(&[0xE0, 0x00]); // CPX #0
        code.extend_from_slice(&[0xF0, 0x04]); // BEQ saw
        code.extend_from_slice(&[0xA9, 0x41]); // LDA #pulse|gate
        code.extend_from_slice(&[0xD0, 0x02]); // BNE set
        code.extend_from_slice(&[0xA9, 0x21]); // saw: LDA #saw|gate
        for &base in &bases {
            sta(&mut code, base + 0x04); // set: STA control
        }
        code.push(0x60); // RTS
        let play_addr = 0x1000 + (code.len() - 2) as u16;
        for &base in &bases {
            code.extend_from_slice(&[0xEE, (base & 0xFF) as u8, (base >> 8) as u8]);
            // INC freq lo
        }
        code.push(0x60);

        let version: u16 = if chips == 2 { 3 } else { 2 };
        let mut h = Vec::with_capacity(0x7C + code.len());
        h.extend_from_slice(b"PSID");
        h.extend_from_slice(&version.to_be_bytes());
        h.extend_from_slice(&0x7Cu16.to_be_bytes()); // data offset
        h.extend_from_slice(&0u16.to_be_bytes()); // load address: in the data
        h.extend_from_slice(&0x1000u16.to_be_bytes()); // init
        h.extend_from_slice(&play_addr.to_be_bytes());
        h.extend_from_slice(&2u16.to_be_bytes()); // songs
        h.extend_from_slice(&1u16.to_be_bytes()); // start song
        h.extend_from_slice(&0u32.to_be_bytes()); // speed: VBI
        for text in ["Resonance Test Tune", "Resonance", "2026 Resonance"] {
            let mut field = [0u8; 32];
            field[..text.len()].copy_from_slice(text.as_bytes());
            h.extend_from_slice(&field);
        }
        // flags: PAL (bits 2–3 = 1), 6581 (bits 4–5 = 1), second SID 8580 (bits 6–7 = 2)
        let flags: u16 = (1 << 2) | (1 << 4) | if chips == 2 { 2 << 6 } else { 0 };
        h.extend_from_slice(&flags.to_be_bytes());
        h.push(0); // start page
        h.push(0); // page length
        h.push(if chips == 2 { 0x42 } else { 0 }); // second SID at $D420
        h.push(0); // third SID
        assert_eq!(h.len(), 0x7C);
        h.extend_from_slice(&code);
        h
    }
}

#[cfg(test)]
mod tests {
    use super::testing::tiny_psid;
    use super::*;

    fn started(chips: u8, song: u16, cfg: &Config) -> (Player, Started) {
        let mut p = Player::new().unwrap();
        let info = p.load_bytes(&tiny_psid(chips)).unwrap();
        assert_eq!(info.songs, 2);
        assert_eq!(info.chips, chips as usize);
        assert_eq!(info.title, "Resonance Test Tune");
        assert_eq!(info.compatibility, Compatibility::C64);
        let s = p.start(song, cfg).unwrap();
        (p, s)
    }

    fn render_secs(p: &mut Player, rate: u32, secs: f32) -> Vec<i16> {
        let frames = (rate as f32 * secs) as usize;
        let mut out = vec![0i16; frames * 2];
        let mut done = 0;
        while done < frames {
            let n = (frames - done).min(512);
            let got = p.render(&mut out[done * 2..(done + n) * 2]);
            assert_eq!(got, n, "render stopped: {}", p.error());
            done += n;
        }
        out
    }

    #[test]
    fn skipping_digital_matches_rendering() {
        // The same power-on delay, so the two instances line up.
        let cfg = Config {
            power_on_delay: Some(0x123),
            ..Config::default()
        };
        let (mut a, sa) = started(1, 1, &cfg);
        let (mut b, sb) = started(1, 1, &cfg);
        assert_eq!(sa.power_on_delay, 0x123);
        assert_eq!(sb.power_on_delay, 0x123);
        let cycles = 2 * 985_248;
        let ran = a.skip(cycles, SkipMode::Render);
        assert!(ran >= cycles && ran < cycles + 100, "{ran}");
        assert_eq!(b.skip(cycles, SkipMode::Digital), ran);
        assert_eq!(a.cycles(), b.cycles());
        assert_eq!(
            format!("{:?}", a.chip_state(0).unwrap()),
            format!("{:?}", b.chip_state(0).unwrap())
        );
        // Both play on from there.
        let out = render_secs(&mut b, 48_000, 0.1);
        assert!(out.iter().any(|&s| s != 0));
        assert!((b.cycles() as f64 - 2.1 * 985_248.0).abs() < 985_248.0 * 0.03);
        // Left to libsidplayfp, the delay is one of its random ones.
        let (_, s) = started(1, 1, &Config::default());
        assert!(s.power_on_delay <= 0x1FFF, "{}", s.power_on_delay);
    }

    #[test]
    fn version_names_both_libraries() {
        assert_eq!(version(), "libsidplayfp 3.1.2, libresidfp 1.2.3");
    }

    #[test]
    fn plays_a_second_of_audio() {
        let cfg = Config {
            scope_cycles: 22,
            ..Config::default()
        };
        let (mut p, s) = started(1, 1, &cfg);
        assert_eq!(s.song, 1);
        assert!(s.is_pal);
        assert_eq!(s.chips, 1);
        assert_eq!(s.models[0], ChipModel::Mos6581);
        assert!((s.cpu_hz - 985_248.4).abs() < 1.0);

        let out = render_secs(&mut p, 48_000, 1.0);
        let peak = out.iter().map(|s| s.unsigned_abs()).max().unwrap();
        assert!(peak > 2000, "peak {peak}");
        // Mono: both channels equal.
        assert!(out.chunks(2).all(|c| c[0] == c[1]));
        // About a second of C64 time.
        let cycles = p.cycles() as f64;
        assert!((cycles - 985_248.0).abs() < 985_248.0 * 0.03, "{cycles}");

        let state = p.chip_state(0).unwrap();
        assert_eq!(state.regs[0x04], 0x21, "sawtooth, gate on");
        assert_eq!(state.regs[0x18], 0x0F);
        assert_eq!(state.env[0], 0xFF, "attack 0, sustain F");
        assert_eq!(state.phase(0), EnvPhase::DecaySustain);
        assert_eq!(state.phase(1), EnvPhase::Release);
        assert!(state.osc3 == 0 && state.env3 == 0, "voice 3 is silent");
    }

    #[test]
    fn scope_samples_follow_the_clock() {
        let cfg = Config {
            scope_cycles: 22,
            ..Config::default()
        };
        let (mut p, _) = started(1, 1, &cfg);
        // Drain whatever init produced, then take exactly 0.1 s.
        let mut buf = vec![0f32; 3 * 8192];
        p.take_scope(0, &mut buf);
        render_secs(&mut p, 48_000, 0.1);
        let n = p.take_scope(0, &mut buf);
        let expected = 985_248.0 / 22.0 * 0.1;
        assert!(
            (n as f64 - expected).abs() < expected * 0.05,
            "{n} vs {expected}"
        );
        let voice1 = &buf[..n];
        let (lo, hi) = voice1
            .iter()
            .fold((1f32, -1f32), |(lo, hi), &s| (lo.min(s), hi.max(s)));
        assert!(
            lo < -0.8 && hi > 0.8,
            "a full-level sawtooth sweeps the range: {lo}..{hi}"
        );
        assert!(
            buf[8192..8192 + n].iter().all(|&s| s == 0.0),
            "voice 2 is silent"
        );
        // Nothing left after taking.
        assert_eq!(p.take_scope(0, &mut buf), 0);
    }

    #[test]
    fn writes_are_recorded_with_cycle_stamps() {
        let (mut p, _) = started(1, 1, &Config::default());
        let mut writes = vec![
            Write {
                cycle: 0,
                reg: 0,
                val: 0
            };
            1024
        ];
        // The tune's init runs once rendering starts.
        assert_eq!(p.take_writes(0, &mut writes), (0, 0));
        render_secs(&mut p, 48_000, 0.1);
        let (copied, total) = p.take_writes(0, &mut writes);
        assert!(
            copied >= 7 && total as usize == copied,
            "init wrote the voice: {copied}/{total}"
        );
        assert!(writes[..copied]
            .iter()
            .any(|w| w.reg == 0x18 && w.val == 0x0F));
        assert!(writes[..copied]
            .iter()
            .any(|w| w.reg == 0x04 && w.val == 0x21));
        render_secs(&mut p, 48_000, 1.0);
        let (copied, total) = p.take_writes(0, &mut writes);
        // INC is a read-modify-write: the 6510 writes the old value, then
        // the new one, and the cycle-exact CPU shows both.
        assert!(
            (90..=110).contains(&total),
            "two writes per PAL frame: {total}"
        );
        assert_eq!(copied, total as usize);
        assert!(writes[..copied].iter().all(|w| w.reg == 0x00));
        assert!(writes[..copied]
            .windows(2)
            .all(|w| w[1].cycle >= w[0].cycle));
        let frames = (copied / 2 - 1) as f64;
        let span = writes[copied - 2].cycle - writes[0].cycle;
        assert!(
            (span as f64 / frames - 19_656.0).abs() < 100.0,
            "a frame apart: {span}"
        );
    }

    #[test]
    fn songs_select_their_waveform() {
        let (mut p, s) = started(1, 2, &Config::default());
        assert_eq!(s.song, 2);
        render_secs(&mut p, 48_000, 0.2);
        assert_eq!(p.chip_state(0).unwrap().regs[0x04], 0x41, "pulse in song 2");
        // The same player can start another song.
        let s = p.start(1, &Config::default()).unwrap();
        assert_eq!(s.song, 1);
        assert_eq!(p.cycles(), 0);
        render_secs(&mut p, 48_000, 0.2);
        assert_eq!(p.chip_state(0).unwrap().regs[0x04], 0x21);
        // Song 0 is the start song.
        assert_eq!(p.start(0, &Config::default()).unwrap().song, 1);
    }

    #[test]
    fn two_sids_play_left_and_right() {
        let (mut p, s) = started(2, 1, &Config::default());
        assert_eq!(s.chips, 2);
        assert_eq!(
            s.models,
            [ChipModel::Mos6581, ChipModel::Mos8580, ChipModel::Mos6581]
        );
        let out = render_secs(&mut p, 48_000, 0.5);
        let energy = |ch: usize| {
            out.iter()
                .skip(ch)
                .step_by(2)
                .map(|&s| (s as f64).abs())
                .sum::<f64>()
        };
        assert!(energy(0) > 1e5 && energy(1) > 1e5);
        assert!(
            out.chunks(2).any(|c| c[0] != c[1]),
            "two chips sound different"
        );
        assert_eq!(p.chip_state(1).unwrap().regs[0x04], 0x21);

        let cfg = Config {
            mono_2sid: true,
            ..Config::default()
        };
        p.start(1, &cfg).unwrap();
        let out = render_secs(&mut p, 48_000, 0.2);
        assert!(
            out.chunks(2).all(|c| c[0] == c[1]),
            "mono_2sid mixes both to both"
        );
    }

    #[test]
    fn header_models_and_clock_can_be_forced() {
        let cfg = Config {
            default_model: ChipModel::Mos8580,
            force_model: true,
            default_clock: Clock::Ntsc,
            force_clock: true,
            sample_rate: 44_100,
            ..Config::default()
        };
        let (mut p, s) = started(1, 1, &cfg);
        assert_eq!(s.models[0], ChipModel::Mos8580);
        assert!(!s.is_pal);
        assert!((s.cpu_hz - 1_022_727.14).abs() < 1.0);
        render_secs(&mut p, 44_100, 0.2);
        let cycles = p.cycles() as f64;
        assert!(
            (cycles - 1_022_727.0 * 0.2).abs() < 1_022_727.0 * 0.2 * 0.03,
            "{cycles}"
        );
    }

    #[test]
    fn resample_method_works_too() {
        let cfg = Config {
            sampling: SamplingMethod::Resample,
            ..Config::default()
        };
        let (mut p, _) = started(1, 1, &cfg);
        let out = render_secs(&mut p, 48_000, 0.3);
        assert!(out.iter().any(|&s| s.unsigned_abs() > 2000));
    }

    fn sidlite(extra: Config) -> Config {
        Config {
            chip: Chip::SidLite,
            scope_cycles: 22,
            ..extra
        }
    }

    #[test]
    fn sidlite_plays_too() {
        let (mut p, s) = started(1, 1, &sidlite(Config::default()));
        assert_eq!(s.models[0], ChipModel::Mos6581);
        let out = render_secs(&mut p, 48_000, 1.0);
        let peak = out.iter().map(|s| s.unsigned_abs()).max().unwrap();
        assert!(peak > 2000, "peak {peak}");
        assert!(out.chunks(2).all(|c| c[0] == c[1]));
        let cycles = p.cycles() as f64;
        assert!((cycles - 985_248.0).abs() < 985_248.0 * 0.03, "{cycles}");
        let state = p.chip_state(0).unwrap();
        assert_eq!(state.regs[0x04], 0x21);
        assert_eq!(state.env[0], 0xFF, "attack 0, sustain F");
        assert_eq!(state.phase(0), EnvPhase::DecaySustain);
        assert_eq!(state.phase(1), EnvPhase::Release);
        // Scope and writes come the same way.
        let mut buf = vec![0f32; 3 * 8192];
        p.take_scope(0, &mut buf);
        render_secs(&mut p, 48_000, 0.1);
        let n = p.take_scope(0, &mut buf);
        let expected = 985_248.0 / 22.0 * 0.1;
        assert!(
            (n as f64 - expected).abs() < expected * 0.05,
            "{n} vs {expected}"
        );
        let (lo, hi) = buf[..n]
            .iter()
            .fold((1f32, -1f32), |(lo, hi), &s| (lo.min(s), hi.max(s)));
        assert!(lo < -0.8 && hi > 0.8, "{lo}..{hi}");
        let mut writes = vec![
            Write {
                cycle: 0,
                reg: 0,
                val: 0
            };
            1024
        ];
        let (copied, total) = p.take_writes(0, &mut writes);
        assert!(copied > 0 && total as usize == copied);
    }

    #[test]
    fn sidlite_two_sids_and_models() {
        let (mut p, s) = started(2, 2, &sidlite(Config::default()));
        assert_eq!(s.chips, 2);
        assert_eq!(s.models[1], ChipModel::Mos8580);
        let out = render_secs(&mut p, 44_100, 0.5);
        assert!(out.chunks(2).any(|c| c[0] != c[1]));
        assert_eq!(p.chip_state(1).unwrap().regs[0x04], 0x41, "pulse in song 2");
        // Output rates above 48 kHz are refused for SIDLite.
        let mut p = Player::new().unwrap();
        p.load_bytes(&tiny_psid(1)).unwrap();
        let err = p
            .start(
                1,
                &sidlite(Config {
                    sample_rate: 96_000,
                    ..Config::default()
                }),
            )
            .unwrap_err();
        assert!(err.contains("48000"), "{err}");
    }

    #[test]
    fn md5_is_the_hvsc_one() {
        let mut p = Player::new().unwrap();
        p.load_bytes(&tiny_psid(1)).unwrap();
        let md5 = p.md5().unwrap();
        assert_eq!(md5.len(), 32);
        assert!(md5.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(format!("{:x}", md5_of(&tiny_psid(1))), md5);
    }

    /// Straight RFC 1321, enough to check the HVSC key.
    fn md5_of(data: &[u8]) -> u128 {
        let s: [u32; 64] = [
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20,
            5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
        ];
        let k: Vec<u32> = (0..64)
            .map(|i| ((i as f64 + 1.0).sin().abs() * 4_294_967_296.0) as u32)
            .collect();
        let (mut a0, mut b0, mut c0, mut d0) =
            (0x67452301u32, 0xefcdab89u32, 0x98badcfeu32, 0x10325476u32);
        let mut msg = data.to_vec();
        msg.push(0x80);
        while msg.len() % 64 != 56 {
            msg.push(0);
        }
        msg.extend_from_slice(&((data.len() as u64) * 8).to_le_bytes());
        for chunk in msg.chunks(64) {
            let m: Vec<u32> = chunk
                .chunks(4)
                .map(|w| u32::from_le_bytes([w[0], w[1], w[2], w[3]]))
                .collect();
            let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
            for i in 0..64 {
                let (f, g) = match i / 16 {
                    0 => ((b & c) | (!b & d), i),
                    1 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                    2 => (b ^ c ^ d, (3 * i + 5) % 16),
                    _ => (c ^ (b | !d), (7 * i) % 16),
                };
                let f = f.wrapping_add(a).wrapping_add(k[i]).wrapping_add(m[g]);
                a = d;
                d = c;
                c = b;
                b = b.wrapping_add(f.rotate_left(s[i]));
            }
            a0 = a0.wrapping_add(a);
            b0 = b0.wrapping_add(b);
            c0 = c0.wrapping_add(c);
            d0 = d0.wrapping_add(d);
        }
        let mut out = [0u8; 16];
        out[..4].copy_from_slice(&a0.to_le_bytes());
        out[4..8].copy_from_slice(&b0.to_le_bytes());
        out[8..12].copy_from_slice(&c0.to_le_bytes());
        out[12..].copy_from_slice(&d0.to_le_bytes());
        u128::from_be_bytes(out)
    }

    #[test]
    fn errors_are_reported() {
        let mut p = Player::new().unwrap();
        assert!(p.load_bytes(b"not a sid file at all").is_err());
        assert!(!p.error().is_empty());
        let mut out = [0i16; 64];
        assert_eq!(p.render(&mut out), 0, "nothing loaded renders silence");
        assert!(p.start(1, &Config::default()).is_err());
        let mut p = Player::new().unwrap();
        p.load_bytes(&tiny_psid(1)).unwrap();
        let bad = Config {
            sample_rate: 1000,
            ..Config::default()
        };
        assert!(p.start(1, &bad).is_err());
    }
}

/// Where the time goes: `RSFP_BENCH_TUNE=<file.sid> cargo test -p residfp-sys
/// --release -- --ignored --nocapture bench`. Prints milliseconds of CPU per
/// second of audio for a few configurations.
#[cfg(test)]
mod bench {
    use super::*;

    #[test]
    #[ignore]
    fn bench() {
        let data = match std::env::var("RSFP_BENCH_TUNE") {
            Ok(path) => std::fs::read(path).expect("read the tune"),
            Err(_) => testing::tiny_psid(1),
        };
        let secs = 10.0f64;
        let cases: [(&str, Config, bool); 6] = [
            (
                "SIDLite, scope 22",
                Config {
                    chip: Chip::SidLite,
                    scope_cycles: 22,
                    ..Config::default()
                },
                true,
            ),
            (
                "scope 22 (as played)",
                Config {
                    scope_cycles: 22,
                    ..Config::default()
                },
                true,
            ),
            ("scope off", Config::default(), true),
            (
                "scope 22, filter off",
                Config {
                    scope_cycles: 22,
                    ..Config::default()
                },
                false,
            ),
            (
                "scope 22, forced 8580",
                Config {
                    scope_cycles: 22,
                    default_model: ChipModel::Mos8580,
                    force_model: true,
                    ..Config::default()
                },
                true,
            ),
            (
                "scope 22, resample",
                Config {
                    scope_cycles: 22,
                    sampling: SamplingMethod::Resample,
                    ..Config::default()
                },
                true,
            ),
        ];
        for (name, cfg, filter) in cases {
            let mut p = Player::new().unwrap();
            p.load_bytes(&data).unwrap();
            let s = p.start(0, &cfg).unwrap();
            for c in 0..s.chips {
                p.filter(c, filter);
            }
            let mut out = vec![0i16; 1024];
            let mut scope = vec![0f32; 3 * 8192];
            let frames = (cfg.sample_rate as f64 * secs) as usize;
            let t0 = std::time::Instant::now();
            let mut done = 0;
            while done < frames {
                let n = p.render(&mut out).max(1);
                done += n;
                if done % (512 * 20) < 512 {
                    for c in 0..s.chips {
                        p.take_scope(c, &mut scope);
                        p.take_writes(c, &mut []);
                    }
                }
            }
            let ms = t0.elapsed().as_secs_f64() * 1000.0 / secs;
            println!(
                "{name:<24} {:>6.1} ms per second of audio ({} chip(s), {})",
                ms,
                s.chips,
                if s.is_pal { "PAL" } else { "NTSC" }
            );
        }
    }
}
