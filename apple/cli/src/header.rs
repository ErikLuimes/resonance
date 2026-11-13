//! Thin lines over and between the terminal player's panes, as on a BBS.

use crate::palette;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;

/// A thin line down the edge of a column, fading out over its last rows instead
/// of stopping short. Where the top line runs above it, it joins it: ┬ between
/// columns, a corner at the window's sides.
pub fn draw_column_edge(buffer: &mut Buffer, x: u16, area: Rect) {
    let fade = (area.height / 3).max(1);
    for row in 0..area.height {
        let left = area.height - row;
        let keep = if left > fade { 1.0 } else { f32::from(left) / f32::from(fade + 1) };
        if let Some(cell) = buffer.cell_mut((x, area.y + row)) {
            cell.set_char('│').set_fg(palette::frame_fading(keep));
        }
    }
    let Some(y) = area.y.checked_sub(1) else { return };
    let (first, last) = (buffer.area.left(), buffer.area.right().saturating_sub(1));
    if let Some(cell) = buffer.cell_mut((x, y)).filter(|c| c.symbol() == "─") {
        cell.set_char(if x == first { '┌' } else if x == last { '┐' } else { '┬' });
    }
}

/// The line across the top of the panes.
pub fn draw_top_line(buffer: &mut Buffer, area: Rect) {
    for n in 0..area.width {
        if let Some(cell) = buffer.cell_mut((area.x + n, area.y)) {
            cell.set_char('─').set_fg(palette::frame());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn columns_hang_from_the_top_line() {
        let area = Rect::new(0, 0, 9, 4);
        let mut buffer = Buffer::empty(area);
        draw_top_line(&mut buffer, Rect::new(0, 0, 9, 1));
        for x in [0, 4, 8] {
            draw_column_edge(&mut buffer, x, Rect::new(0, 1, 9, 3));
        }
        let top: String = (0..9).map(|x| buffer[(x, 0)].symbol()).collect();
        assert_eq!(top, "┌───┬───┐");
    }

    #[test]
    fn edges_are_lines_that_fade_out_at_the_bottom() {
        let area = Rect::new(0, 0, 1, 12);
        let mut buffer = Buffer::empty(area);
        draw_column_edge(&mut buffer, 0, area);
        assert!((0..12).all(|y| buffer[(0, y)].symbol() == "│"));
        assert_eq!(buffer[(0, 0)].fg, palette::frame());
        assert_ne!(buffer[(0, 11)].fg, palette::frame());
        for height in [0, 1, 2] {
            let area = Rect::new(0, 0, 1, height);
            draw_column_edge(&mut Buffer::empty(area), 0, area);
        }
    }
}
