//! What the terminal app hears of the music, from the voices' samples: each reading
//! becomes a level and an estimated pitch. The visuals and the voices' notes go by
//! these, and the progress bar's head pulses with the level.

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

/// A voice's colour: `level` 0 is darkest, 4 brightest.
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

/// A slim bar in the header's grays: a fine line for what's left, a heavier one for
/// what's played with a glint running along it, and a bright tail to a head that
/// pulses with the music's level.
pub fn progress(buffer: &mut Buffer, area: Rect, ratio: f64, level: f32, heard: u64) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let head = (f64::from(area.width - 1) * ratio.clamp(0.0, 1.0)).round() as u16;
    let glint = (heard % 40) as i64;
    let y = area.y;
    for column in 0..area.width {
        let x = area.x + column;
        if column > head {
            put(buffer, x, y, '─', Color::Indexed(238));
        } else if column == head {
            let ch = if level > 0.66 {
                '█'
            } else if level > 0.33 {
                '▓'
            } else {
                '▒'
            };
            put(buffer, x, y, ch, Color::Indexed(231));
        } else {
            let color = match head - column {
                1 => 254,
                2 => 251,
                3 => 248,
                4 => 246,
                _ if (i64::from(column) - glint).rem_euclid(40) < 2 => 250,
                _ => 243,
            };
            put(buffer, x, y, '━', Color::Indexed(color));
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

    #[test]
    fn the_bar_draws_in_any_size_with_nothing_heard() {
        for (w, h) in [(0, 0), (1, 1), (4, 1), (80, 2), (3, 40)] {
            let area = Rect::new(0, 0, w, h);
            progress(&mut Buffer::empty(area), area, 0.5, 0.5, 0);
        }
    }

    #[test]
    fn the_bar_shows_played_a_head_and_what_is_left() {
        let area = Rect::new(0, 0, 21, 1);
        let mut buffer = Buffer::empty(area);
        progress(&mut buffer, area, 0.5, 1.0, 0);
        assert_eq!(buffer[(0, 0)].symbol(), "━");
        assert_eq!(buffer[(10, 0)].symbol(), "█");
        assert_eq!(buffer[(20, 0)].symbol(), "─");
        progress(&mut buffer, area, 0.5, 0.1, 0);
        assert_eq!(buffer[(10, 0)].symbol(), "▒", "a quiet moment dims the head");
        progress(&mut buffer, area, 1.0, 1.0, 0);
        assert_eq!(buffer[(20, 0)].symbol(), "█");
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
