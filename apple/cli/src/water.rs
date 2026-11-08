//! A pool seen from above, simulated with the wave equation and drawn with half blocks.
//! Every new note drops into its voice's part of the pool, low notes making wide
//! ripples and high notes tight ones; noise falls as rain, and big hits make a splash.
//! Waves pass through each other, so each voice keeps a field of its own, added up to
//! draw: that also tells how much of each voice is in any ripple, for its colors.

use crate::viz::{self, VoiceReading};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::Color;
use std::time::{Duration, Instant};

const STEP: Duration = Duration::from_millis(33);
const MOST_STEPS_AT_ONCE: u32 = 3;
/// Wave steps in each frame, for the speed the ripples spread at.
const SUBSTEPS: usize = 2;
/// Must stay under 0.5 for the simulation to be stable.
const WAVE_SPEED: f32 = 0.25;
/// What a wave keeps of itself each substep: gone in about 5 seconds, so that busy
/// music still shows single ripples and not just a choppy sea.
const DAMPING: f32 = 0.98;
const SILENT: f32 = 0.06;
const NEW_NOTE: f32 = 0.5;
const LOUDER_BY: f32 = 0.25;
const WIDEST_DROP: f32 = 7.0;
const TIGHTEST_DROP: f32 = 1.6;
const LOWEST_NOTE: f32 = 24.0;
const HIGHEST_NOTE: f32 = 96.0;
/// As for the Tesla coils, a jump of this much is a big hit.
const SPLASH_JUMP: f32 = 1.4;
const MOST_DROPS_WAITING: usize = 64;
/// From the slope of the water to how much light it catches.
const SHINE: f32 = 3.0;
/// Steps of light either way. Rounding means still water doesn't change from frame to
/// frame, so nothing needs sending to the terminal.
const LIGHT_STEPS: f32 = 12.0;

const DEEP: (f32, f32, f32) = (6.0, 26.0, 48.0);
const SHADOW: (f32, f32, f32) = (2.0, 10.0, 24.0);
const LIT: (f32, f32, f32) = (30.0, 120.0, 170.0);
const GLINT: (f32, f32, f32) = (222.0, 245.0, 255.0);
const CHANNELS: [(f32, f32, f32); 3] = [(94.0, 234.0, 212.0), (244.0, 114.0, 208.0), (255.0, 138.0, 112.0)];
const WATER_256: [u8; 11] = [16, 17, 18, 24, 31, 38, 45, 87, 123, 159, 231];

fn blend(a: (f32, f32, f32), b: (f32, f32, f32), t: f32) -> (f32, f32, f32) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

