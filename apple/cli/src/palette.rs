//! The terminal app's colors, each in millions of colors and its nearest of 256,
//! so it looks the same on any terminal: Terminal itself only has the 256.

use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Style};
use std::sync::LazyLock;

static TRUECOLOR: LazyLock<bool> = LazyLock::new(crate::skull::terminal_has_truecolor);

const fn ink(rgb: (u8, u8, u8), nearest: u8) -> ((u8, u8, u8), u8) {
    (rgb, nearest)
}

fn color((rgb, nearest): ((u8, u8, u8), u8)) -> Color {
    if *TRUECOLOR {
        Color::Rgb(rgb.0, rgb.1, rgb.2)
    } else {
        Color::Indexed(nearest)
    }
}

const BACKGROUND: ((u8, u8, u8), u8) = ink((0x14, 0x16, 0x1a), 233);
const TEXT: ((u8, u8, u8), u8) = ink((0xd7, 0xda, 0xe0), 253);
const MUTED: ((u8, u8, u8), u8) = ink((0x7a, 0x80, 0x8c), 244);
const ACCENT: ((u8, u8, u8), u8) = ink((0xe9, 0xa1, 0x3b), 214);
const SELECTION: ((u8, u8, u8), u8) = ink((0x2a, 0x30, 0x40), 237);
const BAR: ((u8, u8, u8), u8) = ink((0x2c, 0x31, 0x3b), 236);
const BAR_FOCUSED: ((u8, u8, u8), u8) = ink((0x3a, 0x40, 0x4d), 238);
const FAINT: ((u8, u8, u8), u8) = ink((0x34, 0x38, 0x42), 238);
const WHITE: ((u8, u8, u8), u8) = ink((0xe8, 0xe8, 0xe8), 255);
const CYAN: ((u8, u8, u8), u8) = ink((0x5a, 0xc7, 0xe8), 81);
const VIOLET: ((u8, u8, u8), u8) = ink((0xa3, 0x7d, 0xf5), 141);
const ORANGE: ((u8, u8, u8), u8) = ink((0xf2, 0xa1, 0x54), 215);
const RED: ((u8, u8, u8), u8) = ink((0xf0, 0x70, 0x70), 210);
const GREEN: ((u8, u8, u8), u8) = ink((0x80, 0xdb, 0xa3), 115);
const FRAME: ((u8, u8, u8), u8) = ink((0x4d, 0x52, 0x60), 240);

pub fn background() -> Color {
    color(BACKGROUND)
}
pub fn text() -> Color {
    color(TEXT)
}
pub fn muted() -> Color {
    color(MUTED)
}
/// The accent chosen in System Settings, as the app uses it; Resonance's amber
/// where there's no Mac to ask.
pub fn accent() -> Color {
    color(*SYSTEM_ACCENT)
}

/// The accent mixed toward white: `share` of accent, from 0 to 1.
pub fn accent_light(share: f32) -> Color {
    mixed(WHITE.0, share)
}

fn mixed(other: (u8, u8, u8), share: f32) -> Color {
    let (accent, _) = *SYSTEM_ACCENT;
    let mix = |a: u8, b: u8| (f32::from(b) + (f32::from(a) - f32::from(b)) * share.clamp(0.0, 1.0)).round() as u8;
    let rgb = (mix(accent.0, other.0), mix(accent.1, other.1), mix(accent.2, other.2));
    color((rgb, nearest_of_256(rgb)))
}

static SYSTEM_ACCENT: LazyLock<((u8, u8, u8), u8)> = LazyLock::new(|| system_accent().unwrap_or(ACCENT));

/// macOS keeps the accent as a number in the global defaults, and none at all
/// for multicolor, where an app without its own accent (as Resonance) gets blue.
#[cfg(target_os = "macos")]
fn system_accent() -> Option<((u8, u8, u8), u8)> {
    let out = std::process::Command::new("defaults").args(["read", "-g", "AppleAccentColor"]).output().ok()?;
    let number = if out.status.success() { String::from_utf8_lossy(&out.stdout).trim().parse().ok()? } else { 4 };
    Some(accent_numbered(number))
}

