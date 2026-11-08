//! A tune as a tracker would show it, rebuilt from what its player writes to the chip.
//!
//! A `.sid` file holds player code, not patterns, so there's nothing to read. This runs
//! the tune once with the capture-only SID, as the fingerprint scan does, and works out
//! notes, a row grid, instruments and effects from the register writes. Because it sees
//! each write rather than the end of each frame, it catches a gate closed and reopened
//! within one frame. Why it works this way: `design/visualizers/TRACKER.md`.
//! Change it only against `examples/tracker_bench.rs`.

use sidplayfp_sys::Player;

const VOICES: usize = 3;
/// Frames either side of a row that vibrato is judged over.
const VIBRATO_REACH: usize = 10;
/// A new note without a new gate needs to jump this far, in semitones, and then hold.
const LEGATO_JUMP: f32 = 0.75;
const LEGATO_HOLD: usize = 3;
/// How sure, beyond luck, a grid must be; below it, rows are only a ruler.
const GRID_FROM: f32 = 0.6;
/// A longer row may do this nearly as well as the best and still be chosen.
const NEARLY_BEST: f32 = 0.97;
/// Frames per row when there's no grid to find.
const FREE_ROW: f32 = 6.0;
/// The longest row a grid may have, in frames.
const LONGEST_ROW: f32 = 16.0;
/// A gate that reopens this soon is a hard restart, not a note ending.
const RESTART_FRAMES: usize = 4;

