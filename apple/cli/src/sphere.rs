//! The app's Particle sphere, in half blocks (Resonance/Shaders/Particles.metal and
//! ParticleSphere.swift, whose formulas and timings these follow). Points spread over a
//! turning sphere, a third per voice: a voice's points ripple with its level at a rate
//! set by its note, noise jitters them, and each new note sends a wave across the sphere
//! from that voice's pole. Nearer points are brighter, and light adds up where they meet.
//!
//! The app knows when a note starts; here it's inferred from the sound, so a wave can
//! come a little late, and a fast repeat of the same note can bring none.

use crate::viz::{self, VoiceReading};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::Color;
use std::time::{Duration, Instant};

const STEP: Duration = Duration::from_millis(33);
const MOST_STEPS_AT_ONCE: u32 = 3;
const POINTS: usize = 24_000;
/// Where each voice's waves start from, a third of the way round.
const POLES: [(f32, f32, f32); 3] = [(0.0, 1.0, 0.0), (0.87, -0.5, 0.0), (-0.87, -0.5, 0.0)];
/// How long things take to settle, in seconds, as in the app.
const LEVEL_SETTLES: f32 = 0.075;
const RIPPLE_GLIDES: f32 = 0.25;
const POINT_EASES: f32 = 0.08;
/// A voice that's stopped being heard, as the app's silent voices do.
const RESTING_LEVEL: f32 = 0.02;
/// What a heard level keeps per step until the next reading says otherwise.
const FADING: f32 = 0.9;
const NEW_NOTE: f32 = 0.5;
const LOUDER_BY: f32 = 0.25;
/// Of the shorter side, in half-rows: bigger than in the app, as a terminal has less room.
const RADIUS: f32 = 0.42;
const CAMERA: f32 = 3.4;
/// How bright the sphere is overall, whatever the window's size.
const EXPOSURE: f32 = 1.7;
const DRAWN_ABOVE: f32 = 0.05;
const SOFTNESS: f32 = 1.1;
const VOICE_RGB: [(f32, f32, f32); 3] = [(94.0, 234.0, 212.0), (244.0, 114.0, 208.0), (255.0, 138.0, 112.0)];

#[derive(Debug, Clone, Copy)]
struct Point {
    x: f32,
    y: f32,
    z: f32,
    latitude: f32,
    from_pole: f32,
    seed: f32,
    voice: u8,
}

pub struct Sphere {
    width: usize,
    height: usize,
    points: Vec<Point>,
    offsets: Vec<f32>,
    /// A voice's light in each half-row cell.
    light: Vec<[f32; 3]>,
    targets: [f32; 3],
    levels: [f32; 3],
    frequencies: [f32; 3],
    hits: [f32; 3],
    noisy: [bool; 3],
    last: [VoiceReading; 3],
    time: f32,
    frame: u32,
    last_step: Option<Instant>,
}

fn hash(a: f32, b: f32) -> f32 {
    let x = (a * 12.9898 + b * 78.233).sin() * 43_758.547;
    x - x.floor()
}

/// A Fibonacci sphere: evenly spread points, dealt to the voices in turn.
fn make_points() -> Vec<Point> {
    let golden = std::f32::consts::PI * (3.0 - 5.0_f32.sqrt());
    (0..POINTS)
        .map(|i| {
            let y = 1.0 - i as f32 / (POINTS - 1) as f32 * 2.0;
            let r = (1.0 - y * y).max(0.0).sqrt();
            let theta = golden * i as f32;
            let (x, z) = (theta.cos() * r, theta.sin() * r);
            let voice = i % 3;
            let (px, py, pz) = POLES[voice];
            let from_pole = (x * px + y * py + z * pz).clamp(-1.0, 1.0).acos();
            Point { x, y, z, latitude: y.asin(), from_pole, seed: hash(i as f32, 7.0), voice: voice as u8 }
        })
        .collect()
}

impl Default for Sphere {
    fn default() -> Sphere {
        Sphere {
            width: 0,
            height: 0,
            points: make_points(),
            offsets: vec![0.0; POINTS],
            light: Vec::new(),
            targets: [RESTING_LEVEL; 3],
            levels: [RESTING_LEVEL; 3],
            frequencies: [3.0; 3],
            hits: [-9.0; 3],
            noisy: [false; 3],
            last: [VoiceReading::default(); 3],
            time: 0.0,
            frame: 0,
            last_step: None,
        }
    }
}

