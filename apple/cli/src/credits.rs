//! The credits: `c` in the terminal app, or `resonance credits`. Big flat letters in the
//! same 3D space as a starfield, drawn in half blocks. "Thanks for listening to", calm;
//! the camera starts to move; "Resonance" arrives and the letters start to turn; the
//! rest passes in that motion; the stars settle; then the names, as plain text. The
//! reasoning is in design/credits/README.md, with the mockups this follows.

use crate::model::Now;
use crate::palette;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use std::sync::LazyLock;

const THANKS: &str = "THANKS FOR LISTENING TO";
const NAME: &str = "RESONANCE";
const PEOPLE: &str = "WE WOULD LIKE TO THANK THE FOLLOWING PEOPLE";

/// The picture is worked out at the size it was designed at, then fitted to the window.
const WIDTH: f64 = 320.0;
const HEIGHT: f64 = 200.0;
const FOCAL: f64 = WIDTH / 2.0;

/// Where in the stars' flight the credits start: the camera's turning is nearly steady
/// for the next few seconds, so the letters stay in view.
const FLIGHT_FROM: f64 = 8.0;
const REF_YAW: f64 = 1.8;
const LETTER_HEIGHT: f64 = 0.19;
const LETTER_WIDTH: f64 = 0.255;
const NEAREST: f64 = 0.14;
const SIDE: V = [0.0, -0.45, 3.7];
const STEP: f64 = 1.76;
const SPACE: f64 = 0.95;
const READ_SPEED: f64 = 6.0;
const TILT: f64 = 0.22;
/// How far along the line a letter is when it comes into view.
const ARRIVES: f64 = 3.8;
const START: f64 = 5.2;
const SETTLE: f64 = 3.0;
/// The stars drift against the text until the camera starts, turning this much a second.
const DRIFT: f64 = 0.22;
const DRIFT_EASE: f64 = 1.5;
const ROLL_RATE: f64 = 0.55;
const SPIN_RATE: f64 = 1.05;
const CIRCLE_RATE: f64 = 0.55;
/// Super bold: each outline grows, and each counter shrinks, by this much.
const BOLD: f64 = 0.3;
const MITRE: f64 = 2.1;
/// Seconds a name stays up.
const HOLD: f64 = 4.0;
const STARS: usize = 500;

const PEOPLE_PAGES: [[&str; 3]; 13] = [
    ["A PRODUCTION BY", "ERIK LUIMES", ""],
    ["DIRECTOR OF SAYING NO", "ERIK LUIMES", "IT WAS PERFECT, PUT IT BACK"],
    ["TYPED VERY FAST", "CLAUDE", "BY ANTHROPIC"],
    ["BROKE THE BUILD", "CLAUDE", "TWICE BEFORE COFFEE"],
    ["BUILT THE HOUSE WE MOVED INTO", "MARCIN SPOCZYNSKI", "PHOSPHOR"],
    ["CHIP WHISPERER", "DAG LEM", "RESID"],
    ["KEEPER OF THE FILTER CURVES", "LEANDRO NINI", "LIBSIDPLAYFP AND RESIDFP"],
    ["LIGHTWEIGHT CHAMPION", "HERMIT", "SIDLITE"],
    ["THREE VOICES SHOULD BE ENOUGH", "BOB YANNES", "MOS 6581, 1982"],
    ["HEAD OF 60,000 THINGS", "THE HVSC CREW", "AND EVERY COMPOSER IN IT"],
    ["PROFESSIONAL LISTENER", "YIZHI LI ET AL", "MERT"],
    ["SKULL SURGEON", "INIGO QUILEZ", "DISTANCE FUNCTIONS"],
    ["ALL RESPECT TO THE DEMOSCENE", "TRITON", "WE FORGIVE THE PC"],
];

type V = [f64; 3];
type Outline = Vec<Vec<(f64, f64)>>;

