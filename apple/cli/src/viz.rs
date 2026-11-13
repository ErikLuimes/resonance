//! What the terminal app hears of the music, from the voices' samples: each reading
//! becomes a level and an estimated pitch. The visuals and the voices' notes go by
//! these, and the progress bar's head pulses with the level.

use crate::palette;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::Color;

/// The voices' samples come at about this rate (design/visualizers/ROADMAP.md).
const SAMPLE_RATE: f32 = 44_800.0;
/// Below this a voice is silent, not quiet.
const QUIETEST: f32 = 0.02;
/// More crossings a second than any note a SID tune plays much: this is noise.
const NOISE_ABOVE_HZ: f32 = 4_500.0;
/// A second's worth of `LOUDEST_KEEPS`, about 20 readings: some 15 seconds to halve.
const LOUDEST_KEEPS: f32 = 0.9977;
const NAMES: [&str; 12] = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"];

/// The voices: cyan, green and orange, from the palette's at level 3.
const RAMP_RGB: [[(u8, u8, u8); 5]; 3] = [
    [(16, 52, 66), (28, 92, 112), (46, 146, 176), (90, 199, 232), (214, 243, 252)],
    [(20, 60, 42), (36, 104, 74), (72, 162, 118), (128, 219, 163), (222, 248, 232)],
    [(74, 42, 14), (130, 76, 26), (196, 120, 50), (242, 161, 84), (253, 230, 206)],
];
const RAMP_256: [[u8; 5]; 3] = [[23, 24, 38, 81, 195], [22, 29, 35, 115, 194], [52, 94, 172, 215, 223]];

