//! The skull: `v` in the terminal app. A real 3D model, marched ray by ray for each
//! character and shaded in plain ASCII. Its eyes and jaw follow the voices, so all
//! of this is pure: levels in, a picture out, and no terminal needed to test it.
//!
//! The distance functions follow Inigo Quilez's articles on the technique:
//! https://iquilezles.org/articles/distfunctions/ and https://iquilezles.org/articles/smin/

use ratatui::style::Color;
use std::time::{Duration, Instant};

const RAMP: &[u8] = b".,:;i1tfLCG08@";
const BONE_RGB: [(u8, u8, u8); 6] =
    [(58, 66, 78), (90, 100, 114), (134, 144, 160), (180, 187, 198), (221, 225, 230), (255, 255, 255)];
const EYE_RGB: [(u8, u8, u8); 4] = [(143, 58, 43), (212, 95, 73), (255, 138, 112), (255, 224, 216)];
const BONE_256: [u8; 6] = [238, 241, 245, 249, 253, 231];
const EYE_256: [u8; 4] = [88, 167, 209, 224];

/// Frames never come faster than this, and slow down to leave the CPU half free.
const FASTEST_FRAME: Duration = Duration::from_millis(33);
const START_SPIN: f32 = 0.64;
const MOST_SPIN: f32 = 3.0;
const SPIN_STEP: f32 = 0.3;

/// How fast the eyes and jaw settle once the sound stops feeding them, in seconds.
const EYES_SETTLE: f32 = 0.18;
const JAW_SETTLE: f32 = 0.12;
/// Each hearing's share of the loudest level so far that's kept, about 20 a second:
/// it takes some 15 seconds to halve, so a quiet passage still looks quiet.
const LOUDEST_KEEPS: f32 = 0.9977;
/// Below this a voice is silence, not a very quiet tune to turn up.
const QUIETEST: f32 = 0.02;
/// A jump in the voices' summed level that opens the jaw all the way: about two of
/// the three voices starting at full level at once.
const FULL_CHOMP: f32 = 1.5;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Ink {
    Bone(u8),
    Eye(u8),
}