fn outline(letter: char) -> &'static [&'static [(f64, f64)]] {
    match letter {
        'A' => &[&[(1.8, 0.0), (3.2, 0.0), (5.0, 7.0), (3.6, 7.0), (3.2, 5.3), (1.8, 5.3), (1.4, 7.0), (0.0, 7.0)], &[(1.85, 4.15), (3.15, 4.15), (2.5, 1.2)]],
        'B' => &[&[(0.0, 0.0), (4.0, 0.0), (5.0, 1.0), (5.0, 2.7), (4.3, 3.5), (5.0, 4.3), (5.0, 6.0), (4.0, 7.0), (0.0, 7.0)], &[(1.4, 1.2), (3.3, 1.2), (3.6, 1.5), (3.6, 2.5), (3.3, 2.8), (1.4, 2.8)], &[(1.4, 4.2), (3.3, 4.2), (3.6, 4.5), (3.6, 5.5), (3.3, 5.8), (1.4, 5.8)]],
        'C' => &[&[(1.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.7, 1.3), (1.4, 1.6), (1.4, 5.4), (1.7, 5.7), (5.0, 5.7), (5.0, 7.0), (1.0, 7.0), (0.0, 6.0), (0.0, 1.0)]],
        'D' => &[&[(0.0, 0.0), (3.6, 0.0), (5.0, 1.4), (5.0, 5.6), (3.6, 7.0), (0.0, 7.0)], &[(1.4, 1.3), (3.0, 1.3), (3.6, 1.9), (3.6, 5.1), (3.0, 5.7), (1.4, 5.7)]],
        'E' => &[&[(0.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.4, 1.3), (1.4, 2.8), (4.2, 2.8), (4.2, 4.1), (1.4, 4.1), (1.4, 5.7), (5.0, 5.7), (5.0, 7.0), (0.0, 7.0)]],
        'F' => &[&[(0.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.4, 1.3), (1.4, 2.8), (4.2, 2.8), (4.2, 4.1), (1.4, 4.1), (1.4, 7.0), (0.0, 7.0)]],
        'G' => &[&[(1.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.7, 1.3), (1.4, 1.6), (1.4, 5.4), (1.7, 5.7), (3.6, 5.7), (3.6, 4.3), (2.6, 4.3), (2.6, 3.1), (5.0, 3.1), (5.0, 7.0), (1.0, 7.0), (0.0, 6.0), (0.0, 1.0)]],
        'H' => &[&[(0.0, 0.0), (1.4, 0.0), (1.4, 2.8), (3.6, 2.8), (3.6, 0.0), (5.0, 0.0), (5.0, 7.0), (3.6, 7.0), (3.6, 4.1), (1.4, 4.1), (1.4, 7.0), (0.0, 7.0)]],
        'I' => &[&[(1.8, 0.0), (3.2, 0.0), (3.2, 7.0), (1.8, 7.0)]],
        'J' => &[&[(3.6, 0.0), (5.0, 0.0), (5.0, 6.0), (4.0, 7.0), (1.0, 7.0), (0.0, 6.0), (0.0, 4.6), (1.4, 4.6), (1.4, 5.4), (1.7, 5.7), (3.3, 5.7), (3.6, 5.4)]],
        'K' => &[&[(0.0, 0.0), (1.4, 0.0), (1.4, 2.7), (3.4, 0.0), (5.0, 0.0), (2.7, 3.2), (5.0, 7.0), (3.4, 7.0), (1.4, 3.9), (1.4, 7.0), (0.0, 7.0)]],
        'L' => &[&[(0.0, 0.0), (1.4, 0.0), (1.4, 5.7), (5.0, 5.7), (5.0, 7.0), (0.0, 7.0)]],
        'M' => &[&[(0.0, 0.0), (1.3, 0.0), (2.5, 2.6), (3.7, 0.0), (5.0, 0.0), (5.0, 7.0), (3.7, 7.0), (3.7, 2.8), (2.5, 5.2), (1.3, 2.8), (1.3, 7.0), (0.0, 7.0)]],
        'N' => &[&[(0.0, 0.0), (1.3, 0.0), (3.7, 4.6), (3.7, 0.0), (5.0, 0.0), (5.0, 7.0), (3.7, 7.0), (1.3, 2.4), (1.3, 7.0), (0.0, 7.0)]],
        'O' => &[&[(1.0, 0.0), (4.0, 0.0), (5.0, 1.0), (5.0, 6.0), (4.0, 7.0), (1.0, 7.0), (0.0, 6.0), (0.0, 1.0)], &[(1.7, 1.3), (3.3, 1.3), (3.6, 1.6), (3.6, 5.4), (3.3, 5.7), (1.7, 5.7), (1.4, 5.4), (1.4, 1.6)]],
        'P' => &[&[(0.0, 0.0), (4.0, 0.0), (5.0, 1.0), (5.0, 3.3), (4.0, 4.3), (1.4, 4.3), (1.4, 7.0), (0.0, 7.0)], &[(1.4, 1.2), (3.3, 1.2), (3.6, 1.5), (3.6, 2.8), (3.3, 3.1), (1.4, 3.1)]],
        'Q' => &[&[(1.0, 0.0), (4.0, 0.0), (5.0, 1.0), (5.0, 5.6), (4.1, 6.4), (5.0, 7.0), (1.0, 7.0), (0.0, 6.0), (0.0, 1.0)], &[(1.7, 1.3), (3.3, 1.3), (3.6, 1.6), (3.6, 5.0), (3.3, 5.7), (1.7, 5.7), (1.4, 5.4), (1.4, 1.6)]],
        'R' => &[&[(0.0, 0.0), (4.0, 0.0), (5.0, 1.0), (5.0, 3.0), (4.0, 4.0), (5.0, 7.0), (3.6, 7.0), (2.7, 4.2), (1.4, 4.2), (1.4, 7.0), (0.0, 7.0)], &[(1.4, 1.2), (3.4, 1.2), (3.7, 1.5), (3.7, 2.7), (3.4, 3.0), (1.4, 3.0)]],
        'S' => &[&[(1.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.6, 1.3), (1.4, 1.5), (1.4, 2.6), (1.6, 2.8), (4.0, 2.8), (5.0, 3.8), (5.0, 6.0), (4.0, 7.0), (0.0, 7.0), (0.0, 5.7), (3.4, 5.7), (3.6, 5.5), (3.6, 4.3), (3.4, 4.1), (1.0, 4.1), (0.0, 3.1), (0.0, 1.0)]],
        'T' => &[&[(0.0, 0.0), (5.0, 0.0), (5.0, 1.3), (3.2, 1.3), (3.2, 7.0), (1.8, 7.0), (1.8, 1.3), (0.0, 1.3)]],
        'U' => &[&[(0.0, 0.0), (1.4, 0.0), (1.4, 5.4), (1.7, 5.7), (3.3, 5.7), (3.6, 5.4), (3.6, 0.0), (5.0, 0.0), (5.0, 6.0), (4.0, 7.0), (1.0, 7.0), (0.0, 6.0)]],
        'V' => &[&[(0.0, 0.0), (1.5, 0.0), (2.5, 5.0), (3.5, 0.0), (5.0, 0.0), (3.3, 7.0), (1.7, 7.0)]],
        'W' => &[&[(0.0, 0.0), (1.3, 0.0), (1.6, 4.6), (2.5, 2.4), (3.4, 4.6), (3.7, 0.0), (5.0, 0.0), (4.4, 7.0), (3.1, 7.0), (2.5, 5.4), (1.9, 7.0), (0.6, 7.0)]],
        'X' => &[&[(0.0, 0.0), (1.6, 0.0), (2.5, 2.3), (3.4, 0.0), (5.0, 0.0), (3.3, 3.5), (5.0, 7.0), (3.4, 7.0), (2.5, 4.7), (1.6, 7.0), (0.0, 7.0), (1.7, 3.5)]],
        'Y' => &[&[(0.0, 0.0), (1.5, 0.0), (2.5, 2.6), (3.5, 0.0), (5.0, 0.0), (3.2, 4.0), (3.2, 7.0), (1.8, 7.0), (1.8, 4.0)]],
        'Z' => &[&[(0.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.8, 5.7), (5.0, 5.7), (5.0, 7.0), (0.0, 7.0), (0.0, 5.7), (3.2, 1.3), (0.0, 1.3)]],
        _ => &[],
    }
}

