//! A Tesla coil for each voice, drawn with half blocks. A voice's pitch sets how high
//! its lightning strikes and its level how bright and branched that is; noise crackles
//! as short sparks; and a sudden jump in level fires a discharge across all three.

use crate::viz::{self, VoiceReading};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::Color;
use std::time::{Duration, Instant};

const STEP: Duration = Duration::from_millis(33);
const MOST_STEPS_AT_ONCE: u32 = 3;
/// The range of notes that reach from the coil to the top of the screen: C1 to C7.
const LOWEST_NOTE: f32 = 24.0;
const HIGHEST_NOTE: f32 = 96.0;
/// Below this a voice's coil is resting.
const AWAKE: f32 = 0.06;
const DRAWN_ABOVE: f32 = 0.08;
/// How much of the last frame's light stays: a little, for a glow on the eye.
const AFTERGLOW: f32 = 0.5;
const AFTERGLOW_AFTER_A_HIT: f32 = 0.78;
/// A jump in the voices' summed level big enough for a discharge. On Lightforce one
/// reading in ten jumped by 1.38 or more, so this keeps discharges to about one or two
/// a second: events, and not a constant wall of light over the notes.
const DISCHARGE_JUMP: f32 = 1.4;
const COIL_ROWS: usize = 5;
const COIL: Color = Color::Indexed(245);

pub struct Tesla {
    width: usize,
    height: usize,
    light: Vec<f32>,
    owner: Vec<u8>,
    voices: [VoiceReading; 3],
    surge: f32,
    discharge: bool,
    last_total: f32,
    random: u32,
    last_step: Option<Instant>,
    path: Vec<(f32, f32)>,
}

impl Default for Tesla {
    fn default() -> Tesla {
        Tesla {
            width: 0,
            height: 0,
            light: Vec::new(),
            owner: Vec::new(),
            voices: [VoiceReading::default(); 3],
            surge: 0.0,
            discharge: false,
            last_total: 0.0,
            random: 0x51F1_5E2D,
            last_step: None,
            path: Vec::new(),
        }
    }
}

impl Tesla {
    fn chance(&mut self) -> f32 {
        let mut x = self.random;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.random = x;
        (x >> 8) as f32 / (1u32 << 24) as f32
    }

    /// One reading of the voices.
    pub fn hear(&mut self, reading: [VoiceReading; 3]) {
        let total: f32 = reading.iter().map(|voice| voice.level).sum();
        let jump = (total - self.last_total).max(0.0);
        self.last_total = total;
        self.surge = self.surge.max((jump / 1.5).min(1.0));
        if jump > DISCHARGE_JUMP {
            self.discharge = true;
        }
        for (voice, heard) in self.voices.iter_mut().zip(reading) {
            let level = voice.level.max(heard.level);
            *voice = VoiceReading { level, note: heard.note.or(voice.note), noisy: heard.noisy };
        }
    }

    /// Run on to now, for a grid of this many columns and half-rows.
    pub fn advance(&mut self, now: Instant, width: u16, rows: u16) {
        let (width, height) = (width as usize, rows as usize * 2);
        if width != self.width || height != self.height {
            self.width = width;
            self.height = height;
            self.light = vec![0.0; width * height];
            self.owner = vec![0; width * height];
        }
        let Some(last) = self.last_step else {
            self.last_step = Some(now);
            self.step();
            return;
        };
        let steps = (now.duration_since(last).as_secs_f32() / STEP.as_secs_f32()) as u32;
        for _ in 0..steps.min(MOST_STEPS_AT_ONCE) {
            self.step();
        }
        if steps > 0 {
            self.last_step = Some(now);
        }
    }

    /// The top of a voice's coil, in the grid.
    fn coil_tip(&self, voice: usize) -> (f32, f32) {
        let x = (voice as f32 * 2.0 + 1.0) / 6.0 * self.width as f32;
        (x, self.height as f32 - (COIL_ROWS * 2) as f32)
    }

