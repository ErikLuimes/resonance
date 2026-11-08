//! The name at the top of the terminal app, in the block-and-shade style of old ANSI
//! scene logos. The biggest size that leaves the player room is the one that shows.

use crate::palette;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};

const FULL: [&str; 28] = [
    "                                                       ▓▓",
    "   ▓▓                        ▓▓         ░              ██                                   ░              ▓▓",
    "   ██         ░              ██         ▒              ██         ░                      ▓▓ ▒              ██",
    "   ██         ▒      ▀      █▓▓█        ▓             █▓▓█ ▀      ▒    PRESS PLAY!       ██ ▓              ██",
    "  █▒▒█  █     ▓             █▒▒█  ▄     ▒             █▒▒█        ▓    ▀▀▀▀▀▀▀▀▀▀▀    █  ██ ▒             █▒▒█  ▄",
    "  █░░█        ▒             █░░█        ░             █░░█        ▒                     █▒▒█░             █░░█",
    "  █░░█        ░               ██████████              █░░█              ██              █░░█    █████████ █░░█",
    "  ███████████                ███████████              ██       ███     ████             █░░█  ███████████  ███████████",
    "  ████████████  ███████████ ████            ██████    ███      ███    █████     ██       ███ ████     ░   ████████████",
    " ░████ ░  ████ ████████████ █▓▓█          ██████████  ████     ███    █▓▓███    ███      ███ █▓▓█     ▒   ████        ░",
    " ░█▓▓█ ▒ ░█▓▓█ ████          █▒▒█        ████    ████ █▓▓██    █▓▓   █▒▒█ ███   ████     ███ █▒▒█     ▒   █▓▓█        ░",
    " ▒█▒▒█ ▒ ░█▒▒█ █▓▓█           ████       █▓▓█ ░  █▓▓█ █▒▒███   █▒▒   █░░█  ███  █▓▓██    █▓▓ █░░█     ▒   █▒▒█        ▒",
    "█▓█░░█ ░ █░░█  █▒▒█             █████    █▒▒█ ▒  █▒▒█ █░░████  █░░  █░░█    ███ █▒▒███   █▒▒ █░░█     ░   █░░█  ███   ▓█",
    " ▓█████████    █░░█  ███          ████   █░░█ ▒ ░█░░█ █░░█ ███ █░░  ███████████ █░░████  █░░ █░░█         █████████   ▓",
    " ▒█░░█ ███     █████████           █▒▒█  █░░█ ▒ ▒█░░█ █░░█  ███░░█ █▒▒█ ░   █▒▒ █░░█ ███ █░░ █▒▒█         █░░█  ███   ▒",
    " ░█▒▒█  ███    █░░█  ███            █▓▓█ █░░█ ▒ ▒█░░█ █▒▒█   █████ █▓▓█ ▒░  █▓▓ █░░█ ▒███░░█ █▓▓█         █▒▒█        ░",
    "  █▓▓█   ███   █▒▒█                 ████ █▒▒█ ▒ ░█▒▒█ █▓▓█    ████ ████ ▒░  ███ █▒▒█ ▒ █████ ████         █▓▓█",
    "  ████    ███  █▓▓█         ███████████  █▓▓█ ▒  █▓▓█ ████     ███ ████ ░   ███ █▓▓█ ░  ████  ███████████ ████",
    "  ████     ███ ████         ██████████   ████ ░  ████ ████      ██  ██       ██ ████     ███    █████████ ████████████",
    "   ██       ██ ████████████ ██            ██████████   ██        █  █         █ ████      ██            █  ███████████",
    "   █         █  ███████████                 ██████     █                   █░░█  ██        █ █░░█                   ██",
    "                         ██                  ██                            █░░█  █           █░░█",
    "               █░░█        ░                     █░░█░                     █▒▒█░             █▒▒█        ░",
    "               █░░█        ▒                     █░░█▒                      ██ ▒              ██         ▒",
    "           ▀   █▒▒█        ▓                  █  █▒▒█▓                      ██ ▓              ██         ▓       ▄",
    "                ██         ▒                      ██ ▒                   ▄  ▓▓ ▒              ▓▓   ▀     ▒",
    "                ██         ░                      ██                           ░                         ░",
    "                ▓▓                                ▓▓",
];
const COMPACT: [&str; 9] = [
    "░           ░           ░           ░           ░",
    "▓           ▓           ▓           ▓           ▓",
    "█████        ████       █▒  █       █▒  █       █████",
    "█▒ ██ █████ ██     ███  ██▒ █  ███  ██▒ █  ████ █▒",
    "████  █▒     ███  █▒ ▒█ █░█ █ █▒ ▒█ █░█ █ █▒    ████",
    "█░██  ████     ██ █░ ░█ █▒ ██ █████ █▒ ██ █░    █░",
    "█▒ ██ █░    ████  █▒ ▒█ █▒  █ █░ ░█ █▒  █ █▒    █████",
    "      █████       ▓███        █▒ ▒█       ▓████",
    "      ▒           ▒           ▒           ▒",
];
const SUBTITLE: &str = "░▒▓  T H E   S O U N D   O F   T H E   C O M M O D O R E   6 4  ▓▒░";
const DETAILS: &str = "60,000 TUNES  -<>-  SOUNDS LIKE  -<>-  SOUND DRIFT  -<>-  MADE FOR THE MAC";
const SHORT_SUBTITLE: &str = "THE SOUND OF THE COMMODORE 64";
const LINE: &str = "▓▒░ RESONANCE ░▒▓";