fn add(a: V, b: V, by: f64) -> V {
    [a[0] + b[0] * by, a[1] + b[1] * by, a[2] + b[2] * by]
}

fn scaled(a: V, by: f64) -> V {
    [a[0] * by, a[1] * by, a[2] * by]
}

fn normal(v: V) -> V {
    let length = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    scaled(v, 1.0 / length)
}

fn smooth(x: f64) -> f64 {
    let v = x.clamp(0.0, 1.0);
    v * v * (3.0 - 2.0 * v)
}

/// A letter's outline made bolder. Each point moves along the corner's bisector, away
/// from the shape, with sharp corners held back so they don't spike.
fn grown(points: &[(f64, f64)], by: f64) -> Vec<(f64, f64)> {
    let count = points.len();
    let area: f64 = (0..count)
        .map(|i| {
            let (p, q) = (points[i], points[(i + 1) % count]);
            p.0 * q.1 - q.0 * p.1
        })
        .sum();
    let side = if area > 0.0 { 1.0 } else { -1.0 };
    let direction = |a: (f64, f64), b: (f64, f64)| {
        let (x, y) = (b.0 - a.0, b.1 - a.1);
        let length = x.hypot(y);
        (x / length, y / length)
    };
    (0..count)
        .map(|i| {
            let p = points[i];
            let before = direction(points[(i + count - 1) % count], p);
            let after = direction(p, points[(i + 1) % count]);
            let (n1, n2) = ((before.1 * side, -before.0 * side), (after.1 * side, -after.0 * side));
            let (x, y) = (n1.0 + n2.0, n1.1 + n2.1);
            let length = x.hypot(y);
            let (x, y) = if length > 0.0 { (x / length, y / length) } else { (x, y) };
            let cos = (x * n1.0 + y * n1.1).max(0.001);
            let reach = (1.0 / cos).min(MITRE) * by;
            (p.0 + x * reach, p.1 + y * reach)
        })
        .collect()
}