impl Sphere {
    /// One reading of the voices.
    pub fn hear(&mut self, reading: [VoiceReading; 3]) {
        for (voice, heard) in reading.into_iter().enumerate() {
            let before = self.last[voice];
            self.targets[voice] = heard.level.max(RESTING_LEVEL);
            self.noisy[voice] = heard.noisy;
            let changed = match (before.note, heard.note) {
                (Some(was), Some(now)) => (was - now).abs() > NEW_NOTE,
                (None, Some(_)) => true,
                _ => false,
            };
            if heard.level > RESTING_LEVEL && (changed || heard.level - before.level > LOUDER_BY) {
                self.hits[voice] = self.time;
            }
            if let Some(note) = heard.note {
                let wanted = 2.0 + (note - 30.0) / 9.0;
                let glide = 1.0 - (-STEP.as_secs_f32() * 2.0 / RIPPLE_GLIDES).exp();
                self.frequencies[voice] += (wanted - self.frequencies[voice]) * glide;
            }
        }
        self.last = reading;
    }

    /// Run on to now, for a grid of this many columns and half-rows.
    pub fn advance(&mut self, now: Instant, width: u16, rows: u16) {
        let (width, height) = (width as usize, rows as usize * 2);
        if width != self.width || height != self.height {
            self.width = width;
            self.height = height;
            self.light = vec![[0.0; 3]; width * height];
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

    /// How far a point should sit off the unit sphere right now.
    fn displacement(&self, point: &Point) -> f32 {
        let voice = usize::from(point.voice);
        let level = self.levels[voice];
        let since = self.time - self.hits[voice];
        let rate = 1.5 + voice as f32 * 0.7;
        let mut d = level * 0.12 * (self.frequencies[voice] * point.latitude * 3.0 + self.time * rate).sin();
        if self.noisy[voice] {
            d += level * (hash((self.frame % 997) as f32, point.seed * 1000.0) - 0.5) * 0.25;
        }
        let wave = point.from_pole - since * 2.4;
        d + (-(wave * wave) / 0.035).exp() * 0.32 * (-since * 1.4).exp()
    }

    fn step(&mut self) {
        let dt = STEP.as_secs_f32();
        self.time += dt;
        self.frame = self.frame.wrapping_add(1);
        let follow = 1.0 - (-dt / LEVEL_SETTLES).exp();
        for voice in 0..3 {
            self.levels[voice] += (self.targets[voice] - self.levels[voice]) * follow;
            self.targets[voice] = (self.targets[voice] * FADING).max(RESTING_LEVEL);
        }
        let ease = 1.0 - (-dt / POINT_EASES).exp();
        for n in 0..POINTS {
            let target = self.displacement(&self.points[n]);
            self.offsets[n] += (target - self.offsets[n]) * ease;
        }
        self.expose();
    }

    /// Turn the sphere, and add each point's light to the cells around where it lands.
    fn expose(&mut self) {
        let (w, h) = (self.width, self.height);
        if w < 2 || h < 2 {
            return;
        }
        self.light.iter_mut().for_each(|cell| *cell = [0.0; 3]);
        let radius = (w.min(h) as f32 * RADIUS).max(1.0);
        let (spin, lean) = (self.time * 0.22, 0.38 + (self.time * 0.3).sin() * 0.08);
        let (cy, sy, cx, sx) = (spin.cos(), spin.sin(), lean.cos(), lean.sin());
        let camera = radius * CAMERA;
        let (mid_x, mid_y) = (w as f32 / 2.0, h as f32 / 2.0);
        // Evenly bright in any window: a bigger sphere has the same points over more cells.
        let gain = std::f32::consts::PI * radius * radius / POINTS as f32 * EXPOSURE;
        for (point, offset) in self.points.iter().zip(&self.offsets) {
            let size = radius * (1.0 + offset);
            let (qx, qy, qz) = (point.x * size, point.y * size, point.z * size);
            let (x1, z1) = (qx * cy + qz * sy, -qx * sy + qz * cy);
            let (y2, z2) = (qy * cx - z1 * sx, qy * sx + z1 * cx);
            let scale = camera / (camera + z2);
            let (px, py) = (mid_x + x1 * scale - 0.5, mid_y + y2 * scale - 0.5);
            if px < 0.0 || py < 0.0 || px >= (w - 1) as f32 || py >= (h - 1) as f32 {
                continue;
            }
            let voice = usize::from(point.voice);
            let depth = (1.0 - z2 / radius) * 0.5;
            let alpha = (0.12 + depth * 0.55 + self.levels[voice] * 0.45 * depth).clamp(0.06, 1.0) * gain;
            // Shared between the four nearest cells, so points glide and don't hop.
            let (x0, y0) = (px as usize, py as usize);
            let (fx, fy) = (px - x0 as f32, py - y0 as f32);
            self.light[y0 * w + x0][voice] += alpha * (1.0 - fx) * (1.0 - fy);
            self.light[y0 * w + x0 + 1][voice] += alpha * fx * (1.0 - fy);
            self.light[(y0 + 1) * w + x0][voice] += alpha * (1.0 - fx) * fy;
            self.light[(y0 + 1) * w + x0 + 1][voice] += alpha * fx * fy;
        }
    }

    fn color(&self, at: usize, truecolor: bool) -> Color {
        let light = self.light[at];
        let total = light[0] + light[1] + light[2];
        if total < DRAWN_ABOVE {
            return Color::Reset;
        }
        if !truecolor {
            let voice = (0..3).fold(0, |best, v| if light[v] > light[best] { v } else { best });
            return viz::ink(voice, (total * 4.0) as usize, false);
        }
        // Light builds up softly, so the rim, where the most points overlap, keeps the
        // voices' colours and doesn't burn out to white.
        let soft = (1.0 - (-total * SOFTNESS).exp()) / total;
        // Rounded, so that fewer cells change from frame to frame.
        let channel = |pick: fn(&(f32, f32, f32)) -> f32| {
            let value: f32 = (0..3).map(|v| pick(&VOICE_RGB[v]) * light[v] * soft).sum();
            ((value / 16.0).round() * 16.0).min(255.0) as u8
        };
        Color::Rgb(channel(|c| c.0), channel(|c| c.1), channel(|c| c.2))
    }

    /// The sphere, filling an area of the size last given to `advance`.
    pub fn draw(&self, buffer: &mut Buffer, area: Rect, truecolor: bool) {
        if self.width != area.width as usize || self.height != area.height as usize * 2 {
            return;
        }
        for row in 0..area.height as usize {
            for column in 0..self.width {
                let upper = self.color(row * 2 * self.width + column, truecolor);
                let lower = self.color((row * 2 + 1) * self.width + column, truecolor);
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
    }

    #[cfg(test)]
    fn run(&mut self, steps: usize) {
        (0..steps).for_each(|_| self.step());
    }

    #[cfg(test)]
    fn lit_cells(&self) -> usize {
        self.light.iter().filter(|cell| cell[0] + cell[1] + cell[2] >= DRAWN_ABOVE).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sphere(width: u16, rows: u16) -> Sphere {
        let mut sphere = Sphere::default();
        sphere.advance(Instant::now(), width, rows);
        sphere
    }

    fn note(note: f32, level: f32) -> VoiceReading {
        VoiceReading { level, note: Some(note), noisy: false }
    }

    const REST: VoiceReading = VoiceReading { level: 0.0, note: None, noisy: false };

    #[test]
    fn the_points_cover_the_sphere_evenly_and_are_shared_by_the_voices() {
        let points = make_points();
        assert_eq!(points.len(), POINTS);
        for point in &points {
            let length = (point.x * point.x + point.y * point.y + point.z * point.z).sqrt();
            assert!((length - 1.0).abs() < 1e-3);
        }
        let upper = points.iter().filter(|p| p.y > 0.0).count() as f32 / POINTS as f32;
        assert!((upper - 0.5).abs() < 0.01);
        assert_eq!(points.iter().filter(|p| p.voice == 2).count(), POINTS / 3);
    }

    #[test]
    fn it_is_a_round_ball_in_the_middle_with_nothing_in_the_corners() {
        let mut sphere = sphere(120, 30);
        sphere.run(5);
        let lit = |x: usize, y: usize| {
            let cell = sphere.light[y * 120 + x];
            cell[0] + cell[1] + cell[2] >= DRAWN_ABOVE
        };
        assert!(lit(60, 30));
        for corner in [(0, 0), (119, 0), (0, 59), (119, 59)] {
            assert!(!lit(corner.0, corner.1));
        }
        // As wide as it's tall, within a little for the turn and perspective.
        let across = (0..120).filter(|x| lit(*x, 30)).count() as f32;
        let down = (0..60).filter(|y| lit(60, *y)).count() as f32;
        assert!((across / down - 1.0).abs() < 0.15, "across {across} down {down}");
    }

    #[test]
    fn the_near_side_is_brighter_than_the_far_side() {
        let sphere = Sphere::default();
        let alpha = |z2: f32| {
            let depth = (1.0 - z2) * 0.5;
            (0.12 + depth * 0.55 + sphere.levels[0] * 0.45 * depth).clamp(0.06, 1.0)
        };
        assert!(alpha(-1.0) > alpha(1.0) * 3.0);
    }

    #[test]
    fn a_new_note_sends_a_wave_from_the_voices_pole_and_a_held_note_does_not() {
        let mut sphere = sphere(120, 30);
        sphere.run(30);
        sphere.hear([note(60.0, 0.8), REST, REST]);
        let hit = sphere.hits[0];
        assert_eq!(hit, sphere.time);
        sphere.run(5);
        sphere.hear([note(60.0, 0.8), REST, REST]);
        assert_eq!(sphere.hits[0], hit, "a held note set off another wave");
        sphere.hear([note(67.0, 0.8), REST, REST]);
        assert!(sphere.hits[0] > hit);
    }

    #[test]
    fn the_wave_travels_away_from_the_pole() {
        let mut sphere = sphere(120, 30);
        sphere.run(5);
        sphere.levels = [0.0; 3];
        sphere.hits[0] = sphere.time;
        let at = |angle: f32, sphere: &Sphere| {
            let point = Point { x: 0.0, y: 1.0, z: 0.0, latitude: 0.0, from_pole: angle, seed: 0.0, voice: 0 };
            sphere.displacement(&point)
        };
        assert!(at(0.0, &sphere) > 0.2);
        assert!(at(1.5, &sphere) < 0.01);
        sphere.time += 1.5 / 2.4;
        assert!(at(1.5, &sphere) > 0.08);
        assert!(at(0.0, &sphere) < 0.01);
    }

    #[test]
    fn louder_voices_ripple_further() {
        let spread = |level: f32| {
            let mut sphere = sphere(120, 30);
            for _ in 0..30 {
                sphere.hear([note(60.0, level), REST, REST]);
                sphere.step();
            }
            sphere.hits = [-9.0; 3];
            sphere.run(1);
            sphere.points.iter().filter(|p| p.voice == 0).map(|p| sphere.displacement(p).abs()).sum::<f32>()
        };
        assert!(spread(1.0) > spread(0.1) * 3.0);
    }

    #[test]
    fn higher_notes_ripple_faster_and_glide_there() {
        let mut sphere = sphere(120, 30);
        let start = sphere.frequencies[0];
        sphere.hear([note(84.0, 0.8), REST, REST]);
        let first = sphere.frequencies[0];
        assert!(first > start);
        assert!(first < 2.0 + (84.0 - 30.0) / 9.0, "it should glide, not jump");
        for _ in 0..60 {
            sphere.hear([note(84.0, 0.8), REST, REST]);
        }
        assert!((sphere.frequencies[0] - 8.0).abs() < 0.05);
    }

    #[test]
    fn noise_jitters_only_its_own_voice() {
        let mut sphere = sphere(120, 30);
        sphere.hear([VoiceReading { level: 0.9, note: None, noisy: true }, note(60.0, 0.9), REST]);
        sphere.levels = [0.9, 0.9, 0.0];
        sphere.hits = [-9.0; 3];
        let moved_between_frames = |sphere: &mut Sphere, voice: u8| {
            let point = *sphere.points.iter().find(|p| p.voice == voice).unwrap();
            let first = sphere.displacement(&point);
            sphere.frame += 1;
            (sphere.displacement(&point) - first).abs()
        };
        let noisy: f32 = (0..20).map(|_| moved_between_frames(&mut sphere, 0)).sum();
        let tuned: f32 = (0..20).map(|_| moved_between_frames(&mut sphere, 1)).sum();
        assert!(noisy > 0.1);
        assert_eq!(tuned, 0.0);
    }

    #[test]
    fn without_sound_it_settles_to_a_quiet_ball_and_keeps_turning() {
        let mut sphere = sphere(120, 30);
        for _ in 0..30 {
            sphere.hear([note(60.0, 1.0); 3]);
            sphere.step();
        }
        sphere.run(120);
        assert!(sphere.levels.iter().all(|level| *level < 0.05));
        assert!(sphere.lit_cells() > 500, "the ball should stay visible");
        let before = sphere.light.clone();
        sphere.run(5);
        assert_ne!(sphere.light, before);
    }

    #[test]
    fn a_bigger_window_is_about_as_bright() {
        let average = |width: u16, rows: u16| {
            let mut sphere = sphere(width, rows);
            sphere.run(3);
            let lit: Vec<f32> = sphere.light.iter().map(|c| c[0] + c[1] + c[2]).filter(|l| *l > 0.0).collect();
            lit.iter().sum::<f32>() / lit.len() as f32
        };
        let (small, big) = (average(80, 20), average(240, 70));
        assert!((small / big - 1.0).abs() < 0.3, "small {small} big {big}");
    }

    #[test]
    fn colours_add_up_where_voices_meet() {
        let mut sphere = sphere(10, 5);
        sphere.light[0] = [0.5, 0.0, 0.0];
        sphere.light[1] = [0.5, 0.5, 0.0];
        sphere.light[2] = [0.0, 0.0, 0.0];
        assert!(matches!(sphere.color(0, true), Color::Rgb(..)));
        assert_ne!(sphere.color(0, true), sphere.color(1, true));
        assert_eq!(sphere.color(2, true), Color::Reset);
        assert!(matches!(sphere.color(1, false), Color::Indexed(_)));
    }

    #[test]
    fn the_brightest_rim_keeps_its_voices_colour() {
        let mut sphere = sphere(10, 5);
        sphere.light[0] = [30.0, 0.0, 0.0];
        let Color::Rgb(r, g, b) = sphere.color(0, true) else { panic!() };
        assert!(g > r + 80 && b > r + 60, "voice 1 should stay teal: {r} {g} {b}");
    }

    #[test]
    fn any_size_and_a_new_size_are_fine() {
        let start = Instant::now();
        let mut sphere = Sphere::default();
        for (n, (w, h)) in [(0, 0), (1, 1), (2, 1), (3, 200), (200, 1), (0, 20), (80, 24), (10, 2)].into_iter().enumerate() {
            sphere.hear([note(60.0 + n as f32, 1.0), note(40.0, 0.5), VoiceReading { level: 0.8, note: None, noisy: true }]);
            sphere.advance(start + STEP * (n as u32 * 2 + 1), w, h);
            let area = Rect::new(0, 0, w, h);
            let mut buffer = Buffer::empty(area);
            sphere.draw(&mut buffer, area, n % 2 == 0);
        }
    }

    #[test]
    fn a_stale_grid_draws_nothing_rather_than_the_wrong_shape() {
        let sphere = sphere(50, 10);
        let area = Rect::new(0, 0, 80, 24);
        let mut buffer = Buffer::empty(area);
        sphere.draw(&mut buffer, area, true);
        assert!(buffer.content.iter().all(|cell| cell.symbol() == " "));
    }

    /// `cargo test --release -p resonance-cli sphere_time -- --ignored --nocapture`
    #[test]
    #[ignore = "a measurement, for release builds"]
    fn sphere_time() {
        for (w, h) in [(195, 36), (200, 60), (300, 80)] {
            let mut sphere = sphere(w, h);
            let began = Instant::now();
            for n in 0..120 {
                sphere.hear([note(50.0 + (n % 12) as f32, 0.9), note(36.0, 0.8), VoiceReading { level: 0.8, note: None, noisy: true }]);
                sphere.step();
            }
            println!("{w}x{h}: {:.2} ms a step", began.elapsed().as_secs_f64() * 1000.0 / 120.0);
        }
    }

    /// `cargo test -p resonance-cli show_sphere -- --ignored --nocapture`, its light as text.
    #[test]
    #[ignore = "prints the sphere's light to look at"]
    fn show_sphere() {
        let mut sphere = Sphere::default();
        sphere.advance(Instant::now(), 110, 30);
        for n in 0..60 {
            sphere.hear([note(60.0 + (n / 3 % 4) as f32 * 7.0, 0.9), note(40.0, 0.8), VoiceReading { level: 0.7, note: None, noisy: true }]);
            sphere.step();
        }
        for row in sphere.light.chunks(110).step_by(2) {
            let line: String = row
                .iter()
                .map(|cell| match ((cell[0] + cell[1] + cell[2]) * 7.0) as usize {
                    0 => ' ',
                    1 => '.',
                    2 => ':',
                    3 => '-',
                    4 => '=',
                    5 => '+',
                    6 => '*',
                    7 => '#',
                    _ => '@',
                })
                .collect();
            println!("{}", line.trim_end());
        }
    }
}