/// The color for an amount of light, -1 to 1, on water of this color when lit.
fn water_rgb(light: f32, lit: (f32, f32, f32)) -> (f32, f32, f32) {
    if light <= 0.0 {
        blend(DEEP, SHADOW, -light)
    } else if light < 0.6 {
        blend(DEEP, lit, light / 0.6)
    } else {
        blend(lit, GLINT, (light - 0.6) / 0.4)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Drop {
    voice: usize,
    x: f32,
    y: f32,
    radius: f32,
    strength: f32,
}

#[derive(Default)]
struct Field {
    now: Vec<f32>,
    before: Vec<f32>,
    next: Vec<f32>,
}

pub struct Water {
    width: usize,
    height: usize,
    fields: [Field; 3],
    waiting: Vec<Drop>,
    last: [VoiceReading; 3],
    last_total: f32,
    random: u32,
    last_step: Option<Instant>,
}

impl Default for Water {
    fn default() -> Water {
        Water {
            width: 0,
            height: 0,
            fields: Default::default(),
            waiting: Vec::new(),
            last: [VoiceReading::default(); 3],
            last_total: 0.0,
            random: 0x7A3C_91E5,
            last_step: None,
        }
    }
}

impl Water {
    fn chance(&mut self) -> f32 {
        let mut x = self.random;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.random = x;
        (x >> 8) as f32 / (1u32 << 24) as f32
    }

    /// Somewhere in a voice's part of the pool, which runs off into its neighbors'.
    fn place(&mut self, voice: usize) -> (f32, f32) {
        let center = (voice as f32 * 2.0 + 1.0) / 6.0;
        let spread = (self.chance() + self.chance() - 1.0) * 0.26;
        ((center + spread) * self.width as f32, self.chance() * self.height as f32)
    }

    fn drop_in(&mut self, voice: usize, radius: f32, strength: f32) {
        if self.waiting.len() >= MOST_DROPS_WAITING {
            self.waiting.remove(0);
        }
        let (x, y) = self.place(voice);
        self.waiting.push(Drop { voice, x, y, radius, strength });
    }

    /// One reading of the voices.
    pub fn hear(&mut self, reading: [VoiceReading; 3]) {
        for (voice, heard) in reading.into_iter().enumerate() {
            let before = self.last[voice];
            if heard.level < SILENT {
                continue;
            }
            if heard.noisy {
                for _ in 0..(heard.level * 4.0) as usize + 1 {
                    let strength = 0.15 + heard.level * 0.2;
                    self.drop_in(voice, TIGHTEST_DROP, strength);
                }
                continue;
            }
            let changed = match (before.note, heard.note) {
                (Some(was), Some(now)) => (was - now).abs() > NEW_NOTE,
                (None, _) => true,
                _ => false,
            };
            if changed || heard.level - before.level > LOUDER_BY {
                let pitch = heard.note.map_or(0.0, |note| ((note - LOWEST_NOTE) / (HIGHEST_NOTE - LOWEST_NOTE)).clamp(0.0, 1.0));
                let radius = WIDEST_DROP + (TIGHTEST_DROP - WIDEST_DROP) * pitch;
                self.drop_in(voice, radius, 0.25 + heard.level * 0.45);
            }
        }
        let total: f32 = reading.iter().map(|voice| voice.level).sum();
        if total - self.last_total > SPLASH_JUMP {
            let loudest = (0..3).fold(0, |best, v| if reading[v].level > reading[best].level { v } else { best });
            self.drop_in(loudest, WIDEST_DROP * 1.5, 1.2);
        }
        self.last_total = total;
        self.last = reading;
    }

    /// Run on to now, for a grid of this many columns and half-rows.
    pub fn advance(&mut self, now: Instant, width: u16, rows: u16) {
        let (width, height) = (width as usize, rows as usize * 2);
        if width != self.width || height != self.height {
            self.width = width;
            self.height = height;
            for field in &mut self.fields {
                field.now = vec![0.0; width * height];
                field.before = vec![0.0; width * height];
                field.next = vec![0.0; width * height];
            }
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

    fn splash(&mut self, drop: Drop) {
        let (w, h) = (self.width as i32, self.height as i32);
        let reach = (drop.radius * 2.5).ceil() as i32;
        let field = &mut self.fields[drop.voice];
        for y in (drop.y as i32 - reach).max(0)..(drop.y as i32 + reach + 1).min(h) {
            for x in (drop.x as i32 - reach).max(0)..(drop.x as i32 + reach + 1).min(w) {
                let (dx, dy) = (x as f32 - drop.x, y as f32 - drop.y);
                let push = drop.strength * (-(dx * dx + dy * dy) / (drop.radius * drop.radius)).exp();
                let at = (y * w + x) as usize;
                // In both, so it falls in at rest.
                field.now[at] -= push;
                field.before[at] -= push;
            }
        }
    }

    fn step(&mut self) {
        let (w, h) = (self.width, self.height);
        if w == 0 || h == 0 {
            return;
        }
        for drop in std::mem::take(&mut self.waiting) {
            self.splash(drop);
        }
        for _ in 0..SUBSTEPS {
            for field in &mut self.fields {
                for y in 0..h {
                    // Beyond the edge is the edge again: waves bounce off the sides.
                    let up = if y == 0 { 0 } else { y - 1 };
                    let down = (y + 1).min(h - 1);
                    for x in 0..w {
                        let (left, right) = (x.saturating_sub(1), (x + 1).min(w - 1));
                        let here = field.now[y * w + x];
                        let around = field.now[y * w + left]
                            + field.now[y * w + right]
                            + field.now[up * w + x]
                            + field.now[down * w + x];
                        let moved = 2.0 * here - field.before[y * w + x] + WAVE_SPEED * (around - 4.0 * here);
                        field.next[y * w + x] = moved * DAMPING;
                    }
                }
                std::mem::swap(&mut field.before, &mut field.now);
                std::mem::swap(&mut field.now, &mut field.next);
            }
        }
    }

    #[inline]
    fn height_at(&self, at: usize) -> f32 {
        self.fields[0].now[at] + self.fields[1].now[at] + self.fields[2].now[at]
    }

    /// The light on the water here, from its slope, in rounded steps.
    fn light(&self, x: usize, y: usize) -> f32 {
        let (w, h) = (self.width, self.height);
        let across = self.height_at(y * w + (x + 1).min(w - 1)) - self.height_at(y * w + x.saturating_sub(1));
        let along = self.height_at((y + 1).min(h - 1) * w + x) - self.height_at(y.saturating_sub(1) * w + x);
        let light = ((across * 0.6 + along * 0.8) * SHINE).clamp(-1.0, 1.0);
        (light * LIGHT_STEPS).round() / LIGHT_STEPS
    }

    fn color(&self, x: usize, y: usize, truecolor: bool, channels: bool) -> Color {
        let light = self.light(x, y);
        let at = y * self.width + x;
        if !truecolor {
            if channels && light > 0.1 {
                let voice = (0..3).fold(0, |best, v| {
                    if self.fields[v].now[at].abs() > self.fields[best].now[at].abs() {
                        v
                    } else {
                        best
                    }
                });
                return viz::ink(voice, (light * 5.0) as usize, false);
            }
            let step = (light + 1.0) / 2.0 * (WATER_256.len() - 1) as f32;
            return Color::Indexed(WATER_256[(step as usize).min(WATER_256.len() - 1)]);
        }
        let lit = if channels {
            let parts = [self.fields[0].now[at].abs(), self.fields[1].now[at].abs(), self.fields[2].now[at].abs()];
            let total = (parts[0] + parts[1] + parts[2]).max(1e-5);
            let mix = |pick: fn(&(f32, f32, f32)) -> f32| (0..3).map(|v| pick(&CHANNELS[v]) * parts[v] / total).sum::<f32>();
            let color = (mix(|c| c.0), mix(|c| c.1), mix(|c| c.2));
            // Rounded too, so that a ripple's color doesn't shimmer in every cell.
            ((color.0 / 16.0).round() * 16.0, (color.1 / 16.0).round() * 16.0, (color.2 / 16.0).round() * 16.0)
        } else {
            LIT
        };
        let (r, g, b) = water_rgb(light, lit);
        Color::Rgb(r as u8, g as u8, b as u8)
    }

    /// The pool, filling an area of the size last given to `advance`: in water's colors,
    /// or with `channels` in those of the voices making each ripple.
    pub fn draw(&self, buffer: &mut Buffer, area: Rect, truecolor: bool, channels: bool) {
        if self.width != area.width as usize || self.height != area.height as usize * 2 {
            return;
        }
        for row in 0..area.height as usize {
            for column in 0..self.width {
                let Some(cell) = buffer.cell_mut((area.x + column as u16, area.y + row as u16)) else { continue };
                cell.set_char('▀')
                    .set_fg(self.color(column, row * 2, truecolor, channels))
                    .set_bg(self.color(column, row * 2 + 1, truecolor, channels));
            }
        }
    }

    #[cfg(test)]
    fn energy(&self, from: usize, to: usize) -> f32 {
        (0..self.height).map(|y| (from..to).map(|x| self.height_at(y * self.width + x).abs()).sum::<f32>()).sum()
    }

    #[cfg(test)]
    fn run(&mut self, steps: usize) {
        (0..steps).for_each(|_| self.step());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pool() -> Water {
        let mut water = Water::default();
        water.advance(Instant::now(), 120, 30);
        water
    }

    fn note(note: f32, level: f32) -> VoiceReading {
        VoiceReading { level, note: Some(note), noisy: false }
    }

    const REST: VoiceReading = VoiceReading { level: 0.0, note: None, noisy: false };

    fn dropped(water: &mut Water, voice: usize, radius: f32) {
        water.waiting.clear();
        water.waiting.push(Drop { voice, x: 60.0, y: 30.0, radius, strength: 1.0 });
    }

    #[test]
    fn still_water_stays_still_and_all_one_color() {
        let mut water = pool();
        water.run(30);
        assert_eq!(water.energy(0, 120), 0.0);
        let first = water.color(0, 0, true, false);
        assert!((0..60).all(|y| (0..120).all(|x| water.color(x, y, true, false) == first)));
    }

    #[test]
    fn a_ripple_spreads_outward_and_fades() {
        let mut water = pool();
        dropped(&mut water, 0, 3.0);
        water.run(1);
        let at_ring = |water: &Water| water.height_at(30 * 120 + 75).abs();
        assert!(at_ring(&water) < 0.001, "it hasn't got that far yet");
        let mut furthest = 0.0_f32;
        for _ in 0..25 {
            water.step();
            furthest = furthest.max(at_ring(&water));
        }
        assert!(furthest > 0.01, "the ring never arrived: {furthest}");
        let early = water.energy(0, 120);
        water.run(600);
        assert!(water.energy(0, 120) < early * 0.05);
    }

    #[test]
    fn it_never_blows_up_under_the_heaviest_rain() {
        let mut water = pool();
        for _ in 0..600 {
            water.hear([note(40.0, 1.0), REST, VoiceReading { level: 1.0, note: None, noisy: true }]);
            water.hear([note(90.0, 0.2), REST, REST]);
            water.step();
        }
        let most = water.fields.iter().flat_map(|f| f.now.iter()).fold(0.0_f32, |most, h| most.max(h.abs()));
        assert!(most.is_finite() && most < 60.0, "{most}");
    }

    #[test]
    fn waves_bounce_off_the_edges() {
        let mut water = pool();
        water.waiting.push(Drop { voice: 0, x: 2.0, y: 30.0, radius: 3.0, strength: 1.0 });
        water.run(5);
        // Nothing is lost at the wall, so the pool still holds it soon after.
        assert!(water.energy(0, 120) > 1.0);
    }

    #[test]
    fn low_notes_make_wide_ripples_and_high_notes_tight_ones() {
        let radius = |pitch| {
            let mut water = pool();
            water.hear([note(pitch, 0.8), REST, REST]);
            water.waiting[0].radius
        };
        assert!(radius(30.0) > radius(90.0) * 2.0);
    }

    #[test]
    fn each_voice_drops_into_its_own_part() {
        let side = |voice| {
            let mut water = pool();
            for _ in 0..200 {
                let x = water.place(voice).0;
                assert!((-40.0..=160.0).contains(&x));
                water.waiting.push(Drop { voice, x, y: 30.0, radius: 2.0, strength: 0.1 });
                water.step();
            }
            (water.energy(0, 40), water.energy(80, 120))
        };
        let (left, right) = side(0);
        assert!(left > right * 1.5, "voice 1: left {left} right {right}");
        let (left, right) = side(2);
        assert!(right > left * 1.5, "voice 3: left {left} right {right}");
    }

    #[test]
    fn only_a_new_note_drops_in() {
        let mut water = pool();
        water.hear([note(60.0, 0.8), REST, REST]);
        assert_eq!(water.waiting.len(), 1);
        water.waiting.clear();
        water.hear([note(60.0, 0.8), REST, REST]);
        assert!(water.waiting.is_empty(), "a held note fell again");
        water.hear([note(67.0, 0.8), REST, REST]);
        assert_eq!(water.waiting.len(), 1);
    }

    #[test]
    fn noise_falls_as_rain_and_a_big_hit_makes_a_splash() {
        let mut water = pool();
        water.hear([VoiceReading { level: 0.9, note: None, noisy: true }, REST, REST]);
        assert!(water.waiting.len() > 2);
        assert!(water.waiting.iter().all(|d| d.radius == TIGHTEST_DROP));
        let mut water = pool();
        water.hear([note(60.0, 1.0), note(40.0, 1.0), note(70.0, 1.0)]);
        assert!(water.waiting.iter().any(|d| d.radius > WIDEST_DROP));
    }

    #[test]
    fn drops_waiting_while_hidden_are_limited() {
        let mut water = pool();
        for n in 0..500 {
            water.hear([note(40.0 + (n % 40) as f32, 0.9), REST, REST]);
        }
        assert!(water.waiting.len() <= MOST_DROPS_WAITING);
    }

    #[test]
    fn ripples_catch_the_light_with_highlights_and_shade() {
        let mut water = pool();
        dropped(&mut water, 0, 3.0);
        water.run(8);
        let lights: Vec<f32> = (0..60).flat_map(|y| (0..120).map(move |x| (x, y))).map(|(x, y)| water.light(x, y)).collect();
        assert!(lights.iter().any(|l| *l > 0.3));
        assert!(lights.iter().any(|l| *l < -0.3));
    }

    #[test]
    fn channel_colors_follow_the_voice_in_the_ripple() {
        let mut water = pool();
        dropped(&mut water, 2, 3.0);
        water.run(8);
        let brightest = (0..60)
            .flat_map(|y| (0..120).map(move |x| (x, y)))
            .max_by(|a, b| water.light(a.0, a.1).total_cmp(&water.light(b.0, b.1)))
            .unwrap();
        let Color::Rgb(r, g, b) = water.color(brightest.0, brightest.1, true, true) else { panic!() };
        assert!(r > b, "voice 3 should look coral, not blue: {r} {g} {b}");
        let Color::Rgb(r, _, b) = water.color(brightest.0, brightest.1, true, false) else { panic!() };
        assert!(b > r, "plain water should be blue: {r} {b}");
    }

    #[test]
    fn any_size_and_a_new_size_are_fine() {
        let start = Instant::now();
        let mut water = Water::default();
        for (n, (w, h)) in [(0, 0), (1, 1), (5, 3), (3, 200), (200, 1), (0, 20), (80, 24)].into_iter().enumerate() {
            water.hear([note(40.0 + n as f32, 1.0), note(80.0, 1.0), VoiceReading { level: 0.8, note: None, noisy: true }]);
            water.advance(start + STEP * (n as u32 * 2 + 1), w, h);
            let area = Rect::new(0, 0, w, h);
            let mut buffer = Buffer::empty(area);
            water.draw(&mut buffer, area, n % 2 == 0, n % 3 == 0);
        }
    }

    /// `cargo test --release -p resonance-cli water_time -- --ignored --nocapture`
    #[test]
    #[ignore = "a measurement, for release builds"]
    fn water_time() {
        for (w, h) in [(195, 36), (200, 60), (300, 80)] {
            let mut water = Water::default();
            water.advance(Instant::now(), w, h);
            let began = Instant::now();
            for n in 0..120 {
                water.hear([note(40.0 + (n % 30) as f32, 0.9), note(30.0, 0.8), VoiceReading { level: 0.8, note: None, noisy: true }]);
                water.step();
            }
            println!("{w}x{h}: {:.2} ms a step", began.elapsed().as_secs_f64() * 1000.0 / 120.0);
        }
    }

    /// `cargo test -p resonance-cli show_water -- --ignored --nocapture`, its shape as text.
    #[test]
    #[ignore = "prints the water's light to look at"]
    fn show_water() {
        let mut water = Water::default();
        water.advance(Instant::now(), 120, 28);
        for n in 0..90 {
            water.hear([note(60.0 + (n / 3 % 4) as f32 * 7.0, 0.8), note(36.0 + (n / 16 % 3) as f32 * 5.0, 0.8), REST]);
            water.step();
        }
        for row in (0..56).step_by(2) {
            let line: String = (0..120)
                .map(|x| match water.light(x, row) {
                    l if l > 0.6 => '#',
                    l if l > 0.25 => '+',
                    l if l > 0.05 => '.',
                    l if l < -0.25 => '=',
                    l if l < -0.05 => '-',
                    _ => ' ',
                })
                .collect();
            println!("{line}");
        }
    }
}