/// The first outline is the letter; any others are its counters.
static FONT: LazyLock<Vec<(char, Outline)>> = LazyLock::new(|| {
    ('A'..='Z')
        .map(|letter| {
            let shapes = outline(letter)
                .iter()
                .enumerate()
                .map(|(n, shape)| grown(shape, if n == 0 { BOLD } else { -BOLD }))
                .collect();
            (letter, shapes)
        })
        .collect()
});

fn bold_outline(letter: char) -> Option<&'static Outline> {
    FONT.iter().find(|(l, _)| *l == letter).map(|(_, o)| o)
}

/// When things happen, which follows from where the words fall on the line.
struct Timing {
    line: Vec<char>,
    places: Vec<f64>,
    camera_starts: f64,
    letters_start: f64,
    settle_from: f64,
    names_from: f64,
}

static TIMING: LazyLock<Timing> = LazyLock::new(|| {
    let line: Vec<char> = format!("{THANKS}   {NAME}   {PEOPLE}").chars().collect();
    let mut places = Vec::with_capacity(line.len());
    let mut x = START;
    for letter in &line {
        places.push(x);
        x += if *letter == ' ' { SPACE } else { STEP };
    }
    let thanks = THANKS.len();
    let camera_starts = (places[thanks - 1] - ARRIVES) / READ_SPEED;
    let letters_start = (places[thanks + 3] - ARRIVES) / READ_SPEED;
    let settle_from = (places[line.len() - 1] + 7.0) / READ_SPEED;
    Timing { line, places, camera_starts, letters_start, settle_from, names_from: settle_from + SETTLE + 0.3 }
});

/// How far something has turned: its rate grows in from nothing when it starts, holds,
/// then eases out as the stars settle, keeping where it got to.
fn turned(seconds: f64, rate: f64, from: f64) -> f64 {
    let settle_from = TIMING.settle_from;
    let a = (seconds.min(settle_from) - from).max(0.0);
    let b = (seconds - settle_from).clamp(0.0, SETTLE);
    rate * (a * a / (a + 1.6) + b - b * b / (2.0 * SETTLE))
}

fn star_turn(seconds: f64) -> f64 {
    let camera_starts = TIMING.camera_starts;
    let a = seconds.min(camera_starts);
    let b = (seconds - camera_starts).clamp(0.0, DRIFT_EASE);
    -DRIFT * (a + b - b * b / (2.0 * DRIFT_EASE))
}

fn hash(n: f64) -> f64 {
    ((n.sin() * 43_758.545_3) % 1.0).abs()
}

fn vignette(x: f64, y: f64) -> f64 {
    let distance = (x - WIDTH / 2.0).hypot(y - HEIGHT / 2.0);
    let reach = ((distance - 50.0) / 140.0).clamp(0.0, 1.0);
    if reach < 0.55 {
        reach / 0.55 * 0.35
    } else {
        0.35 + (reach - 0.55) / 0.45 * 0.62
    }
}

/// Each star that's in view: where it is, and how bright it ends up, 0 to 255. The
/// same flight as the app's Starfield theme.
fn stars(flight: f64, turn: f64, bank: f64) -> Vec<(f64, f64, f64)> {
    let yaw = flight * 0.12 + (flight * 0.21).sin() * 0.9 + turn;
    let pitch = (flight * 0.15).sin() * 0.35;
    let roll = (flight * 0.09).sin() * 0.5 + bank;
    let (cy, sy, cp, sp, cr, sr) = (yaw.cos(), yaw.sin(), pitch.cos(), pitch.sin(), roll.cos(), roll.sin());
    let camera = [(flight * 0.05).sin() * 3.0, (flight * 0.07).sin() * 2.0, flight * 0.3];
    let mut seen = Vec::new();
    for k in 0..STARS {
        let n = k as f64;
        let star = [hash(n * 12.989) * 2.0, hash(n * 78.233) * 2.0, hash(n * 37.719) * 2.0];
        let r: Vec<f64> = star
            .iter()
            .zip(camera)
            .map(|(s, c)| {
                let d = s - c;
                d - (d / 2.0).floor() * 2.0 - 1.0
            })
            .collect();
        let (x1, z1) = (r[0] * cy - r[2] * sy, r[0] * sy + r[2] * cy);
        let (y2, z2) = (r[1] * cp - z1 * sp, r[1] * sp + z1 * cp);
        let (x3, y3) = (x1 * cr - y2 * sr, x1 * sr + y2 * cr);
        if z2 <= 0.03 {
            continue;
        }
        let (x, y) = (WIDTH / 2.0 + x3 / z2 * FOCAL, HEIGHT / 2.0 + y3 / z2 * FOCAL);
        if !(0.0..WIDTH).contains(&x) || !(0.0..HEIGHT).contains(&y) {
            continue;
        }
        let near = (1.0 - z2).max(0.0);
        let ink = if near > 0.6 {
            255.0
        } else if near > 0.3 {
            168.0
        } else {
            94.0
        };
        seen.push((x, y, ink * (0.35 + near).min(1.0) * (1.0 - vignette(x, y))));
    }
    seen
}