const FULL_COLUMNS: u16 = 120;
const COMPACT_COLUMNS: u16 = 55;
/// The big header comes first: these leave the player only 1 row for the divider, 2
/// for the tune, 3 for the frame and keys, and a usable list.
const FULL_NEEDS_ROWS: u16 = 45;
const TIGHT_NEEDS_ROWS: u16 = 38;
const COMPACT_NEEDS_ROWS: u16 = 25;
/// The big header without its outermost spike tips or the line of details.
const TIGHT_ROWS: u16 = FULL.len() as u16 - 2 + 1;

/// Of the window's height, the most each header grows to: the player keeps the rest.
/// The compact one's window is short, so the player needs more of it.
const FULL_SHARE: f32 = 0.62;
const COMPACT_SHARE: f32 = 0.4;
/// Scales go up in quarters, for an even look to the blocks.
const SCALE_STEP: f32 = 0.25;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Size {
    Full,
    Tight,
    Compact,
    Line,
}

/// Which header a window gets, and how big.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Plan {
    pub size: Size,
    pub scale: f32,
    pub rows: u16,
}

/// As big as fits the width and its share of the height, but never below full size.
fn scale_for(width: u16, height: u16, share: f32, columns: u16, art_rows: u16, text_rows: u16) -> f32 {
    let across = f32::from(width) / f32::from(columns);
    let down = (f32::from(height) * share - f32::from(text_rows)) / f32::from(art_rows);
    ((across.min(down) / SCALE_STEP).floor() * SCALE_STEP).max(1.0)
}

fn scaled(rows: usize, scale: f32) -> u16 {
    (rows as f32 * scale).round() as u16
}

/// The biggest header that leaves the player room in a window this size.
pub fn plan(width: u16, height: u16) -> Plan {
    if width >= FULL_COLUMNS && height >= FULL_NEEDS_ROWS {
        let scale = scale_for(width, height, FULL_SHARE, FULL_COLUMNS, FULL.len() as u16, 2);
        Plan { size: Size::Full, scale, rows: scaled(FULL.len(), scale) + 2 }
    } else if width >= FULL_COLUMNS && height >= TIGHT_NEEDS_ROWS {
        Plan { size: Size::Tight, scale: 1.0, rows: TIGHT_ROWS }
    } else if width >= COMPACT_COLUMNS && height >= COMPACT_NEEDS_ROWS {
        let scale = scale_for(width, height, COMPACT_SHARE, COMPACT_COLUMNS, COMPACT.len() as u16, 1);
        Plan { size: Size::Compact, scale, rows: scaled(COMPACT.len(), scale) + 1 }
    } else {
        Plan { size: Size::Line, scale: 1.0, rows: 1 }
    }
}

#[cfg(test)]
fn rows_for(width: u16, height: u16) -> u16 {
    plan(width, height).rows
}

fn shade(ch: char) -> Color {
    Color::Indexed(match ch {
        '░' => 240,
        '▒' => 243,
        '▓' => 246,
        _ => 248,
    })
}

/// The line under the header: shaded ends and a fine double line running to a block in
/// the middle.
pub fn divider(width: usize) -> String {
    const END: &str = "░▒▓█▓▒░ ";
    const MIDDLE: &str = " ░▒▓█ ▀▄▀▄▀ █▓▒░ ";
    let (end, middle) = (END.chars().count(), MIDDLE.chars().count());
    if width < (end + middle) * 2 {
        return "═".repeat(width);
    }
    let line = width - end * 2 - middle;
    let (left, right) = (line / 2, line - line / 2);
    let closing: String = END.chars().rev().collect();
    format!("{END}{}{MIDDLE}{}{closing}", "═".repeat(left), "═".repeat(right))
}

pub fn draw_divider(buffer: &mut Buffer, area: Rect) {
    for (n, ch) in divider(area.width as usize).chars().enumerate() {
        let color = if ch == '═' { Color::Indexed(243) } else { shade(ch) };
        if let Some(cell) = buffer.cell_mut((area.x + n as u16, area.y)) {
            cell.set_char(ch).set_fg(color);
        }
    }
}

