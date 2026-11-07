//! Fire, simulated as heat rising through a grid twice as tall as the screen's rows,
//! drawn with half blocks. Each voice feeds its own part of the fire: its level sets
//! how hot that part burns, and sudden jumps in level throw the flames up and sparks
//! out. Without sound it dies down to nothing.

use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use crate::viz;
use ratatui::style::Color;
use std::time::{Duration, Instant};

const STEP: Duration = Duration::from_millis(33);
const MOST_STEPS_AT_ONCE: u32 = 3;
const MOST_EMBERS: usize = 90;
/// How many colours the heat is drawn in. Fewer colours means fewer cells changing
/// each frame, so less to send to the terminal.
const SHADES: usize = 28;
const NOISE_SIZE: usize = 64;

/// Heat to light: black through dull red and orange to yellow-white, as a flame glows.
const GLOW: [(f32, (u8, u8, u8)); 8] = [
    (0.0, (0, 0, 0)),
    (0.12, (36, 4, 2)),
    (0.26, (110, 14, 2)),
    (0.42, (196, 44, 4)),
    (0.58, (244, 98, 10)),
    (0.74, (255, 160, 28)),
    (0.88, (255, 220, 92)),
    (1.0, (255, 250, 214)),
];
/// The same glow where the terminal has only 256 colours.
const GLOW_256: [u8; 12] = [16, 52, 88, 124, 160, 196, 202, 208, 214, 220, 228, 230];

fn glow_rgb(heat: f32) -> (u8, u8, u8) {
    let heat = heat.clamp(0.0, 1.0);
    let upper = GLOW.iter().position(|(at, _)| *at >= heat).unwrap_or(GLOW.len() - 1).max(1);
    let (from, a) = GLOW[upper - 1];
    let (to, b) = GLOW[upper];
    let t = (heat - from) / (to - from);
    let mix = |x: u8, y: u8| (f32::from(x) + (f32::from(y) - f32::from(x)) * t) as u8;
    (mix(a.0, b.0), mix(a.1, b.1), mix(a.2, b.2))
}

/// The colour for a shade; 0 is no fire at all, so the terminal's own background.
fn shade_color(shade: usize, truecolor: bool) -> Color {
    if shade == 0 {
        return Color::Reset;
    }
    let heat = shade as f32 / (SHADES - 1) as f32;
    if truecolor {
        let (r, g, b) = glow_rgb(heat);
        Color::Rgb(r, g, b)
    } else {
        Color::Indexed(GLOW_256[((heat * GLOW_256.len() as f32) as usize).min(GLOW_256.len() - 1)])
    }
}

/// The voices' colours, for the view that shows which voice each flame came from.
const CHANNELS: [(f32, f32, f32); 3] = [(94.0, 234.0, 212.0), (244.0, 114.0, 208.0), (255.0, 138.0, 112.0)];

/// Each voice's share of a bit of flame, as a colour that's darker where it's cooler
/// and paler at the hottest. Rounded, so fewer cells change from frame to frame.
fn channel_color(shade: usize, share: [f32; 3], truecolor: bool) -> Color {
    if shade == 0 {
        return Color::Reset;
    }
    let heat = shade as f32 / (SHADES - 1) as f32;
    let total = (share[0] + share[1] + share[2]).max(1e-4);
    if !truecolor {
        let voice = (0..3).fold(0, |best, v| if share[v] > share[best] { v } else { best });
        return viz::ink(voice, (heat * 5.0) as usize, false);
    }
    let channel = |pick: fn(&(f32, f32, f32)) -> f32| {
        let colour: f32 = (0..3).map(|v| pick(&CHANNELS[v]) * share[v] / total).sum();
        let value = if heat < 0.6 { colour * (heat / 0.6) } else { colour + (255.0 - colour) * (heat - 0.6) / 0.4 * 0.7 };
        ((value / 12.0).round() * 12.0).min(255.0) as u8
    };
    Color::Rgb(channel(|c| c.0), channel(|c| c.1), channel(|c| c.2))
}