/// The letters in view at this moment, as outlines on the picture.
fn letters(seconds: f64, flight: f64) -> Vec<Vec<Vec<(f64, f64)>>> {
    let timing = &*TIMING;
    let (right, forward) = ([REF_YAW.cos(), 0.0, -REF_YAW.sin()], [REF_YAW.sin(), 0.0, REF_YAW.cos()]);
    let along_line = normal([1.0, 0.24, -0.44]);
    let line_normal = normal([along_line[2], 0.0, -along_line[0]]);

    let shared = 0.25 + 0.75 * smooth((seconds - timing.camera_starts) / 2.5);
    let moving = smooth((seconds - timing.camera_starts) / 1.6) * (1.0 - smooth((seconds - timing.settle_from) / SETTLE));
    let yaw = REF_YAW + (flight * 0.21).sin() * 0.25 * shared + moving * (seconds * 0.7).sin() * 0.2;
    let pitch = (flight * 0.15).sin() * 0.35 * shared + moving * (seconds * 0.9).sin() * 0.18;
    let roll = (flight * 0.09).sin() * 0.5 * shared + turned(seconds, ROLL_RATE, timing.camera_starts);
    let (cy, sy, cp, sp, cr, sr) = (yaw.cos(), yaw.sin(), pitch.cos(), pitch.sin(), roll.cos(), roll.sin());
    let view = |p: V| -> V {
        let w = [p[0] * right[0] + p[2] * forward[0], p[1], p[0] * right[2] + p[2] * forward[2]];
        let (x1, z1) = (w[0] * cy - w[2] * sy, w[0] * sy + w[2] * cy);
        let (y2, z2) = (w[1] * cp - z1 * sp, w[1] * sp + z1 * cp);
        [x1 * cr - y2 * sr, x1 * sr + y2 * cr, z2]
    };

    // Circling the line while still looking at it: the letters turn around its axis.
    let around = turned(seconds, CIRCLE_RATE, timing.camera_starts);
    let (ca, sa) = (around.cos(), around.sin());
    let wildness = smooth((seconds - timing.camera_starts) / 1.6);
    let spinning = smooth((seconds - timing.letters_start) / 1.6);
    let x_axis = normal([along_line[0] * TILT.cos(), TILT.sin(), along_line[2] * TILT.cos()]);
    let y0 = [-along_line[0] * TILT.sin(), TILT.cos(), -along_line[2] * TILT.sin()];
    let y_axis = add(scaled(y0, ca), line_normal, sa);
    let n_axis = add(scaled(line_normal, ca), y0, -sa);
    let side = [SIDE[0], SIDE[1] * (1.0 - wildness * 0.75), SIDE[2] * (1.0 - wildness * 0.32)];

    let mut seen = Vec::new();
    for (i, letter) in timing.line.iter().enumerate() {
        let along = ARRIVES + (timing.places[i] - READ_SPEED * seconds - ARRIVES) * (1.0 + wildness * 0.6);
        if !(-16.0 + wildness * 3.0..=7.0).contains(&along) {
            continue;
        }
        let Some(shapes) = bold_outline(*letter) else { continue };
        // Out of step with their neighbours by a little, never by how far along the line.
        let spin = turned(seconds, SPIN_RATE, timing.letters_start) + spinning * ((i as f64) * 1.7).sin() * 0.7;
        let (cs, ss) = (spin.cos(), spin.sin());
        let base = add(side, along_line, along);
        let mut projected = Vec::with_capacity(shapes.len());
        let mut behind = false;
        for shape in shapes {
            let mut points = Vec::with_capacity(shape.len());
            for &(px, py) in shape {
                let (u, v) = ((px - 2.5) * LETTER_WIDTH, (py - 3.5) * LETTER_HEIGHT);
                let p = view(add(add(add(base, x_axis, u * cs), n_axis, u * ss), y_axis, v));
                if p[2] < NEAREST {
                    behind = true;
                }
                points.push((WIDTH / 2.0 + p[0] / p[2] * FOCAL, HEIGHT / 2.0 + p[1] / p[2] * FOCAL));
            }
            projected.push(points);
        }
        if !behind {
            seen.push(projected);
        }
    }
    seen
}