/// The edge of a column, shaded like the logo's stems: solid at the ends, dithered in
/// the middle.
pub fn draw_column_edge(buffer: &mut Buffer, x: u16, area: Rect) {
    let middle = f32::from(area.height.saturating_sub(1)) / 2.0;
    for row in 0..area.height {
        let from_middle = (f32::from(row) - middle).abs() / middle.max(1.0);
        let ch = if from_middle < 0.25 {
            '░'
        } else if from_middle < 0.5 {
            '▒'
        } else if from_middle < 0.75 {
            '▓'
        } else {
            '█'
        };
        if let Some(cell) = buffer.cell_mut((x, area.y + row)) {
            cell.set_char(ch).set_fg(frame_shade(ch));
        }
    }
}

/// The columns' top or bottom: half a row thick, to meet their edges neatly.
pub fn draw_frame_edge(buffer: &mut Buffer, area: Rect, top: bool) {
    let ch = if top { '▄' } else { '▀' };
    for n in 0..area.width {
        if let Some(cell) = buffer.cell_mut((area.x + n, area.y)) {
            cell.set_char(ch).set_fg(frame_shade('█'));
        }
    }
}

/// The frame stays back from what's in it, where the logo stands out.
fn frame_shade(ch: char) -> Color {
    match ch {
        '█' | '▓' => palette::frame(),
        _ => palette::faint(),
    }
}

fn put_centered(buffer: &mut Buffer, area: Rect, row: u16, text: &str, style: Option<Style>) {
    let width = text.chars().count() as u16;
    let left = area.x + area.width.saturating_sub(width) / 2;
    for (n, ch) in text.chars().enumerate() {
        if ch == ' ' {
            continue;
        }
        if let Some(cell) = buffer.cell_mut((left + n as u16, area.y + row)) {
            cell.set_char(ch).set_style(style.unwrap_or(Style::new().fg(shade(ch))));
        }
    }
}

/// Words in the art stay their own size when it scales, since stretched letters break.
fn is_words(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '!'
}

/// The art, each cell repeated as the scale needs.
fn put_art(buffer: &mut Buffer, area: Rect, art: &[&str], columns: u16, scale: f32) {
    let wide = (f32::from(columns) * scale).round() as u16;
    let left = area.x + area.width.saturating_sub(wide) / 2;
    let lines: Vec<Vec<char>> = art.iter().map(|line| line.chars().collect()).collect();
    let tall = scaled(art.len(), scale).min(area.height);
    for row in 0..tall {
        let Some(line) = lines.get((f32::from(row) / scale) as usize) else { continue };
        for column in 0..wide.min(area.width) {
            let Some(ch) = line.get((f32::from(column) / scale) as usize).copied() else { continue };
            if ch == ' ' || is_words(ch) {
                continue;
            }
            if let Some(cell) = buffer.cell_mut((left + column, area.y + row)) {
                cell.set_char(ch).set_style(Style::new().fg(shade(ch)));
            }
        }
    }
    for (row, line) in lines.iter().enumerate() {
        let y = (row as f32 * scale) as u16;
        if y >= tall {
            continue;
        }
        for (column, ch) in line.iter().enumerate() {
            if is_words(*ch) {
                // Their start scales with the art, and the rest of the word follows on.
                let start = line.iter().position(|c| is_words(*c)).unwrap_or(column);
                let x = (start as f32 * scale) as u16 + (column - start) as u16;
                if let Some(cell) = buffer.cell_mut((left + x, area.y + y)) {
                    cell.set_char(*ch).set_style(Style::new().fg(shade(*ch)));
                }
            }
        }
    }
}