#[derive(Debug, Clone, Copy)]
struct Ember {
    x: f32,
    y: f32,
    drift: f32,
    rise: f32,
    life: f32,
}

pub struct Fire {
    width: usize,
    height: usize,
    heat: Vec<f32>,
    next: Vec<f32>,
    /// Each bit of flame's share from each voice, carried up along with its heat.
    shares: Vec<[f32; 3]>,
    next_shares: Vec<[f32; 3]>,
    noise: Vec<f32>,
    /// Each voice's level, jumping up with the sound and sinking slowly.
    voices: [f32; 3],
    /// A hit's push on the flames, fading fast.
    surge: f32,
    last_total: f32,
    embers: Vec<Ember>,
    random: u32,
    time: f32,
    last_step: Option<Instant>,
}

impl Default for Fire {
    fn default() -> Fire {
        let mut fire = Fire {
            width: 0,
            height: 0,
            heat: Vec::new(),
            next: Vec::new(),
            shares: Vec::new(),
            next_shares: Vec::new(),
            noise: Vec::new(),
            voices: [0.0; 3],
            surge: 0.0,
            last_total: 0.0,
            embers: Vec::new(),
            random: 0x2F6E_2B1D,
            time: 0.0,
            last_step: None,
        };
        fire.noise = (0..NOISE_SIZE * NOISE_SIZE).map(|_| fire.chance()).collect();
        fire
    }
}

impl Fire {
    /// A number from 0 up to 1.
    fn chance(&mut self) -> f32 {
        let mut x = self.random;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.random = x;
        (x >> 8) as f32 / (1u32 << 24) as f32
    }

    /// Smooth noise that tiles, for the shapes of tongues and the wind.
    #[inline]
    fn smooth(&self, x: f32, y: f32) -> f32 {
        let (fx, fy) = (x - x.floor(), y - y.floor());
        let (x0, y0) = (x.floor() as i32 as usize & (NOISE_SIZE - 1), y.floor() as i32 as usize & (NOISE_SIZE - 1));
        let (x1, y1) = ((x0 + 1) & (NOISE_SIZE - 1), (y0 + 1) & (NOISE_SIZE - 1));
        let (sx, sy) = (fx * fx * (3.0 - 2.0 * fx), fy * fy * (3.0 - 2.0 * fy));
        let at = |gx: usize, gy: usize| self.noise[gy * NOISE_SIZE + gx];
        let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * sx;
        let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * sx;
        top + (bottom - top) * sy
    }

    /// One reading of the voices' levels, 0–1.
    pub fn hear(&mut self, levels: [f32; 3]) {
        for (voice, level) in self.voices.iter_mut().zip(levels) {
            *voice = voice.max(level);
        }
        let total: f32 = levels.iter().sum();
        let jump = (total - self.last_total).max(0.0);
        self.last_total = total;
        self.surge = self.surge.max((jump / 1.5).min(1.0));
        let sparks = (jump * 8.0) as usize;
        for _ in 0..sparks {
            self.spark();
        }
    }

    fn spark(&mut self) {
        if self.embers.len() >= MOST_EMBERS || self.width == 0 {
            return;
        }
        let x = self.chance() * self.width as f32;
        let (drift, rise, life) = (self.chance() - 0.5, 1.6 + self.chance() * 2.2, 0.6 + self.chance() * 0.4);
        let y = self.height as f32 * (0.55 + self.chance() * 0.35);
        self.embers.push(Ember { x, y, drift, rise, life });
    }

    /// How hot this column's source burns from the voices near it, and each one's part.
    fn source(&self, x: usize) -> (f32, [f32; 3]) {
        let at = (x as f32 + 0.5) / self.width.max(1) as f32;
        let (mut heat, mut parts) = (0.0_f32, [0.0_f32; 3]);
        for (voice, level) in self.voices.iter().enumerate() {
            let centre = (voice as f32 * 2.0 + 1.0) / 6.0;
            let off = (at - centre) / 0.27;
            parts[voice] = level * (-off * off).exp();
            heat = heat.max(parts[voice]);
        }
        (heat, parts)
    }