/// What a voice does on a row, beyond its note.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TrackerEffect {
    None,
    Arpeggio,
    Slide,
    Vibrato,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TrackerCell {
    /// "C#4" style; None when no note starts on this row.
    pub note: Option<String>,
    /// Index into the song's instruments, plus one; 0 for none.
    pub instrument: u8,
    /// The note ended on this row.
    pub off: bool,
    pub effect: TrackerEffect,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TrackerRow {
    /// The frame it starts on.
    pub frame: u32,
    /// Always three.
    pub voices: Vec<TrackerCell>,
    /// 11-bit, at the row's start.
    pub cutoff: u16,
    pub resonance: u8,
    /// Which voices go through the filter: bits 0–2.
    pub filter_routing: u8,
    /// Bits 0–3: low-pass, band-pass, high-pass, voice 3 off.
    pub filter_mode: u8,
}

/// A distinct waveform and envelope.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TrackerInstrument {
    /// "Saw", "Pulse", "Noise › Pulse".
    pub name: String,
    pub attack_decay: u8,
    pub sustain_release: u8,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TrackerSong {
    pub is_pal: bool,
    /// Video frames per second, which rows' frames count in.
    pub frame_rate: f64,
    pub frames_per_row: f32,
    /// How sure the grid is, 0–1, beyond what it would catch by luck.
    pub on_grid: f32,
    /// False when no steady grid was found, so rows are only a ruler.
    pub has_grid: bool,
    pub chips: u32,
    pub rows: Vec<TrackerRow>,
    pub instruments: Vec<TrackerInstrument>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct VoiceFrame {
    freq: u16,
    pulse_width: u16,
    control: u8,
    attack_decay: u8,
    sustain_release: u8,
    /// The gate opened during this frame, even if it was closed in it too.
    opened: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct Frame {
    voices: [VoiceFrame; VOICES],
    filter: [u8; 4],
}

/// Runs the tune for `secs` and keeps the registers at the end of each frame.
fn capture(data: &[u8], subtune: u16, secs: f64, chip: usize, canceled: &dyn Fn() -> bool) -> Result<Option<(Vec<Frame>, bool, u32)>, String> {
    let mut player = Player::new()?;
    player.set_roms(None, None, None);
    player.load(data, subtune)?;
    let is_pal = player.is_pal();
    let chips = player.num_sids().clamp(1, 3) as u32;
    let (cycles, clock) = if is_pal { (19_656u32, 985_248.0) } else { (17_095u32, 1_022_727.0) };
    let count = (secs * clock / f64::from(cycles)).ceil().max(1.0) as usize;
    let mut frames = Vec::with_capacity(count);
    let mut regs = [0u8; 32];
    for index in 0..count {
        if index % 256 == 0 && canceled() {
            return Ok(None);
        }
        player.play(cycles)?;
        let mut opened = [false; VOICES];
        for write in player.get_writes() {
            if write.sid_num as usize != chip {
                continue;
            }
            let reg = (write.reg & 0x1F) as usize;
            if reg < 0x15 && reg % 7 == 4 && regs[reg] & 1 == 0 && write.val & 1 == 1 {
                opened[reg / 7] = true;
            }
            regs[reg] = write.val;
        }
        let mut frame = Frame { filter: [regs[0x15], regs[0x16], regs[0x17], regs[0x18]], ..Frame::default() };
        for (v, voice) in frame.voices.iter_mut().enumerate() {
            let r = &regs[v * 7..v * 7 + 7];
            *voice = VoiceFrame {
                freq: u16::from_le_bytes([r[0], r[1]]),
                pulse_width: u16::from_le_bytes([r[2], r[3] & 0x0F]),
                control: r[4],
                attack_decay: r[5],
                sustain_release: r[6],
                opened: opened[v],
            };
        }
        frames.push(frame);
    }
    Ok(Some((frames, is_pal, chips)))
}

fn midi(freq: u16, clock: f64) -> f32 {
    if freq == 0 {
        return 0.0;
    }
    let hz = f64::from(freq) * clock / 16_777_216.0;
    (69.0 + 12.0 * (hz / 440.0).log2()) as f32
}

fn note_name(midi: f32) -> Option<String> {
    const NAMES: [&str; 12] = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"];
    let nearest = midi.round() as i32;
    (midi > 0.0 && (0..=127).contains(&nearest)).then(|| format!("{}{}", NAMES[nearest as usize % 12], nearest / 12 - 1))
}

fn wave_name(wave: u8) -> &'static str {
    match wave {
        1 => "Tri",
        2 => "Saw",
        4 => "Pulse",
        8 => "Noise",
        3 => "Saw+Tri",
        5 => "Pulse+Tri",
        6 => "Pulse+Saw",
        7 => "Pulse+Saw+Tri",
        0 => "Silent",
        _ => "Mixed",
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Note {
    frame: usize,
    midi: f32,
    /// Its first audible waveform and the one it settles on.
    first_wave: u8,
    settled_wave: u8,
    attack_decay: u8,
    sustain_release: u8,
}

/// The waveforms a note starts with and settles on, from its first frames.
fn waves_from(frames: &[Frame], voice: usize, at: usize) -> Option<(u8, u8)> {
    let span = &frames[at..(at + 8).min(frames.len())];
    let first = span.iter().map(|f| f.voices[voice].control >> 4).find(|w| *w != 0)?;
    let settled = span.iter().rev().map(|f| f.voices[voice].control >> 4).find(|w| *w != 0)?;
    Some((first, settled))
}

/// Where each note starts: an opened gate, or a jump that then holds with the gate open.
fn notes_of(frames: &[Frame], voice: usize, clock: f64) -> Vec<Note> {
    let pitch = |at: usize| midi(frames[at].voices[voice].freq, clock);
    let mut notes = Vec::new();
    for at in 0..frames.len() {
        let here = frames[at].voices[voice];
        let gated = here.control & 1 == 1;
        let legato = !here.opened && gated && at > 0 && frames[at - 1].voices[voice].control & 1 == 1 && {
            let jump = (pitch(at) - pitch(at - 1)).abs() >= LEGATO_JUMP;
            let holds = at + LEGATO_HOLD < frames.len() && (1..=LEGATO_HOLD).all(|n| (pitch(at + n) - pitch(at)).abs() < 0.5);
            // The frames before it held too, or this is the end of an arpeggio.
            let settled = at >= 2 && (pitch(at - 1) - pitch(at - 2)).abs() < 0.5;
            jump && holds && settled
        };
        if !(here.opened || legato) || pitch(at) <= 0.0 {
            continue;
        }
        let Some((first_wave, settled_wave)) = waves_from(frames, voice, at) else { continue };
        notes.push(Note { frame: at, midi: pitch(at), first_wave, settled_wave, attack_decay: here.attack_decay, sustain_release: here.sustain_release });
    }
    notes
}

/// Where a voice's notes really end: a gate closing that doesn't soon reopen, which
/// would only be the player's hard restart.
fn ends_of(frames: &[Frame], voice: usize) -> Vec<usize> {
    (1..frames.len())
        .filter(|&at| {
            let was = frames[at - 1].voices[voice].control & 1 == 1;
            let is = frames[at].voices[voice].control & 1 == 1;
            was && !is && !(at..(at + RESTART_FRAMES).min(frames.len())).any(|f| frames[f].voices[voice].opened)
        })
        .collect()
}

/// How far from the grid an event may fall, and still be on it. Long rows allow a frame
/// either way, as players often start a voice a frame late; half-frame rows alternate.
fn slack(period: f32) -> f32 {
    if period.fract() != 0.0 {
        0.51
    } else if period >= 6.0 {
        1.01
    } else {
        0.01
    }
}

/// The share of events a grid would catch by luck.
fn chance(period: f32) -> f32 {
    ((2.0 * slack(period).floor() + if period.fract() != 0.0 { 2.0 } else { 1.0 }) / period).min(1.0)
}

/// The steadiest row length, and how sure that is: (frames per row, 0–1 beyond chance,
/// where it starts). The longest that does nearly as well as the best, as any multiple
/// of a row's length catches fewer events but also fewer by luck.
fn find_grid(events: &[usize]) -> (f32, f32, f32) {
    if events.len() < 8 {
        return (FREE_ROW, 0.0, 0.0);
    }
    let score = |period: f32, phase: f32| -> f32 {
        let allowed = slack(period);
        let on = events.iter().filter(|&&s| {
            let steps = ((s as f32 - phase) / period).round();
            (s as f32 - (phase + steps * period)).abs() <= allowed
        });
        on.count() as f32 / events.len() as f32
    };
    let mut scored = Vec::new();
    let mut period = 2.0f32;
    while period <= LONGEST_ROW {
        let mut best = (0.0f32, 0.0f32);
        let mut phase = 0.0f32;
        while phase < period {
            let s = score(period, phase);
            if s > best.0 {
                best = (s, phase);
            }
            phase += 1.0;
        }
        let luck = chance(period);
        let beyond = if luck >= 1.0 { 0.0 } else { (best.0 - luck) / (1.0 - luck) };
        scored.push((period, beyond, best.1));
        period += 0.5;
    }
    let top = scored.iter().map(|(_, s, _)| *s).fold(0.0f32, f32::max);
    let chosen = scored.iter().rev().find(|(_, s, _)| *s >= top * NEARLY_BEST).or(scored.first());
    let &(period, sure, phase) = chosen.expect("candidates");
    (period, sure, phase)
}

fn effect_of(frames: &[Frame], voice: usize, from: usize, to: usize, clock: f64, note_starts: bool) -> TrackerEffect {
    let pitch = |at: usize| midi(frames[at].voices[voice].freq, clock);
    if frames[from].voices[voice].control & 1 == 0 || pitch(from) <= 0.0 {
        return TrackerEffect::None;
    }
    let to = to.min(frames.len());
    // Big steps every frame or two, coming back: an arpeggio.
    let mut steps = 0;
    let mut notes = [false; 128];
    for at in from..to {
        notes[pitch(at).round().clamp(0.0, 127.0) as usize] = true;
        if at > from && (pitch(at) - pitch(at - 1)).abs() >= 1.5 {
            steps += 1;
        }
    }
    if steps >= 2 && notes.iter().filter(|n| **n).count() >= 2 {
        return TrackerEffect::Arpeggio;
    }
    // Small moves that keep crossing back over their middle, around the row: vibrato.
    let around_from = from.saturating_sub(VIBRATO_REACH);
    let around_to = (to + VIBRATO_REACH).min(frames.len());
    let held = (around_from..around_to).all(|at| frames[at].voices[voice].control & 1 == 1 && !(frames[at].voices[voice].opened && at > from));
    if held {
        let values: Vec<f32> = (around_from..around_to).map(pitch).collect();
        let (low, high) = values.iter().fold((f32::MAX, f32::MIN), |(l, h), v| (l.min(*v), h.max(*v)));
        let middle = (low + high) / 2.0;
        let crossings = values.windows(2).filter(|w| (w[0] - middle).signum() != (w[1] - middle).signum()).count();
        if (0.08..1.5).contains(&(high - low)) && crossings >= 3 {
            return TrackerEffect::Vibrato;
        }
    }
    // One way, steadily: a slide.
    if !note_starts || to - from >= 3 {
        let first = pitch(from);
        let last = pitch(to - 1);
        let rising = (from + 1..to).all(|at| pitch(at) >= pitch(at - 1));
        let falling = (from + 1..to).all(|at| pitch(at) <= pitch(at - 1));
        if (rising || falling) && (last - first).abs() >= 0.25 {
            return TrackerEffect::Slide;
        }
    }
    TrackerEffect::None
}

fn rebuild(frames: &[Frame], is_pal: bool, chips: u32) -> TrackerSong {
    let (cycles, clock) = if is_pal { (19_656.0, 985_248.0) } else { (17_095.0, 1_022_727.0) };
    let notes: [Vec<Note>; VOICES] = std::array::from_fn(|v| notes_of(frames, v, clock));
    let ends: [Vec<usize>; VOICES] = std::array::from_fn(|v| ends_of(frames, v));
    let mut starts: Vec<usize> = notes.iter().flatten().map(|n| n.frame).collect();
    starts.sort_unstable();
    // Notes set the grid: players often close a gate a fixed two frames in, and rows that
    // fine couldn't be read. Endings only halve a long row when they land midway through.
    let (mut period, on_grid, phase) = find_grid(&starts);
    if period >= 8.0 && period % 2.0 == 0.0 {
        let halfway = |at: usize| ((at as f32 - phase).rem_euclid(period) - period / 2.0).abs() <= 1.0;
        let all_ends: Vec<usize> = ends.iter().flatten().copied().collect();
        if all_ends.len() * 2 >= starts.len() && all_ends.iter().filter(|at| halfway(**at)).count() * 10 >= all_ends.len() * 9 {
            period /= 2.0;
        }
    }
    let has_grid = on_grid >= GRID_FROM;
    let (period, phase) = if has_grid { (period, phase) } else { (FREE_ROW, 0.0) };

    let mut instruments: Vec<TrackerInstrument> = Vec::new();
    let row_of_frame = |at: usize| ((at as f32 - phase + 0.5) / period).floor().max(0.0) as usize;
    let last_row = row_of_frame(frames.len().saturating_sub(1));
    let mut rows: Vec<TrackerRow> = (0..=last_row)
        .map(|n| {
            let frame = (phase + n as f32 * period).max(0.0) as usize;
            let f = frames[frame.min(frames.len() - 1)].filter;
            TrackerRow {
                frame: frame as u32,
                voices: vec![TrackerCell { note: None, instrument: 0, off: false, effect: TrackerEffect::None }; VOICES],
                cutoff: u16::from(f[1]) << 3 | u16::from(f[0] & 7),
                resonance: f[2] >> 4,
                filter_routing: f[2] & 7,
                filter_mode: f[3] >> 4,
            }
        })
        .collect();

    for (v, voice_notes) in notes.iter().enumerate() {
        for note in voice_notes {
            let row = &mut rows[row_of_frame(note.frame)].voices[v];
            if row.note.is_some() {
                continue;
            }
            let name = if note.first_wave == note.settled_wave {
                wave_name(note.settled_wave).to_string()
            } else {
                format!("{} › {}", wave_name(note.first_wave), wave_name(note.settled_wave))
            };
            let wanted = TrackerInstrument { name, attack_decay: note.attack_decay, sustain_release: note.sustain_release };
            let id = instruments.iter().position(|i| *i == wanted).unwrap_or_else(|| {
                instruments.push(wanted);
                instruments.len() - 1
            });
            row.note = note_name(note.midi);
            row.instrument = (id + 1).min(255) as u8;
        }
        for &at in &ends[v] {
            let cell = &mut rows[row_of_frame(at)].voices[v];
            cell.off = cell.note.is_none();
        }
        for n in 0..rows.len() {
            let from = rows[n].frame as usize;
            let to = rows.get(n + 1).map_or(frames.len(), |r| r.frame as usize);
            if from >= frames.len() || to <= from {
                continue;
            }
            let starts = rows[n].voices[v].note.is_some();
            rows[n].voices[v].effect = effect_of(frames, v, from, to, clock, starts);
        }
    }

    TrackerSong {
        is_pal,
        frame_rate: clock / cycles,
        frames_per_row: period,
        on_grid,
        has_grid,
        chips,
        rows,
        instruments,
    }
}

/// The tune as a tracker would show it, for `secs`, one chip's voices at a time. None if
/// `canceled` said to stop.
pub fn tracker_song(data: &[u8], subtune: u16, secs: f64, chip: usize, canceled: &dyn Fn() -> bool) -> Result<Option<TrackerSong>, String> {
    let Some((frames, is_pal, chips)) = capture(data, subtune, secs, chip, canceled)? else { return Ok(None) };
    Ok(Some(rebuild(&frames, is_pal, chips)))
}

/// For the benchmark: of the frames in `secs`, the share where two chips agree on what
/// the Sweeps view draws. Each voice's frequency, pulse width and gate, then cutoff and
/// resonance.
pub fn chip_agreement(data: &[u8], subtune: u16, secs: f64, a: usize, b: usize) -> Result<([[f32; 3]; 3], [f32; 2]), String> {
    let first = capture(data, subtune, secs, a, &|| false)?.ok_or("stopped")?.0;
    let second = capture(data, subtune, secs, b, &|| false)?.ok_or("stopped")?.0;
    let frames = first.len().min(second.len()).max(1);
    let share = |same: &dyn Fn(&Frame, &Frame) -> bool| first.iter().zip(&second).filter(|(x, y)| same(x, y)).count() as f32 / frames as f32;
    let voices = std::array::from_fn(|v| {
        [
            share(&|x, y| x.voices[v].freq == y.voices[v].freq),
            share(&|x, y| x.voices[v].pulse_width == y.voices[v].pulse_width),
            share(&|x, y| x.voices[v].control & 1 == y.voices[v].control & 1),
        ]
    });
    let cutoff = share(&|x, y| x.filter[0] & 7 == y.filter[0] & 7 && x.filter[1] == y.filter[1]);
    let resonance = share(&|x, y| x.filter[2] >> 4 == y.filter[2] >> 4);
    Ok((voices, [cutoff, resonance]))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One voice: notes as (start frame, frequency), each held `hold` frames.
    fn tune(notes: &[(usize, u16)], hold: usize, length: usize) -> Vec<Frame> {
        let mut frames = vec![Frame::default(); length];
        for &(start, freq) in notes {
            for (n, frame) in frames.iter_mut().enumerate().skip(start).take(hold) {
                frame.voices[0] = VoiceFrame { freq, pulse_width: 0, control: 0x21, attack_decay: 0x09, sustain_release: 0xA9, opened: n == start };
            }
        }
        frames
    }

    /// About C-4 and G-4 on PAL.
    const C4: u16 = 0x1167;
    const G4: u16 = 0x1A23;

    #[test]
    fn a_steady_tune_finds_its_row_length_and_notes() {
        let notes: Vec<(usize, u16)> = (0..64).map(|n| (n * 6, if n % 2 == 0 { C4 } else { G4 })).collect();
        let song = rebuild(&tune(&notes, 5, 64 * 6), true, 1);
        assert!(song.has_grid);
        assert_eq!(song.frames_per_row, 6.0);
        assert_eq!(song.rows[0].voices[0].note.as_deref(), Some("C-4"));
        assert_eq!(song.rows[1].voices[0].note.as_deref(), Some("G-4"));
        assert_eq!(song.instruments.len(), 1);
        assert_eq!(song.instruments[0].name, "Saw");
    }

    #[test]
    fn a_hard_restart_is_not_a_note_ending() {
        let notes: Vec<(usize, u16)> = (0..32).map(|n| (n * 6, C4)).collect();
        let song = rebuild(&tune(&notes, 4, 32 * 6), true, 1);
        assert!(song.rows.iter().take(30).all(|row| !row.voices[0].off));
    }

    #[test]
    fn a_gate_that_stays_closed_is_a_note_ending() {
        let notes: Vec<(usize, u16)> = (0..16).map(|n| (n * 12, C4)).collect();
        let song = rebuild(&tune(&notes, 6, 16 * 12), true, 1);
        assert!(song.rows.iter().any(|row| row.voices[0].off));
    }

    #[test]
    fn a_gate_reopened_within_a_frame_is_still_a_note() {
        let mut frames = tune(&[(0, C4)], 40, 40);
        frames[20].voices[0].opened = true;
        let notes = notes_of(&frames, 0, 985_248.0);
        assert_eq!(notes.len(), 2);
        assert_eq!(notes[1].frame, 20);
    }

    #[test]
    fn fast_big_steps_are_an_arpeggio_and_not_notes() {
        let mut frames = tune(&[(0, C4)], 48, 48);
        for (n, frame) in frames.iter_mut().enumerate() {
            frame.voices[0].freq = if n % 2 == 0 { C4 } else { G4 };
        }
        assert_eq!(notes_of(&frames, 0, 985_248.0).len(), 1);
        assert_eq!(effect_of(&frames, 0, 6, 12, 985_248.0, false), TrackerEffect::Arpeggio);
    }

    #[test]
    fn a_held_jump_without_a_gate_is_a_new_note() {
        let mut frames = tune(&[(0, C4)], 48, 48);
        for frame in &mut frames[24..] {
            frame.voices[0].freq = G4;
        }
        let notes = notes_of(&frames, 0, 985_248.0);
        assert_eq!(notes.iter().map(|n| n.frame).collect::<Vec<_>>(), [0, 24]);
    }

    #[test]
    fn a_small_wobble_is_vibrato() {
        let mut frames = tune(&[(0, C4)], 64, 64);
        for (n, frame) in frames.iter_mut().enumerate() {
            frame.voices[0].freq = (f64::from(C4) * (1.0 + 0.012 * (n as f64 * 0.9).sin())) as u16;
        }
        assert_eq!(effect_of(&frames, 0, 24, 30, 985_248.0, false), TrackerEffect::Vibrato);
    }

    #[test]
    fn a_steady_rise_is_a_slide() {
        let mut frames = tune(&[(0, C4)], 48, 48);
        for (n, frame) in frames.iter_mut().enumerate() {
            frame.voices[0].freq = C4 + n as u16 * 40;
        }
        assert_eq!(effect_of(&frames, 0, 12, 18, 985_248.0, false), TrackerEffect::Slide);
    }

    #[test]
    fn a_waveform_change_names_the_instrument_by_both() {
        let mut frames = tune(&[(0, C4)], 12, 12);
        frames[0].voices[0].control = 0x81;
        frames[1].voices[0].control = 0x81;
        for frame in &mut frames[2..] {
            frame.voices[0].control = 0x41;
        }
        let notes = notes_of(&frames, 0, 985_248.0);
        assert_eq!((notes[0].first_wave, notes[0].settled_wave), (8, 4));
    }

    #[test]
    fn no_steady_grid_is_said_so() {
        // Gaps that share nothing, from a small generator so they stay the same.
        let (mut start, mut seed) = (0usize, 12345u32);
        let mut notes = Vec::new();
        for _ in 0..200 {
            notes.push((start, C4));
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12345);
            start += 7 + (seed >> 16) as usize % 31;
        }
        let song = rebuild(&tune(&notes, 4, start + 8), true, 1);
        assert!(!song.has_grid, "{}", song.on_grid);
        assert_eq!(song.frames_per_row, FREE_ROW);
    }

    #[test]
    fn silence_has_rows_and_no_notes() {
        let song = rebuild(&vec![Frame::default(); 100], true, 1);
        assert!(!song.has_grid);
        assert!(song.rows.iter().all(|r| r.voices.iter().all(|c| c.note.is_none())));
    }
}