#[cfg(not(target_os = "macos"))]
fn system_accent() -> Option<((u8, u8, u8), u8)> {
    None
}

/// The system colors' dark-mode values, as the terminal app's background is dark.
fn accent_numbered(number: i32) -> ((u8, u8, u8), u8) {
    let rgb = match number {
        -1 => (0x98, 0x98, 0x9d),
        0 => (0xff, 0x45, 0x3a),
        1 => (0xff, 0x9f, 0x0a),
        2 => (0xff, 0xd6, 0x0a),
        3 => (0x32, 0xd7, 0x4b),
        5 => (0xbf, 0x5a, 0xf2),
        6 => (0xff, 0x37, 0x5f),
        _ => (0x0a, 0x84, 0xff),
    };
    (rgb, nearest_of_256(rgb))
}

/// The closest of the 256-color cube and gray ramp.
fn nearest_of_256((r, g, b): (u8, u8, u8)) -> u8 {
    const STEPS: [u8; 6] = [0, 95, 135, 175, 215, 255];
    let distance = |(x, y, z): (u8, u8, u8)| {
        let d = |a: u8, b: u8| (i32::from(a) - i32::from(b)).pow(2);
        d(x, r) + d(y, g) + d(z, b)
    };
    let cube = (0..216u16).map(|i| {
        let rgb = (STEPS[usize::from(i / 36)], STEPS[usize::from(i / 6 % 6)], STEPS[usize::from(i % 6)]);
        (distance(rgb), 16 + i)
    });
    let grays = (0..24u16).map(|i| {
        let v = (8 + 10 * i) as u8;
        (distance((v, v, v)), 232 + i)
    });
    cube.chain(grays).min().map_or(15, |(_, index)| index as u8)
}
pub fn selection() -> Color {
    color(SELECTION)
}
/// Behind a section's heading.
pub fn bar(focused: bool) -> Color {
    color(if focused { BAR_FOCUSED } else { BAR })
}
/// Rules, empty bars: there, but only just.
pub fn faint() -> Color {
    color(FAINT)
}
/// The playhead.
pub fn white() -> Color {
    color(WHITE)
}
pub fn cyan() -> Color {
    color(CYAN)
}
pub fn violet() -> Color {
    color(VIOLET)
}
pub fn orange() -> Color {
    color(ORANGE)
}
pub fn red() -> Color {
    color(RED)
}
pub fn green() -> Color {
    color(GREEN)
}
/// The frame around the panes.
pub fn frame() -> Color {
    color(FRAME)
}

/// The frame's color fading into the background: `keep` of it, from 0 to 1.
pub fn frame_fading(keep: f32) -> Color {
    let mix = |a: u8, b: u8| (f32::from(b) + (f32::from(a) - f32::from(b)) * keep.clamp(0.0, 1.0)).round() as u8;
    let rgb = (mix(FRAME.0 .0, BACKGROUND.0 .0), mix(FRAME.0 .1, BACKGROUND.0 .1), mix(FRAME.0 .2, BACKGROUND.0 .2));
    color((rgb, nearest_of_256(rgb)))
}

/// A trait's color, as in the app: rhythm and pitch movement in cyan, the filter
/// in violet, the chip's harsher tricks in orange, samples in red, pulse-width
/// sweeps in green.
pub fn trait_color(index: usize) -> Color {
    color(match index {
        0 => WHITE,
        1 | 2 => CYAN,
        3 => VIOLET,
        6 => RED,
        8 => GREEN,
        _ => ORANGE,
    })
}

pub fn dim() -> Style {
    Style::new().fg(muted())
}