/// A voice's color: `level` 0 is darkest, 4 brightest.
pub fn ink(voice: usize, level: usize, truecolor: bool) -> Color {
    let (voice, level) = (voice % 3, level.min(4));
    if truecolor {
        let (r, g, b) = RAMP_RGB[voice][level];
        Color::Rgb(r, g, b)
    } else {
        Color::Indexed(RAMP_256[voice][level])
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct VoiceReading {
    /// 0–1, against the loudest heard lately.
    pub level: f32,
    /// A MIDI note, fractional; `None` when silent, too low to tell, or noise.
    pub note: Option<f32>,
    pub noisy: bool,
}

/// A voice's raw peak, and its pitch by counting rising zero crossings, with a margin
/// so small ripples on a waveform don't count.
fn listen(samples: &[f32]) -> (f32, Option<f32>, bool) {
    let peak = samples.iter().fold(0.0_f32, |most, s| most.max(s.abs()));
    if peak < QUIETEST {
        return (peak, None, false);
    }
    let margin = peak * 0.25;
    let (mut armed, mut first, mut last, mut crossings) = (false, None, 0_usize, 0_u32);
    for (n, sample) in samples.iter().enumerate() {
        if *sample < -margin {
            armed = true;
        } else if armed && *sample > margin {
            armed = false;
            crossings += 1;
            first.get_or_insert(n);
            last = n;
        }
    }
    let Some(first) = first.filter(|first| crossings >= 2 && last > *first) else {
        return (peak, None, false);
    };
    let hertz = (crossings - 1) as f32 * SAMPLE_RATE / (last - first) as f32;
    if hertz > NOISE_ABOVE_HZ {
        return (peak, None, true);
    }
    (peak, Some(69.0 + 12.0 * (hertz / 440.0).log2()), false)
}

/// "C-4", from a MIDI note. Middle C (60) is C-4, as trackers call it.
pub fn note_name(note: f32) -> String {
    let whole = note.round().max(0.0) as i32;
    format!("{}{}", NAMES[(whole % 12) as usize], whole / 12 - 1)
}

#[derive(Debug, Clone)]
pub struct Ears {
    latest: [VoiceReading; 3],
    /// Readings ever heard, so patterns move with the music and not with the window.
    pub heard: u64,
    loudest: f32,
}

impl Default for Ears {
    fn default() -> Ears {
        Ears {
            latest: [VoiceReading::default(); 3],
            heard: 0,
            loudest: QUIETEST,
        }
    }
}

impl Ears {
    /// One reading of the voices.
    pub fn hear(&mut self, voices: &[Vec<f32>]) {
        let heard: Vec<(f32, Option<f32>, bool)> = voices.iter().take(3).map(|v| listen(v)).collect();
        let top = heard.iter().fold(0.0_f32, |most, h| most.max(h.0));
        self.loudest = (self.loudest * LOUDEST_KEEPS).max(top).max(QUIETEST);
        let mut reading = [VoiceReading::default(); 3];
        for (voice, (peak, note, noisy)) in heard.into_iter().enumerate() {
            let level = if peak < QUIETEST { 0.0 } else { (peak / self.loudest).min(1.0) };
            reading[voice] = VoiceReading { level, note, noisy };
        }
        self.latest = reading;
        self.heard += 1;
    }

    pub fn latest(&self) -> [VoiceReading; 3] {
        self.latest
    }
}

fn put(buffer: &mut Buffer, x: u16, y: u16, ch: char, color: Color) {
    if let Some(cell) = buffer.cell_mut((x, y)) {
        cell.set_char(ch).set_fg(color);
    }
}

/// What the bar shows, each as a share of the tune from 0 to 1.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bar {
    /// Played, in the accent; `None` when the tune's length isn't known.
    pub played: Option<f64>,
    /// A point chosen to scrub to, or one being caught up with: filled in gray
    /// between it and what's played.
    pub chosen: Option<f64>,
    /// For a tune of unknown length: where the sweep is, from 0 to 1.
    pub sweep: f64,
}

/// The bar: ▰ in the accent for what's played, with a glint running along it,
/// ▰ in gray up to a point chosen to scrub to, and ▱ in gray for what's left.
/// The playhead, or the point being chosen, is a white ●, like the knob on a
/// Mac slider, so it's easy to find. A tune of unknown length
/// gets a short run of ▰ in light gray sweeping across instead, as Apple's
/// indeterminate bar: nothing is played or chosen, so there's no accent.
pub fn progress(buffer: &mut Buffer, area: Rect, bar: Bar, level: f32, heard: u64) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let y = area.y;
    let cells = |share: f64| (f64::from(area.width) * share.clamp(0.0, 1.0)).round() as u16;
    let Some(played) = bar.played else {
        let run = (area.width / 6).max(3);
        let start = (f64::from(area.width + run) * bar.sweep.clamp(0.0, 1.0)) as i32 - i32::from(run);
        for column in 0..area.width {
            let on = (start..start + i32::from(run)).contains(&i32::from(column));
            put(buffer, area.x + column, y, if on { '▰' } else { '▱' }, if on { palette::text() } else { palette::muted() });
        }
        return;
    };
    let _ = level;
    let played = cells(played);
    let chosen = bar.chosen.map_or(played, cells);
    let (blue, gray) = (played.min(chosen), played.max(chosen));
    // The head: the point being chosen or caught up with, else the playhead,
    // once anything has played.
    let mark = if bar.chosen.is_some() { chosen } else { played };
    let head = (bar.chosen.is_some() || played > 0).then(|| mark.saturating_sub(1).min(area.width - 1));
    let glint = (heard % 40) as i64;
    for column in 0..area.width {
        let x = area.x + column;
        if head == Some(column) {
            put(buffer, x, y, '●', palette::white());
        } else if column >= gray {
            put(buffer, x, y, '▱', palette::muted());
        } else if column >= blue {
            put(buffer, x, y, '▰', palette::muted());
        } else if (i64::from(column) - glint).rem_euclid(40) < 2 {
            put(buffer, x, y, '▰', palette::accent_light(0.7));
        } else {
            put(buffer, x, y, '▰', palette::accent());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A square wave at a pitch, like a SID pulse voice.
    fn tone(hertz: f32, level: f32) -> Vec<f32> {
        (0..2048)
            .map(|n| if (n as f32 * hertz / SAMPLE_RATE).fract() < 0.5 { level } else { -level })
            .collect()
    }

    fn spark(a: u64, b: u64) -> f32 {
        let x = ((a as f64) * 12.9898 + (b as f64) * 78.233).sin() * 43_758.545_3;
        (x - x.floor()) as f32
    }

    fn noise(level: f32) -> Vec<f32> {
        (0..2048).map(|n| (spark(n, 1) * 2.0 - 1.0) * level).collect()
    }

    #[test]
    fn hears_the_pitch_of_a_note() {
        for (hertz, expected) in [(440.0, 69.0), (65.41, 36.0), (1046.5, 84.0)] {
            let (_, note, noisy) = listen(&tone(hertz, 0.8));
            assert!(!noisy);
            let note = note.unwrap();
            assert!((note - expected).abs() < 0.5, "{hertz} Hz heard as {note}");
        }
    }

    #[test]
    fn tells_noise_and_silence_from_notes() {
        assert!(listen(&noise(0.8)).2);
        assert_eq!(listen(&vec![0.0; 1024]), (0.0, None, false));
        assert_eq!(listen(&[]), (0.0, None, false));
    }

    #[test]
    fn a_note_too_low_for_the_window_has_no_pitch_but_still_has_a_level() {
        let (peak, note, _) = listen(&tone(15.0, 0.8));
        assert_eq!(note, None);
        assert!(peak > 0.7);
    }

    #[test]
    fn names_notes_as_trackers_do() {
        assert_eq!(note_name(60.0), "C-4");
        assert_eq!(note_name(69.2), "A-4");
        assert_eq!(note_name(61.0), "C#4");
    }

    #[test]
    fn levels_are_against_the_loudest_lately() {
        let mut quiet = Ears::default();
        quiet.hear(&[tone(440.0, 0.1), tone(440.0, 0.05), vec![0.0; 8]]);
        let now = quiet.latest();
        assert!((now[0].level - 1.0).abs() < 1e-4);
        assert!((now[1].level - 0.5).abs() < 1e-3);
        assert_eq!(now[2].level, 0.0);
    }

    fn known(played: f64) -> Bar {
        Bar { played: Some(played), chosen: None, sweep: 0.0 }
    }

    #[test]
    fn the_bar_draws_in_any_size_with_nothing_heard() {
        for (w, h) in [(0, 0), (1, 1), (4, 1), (80, 2), (3, 40)] {
            let area = Rect::new(0, 0, w, h);
            progress(&mut Buffer::empty(area), area, known(0.5), 0.5, 0);
            progress(&mut Buffer::empty(area), area, Bar { played: None, chosen: None, sweep: 0.5 }, 0.5, 0);
        }
    }

    #[test]
    fn a_chosen_point_fills_in_gray_up_to_it() {
        let area = Rect::new(0, 0, 10, 1);
        let mut buffer = Buffer::empty(area);
        progress(&mut buffer, area, Bar { played: Some(0.2), chosen: Some(0.6), sweep: 0.0 }, 1.0, 20);
        assert_eq!(buffer[(1, 0)].fg, palette::accent());
        assert_eq!(buffer[(4, 0)].fg, palette::muted());
        assert_eq!(buffer[(4, 0)].symbol(), "▰");
        assert_eq!(buffer[(5, 0)].symbol(), "●", "the point being chosen");
        assert_eq!(buffer[(6, 0)].symbol(), "▱");
    }

    #[test]
    fn an_unknown_length_sweeps_a_short_run() {
        let area = Rect::new(0, 0, 30, 1);
        let mut buffer = Buffer::empty(area);
        progress(&mut buffer, area, Bar { played: None, chosen: None, sweep: 0.5 }, 0.0, 0);
        let filled = (0..30).filter(|&x| buffer[(x, 0)].symbol() == "▰").count();
        assert_eq!(filled, 5);
        assert_eq!(buffer[(0, 0)].symbol(), "▱");
    }

    #[test]
    fn the_bar_shows_played_and_what_is_left() {
        let area = Rect::new(0, 0, 20, 1);
        let mut buffer = Buffer::empty(area);
        progress(&mut buffer, area, known(0.45), 1.0, 0);
        assert_eq!(buffer[(0, 0)].symbol(), "▰");
        assert_eq!(buffer[(7, 0)].symbol(), "▰");
        assert_eq!(buffer[(8, 0)].symbol(), "●", "the playhead");
        assert_eq!(buffer[(8, 0)].fg, palette::white());
        assert_eq!(buffer[(9, 0)].symbol(), "▱");
        progress(&mut buffer, area, known(1.0), 1.0, 0);
        assert_eq!(buffer[(19, 0)].symbol(), "●");
        progress(&mut buffer, area, known(0.0), 1.0, 0);
        assert_eq!(buffer[(0, 0)].symbol(), "▱");
    }

    #[test]
    fn both_palettes_cover_every_voice_and_level() {
        for voice in 0..3 {
            for level in 0..5 {
                assert!(matches!(ink(voice, level, true), Color::Rgb(..)));
                assert!(matches!(ink(voice, level, false), Color::Indexed(_)));
            }
        }
    }
}