/// A letter's fill: one half-block pixel per half a cell, by whether its centre is inside.
fn fill(lit: &mut [bool], columns: usize, pixels: usize, shapes: &[Vec<(f64, f64)>]) {
    let mut crossings = Vec::new();
    for row in 0..pixels {
        let y = (row as f64 + 0.5) / pixels as f64 * HEIGHT;
        crossings.clear();
        for shape in shapes {
            for i in 0..shape.len() {
                let (a, b) = (shape[i], shape[(i + 1) % shape.len()]);
                if (a.1 <= y) != (b.1 <= y) {
                    crossings.push(a.0 + (y - a.1) / (b.1 - a.1) * (b.0 - a.0));
                }
            }
        }
        crossings.sort_by(f64::total_cmp);
        for pair in crossings.as_chunks::<2>().0 {
            let first = (pair[0] / WIDTH * columns as f64 - 0.5).ceil().max(0.0) as usize;
            let last = ((pair[1] / WIDTH * columns as f64 - 0.5).floor()).min(columns as f64 - 1.0);
            if last < 0.0 {
                continue;
            }
            for column in first..=last as usize {
                lit[row * columns + column] = true;
            }
        }
    }
}

/// The people, then whoever's playing, as the one actually doing the work.
fn pages(tune: Option<&Now>) -> Vec<[String; 3]> {
    let mut all: Vec<[String; 3]> = PEOPLE_PAGES.iter().map(|page| page.map(str::to_string)).collect();
    if let Some(tune) = tune {
        let title = tune.title.to_uppercase();
        let author = tune.author.trim();
        // HVSC's way of saying no one knows.
        let page = if author.is_empty() || author == "<?>" {
            [String::from("ACTUALLY DOING THE WORK"), title, String::from("NOW PLAYING")]
        } else {
            [String::from("ACTUALLY DOING THE WORK"), author.to_uppercase(), format!("{title}, NOW PLAYING")]
        };
        all.push(page);
    }
    all
}

/// How long the whole thing runs, after which it closes by itself.
pub fn length(tune: Option<&Now>) -> f64 {
    TIMING.names_from + pages(tune).len() as f64 * HOLD
}

/// Typed on, held, and taken off again from the end.
fn typed(text: &str, moment: f64, from: f64) -> usize {
    let count = text.chars().count();
    if moment < 0.86 {
        (((moment - from).max(0.0) * 70.0) as usize).min(count)
    } else {
        (((1.0 - (moment - 0.86) / 0.1).max(0.0) * count as f64) as usize).min(count)
    }
}

fn put_line(buffer: &mut Buffer, area: Rect, row: u16, text: &str, shown: usize, style: Style) {
    if row >= area.height {
        return;
    }
    let width = text.chars().count() as u16;
    let left = area.width.saturating_sub(width) / 2;
    for (n, letter) in text.chars().take(shown).enumerate() {
        let column = left + n as u16;
        if column < area.width {
            if let Some(cell) = buffer.cell_mut((area.x + column, area.y + row)) {
                cell.set_char(letter).set_style(style);
            }
        }
    }
}