    fn lay(&mut self, x: f32, y: f32, light: f32, voice: usize) {
        if x < 0.0 || y < 0.0 {
            return;
        }
        let (x, y) = (x as usize, y as usize);
        if x < self.width && y < self.height {
            let at = y * self.width + x;
            if light >= self.light[at] {
                self.light[at] = light;
                self.owner[at] = voice as u8;
            }
        }
    }

    /// A jagged path between two points, by repeatedly knocking midpoints sideways.
    fn jag(&mut self, from: (f32, f32), to: (f32, f32), rough: f32) {
        let mut path = std::mem::take(&mut self.path);
        path.clear();
        path.push(from);
        path.push(to);
        let length = ((to.0 - from.0).powi(2) + (to.1 - from.1).powi(2)).sqrt();
        let mut reach = length * rough;
        while reach > 0.7 && path.len() < 512 {
            let mut finer = Vec::with_capacity(path.len() * 2);
            for pair in path.windows(2) {
                let (a, b) = (pair[0], pair[1]);
                let (dx, dy) = (b.0 - a.0, b.1 - a.1);
                let across = (dx * dx + dy * dy).sqrt().max(1e-3);
                let knock = (self.chance() - 0.5) * 2.0 * reach;
                finer.push(a);
                finer.push(((a.0 + b.0) / 2.0 - dy / across * knock, (a.1 + b.1) / 2.0 + dx / across * knock));
            }
            finer.push(*path.last().unwrap_or(&to));
            path = finer;
            reach *= 0.55;
        }
        self.path = path;
    }

