//! Shaded edges for the terminal player frame.

use crate::palette;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::Color;

/// The edge of a column: solid at the ends, dithered in the middle.
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

/// The frame stays back from what's in it.
fn frame_shade(ch: char) -> Color {
    match ch {
        '█' | '▓' => palette::frame(),
        _ => palette::faint(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

}