/// One moment of the credits, `seconds` after they started.
pub fn draw(buffer: &mut Buffer, area: Rect, seconds: f64, tune: Option<&Now>) {
    if area.width == 0 || area.height < 2 {
        return;
    }
    let timing = &*TIMING;
    let columns = area.width as usize;
    let picture_rows = area.height - 1;
    let pixels = picture_rows as usize * 2;
    let flight = FLIGHT_FROM + seconds;

    let mut star_cells = vec![0.0_f64; columns * picture_rows as usize];
    for (x, y, bright) in stars(flight, star_turn(seconds), turned(seconds, ROLL_RATE, timing.camera_starts)) {
        let column = ((x / WIDTH * columns as f64) as usize).min(columns - 1);
        let row = ((y / HEIGHT * picture_rows as f64) as usize).min(picture_rows as usize - 1);
        let cell = &mut star_cells[row * columns + column];
        *cell = cell.max(bright);
    }
    for row in 0..picture_rows {
        for column in 0..columns {
            let bright = star_cells[row as usize * columns + column];
            if bright <= 60.0 {
                continue;
            }
            let (letter, ink) = if bright > 190.0 {
                ('*', 255)
            } else if bright > 120.0 {
                ('+', 248)
            } else {
                ('·', 242)
            };
            if let Some(cell) = buffer.cell_mut((area.x + column as u16, area.y + row)) {
                cell.set_char(letter).set_fg(Color::Indexed(ink));
            }
        }
    }

    if seconds < timing.names_from {
        let mut lit = vec![false; columns * pixels];
        for shapes in letters(seconds, flight) {
            fill(&mut lit, columns, pixels, &shapes);
        }
        for row in 0..picture_rows as usize {
            for column in 0..columns {
                let upper = lit[row * 2 * columns + column];
                let lower = lit[(row * 2 + 1) * columns + column];
                let block = match (upper, lower) {
                    (true, true) => '█',
                    (true, false) => '▀',
                    (false, true) => '▄',
                    (false, false) => continue,
                };
                if let Some(cell) = buffer.cell_mut((area.x + column as u16, area.y + row as u16)) {
                    cell.set_char(block).set_fg(Color::Indexed(255));
                }
            }
        }
    } else {
        let all = pages(tune);
        let elapsed = seconds - timing.names_from;
        if let Some(page) = all.get((elapsed / HOLD) as usize) {
            let moment = (elapsed / HOLD).fract();
            let middle = (picture_rows / 2).saturating_sub(2);
            let accent = Style::new().fg(palette::accent());
            let name = Style::new().fg(Color::Indexed(231)).add_modifier(Modifier::BOLD);
            put_line(buffer, area, middle, &page[0], typed(&page[0], moment, 0.0), accent);
            put_line(buffer, area, middle + 2, &page[1], typed(&page[1], moment, 0.03), name);
            put_line(buffer, area, middle + 4, &page[2], typed(&page[2], moment, 0.06), palette::dim());
        }
    }
    let hint = "esc back  p pause  . , next or previous  q quit";
    for (n, letter) in hint.chars().take(columns.saturating_sub(1)).enumerate() {
        if let Some(cell) = buffer.cell_mut((area.x + 1 + n as u16, area.y + picture_rows)) {
            cell.set_char(letter).set_style(palette::dim());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tune(author: &str) -> Now {
        Now { path: "/a.sid".into(), title: "Commando".into(), author: author.into(), released: "1985".into(), song: 1, songs: 1 }
    }

    fn screen(seconds: f64, columns: u16, rows: u16, playing: Option<&Now>) -> String {
        let area = Rect::new(0, 0, columns, rows);
        let mut buffer = Buffer::empty(area);
        draw(&mut buffer, area, seconds, playing);
        buffer.content.iter().map(|c| c.symbol()).collect::<Vec<_>>().chunks(columns as usize).map(|l| l.concat()).collect::<Vec<_>>().join("\n")
    }

    fn blocks(text: &str) -> usize {
        text.chars().filter(|c| matches!(c, '█' | '▀' | '▄')).count()
    }

    #[test]
    fn every_letter_of_the_alphabet_has_a_bold_shape() {
        for letter in 'A'..='Z' {
            let shapes = bold_outline(letter).unwrap();
            assert!(!shapes.is_empty() && shapes[0].iter().all(|p| p.0.is_finite() && p.1.is_finite()), "{letter}");
        }
    }

    #[test]
    fn growing_makes_a_letter_wider_and_its_counter_smaller() {
        let width = |points: &[(f64, f64)]| {
            let xs = points.iter().map(|p| p.0);
            xs.clone().fold(f64::MIN, f64::max) - xs.fold(f64::MAX, f64::min)
        };
        let o = outline('O');
        assert!(width(&grown(o[0], BOLD)) > width(o[0]));
        assert!(width(&grown(o[1], -BOLD)) < width(o[1]));
    }

    #[test]
    fn it_runs_in_the_order_of_the_script() {
        let t = &*TIMING;
        assert!(0.0 < t.camera_starts);
        assert!(t.camera_starts < t.letters_start);
        assert!(t.letters_start < t.settle_from);
        assert!(t.settle_from < t.names_from);
    }

    #[test]
    fn the_first_words_pass_calmly_with_the_camera_still_to_come() {
        assert_eq!(turned(TIMING.camera_starts, ROLL_RATE, TIMING.camera_starts), 0.0);
        assert_eq!(turned(TIMING.letters_start, SPIN_RATE, TIMING.letters_start), 0.0);
        assert!(blocks(&screen(3.0, 120, 38, None)) > 100);
    }

    #[test]
    fn the_letters_never_spin_fast() {
        let t = &*TIMING;
        let mut fastest = 0.0_f64;
        let mut s = t.letters_start;
        while s < t.names_from {
            let at = |s: f64| turned(s, SPIN_RATE, t.letters_start);
            fastest = fastest.max((at(s + 0.02) - at(s)) / 0.02);
            s += 0.02;
        }
        assert!(fastest <= SPIN_RATE + 0.01, "{fastest}");
    }

    #[test]
    fn the_letters_are_gone_before_the_stars_settle() {
        assert_eq!(blocks(&screen(TIMING.settle_from + 0.01, 120, 38, None)), 0);
    }

    #[test]
    fn nothing_jumps_when_the_stars_have_settled() {
        let t = &*TIMING;
        let end = turned(t.settle_from + SETTLE, ROLL_RATE, t.camera_starts);
        assert_eq!(turned(t.settle_from + SETTLE + 20.0, ROLL_RATE, t.camera_starts), end);
    }

    #[test]
    fn stars_are_there_all_the_way_through() {
        for seconds in [0.5, 10.0, TIMING.names_from + 1.0] {
            let text = screen(seconds, 120, 38, None);
            assert!(text.chars().filter(|c| matches!(c, '*' | '+' | '·')).count() > 3, "at {seconds}");
        }
    }

    #[test]
    fn the_names_come_after_the_stars_settle_and_triton_gets_a_page() {
        let at = |page: usize| TIMING.names_from + (page as f64 + 0.6) * HOLD;
        assert!(screen(at(0), 120, 38, None).contains("ERIK LUIMES"));
        let triton = PEOPLE_PAGES.iter().position(|p| p[1] == "TRITON").unwrap();
        let shown = screen(at(triton), 120, 38, None);
        assert!(shown.contains("TRITON") && shown.contains("WE FORGIVE THE PC"));
        let skull = PEOPLE_PAGES.iter().position(|p| p[0] == "SKULL SURGEON").unwrap();
        let shown = screen(at(skull), 120, 38, None);
        assert!(shown.contains("SKULL SURGEON") && shown.contains("INIGO QUILEZ") && shown.contains("DISTANCE FUNCTIONS"), "{shown}");
    }

    #[test]
    fn the_last_page_names_what_is_actually_playing() {
        let playing = tune("Rob Hubbard");
        let shown = screen(TIMING.names_from + (PEOPLE_PAGES.len() as f64 + 0.6) * HOLD, 120, 38, Some(&playing));
        assert!(shown.contains("ACTUALLY DOING THE WORK") && shown.contains("ROB HUBBARD") && shown.contains("COMMANDO, NOW PLAYING"), "{shown}");
    }

    #[test]
    fn an_unknown_composer_leaves_the_tune_on_its_own() {
        let playing = tune("<?>");
        let page = pages(Some(&playing)).pop().unwrap();
        assert_eq!(page[1], "COMMANDO");
        assert_eq!(page[2], "NOW PLAYING");
    }

    #[test]
    fn with_nothing_playing_the_tune_page_is_left_out() {
        let playing = tune("Rob Hubbard");
        assert_eq!(pages(None).len(), PEOPLE_PAGES.len());
        assert_eq!(length(Some(&playing)), length(None) + HOLD);
    }

    #[test]
    fn it_ends_in_empty_space_rather_than_on_a_page_that_is_not_there() {
        let text = screen(length(None) + 5.0, 80, 24, None);
        assert!(!text.contains("TRITON"));
    }

    #[test]
    fn text_types_on_and_off() {
        assert_eq!(typed("TRITON", 0.0, 0.0), 0);
        assert_eq!(typed("TRITON", 0.5, 0.0), 6);
        assert_eq!(typed("TRITON", 0.97, 0.0), 0);
    }

    #[test]
    fn any_window_is_fine_and_the_picture_is_the_same_each_time() {
        for (columns, rows) in [(1, 1), (1, 2), (2, 2), (10, 3), (40, 12), (80, 24), (120, 38), (300, 90)] {
            let mut seconds = 0.0;
            while seconds < length(None) + 1.0 {
                let _ = screen(seconds, columns, rows, None);
                seconds += 1.7;
            }
        }
        assert_eq!(screen(12.3, 80, 24, None), screen(12.3, 80, 24, None));
    }

    #[test]
    fn a_small_window_keeps_the_letters_readable_in_size() {
        assert!(blocks(&screen(3.0, 80, 24, None)) > 60);
    }

    #[test]
    fn fill_stays_inside_the_grid_for_shapes_off_the_edge() {
        let mut lit = vec![false; 20 * 10];
        let huge = vec![vec![(-500.0, -500.0), (900.0, -500.0), (900.0, 900.0), (-500.0, 900.0)]];
        fill(&mut lit, 20, 10, &huge);
        assert!(lit.iter().all(|cell| *cell));
        let mut none = vec![false; 20 * 10];
        let far = vec![vec![(900.0, 0.0), (950.0, 0.0), (950.0, 200.0), (900.0, 200.0)]];
        fill(&mut none, 20, 10, &far);
        assert!(none.iter().all(|cell| !*cell));
    }
}
