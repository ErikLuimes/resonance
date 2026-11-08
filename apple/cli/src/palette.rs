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
const QUIET_SELECTION: ((u8, u8, u8), u8) = ink((0x1e, 0x22, 0x2b), 235);
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
pub fn accent() -> Color {
    color(ACCENT)
}
pub fn selection() -> Color {
    color(SELECTION)
}
pub fn quiet_selection() -> Color {
    color(QUIET_SELECTION)
}
/// Rules, empty bars: there, but only just.
pub fn faint() -> Color {
    color(FAINT)
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
    fn traits_take_the_apps_groups() {
        assert_eq!(trait_color(1), trait_color(2));
        assert_eq!(trait_color(4), trait_color(7));
        assert_ne!(trait_color(3), trait_color(6));
    }
}