    /// Run the fire on to now, for a grid of this many columns and half-rows.
    pub fn advance(&mut self, now: Instant, width: u16, rows: u16) {
        let (width, height) = (width as usize, rows as usize * 2);
        if width != self.width || height != self.height {
            self.width = width;
            self.height = height;
            self.heat = vec![0.0; width * height];
            self.next = vec![0.0; width * height];
            self.shares = vec![[0.0; 3]; width * height];
            self.next_shares = vec![[0.0; 3]; width * height];
            self.embers.clear();
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

    fn step(&mut self) {
        let (w, h) = (self.width, self.height);
        if w == 0 || h < 4 {
            return;
        }
        self.time += STEP.as_secs_f32();
        let time = self.time;
        for voice in &mut self.voices {
            *voice *= 0.93;
        }
        self.surge *= 0.86;
        let energy = (self.voices.iter().sum::<f32>() / 3.0).min(1.0);
        // How far a flame reaches before it has cooled away, as a share of the height.
        let reach = (0.28 + 0.5 * energy + 0.35 * self.surge) * h as f32;
        let cooling = 1.0 / reach;
        // Texture on a fixed scale in cells, so a bigger window has more flames.
        let (scale_x, scale_y) = (0.11, 0.07);
        let rise = 34.0 * time;

        // Each stretch of the fire has its own reach, drifting slowly: separate tongues.
        let tongues: Vec<f32> = (0..w)
            .map(|x| {
                let broad = self.smooth(x as f32 * 0.075 + time * 0.5, time * 1.3);
                let thin = self.smooth(x as f32 * 0.23 - time * 0.9 + 31.0, time * 2.7 + 9.0);
                let shape = broad * 0.65 + thin * 0.35;
                let shape = ((shape - 0.28) / 0.44).clamp(0.0, 1.0);
                // 0 cools fastest; the tallest tongues barely cool at all low down.
                3.4 - 3.0 * shape * shape * (3.0 - 2.0 * shape)
            })
            .collect();
        for y in 0..h - 2 {
            for x in 0..w {
                let (fy, fx) = (y as f32, x as f32);
                // Wind: the flames lean and swirl, more the higher they are.
                let height_up = 1.0 - fy / h as f32;
                let wind = (self.smooth(fx * 0.04 + time * 0.25, (fy + rise * 0.6) * 0.045) - 0.5) * (0.6 + 5.5 * height_up * height_up);
                let from = (x as i32 + wind.round() as i32).clamp(0, w as i32 - 1) as usize;
                let left = from.saturating_sub(1);
                let right = (from + 1).min(w - 1);
                let near = self.heat[(y + 1) * w + from];
                let far = self.heat[(y + 2) * w + from];
                let sides = self.heat[(y + 1) * w + left] + self.heat[(y + 1) * w + right];
                let lifted = near * 0.44 + far * 0.48 + sides * 0.04;
                // Fine patches that burn out faster fray the tongues' edges.
                let fray = self.smooth(fx * scale_x * 2.6 + 17.0, (fy + rise * 1.2) * scale_y * 2.6);
                let burn = cooling * tongues[from] * (0.45 + 1.1 * fray * fray);
                self.next[y * w + x] = (lifted - burn).max(0.0);
                let (a, b) = (self.shares[(y + 1) * w + from], self.shares[(y + 2) * w + from]);
                let (wa, wb) = (near + 1e-4, far + 1e-4);
                self.next_shares[y * w + x] = [
                    (a[0] * wa + b[0] * wb) / (wa + wb),
                    (a[1] * wa + b[1] * wb) / (wa + wb),
                    (a[2] * wa + b[2] * wb) / (wa + wb),
                ];
            }
        }
        // The bed the flames rise from, flickering.
        for x in 0..w {
            let (source, parts) = self.source(x);
            let flicker = 0.72 + 0.38 * self.smooth(x as f32 * 0.31, time * 9.0);
            let lit = (source * flicker * 1.5).min(1.0);
            for row in h - 2..h {
                let keep = self.heat[row * w + x] * 0.5;
                self.next[row * w + x] = lit.max(keep);
                self.next_shares[row * w + x] = parts;
            }
        }
        std::mem::swap(&mut self.heat, &mut self.next);
        std::mem::swap(&mut self.shares, &mut self.next_shares);

        let mut embers = std::mem::take(&mut self.embers);
        embers.retain_mut(|ember| {
            ember.y -= ember.rise;
            ember.x += ember.drift + (self.smooth(ember.x * 0.2, ember.y * 0.2) - 0.5) * 1.6;
            ember.life -= 0.022;
            ember.life > 0.0 && ember.y >= 0.0
        });
        for ember in &embers {
            let (x, y) = (ember.x.max(0.0) as usize, ember.y as usize);
            if x < w && y < h {
                let cell = &mut self.heat[y * w + x];
                *cell = cell.max(ember.life.min(0.95));
            }
        }
        self.embers = embers;
    }

    /// The fire so far, filling an area of the size last given to `advance`: in a
    /// flame's colours, or with `channels` in those of the voices it came from.
    pub fn draw(&self, buffer: &mut Buffer, area: Rect, truecolor: bool, channels: bool) {
        if self.width != area.width as usize || self.height != area.height as usize * 2 {
            return;
        }
        let shade = |heat: f32| ((heat * (SHADES - 1) as f32) as usize).min(SHADES - 1);
        let color = |shade: usize, at: usize| {
            if channels {
                channel_color(shade, self.shares[at], truecolor)
            } else {
                shade_color(shade, truecolor)
            }
        };
        for row in 0..area.height as usize {
            for column in 0..self.width {
                let (above, below) = (row * 2 * self.width + column, (row * 2 + 1) * self.width + column);
                let (upper, lower) = (shade(self.heat[above]), shade(self.heat[below]));
                if upper == 0 && lower == 0 {
                    continue;
                }
                let Some(cell) = buffer.cell_mut((area.x + column as u16, area.y + row as u16)) else { continue };
                if upper == 0 {
                    cell.set_char('▄').set_fg(color(lower, below));
                } else {
                    cell.set_char('▀').set_fg(color(upper, above)).set_bg(color(lower, below));
                }
            }
        }
    }

    /// The share of the grid that's alight, and how high the flames reach, 0–1.
    #[cfg(test)]
    fn measure(&self) -> (f32, f32) {
        let lit = self.heat.iter().filter(|h| **h > 0.12).count() as f32 / self.heat.len().max(1) as f32;
        let top = self.heat.chunks(self.width.max(1)).position(|row| row.iter().filter(|h| **h > 0.25).count() > self.width / 20);
        (lit, top.map_or(0.0, |y| 1.0 - y as f32 / self.height as f32))
    }

    #[cfg(test)]
    fn side_heat(&self, from: usize, to: usize) -> f32 {
        self.heat.chunks(self.width).map(|row| row[from..to].iter().sum::<f32>()).sum()
    }

    #[cfg(test)]
    fn run(&mut self, steps: usize, levels: [f32; 3]) {
        for _ in 0..steps {
            self.hear(levels);
            self.step();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fire(width: u16, rows: u16) -> Fire {
        let mut fire = Fire::default();
        fire.advance(Instant::now(), width, rows);
        fire
    }

    #[test]
    fn it_grows_with_the_sound_and_dies_without_it() {
        let mut quiet = fire(100, 30);
        quiet.run(150, [0.2, 0.2, 0.2]);
        let mut loud = fire(100, 30);
        loud.run(150, [1.0, 1.0, 1.0]);
        assert!(loud.measure().1 > quiet.measure().1, "loud {:?} quiet {:?}", loud.measure(), quiet.measure());
        assert!(loud.measure().0 > quiet.measure().0 * 1.5, "loud {:?} quiet {:?}", loud.measure(), quiet.measure());
        loud.run(0, [0.0; 3]);
        for _ in 0..400 {
            loud.step();
        }
        assert!(loud.measure().0 < 0.001, "still burning: {:?}", loud.measure());
    }

    #[test]
    fn it_looks_like_flames_and_not_a_flat_wall() {
        let mut fire = fire(100, 30);
        fire.run(150, [0.9, 0.9, 0.9]);
        let (lit, top) = fire.measure();
        assert!(lit > 0.1 && lit < 0.9, "lit {lit}");
        assert!(top > 0.2 && top < 1.0, "top {top}");
        // Halfway up, some columns burn and others don't.
        let row = &fire.heat[30 * 100..31 * 100];
        let burning = row.iter().filter(|h| **h > 0.2).count();
        assert!(burning > 3 && burning < 97, "{burning} of 100 alight at mid height");
    }

    #[test]
    fn it_is_hottest_at_the_bottom() {
        let mut fire = fire(100, 30);
        fire.run(150, [0.9, 0.9, 0.9]);
        let row_heat = |y: usize| fire.heat[y * 100..(y + 1) * 100].iter().sum::<f32>();
        assert!(row_heat(59) > row_heat(40));
        assert!(row_heat(40) > row_heat(10));
    }

    #[test]
    fn each_voice_feeds_its_own_part() {
        let mut fire = fire(90, 30);
        fire.run(100, [1.0, 0.0, 0.0]);
        assert!(fire.side_heat(0, 30) > fire.side_heat(60, 90) * 3.0);
        let mut fire = self::fire(90, 30);
        fire.run(100, [0.0, 0.0, 1.0]);
        assert!(fire.side_heat(60, 90) > fire.side_heat(0, 30) * 3.0);
    }

    /// The colour of the most flame in these columns, as the voice it's closest to.
    fn voice_of_flames(fire: &Fire, from: usize, to: usize) -> usize {
        let mut totals = [0.0_f32; 3];
        for (row, heats) in fire.heat.chunks(fire.width).enumerate() {
            for (x, heat) in heats.iter().enumerate().take(to).skip(from) {
                if *heat > 0.12 {
                    let share = fire.shares[row * fire.width + x];
                    (0..3).for_each(|v| totals[v] += share[v]);
                }
            }
        }
        (0..3).fold(0, |best, v| if totals[v] > totals[best] { v } else { best })
    }

    #[test]
    fn flames_carry_the_colour_of_the_voice_that_fed_them_as_they_rise() {
        let mut fire = fire(90, 30);
        fire.run(120, [1.0, 1.0, 1.0]);
        assert_eq!(voice_of_flames(&fire, 0, 25), 0);
        assert_eq!(voice_of_flames(&fire, 35, 55), 1);
        assert_eq!(voice_of_flames(&fire, 65, 90), 2);
    }

    #[test]
    fn channel_colours_are_the_voices_and_pale_when_hottest() {
        let warm = |share| channel_color(SHADES / 2, share, true);
        let Color::Rgb(r, g, b) = warm([1.0, 0.0, 0.0]) else { panic!() };
        assert!(g > r && b > r, "voice 1 should be teal: {r} {g} {b}");
        let Color::Rgb(r, g, b) = warm([0.0, 1.0, 0.0]) else { panic!() };
        assert!(r > g && b > g, "voice 2 should be magenta: {r} {g} {b}");
        let Color::Rgb(r, g, b) = warm([0.0, 0.0, 1.0]) else { panic!() };
        assert!(r > g && r > b, "voice 3 should be coral: {r} {g} {b}");
        let Color::Rgb(r, _, _) = channel_color(SHADES - 1, [1.0, 0.0, 0.0], true) else { panic!() };
        assert!(r > 150, "the hottest should turn pale, not stay pure");
        assert_eq!(channel_color(0, [1.0, 0.0, 0.0], true), Color::Reset);
        assert!(matches!(channel_color(10, [0.0, 1.0, 0.0], false), Color::Indexed(_)));
    }

    #[test]
    fn a_hit_throws_the_flames_up_and_sparks_out_but_a_held_note_does_not() {
        let mut fire = fire(100, 30);
        fire.run(100, [0.5, 0.5, 0.5]);
        fire.embers.clear();
        fire.surge = 0.0;
        fire.hear([0.5, 0.5, 0.5]);
        assert_eq!(fire.surge, 0.0);
        assert!(fire.embers.is_empty());
        fire.hear([1.0, 1.0, 1.0]);
        assert!(fire.surge > 0.9);
        assert!(!fire.embers.is_empty());
    }

    #[test]
    fn embers_are_limited_and_all_die() {
        let mut fire = fire(100, 30);
        for _ in 0..200 {
            fire.hear([1.0, 1.0, 1.0]);
            fire.hear([0.0, 0.0, 0.0]);
        }
        assert!(fire.embers.len() <= MOST_EMBERS);
        for _ in 0..200 {
            fire.step();
        }
        assert!(fire.embers.is_empty());
    }

    #[test]
    fn any_size_and_a_new_size_are_fine() {
        let start = Instant::now();
        let mut fire = Fire::default();
        for (n, (w, h)) in [(0, 0), (1, 1), (2, 1), (3, 200), (200, 1), (0, 20), (80, 24), (10, 2)].into_iter().enumerate() {
            fire.hear([1.0, 0.5, 0.2]);
            fire.advance(start + STEP * (n as u32 * 2 + 1), w, h);
            let area = Rect::new(0, 0, w, h);
            let mut buffer = Buffer::empty(area);
            fire.draw(&mut buffer, area, n % 2 == 0, n % 3 == 0);
        }
    }

    #[test]
    fn a_stale_grid_draws_nothing_rather_than_the_wrong_shape() {
        let fire = fire(50, 10);
        let area = Rect::new(0, 0, 80, 24);
        let mut buffer = Buffer::empty(area);
        fire.draw(&mut buffer, area, true, false);
        assert!(buffer.content.iter().all(|cell| cell.symbol() == " "));
    }

    #[test]
    fn the_glow_runs_from_black_to_near_white() {
        assert_eq!(glow_rgb(0.0), (0, 0, 0));
        let (r, g, b) = glow_rgb(1.0);
        assert!(r > 250 && g > 240 && b > 200);
        let (mid_r, mid_g, mid_b) = glow_rgb(0.5);
        assert!(mid_r > mid_g && mid_g > mid_b);
        assert_eq!(shade_color(0, true), Color::Reset);
        assert!(matches!(shade_color(SHADES - 1, true), Color::Rgb(..)));
        assert!(matches!(shade_color(SHADES - 1, false), Color::Indexed(_)));
    }

    /// `cargo test --release -p resonance-cli fire_time -- --ignored --nocapture`
    #[test]
    #[ignore = "a measurement, for release builds"]
    fn fire_time() {
        for (w, h) in [(132, 46), (200, 60), (300, 80)] {
            let mut fire = fire(w, h);
            let began = Instant::now();
            for _ in 0..120 {
                fire.hear([0.8, 0.6, 0.7]);
                fire.step();
            }
            println!("{w}x{h}: {:.2} ms a step", began.elapsed().as_secs_f64() * 1000.0 / 120.0);
        }
    }

    /// `cargo test -p resonance-cli show_fire -- --ignored --nocapture`, its shape as text.
    #[test]
    #[ignore = "prints the fire's shape to look at"]
    fn show_fire() {
        let mut fire = fire(110, 26);
        fire.run(150, [0.9, 0.7, 0.8]);
        for row in fire.heat.chunks(110).step_by(2) {
            let line: String = row
                .iter()
                .map(|h| match (h * 6.0) as usize {
                    0 => ' ',
                    1 => '.',
                    2 => ':',
                    3 => 'o',
                    4 => 'O',
                    _ => '@',
                })
                .collect();
            println!("{}", line.trim_end());
        }
    }
}