/// Draw the header a `plan` chose, in the rows it asked for.
pub fn draw(buffer: &mut Buffer, area: Rect, plan: Plan) {
    if area.height == 0 {
        return;
    }
    let plain = Style::new().fg(Color::Indexed(248));
    let bold = plain.add_modifier(Modifier::BOLD);
    match plan.size {
        Size::Full => {
            put_art(buffer, area, &FULL, FULL_COLUMNS, plan.scale);
            let art = scaled(FULL.len(), plan.scale);
            put_centered(buffer, area, art, SUBTITLE, Some(bold));
            put_centered(buffer, area, art + 1, DETAILS, Some(Style::new().fg(Color::Indexed(246))));
        }
        Size::Tight => {
            put_art(buffer, area, &FULL[1..FULL.len() - 1], FULL_COLUMNS, 1.0);
            put_centered(buffer, area, TIGHT_ROWS - 1, SUBTITLE, Some(bold));
        }
        Size::Compact => {
            put_art(buffer, area, &COMPACT, COMPACT_COLUMNS, plan.scale);
            put_centered(buffer, area, scaled(COMPACT.len(), plan.scale), SHORT_SUBTITLE, Some(bold));
        }
        Size::Line => put_centered(buffer, area, 0, LINE, Some(bold)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_size_follows_the_window() {
        assert_eq!(rows_for(195, 51), 30);
        assert_eq!(rows_for(120, 45), 30);
        assert_eq!(plan(119, 80).size, Size::Compact);
        assert_eq!(rows_for(120, 44), 27);
        assert_eq!(rows_for(195, 40), 27);
        assert_eq!(rows_for(120, 38), 27);
        assert_eq!(plan(120, 37).size, Size::Compact);
        assert_eq!(rows_for(120, 37), 15);
        assert_eq!(rows_for(55, 25), 10);
        assert_eq!(rows_for(55, 24), 1);
        assert_eq!(rows_for(54, 80), 1);
        assert_eq!(rows_for(10, 3), 1);
    }

    #[test]
    fn the_divider_fills_its_width_and_reads_the_same_both_ways() {
        for width in [0_usize, 1, 10, 49, 50, 51, 120, 195, 500] {
            let line = divider(width);
            assert_eq!(line.chars().count(), width);
        }
        let line: Vec<char> = divider(121).chars().collect();
        assert_eq!(line[0], '░');
        assert_eq!(line[120], '░');
        assert!(line.contains(&'═') && line.contains(&'▀'));
    }

    #[test]
    fn column_edges_are_solid_at_the_ends_and_dithered_in_the_middle() {
        let area = Rect::new(0, 0, 1, 21);
        let mut buffer = Buffer::empty(area);
        draw_column_edge(&mut buffer, 0, area);
        assert_eq!(buffer[(0, 0)].symbol(), "█");
        assert_eq!(buffer[(0, 20)].symbol(), "█");
        assert_eq!(buffer[(0, 10)].symbol(), "░");
        for height in [0, 1, 2] {
            let area = Rect::new(0, 0, 1, height);
            let mut buffer = Buffer::empty(area);
            draw_column_edge(&mut buffer, 0, area);
        }
    }

    #[test]
    fn the_art_fits_the_widths_it_claims() {
        assert!(FULL.iter().all(|l| l.chars().count() <= FULL_COLUMNS as usize));
        assert!(COMPACT.iter().all(|l| l.chars().count() <= COMPACT_COLUMNS as usize));
        assert!(SUBTITLE.chars().count() <= FULL_COLUMNS as usize);
        assert!(DETAILS.chars().count() <= FULL_COLUMNS as usize);
    }

    #[test]
    fn it_grows_with_the_window_and_always_leaves_the_player_room() {
        assert_eq!(plan(240, 95).scale, 2.0);
        assert!(plan(240, 95).rows > plan(195, 51).rows);
        for width in (0..500).step_by(7) {
            for height in (0..200).step_by(3) {
                let plan = plan(width, height);
                if plan.rows > 1 {
                    assert!(height - plan.rows >= 12, "{width}x{height}: {plan:?}");
                }
                assert!(plan.scale >= 1.0);
                let columns = match plan.size {
                    Size::Full | Size::Tight => FULL_COLUMNS,
                    _ => COMPACT_COLUMNS,
                };
                if plan.size != Size::Line {
                    assert!((f32::from(columns) * plan.scale) as u16 <= width, "{width}x{height}: {plan:?}");
                }
            }
        }
    }

    fn text_of(width: u16, height: u16) -> String {
        let plan = plan(width, height);
        let area = Rect::new(0, 0, width, plan.rows);
        let mut buffer = Buffer::empty(area);
        draw(&mut buffer, area, plan);
        buffer.content.iter().map(|c| c.symbol()).collect()
    }

    #[test]
    fn words_stay_whole_at_every_scale() {
        for (width, height) in [(120, 45), (150, 60), (195, 70), (240, 95), (400, 130)] {
            assert!(text_of(width, height).contains("PRESS PLAY!"), "{width}x{height}");
        }
    }

    #[test]
    fn a_scaled_logo_has_more_blocks() {
        let blocks = |text: String| text.matches('█').count();
        assert!(blocks(text_of(240, 95)) > blocks(text_of(120, 45)) * 3);
    }

    #[test]
    fn every_size_draws_in_any_area() {
        for (w, h) in [(200, 30), (120, 30), (120, 27), (55, 10), (40, 1), (5, 1), (1, 1), (10, 30), (0, 0)] {
            let area = Rect::new(0, 0, w, h);
            for size in [Size::Full, Size::Tight, Size::Compact, Size::Line] {
                for scale in [1.0, 1.25, 2.0] {
                    let mut buffer = Buffer::empty(area);
                    draw(&mut buffer, area, Plan { size, scale, rows: h });
                }
            }
        }
    }
}