impl Ink {
    pub fn color(self, truecolor: bool) -> Color {
        let rgb = |(r, g, b): (u8, u8, u8)| Color::Rgb(r, g, b);
        match (self, truecolor) {
            (Ink::Bone(n), true) => rgb(BONE_RGB[n as usize]),
            (Ink::Eye(n), true) => rgb(EYE_RGB[n as usize]),
            (Ink::Bone(n), false) => Color::Indexed(BONE_256[n as usize]),
            (Ink::Eye(n), false) => Color::Indexed(EYE_256[n as usize]),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Glyph {
    pub ch: char,
    pub ink: Ink,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Picture {
    pub width: u16,
    pub height: u16,
    pub glyphs: Vec<Option<Glyph>>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pose {
    pub angle: f32,
    pub tilt: f32,
    /// 0 is closed, 1 wide open.
    pub jaw: f32,
    /// 0 is dark, 1 full glow.
    pub eyes: f32,
}

// MARK: The model

/// A signed distance to an ellipsoid, close enough to march by. Inigo Quilez's bound.
#[inline]
fn ellipsoid(x: f32, y: f32, z: f32, rx: f32, ry: f32, rz: f32) -> f32 {
    let (a, b, c) = (x / rx, y / ry, z / rz);
    let k0 = (a * a + b * b + c * c).sqrt();
    let (a2, b2, c2) = (a / rx, b / ry, c / rz);
    let k1 = (a2 * a2 + b2 * b2 + c2 * c2).sqrt();
    if k1 < 1e-6 {
        -rx.min(ry).min(rz)
    } else {
        k0 * (k0 - 1.0) / k1
    }
}

/// The nearer of two shapes, melted together where they meet: Inigo Quilez's
/// polynomial smooth minimum.
#[inline]
fn blend(a: f32, b: f32, k: f32) -> f32 {
    let h = (k - (a - b).abs()).max(0.0) / k;
    a.min(b) - h * h * k * 0.25
}

#[inline]
fn carve(a: f32, b: f32, k: f32) -> f32 {
    -blend(-a, b, k)
}

/// One row of teeth around an arc, from the nearest tooth only.
#[inline]
fn teeth(x: f32, y: f32, z: f32, radius: f32) -> f32 {
    if y.abs() > 0.4 {
        return y.abs() - 0.1;
    }
    const STEP: f32 = 0.27;
    let at = (x.atan2(z) / STEP).round().clamp(-4.0, 4.0) * STEP;
    ellipsoid(x - at.sin() * radius, y, z - at.cos() * radius, 0.062, 0.095, 0.05)
}

fn distance(x: f32, y: f32, z: f32, open: f32) -> f32 {
    let side = x.abs();
    let mut d = ellipsoid(x, y - 0.38, z + 0.12, 0.86, 0.78, 0.98); // Cranium.
    d = blend(d, ellipsoid(x, y + 0.12, z - 0.32, 0.6, 0.58, 0.52), 0.18); // Face.
    d = blend(d, ellipsoid(side - 0.47, y + 0.2, z - 0.44, 0.2, 0.14, 0.17), 0.1); // Cheekbones.
    d = blend(d, ellipsoid(side - 0.26, y - 0.2, z - 0.74, 0.26, 0.08, 0.12), 0.08); // Brow.
    d = blend(d, ellipsoid(x, y + 0.5, z - 0.46, 0.4, 0.2, 0.36), 0.08); // Upper jaw.
    d = carve(d, ellipsoid(side - 0.29, y - 0.02, z - 0.82, 0.22, 0.19, 0.28), 0.05); // Eye sockets.
    d = carve(d, ellipsoid(side - 0.04, y + 0.25, z - 0.9, 0.07, 0.15, 0.2), 0.03); // Nose.
    d = carve(d, ellipsoid(side - 0.9, y, z - 0.22, 0.22, 0.28, 0.32), 0.1); // Temples.
    d = d.min(teeth(x, y + 0.62, z - 0.42, 0.36));

    let (y, z) = (y + open, z - open * 0.4);
    let mut jaw = ellipsoid(x, y + 0.86, z - 0.42, 0.42, 0.16, 0.4);
    jaw = blend(jaw, ellipsoid(side - 0.48, y + 0.5, z - 0.15, 0.09, 0.32, 0.16), 0.08);
    jaw = carve(jaw, ellipsoid(x, y + 0.74, z - 0.38, 0.3, 0.14, 0.3), 0.05);
    jaw = jaw.min(teeth(x, y + 0.74, z - 0.42, 0.33));
    d.min(jaw)
}

// MARK: The picture

/// Everything around the skull fits inside a sphere this wide, so most rays stop early.
const BOUND: f32 = 1.75;
const CAMERA: f32 = 4.2;
/// The view's half-height at unit distance.
const VIEW: f32 = 0.42;
const MAX_STEPS: u32 = 26;
const SURFACE: f32 = 0.006;
/// A terminal cell's width over its height.
const CELL: f32 = 0.5;

pub fn render(pose: Pose, width: u16, height: u16) -> Picture {
    let (w, h) = (width as usize, height as usize);
    let mut glyphs = vec![None; w * h];
    if w == 0 || h == 0 {
        return Picture { width, height, glyphs };
    }
    let (ct, st) = (pose.angle.cos(), pose.angle.sin());
    let (cx, sx) = (pose.tilt.cos(), pose.tilt.sin());
    let turn = |x: f32, y: f32, z: f32| {
        let (x1, z1) = (x * ct + z * st, -x * st + z * ct);
        (x1, y * cx - z1 * sx, y * sx + z1 * cx)
    };
    let (ox, oy, oz) = turn(0.0, 0.0, CAMERA);
    let (lx, ly, lz) = turn(-0.5, 0.6, 0.62);
    let light = (lx * lx + ly * ly + lz * lz).sqrt();
    let (lx, ly, lz) = (lx / light, ly / light, lz / light);
    let open = 0.015 + 0.11 * pose.jaw.clamp(0.0, 1.0);
    let eyes = pose.eyes.clamp(0.0, 1.0);
    // The smaller of the two fits, counted in rows, so a narrow window still shows it whole.
    let fit = (h as f32).min(w as f32 * CELL) / 2.0;
    let origin_sq = ox * ox + oy * oy + oz * oz - BOUND * BOUND;

    for row in 0..h {
        let v = (h as f32 / 2.0 - row as f32 - 0.5) / fit * VIEW;
        for col in 0..w {
            let u = (col as f32 + 0.5 - w as f32 / 2.0) * CELL / fit * VIEW;
            let length = (u * u + v * v + 1.0).sqrt();
            let (dx, dy, dz) = turn(u / length, v / length, -1.0 / length);
            let b = ox * dx + oy * dy + oz * dz;
            let reach = b * b - origin_sq;
            if reach <= 0.0 {
                continue;
            }
            let reach = reach.sqrt();
            let (mut t, end) = (-b - reach, -b + reach);
            let (mut steps, mut hit) = (0, false);
            let (mut px, mut py, mut pz) = (0.0, 0.0, 0.0);
            while steps < MAX_STEPS {
                px = ox + dx * t;
                py = oy + dy * t;
                pz = oz + dz * t;
                let d = distance(px, py, pz, open);
                if d < SURFACE {
                    hit = true;
                    break;
                }
                t += d * 0.9;
                if t > end {
                    break;
                }
                steps += 1;
            }
            if hit {
                let shade = Hit { p: (px, py, pz), ray: (dx, dy, dz), light: (lx, ly, lz), steps, open, eyes };
                glyphs[row * w + col] = Some(shade.glyph());
            }
        }
    }
    Picture { width, height, glyphs }
}

struct Hit {
    p: (f32, f32, f32),
    ray: (f32, f32, f32),
    light: (f32, f32, f32),
    steps: u32,
    open: f32,
    eyes: f32,
}

impl Hit {
    fn glyph(&self) -> Glyph {
        let (px, py, pz) = self.p;
        // The back of each socket holds the glow.
        let side = px.abs() - 0.29;
        let from_eye = (side * side + (py - 0.02) * (py - 0.02) + (pz - 0.62) * (pz - 0.62)).sqrt();
        if from_eye < 0.26 && pz < 0.82 {
            let glow = ((1.0 - from_eye / 0.26) * self.eyes + 0.15).min(0.999);
            let ch = if glow > 0.6 {
                '#'
            } else if glow > 0.3 {
                '*'
            } else {
                '+'
            };
            return Glyph { ch, ink: Ink::Eye((glow * EYE_RGB.len() as f32) as u8) };
        }

        const E: f32 = 0.012;
        let open = self.open;
        let a = distance(px + E, py - E, pz - E, open);
        let b = distance(px - E, py - E, pz + E, open);
        let c = distance(px - E, py + E, pz - E, open);
        let d = distance(px + E, py + E, pz + E, open);
        let (nx, ny, nz) = (a - b - c + d, -a - b + c + d, -a + b - c + d);
        let n = (nx * nx + ny * ny + nz * nz).sqrt().max(1e-6);
        let (nx, ny, nz) = (nx / n, ny / n, nz / n);
        let (dx, dy, dz) = self.ray;
        let (lx, ly, lz) = self.light;
        let diffuse = (nx * lx + ny * ly + nz * lz).max(0.0);
        let facing = -(nx * dx + ny * dy + nz * dz);
        let (rx, ry, rz) = (2.0 * diffuse * nx - lx, 2.0 * diffuse * ny - ly, 2.0 * diffuse * nz - lz);
        let shine = (-(rx * dx + ry * dy + rz * dz)).max(0.0).powi(16);
        let rim = (1.0 - facing.max(0.0)).powf(2.5);
        // Rays that crept past edges took many steps: a cheap shadow in the hollows.
        let shadow = 1.0 - self.steps as f32 / MAX_STEPS as f32 * 0.6;
        let light = (0.07 + 0.72 * diffuse * shadow + 0.3 * shine + 0.14 * rim * shadow).min(0.999);
        Glyph {
            ch: RAMP[(light * RAMP.len() as f32) as usize] as char,
            ink: Ink::Bone((light * BONE_RGB.len() as f32) as u8),
        }
    }
}

// MARK: Hearing

/// The voices turned into eyes and jaw. Levels are measured against the loudest heard
/// lately, so a quiet tune moves the skull as much as a loud one.
#[derive(Debug, Clone, Default)]
pub struct Reaction {
    pub eyes: f32,
    pub jaw: f32,
    loudest: f32,
    last_total: f32,
}

impl Reaction {
    /// One reading of each voice's samples.
    pub fn hear(&mut self, voices: &[Vec<f32>]) {
        let peaks = voices.iter().map(|samples| samples.iter().fold(0.0_f32, |most, s| most.max(s.abs())));
        let (mut top, mut sum) = (0.0_f32, 0.0_f32);
        for peak in peaks {
            top = top.max(peak);
            sum += peak;
        }
        self.loudest = (self.loudest * LOUDEST_KEEPS).max(top).max(QUIETEST);
        let total = sum / self.loudest;
        // All the voices together, squared: on Lightforce the loudest voice alone sat
        // at 94%, so the eyes hardly moved, while this ranges from 19% to 82%.
        let voices_heard = voices.len().max(1) as f32;
        self.eyes = self.eyes.max((total / voices_heard).powi(2));
        self.jaw = self.jaw.max(((total - self.last_total) / FULL_CHOMP).clamp(0.0, 1.0));
        self.last_total = total;
    }

    /// Time passing: everything settles unless the voices keep it up.
    pub fn settle(&mut self, seconds: f32) {
        self.eyes *= (-seconds / EYES_SETTLE).exp();
        self.jaw *= (-seconds / JAW_SETTLE).exp();
    }
}

// MARK: The view's state

pub struct Skull {
    pub reaction: Reaction,
    pub picture: Picture,
    pub truecolor: bool,
    pub spin: f32,
    angle: f32,
    last_frame: Option<Instant>,
    took: Duration,
}

impl Skull {
    pub fn new(truecolor: bool) -> Skull {
        Skull {
            reaction: Reaction::default(),
            picture: Picture::default(),
            truecolor,
            angle: 0.5,
            spin: START_SPIN,
            last_frame: None,
            took: Duration::ZERO,
        }
    }

    pub fn turn_faster(&mut self, by: i8) {
        self.spin = (self.spin + f32::from(by) * SPIN_STEP).clamp(-MOST_SPIN, MOST_SPIN);
    }

    /// Bring the picture up to date, when a new one is due.
    pub fn advance(&mut self, now: Instant, width: u16, height: u16, playing: bool) {
        let resized = self.picture.width != width || self.picture.height != height;
        let wait = FASTEST_FRAME.max(self.took * 2);
        let seconds = match self.last_frame {
            Some(last) if !resized && now.duration_since(last) < wait => return,
            Some(last) => now.duration_since(last).as_secs_f32(),
            None => 0.0,
        };
        self.reaction.settle(seconds);
        if playing {
            self.angle += self.spin * seconds;
        }
        let pose = Pose {
            angle: self.angle,
            tilt: 0.14 * (self.angle * 0.37).sin() - 0.04,
            jaw: self.reaction.jaw,
            eyes: self.reaction.eyes,
        };
        let began = Instant::now();
        self.picture = render(pose, width, height);
        self.took = began.elapsed();
        self.last_frame = Some(now);
    }
}

/// Whether the terminal says it shows millions of colours.
pub fn terminal_has_truecolor() -> bool {
    std::env::var("COLORTERM").is_ok_and(|v| v.contains("truecolor") || v.contains("24bit"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const FACING: Pose = Pose { angle: 0.0, tilt: 0.0, jaw: 0.0, eyes: 0.0 };

    fn count(picture: &Picture, wanted: impl Fn(&Glyph) -> bool) -> usize {
        picture.glyphs.iter().flatten().filter(|g| wanted(g)).count()
    }

    fn glow_cells(picture: &Picture) -> usize {
        count(picture, |g| matches!(g.ink, Ink::Eye(_)))
    }

    #[test]
    fn draws_a_skull_in_the_middle_and_nothing_in_the_corners() {
        let picture = render(FACING, 110, 50);
        assert_eq!(picture.glyphs.len(), 110 * 50);
        let filled = count(&picture, |_| true);
        assert!(filled > 500, "only {filled} cells drawn");
        assert!(filled < 110 * 50 / 2, "{filled} cells drawn");
        for corner in [0, 109, 110 * 49, 110 * 50 - 1] {
            assert_eq!(picture.glyphs[corner], None);
        }
    }

    #[test]
    fn only_plain_ascii_comes_out() {
        let picture = render(FACING, 80, 40);
        assert!(picture.glyphs.iter().flatten().all(|g| g.ch.is_ascii_graphic()));
    }

    #[test]
    fn the_sockets_are_seen_from_the_front_but_not_from_behind() {
        assert!(glow_cells(&render(FACING, 110, 50)) > 0);
        assert_eq!(glow_cells(&render(Pose { angle: std::f32::consts::PI, ..FACING }, 110, 50)), 0);
    }

    #[test]
    fn its_eyes_burn_brighter_with_the_sound() {
        let picture = |eyes| render(Pose { eyes, ..FACING }, 110, 50);
        let hottest = |p: &Picture| count(p, |g| g.ch == '#');
        assert_eq!(hottest(&picture(0.0)), 0);
        assert!(hottest(&picture(1.0)) > 0);
    }

    #[test]
    fn the_jaw_opens_and_turning_changes_the_picture() {
        let closed = render(FACING, 110, 50);
        assert_ne!(closed, render(Pose { jaw: 1.0, ..FACING }, 110, 50));
        assert_ne!(closed, render(Pose { angle: 0.3, ..FACING }, 110, 50));
    }

    #[test]
    fn any_window_size_is_fine() {
        for (w, h) in [(0, 0), (0, 10), (10, 0), (1, 1), (3, 200), (200, 3)] {
            let picture = render(FACING, w, h);
            assert_eq!(picture.glyphs.len(), w as usize * h as usize);
        }
    }

    #[test]
    fn a_narrow_window_still_shows_the_whole_head() {
        // The widest rows would touch the sides if it were cut off.
        let picture = render(FACING, 30, 50);
        let edge = (0..50).filter(|row| picture.glyphs[row * 30].is_some() || picture.glyphs[row * 30 + 29].is_some());
        assert_eq!(edge.count(), 0);
    }

    fn voices(levels: [f32; 3]) -> Vec<Vec<f32>> {
        levels.iter().map(|level| vec![0.0, *level, -*level * 0.5]).collect()
    }

    #[test]
    fn a_quiet_tune_moves_it_as_much_as_a_loud_one() {
        let eyes_for = |level: f32| {
            let mut reaction = Reaction::default();
            reaction.hear(&voices([level, level, level]));
            reaction.eyes
        };
        assert!((eyes_for(0.9) - 1.0).abs() < 1e-4);
        assert!((eyes_for(0.1) - 1.0).abs() < 1e-4);
    }

    #[test]
    fn its_eyes_burn_brighter_the_more_voices_sound() {
        let eyes_for = |levels| {
            let mut reaction = Reaction::default();
            reaction.hear(&voices([1.0, 1.0, 1.0]));
            reaction.settle(5.0);
            reaction.hear(&voices(levels));
            reaction.eyes
        };
        assert!(eyes_for([1.0, 0.0, 0.0]) < 0.15);
        assert!(eyes_for([1.0, 1.0, 0.0]) > 0.4);
        assert!(eyes_for([1.0, 1.0, 1.0]) > 0.99);
    }

    #[test]
    fn hits_open_the_jaw_but_a_held_note_does_not() {
        let mut reaction = Reaction::default();
        reaction.hear(&voices([0.8, 0.0, 0.0]));
        reaction.settle(5.0);
        assert!(reaction.jaw < 0.01);
        reaction.hear(&voices([0.8, 0.0, 0.0]));
        assert!(reaction.jaw < 0.01, "a held note opened the jaw to {}", reaction.jaw);
        reaction.hear(&voices([0.8, 0.8, 0.8]));
        assert!(reaction.jaw > 0.9, "a hit on all voices only opened it to {}", reaction.jaw);
    }

    #[test]
    fn silence_leaves_it_dark_and_shut() {
        let mut reaction = Reaction::default();
        reaction.hear(&[vec![0.0; 8], vec![0.0; 8], vec![0.0; 8]]);
        reaction.hear(&[]);
        assert_eq!((reaction.eyes, reaction.jaw), (0.0, 0.0));
    }

    #[test]
    fn it_settles_with_time_alone() {
        let mut reaction = Reaction::default();
        reaction.hear(&voices([0.5, 0.5, 0.5]));
        assert!(reaction.eyes > 0.9 && reaction.jaw > 0.9);
        reaction.settle(1.0);
        assert!(reaction.eyes < 0.01 && reaction.jaw < 0.01);
    }

    #[test]
    fn it_only_turns_while_music_plays_and_redraws_on_a_new_size() {
        let start = Instant::now();
        let mut skull = Skull::new(true);
        skull.advance(start, 60, 30, false);
        let first = skull.picture.clone();
        skull.advance(start + Duration::from_secs(1), 60, 30, false);
        assert_eq!(skull.picture, first);
        skull.advance(start + Duration::from_secs(2), 60, 30, true);
        assert_ne!(skull.picture, first);
        skull.advance(start + Duration::from_secs(2), 40, 20, true);
        assert_eq!((skull.picture.width, skull.picture.height), (40, 20));
    }

    #[test]
    fn frames_wait_their_turn() {
        let start = Instant::now();
        let mut skull = Skull::new(true);
        skull.advance(start, 60, 30, true);
        let first = skull.picture.clone();
        skull.advance(start + Duration::from_millis(1), 60, 30, true);
        assert_eq!(skull.picture, first);
    }

    #[test]
    fn spin_stops_at_its_limits() {
        let mut skull = Skull::new(true);
        for _ in 0..100 {
            skull.turn_faster(1);
        }
        assert_eq!(skull.spin, MOST_SPIN);
        for _ in 0..100 {
            skull.turn_faster(-1);
        }
        assert_eq!(skull.spin, -MOST_SPIN);
    }

    #[test]
    fn both_palettes_cover_every_shade() {
        for n in 0..BONE_RGB.len() as u8 {
            assert!(matches!(Ink::Bone(n).color(true), Color::Rgb(..)));
            assert!(matches!(Ink::Bone(n).color(false), Color::Indexed(_)));
        }
        for n in 0..EYE_RGB.len() as u8 {
            assert!(matches!(Ink::Eye(n).color(true), Color::Rgb(..)));
            assert!(matches!(Ink::Eye(n).color(false), Color::Indexed(_)));
        }
    }

    /// `cargo test -p resonance-cli show_it -- --ignored --nocapture`, to look at it.
    #[test]
    #[ignore = "prints frames to look at"]
    fn show_it() {
        for pose in [
            Pose { angle: 0.0, tilt: -0.04, jaw: 0.0, eyes: 1.0 },
            Pose { angle: 0.7, tilt: 0.05, jaw: 1.0, eyes: 0.4 },
            Pose { angle: 1.57, tilt: 0.0, jaw: 0.3, eyes: 0.0 },
        ] {
            let picture = render(pose, 100, 44);
            for row in picture.glyphs.chunks(100) {
                let line: String = row.iter().map(|g| g.map_or(' ', |g| g.ch)).collect();
                println!("{}", line.trim_end());
            }
        }
    }

    /// `cargo test --release frame_time -- --ignored --nocapture`
    #[test]
    #[ignore = "a measurement, for release builds"]
    fn frame_time() {
        for (w, h) in [(110, 50), (200, 60), (300, 80)] {
            let began = Instant::now();
            let frames = 60;
            for n in 0..frames {
                let pose = Pose { angle: n as f32 * 0.05, tilt: 0.0, jaw: 0.5, eyes: 0.5 };
                std::hint::black_box(render(pose, w, h));
            }
            println!("{w}x{h}: {:.1} ms a frame", began.elapsed().as_secs_f64() * 1000.0 / f64::from(frames));
        }
    }
}