/// The window's own colors, wherever nothing chose one. Last of all in a frame,
/// so nothing that clears or resets a cell lets the terminal's own colors through.
pub fn paint(buffer: &mut Buffer) {
    let (paper, ink) = (background(), text());
    for cell in &mut buffer.content {
        if cell.bg == Color::Reset {
            cell.bg = paper;
        }
        if cell.fg == Color::Reset {
            cell.fg = ink;
        }
    }
}

/// Lets a picture thin out into the window instead of stopping at a hard edge. In
/// millions of colors only: 256 have nothing to blend through, and keep the edge.
pub fn fade_edges(buffer: &mut Buffer, area: Rect, bottom: bool) {
    let Color::Rgb(r, g, b) = background() else { return };
    let (across, down) = ((area.width / 8).max(1), (area.height / 6).max(1));
    let blend = |color: Color, keep: f32| match color {
        Color::Rgb(red, green, blue) => {
            let mix = |from: u8, to: u8| (f32::from(to) + (f32::from(from) - f32::from(to)) * keep) as u8;
            Color::Rgb(mix(red, r), mix(green, g), mix(blue, b))
        }
        other => other,
    };
    for y in area.top()..area.bottom() {
        for x in area.left()..area.right() {
            let sides = (x - area.left()).min(area.right() - 1 - x);
            let above = y - area.top();
            let below = if bottom { area.bottom() - 1 - y } else { down };
            let from_x = (f32::from(sides) + 0.5) / f32::from(across);
            let from_y = (f32::from(above.min(below)) + 0.5) / f32::from(down);
            let keep = from_x.min(from_y).min(1.0);
            if keep < 1.0 {
                if let Some(cell) = buffer.cell_mut((x, y)) {
                    cell.fg = blend(cell.fg, keep);
                    cell.bg = blend(cell.bg, keep);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_is_left_in_the_terminals_own_colors() {
        let mut buffer = Buffer::empty(Rect::new(0, 0, 3, 1));
        buffer[(1, 0)].set_fg(accent());
        paint(&mut buffer);
        assert!(buffer.content.iter().all(|c| c.bg == background()));
        assert_eq!(buffer[(0, 0)].fg, text());
        assert_eq!(buffer[(1, 0)].fg, accent());
    }

    #[test]
    fn fading_thins_the_edges_and_leaves_the_middle_and_what_has_no_color() {
        // In the terminal these tests run in, it may have only 256 colors.
        if !*TRUECOLOR {
            return;
        }
        let area = Rect::new(0, 0, 40, 20);
        let mut buffer = Buffer::empty(area);
        let lit = Color::Rgb(200, 100, 50);
        for cell in &mut buffer.content {
            cell.bg = lit;
        }
        fade_edges(&mut buffer, area, false);
        assert_eq!(buffer[(20, 10)].bg, lit);
        assert_ne!(buffer[(0, 10)].bg, lit);
        assert_ne!(buffer[(20, 0)].bg, lit);
        assert_eq!(buffer[(20, 19)].bg, lit, "the fire's base stays");
        assert_eq!(buffer[(20, 10)].fg, Color::Reset);
    }

    #[test]
    fn accents_find_their_nearest_of_256() {
        assert_eq!(nearest_of_256((255, 175, 0)), 214);
        assert_eq!(nearest_of_256((128, 128, 128)), 244);
        assert_eq!(accent_numbered(4).1, 33);
        assert_eq!(accent_numbered(99), accent_numbered(4));
    }

    #[test]
    fn lights_run_from_the_accent_to_white() {
        if !*TRUECOLOR {
            return;
        }
        assert_eq!(accent_light(1.0), accent());
        assert_eq!(accent_light(0.0), color(WHITE));
    }

    #[test]
    fn traits_take_the_apps_groups() {
        assert_eq!(trait_color(1), trait_color(2));
        assert_eq!(trait_color(4), trait_color(7));
        assert_ne!(trait_color(3), trait_color(6));
    }
}