    /// The last jagged path, in light.
    fn stroke(&mut self, light: f32, thick: bool, voice: usize) {
        let path = std::mem::take(&mut self.path);
        for pair in path.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            let steps = (b.0 - a.0).abs().max((b.1 - a.1).abs()).ceil().max(1.0) as usize;
            for n in 0..=steps {
                let t = n as f32 / steps as f32;
                let (x, y) = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t);
                self.lay(x, y, light, voice);
                if thick {
                    self.lay(x + 1.0, y, light * 0.55, voice);
                    self.lay(x - 1.0, y, light * 0.55, voice);
                }
            }
        }
        self.path = path;
    }

    fn bolt(&mut self, from: (f32, f32), to: (f32, f32), level: f32, voice: usize) {
        self.jag(from, to, 0.24);
        self.stroke((0.5 + level * 0.5).min(1.0), level > 0.6, voice);
        // Branches fork off the path and fade; louder voices have more of them.
        let forks = (level * 4.0) as usize;
        let points = self.path.clone();
        for _ in 0..forks {
            if points.len() < 3 {
                break;
            }
            let start = points[(self.chance() * (points.len() - 1) as f32) as usize];
            let length = (to.1 - from.1).abs().max(8.0) * (0.15 + self.chance() * 0.25);
            let side = if self.chance() < 0.5 { -1.0 } else { 1.0 };
            let up = if to.1 < from.1 { -1.0 } else { 1.0 };
            let end = (start.0 + side * length * (0.5 + self.chance()), start.1 + up * length * self.chance());
            self.jag(start, end, 0.28);
            self.stroke(0.25 + level * 0.3, false, voice);
        }
    }

    fn crackle(&mut self, voice: usize, level: f32) {
        let tip = self.coil_tip(voice);
        let sparks = (level * 12.0) as usize + 1;
        let span = self.height as f32 * 0.32;
        for _ in 0..sparks {
            let start = (tip.0 + (self.chance() - 0.5) * 7.0, tip.1 - self.chance() * 4.0);
            let far = span * (0.2 + self.chance() * 0.8);
            let end = (start.0 + (self.chance() - 0.5) * far * 1.6, start.1 - self.chance() * far);
            self.jag(start, end, 0.34);
            self.stroke(0.3 + level * 0.6, false, voice);
        }
    }

    fn step(&mut self) {
        if self.width == 0 || self.height < COIL_ROWS * 2 + 2 {
            return;
        }
        let keep = if self.surge > 0.25 { AFTERGLOW_AFTER_A_HIT } else { AFTERGLOW };
        for light in &mut self.light {
            *light *= keep;
        }
        let top = self.height as f32;
        for voice in 0..3 {
            let heard = self.voices[voice];
            if heard.level < AWAKE {
                continue;
            }
            let tip = self.coil_tip(voice);
            if heard.noisy {
                self.crackle(voice, heard.level);
                continue;
            }
            let pitch = heard.note.map_or(0.05, |note| ((note - LOWEST_NOTE) / (HIGHEST_NOTE - LOWEST_NOTE)).clamp(0.05, 1.0));
            let height = (tip.1 - 1.0) * pitch;
            let wander = (self.chance() - 0.5) * height * 0.75;
            self.bolt(tip, (tip.0 + wander, tip.1 - height), heard.level, voice);
            if heard.level > 0.75 && self.chance() < 0.5 {
                let wander = (self.chance() - 0.5) * height * 0.9;
                self.bolt(tip, (tip.0 + wander, tip.1 - height * 0.8), heard.level * 0.6, voice);
            }
            // The glowing ball on top of the coil, as big as the voice is loud.
            let radius = 1.0 + heard.level * 2.5;
            for dy in -3..=3 {
                for dx in -4..=4 {
                    let distance = ((dx * dx + dy * dy) as f32).sqrt();
                    if distance <= radius {
                        let glow = heard.level * (1.0 - distance / (radius + 1.0));
                        self.lay(tip.0 + dx as f32, tip.1 + dy as f32, glow, voice);
                    }
                }
            }
        }
        if self.discharge {
            self.discharge = false;
            let tips = [self.coil_tip(0), self.coil_tip(1), self.coil_tip(2)];
            let awake = |tesla: &Tesla, voice: usize| tesla.voices[voice].level >= AWAKE;
            for (voice, next) in [(0, 1), (1, 2)] {
                if awake(self, voice) && awake(self, next) {
                    self.bolt(tips[voice], tips[next], 1.0, voice);
                }
            }
            for (voice, tip) in tips.into_iter().enumerate() {
                if awake(self, voice) {
                    let wander = (self.chance() - 0.5) * top * 0.4;
                    self.bolt(tip, (tip.0 + wander, 0.0), 1.0, voice);
                }
            }
        }
        self.surge *= 0.82;
        for voice in &mut self.voices {
            voice.level *= 0.72;
        }
    }

    fn color(&self, at: usize, truecolor: bool) -> Color {
        let light = self.light[at];
        if light < DRAWN_ABOVE {
            return Color::Reset;
        }
        let level = if light > 0.82 {
            4
        } else if light > 0.55 {
            3
        } else if light > 0.3 {
            2
        } else if light > 0.16 {
            1
        } else {
            0
        };
        viz::ink(usize::from(self.owner[at]), level, truecolor)
    }

    /// The coils and their lightning, filling an area of the size last given to `advance`.
    pub fn draw(&self, buffer: &mut Buffer, area: Rect, truecolor: bool) {
        if self.width != area.width as usize || self.height != area.height as usize * 2 {
            return;
        }
        for row in 0..area.height as usize {
            for column in 0..self.width {
                let (above, below) = (row * 2 * self.width + column, (row * 2 + 1) * self.width + column);
                let (upper, lower) = (self.color(above, truecolor), self.color(below, truecolor));
                if upper == Color::Reset && lower == Color::Reset {
                    continue;
                }
                let Some(cell) = buffer.cell_mut((area.x + column as u16, area.y + row as u16)) else { continue };
                if upper == Color::Reset {
                    cell.set_char('▄').set_fg(lower);
                } else {
                    cell.set_char('▀').set_fg(upper).set_bg(lower);
                }
            }
        }
        if self.height < COIL_ROWS * 2 + 2 {
            return;
        }
        // The coils stand in front: tapered towers, one for each voice.
        for voice in 0..3 {
            let x = self.coil_tip(voice).0 as i32;
            for up in 0..COIL_ROWS as i32 {
                let half = (COIL_ROWS as i32 - up) / 2;
                let y = area.y + area.height - 1 - up as u16;
                for dx in -half..=half {
                    let column = x + dx;
                    if column >= 0 && (column as usize) < self.width {
                        let ch = if up % 2 == 0 { '█' } else { '▓' };
                        if let Some(cell) = buffer.cell_mut((area.x + column as u16, y)) {
                            cell.set_char(ch).set_fg(COIL).set_bg(Color::Reset);
                        }
                    }
                }
            }
        }
    }

    #[cfg(test)]
    fn run(&mut self, steps: usize, reading: [VoiceReading; 3]) {
        for _ in 0..steps {
            self.hear(reading);
            self.step();
        }
    }

    /// How high a voice's light reaches above its coil, in half-rows.
    #[cfg(test)]
    fn reach(&self, voice: u8) -> usize {
        let top = self.light.chunks(self.width).enumerate().find_map(|(y, row)| {
            let owners = &self.owner[y * self.width..(y + 1) * self.width];
            row.iter().zip(owners).any(|(light, owner)| *light > 0.3 && *owner == voice).then_some(y)
        });
        top.map_or(0, |y| (self.height - COIL_ROWS * 2).saturating_sub(y))
    }

    #[cfg(test)]
    fn lit(&self, voice: u8) -> usize {
        self.light.iter().zip(&self.owner).filter(|(light, owner)| **light > DRAWN_ABOVE && **owner == voice).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tesla() -> Tesla {
        let mut tesla = Tesla::default();
        tesla.advance(Instant::now(), 120, 40);
        tesla
    }

    fn note(note: f32, level: f32) -> VoiceReading {
        VoiceReading { level, note: Some(note), noisy: false }
    }

    const REST: VoiceReading = VoiceReading { level: 0.0, note: None, noisy: false };

    /// The highest a voice reaches over a few steps, as bolts vary from one to the next.
    fn most_reach(reading: [VoiceReading; 3], voice: u8) -> usize {
        let mut tesla = tesla();
        // Past the first reading, which is a hit, and its discharge.
        tesla.run(20, reading);
        (0..30)
            .map(|_| {
                tesla.run(1, reading);
                tesla.reach(voice)
            })
            .max()
            .unwrap()
    }

    #[test]
    fn higher_notes_strike_higher() {
        let low = most_reach([note(36.0, 0.8), REST, REST], 0);
        let middle = most_reach([note(60.0, 0.8), REST, REST], 0);
        let high = most_reach([note(84.0, 0.8), REST, REST], 0);
        assert!(low < middle && middle < high, "{low} {middle} {high}");
    }

    #[test]
    fn louder_voices_are_more_branched() {
        let lit = |level| {
            let mut tesla = tesla();
            let mut total = 0;
            for _ in 0..40 {
                tesla.run(1, [note(72.0, level), REST, REST]);
                total += tesla.lit(0);
            }
            total
        };
        assert!(lit(1.0) > lit(0.2) * 2);
    }

    #[test]
    fn a_resting_voice_stays_dark_and_each_keeps_to_its_coil() {
        let mut tesla = tesla();
        tesla.run(30, [note(60.0, 0.9), REST, REST]);
        assert!(tesla.lit(0) > 0);
        assert_eq!(tesla.lit(1) + tesla.lit(2), 0);
        let mut tesla = self::tesla();
        tesla.run(30, [REST, REST, note(60.0, 0.9)]);
        let right: f32 = tesla.light.chunks(120).map(|row| row[80..].iter().sum::<f32>()).sum();
        let left: f32 = tesla.light.chunks(120).map(|row| row[..40].iter().sum::<f32>()).sum();
        assert!(right > left * 5.0, "right {right} left {left}");
    }

    #[test]
    fn noise_crackles_low_and_wide_rather_than_striking() {
        let noisy = VoiceReading { level: 0.9, note: None, noisy: true };
        let sparks = most_reach([noisy, REST, REST], 0);
        let tall = most_reach([note(90.0, 0.9), REST, REST], 0);
        assert!(sparks > 0);
        assert!(sparks < tall, "sparks {sparks} tall {tall}");
    }

    #[test]
    fn it_goes_dark_without_sound() {
        let mut tesla = tesla();
        tesla.run(30, [note(60.0, 0.9); 3]);
        for _ in 0..40 {
            tesla.step();
        }
        assert!(tesla.light.iter().all(|light| *light < DRAWN_ABOVE));
    }

    #[test]
    fn a_hit_discharges_across_the_coils_but_a_held_note_does_not() {
        let mut tesla = tesla();
        tesla.hear([note(40.0, 0.5); 3]);
        tesla.discharge = false;
        tesla.hear([note(40.0, 0.5); 3]);
        assert!(!tesla.discharge);
        tesla.hear([note(40.0, 1.0); 3]);
        assert!(tesla.discharge);
        tesla.step();
        assert!(!tesla.discharge);
        // Low notes barely leave the coils, so light at the top is the discharge's.
        let top: f32 = tesla.light[..120 * 8].iter().sum();
        assert!(top > 0.0);
    }

    #[test]
    fn a_note_too_low_to_name_still_makes_a_short_arc() {
        let reach = most_reach([VoiceReading { level: 0.9, note: None, noisy: false }, REST, REST], 0);
        assert!(reach > 0 && reach < 30, "{reach}");
    }

    #[test]
    fn any_size_and_a_new_size_are_fine() {
        let start = Instant::now();
        let mut tesla = Tesla::default();
        for (n, (w, h)) in [(0, 0), (1, 1), (5, 3), (3, 200), (200, 1), (0, 20), (80, 24), (10, 6), (10, 7)].into_iter().enumerate() {
            tesla.hear([note(70.0, 1.0), note(40.0, 0.5), VoiceReading { level: 0.8, note: None, noisy: true }]);
            tesla.advance(start + STEP * (n as u32 * 2 + 1), w, h);
            let area = Rect::new(0, 0, w, h);
            let mut buffer = Buffer::empty(area);
            tesla.draw(&mut buffer, area, n % 2 == 0);
        }
    }

    #[test]
    fn a_stale_grid_draws_nothing_rather_than_the_wrong_shape() {
        let tesla = tesla();
        let area = Rect::new(0, 0, 80, 24);
        let mut buffer = Buffer::empty(area);
        tesla.draw(&mut buffer, area, true);
        assert!(buffer.content.iter().all(|cell| cell.symbol() == " "));
    }

    /// `cargo test --release -p resonance-cli tesla_time -- --ignored --nocapture`
    #[test]
    #[ignore = "a measurement, for release builds"]
    fn tesla_time() {
        for (w, h) in [(132, 46), (200, 60), (300, 80)] {
            let mut tesla = Tesla::default();
            tesla.advance(Instant::now(), w, h);
            let began = Instant::now();
            for _ in 0..120 {
                tesla.run(1, [note(80.0, 1.0), note(40.0, 0.9), VoiceReading { level: 0.9, note: None, noisy: true }]);
            }
            println!("{w}x{h}: {:.2} ms a step", began.elapsed().as_secs_f64() * 1000.0 / 120.0);
        }
    }

    /// `cargo test -p resonance-cli show_tesla -- --ignored --nocapture`, its shape as text.
    #[test]
    #[ignore = "prints the lightning's shape to look at"]
    fn show_tesla() {
        let mut tesla = Tesla::default();
        tesla.advance(Instant::now(), 120, 30);
        tesla.run(10, [note(84.0, 0.95), note(45.0, 0.8), VoiceReading { level: 0.8, note: None, noisy: true }]);
        tesla.hear([note(84.0, 1.0), note(45.0, 1.0), note(70.0, 1.0)]);
        for row in tesla.light.chunks(120).step_by(2) {
            let line: String = row
                .iter()
                .map(|light| match (light * 5.0) as usize {
                    0 => ' ',
                    1 => '.',
                    2 => ':',
                    3 => '+',
                    _ => '#',
                })
                .collect();
            println!("{}", line.trim_end());
        }
    }
}
