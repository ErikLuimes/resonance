//! A fingerprint in characters: one bar per trait, always in the same place, so
//! tunes that sound alike look alike. The same barcode at two sizes, and what the
//! side panel shows beside it. Height carries the value and colour only the group,
//! so it reads on any terminal and without the colours.

use crate::model::Mix;
use crate::palette;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

pub const TRAITS: usize = 9;
/// How wide the barcode is in a list.
pub const SMALL_WIDTH: u16 = TRAITS as u16;
const BLOCKS: [char; 9] = [' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
const LABELS: [&str; TRAITS] = ["Nt", "Ar", "Vb", "Fl", "Rm", "Sy", "Dg", "Nz", "Pw"];
const MEANINGS: [&str; TRAITS] =
    ["Notes", "Arpeggios", "Vibrato", "Filter", "Ring modulation", "Hard sync", "Digi samples", "Noise, mostly drums", "Pulse-width sweeps"];

fn value(traits: &[f32], index: usize) -> f32 {
    traits.get(index).copied().unwrap_or(0.0).clamp(0.0, 1.0)
}

/// One row of nine, with what's absent still marking its place.
pub fn small(traits: &[f32]) -> Vec<Span<'static>> {
    (0..TRAITS)
        .map(|index| {
            let level = (value(traits, index) * 8.0).round() as usize;
            if level == 0 {
                Span::styled("▁", Style::new().fg(palette::faint()))
            } else {
                Span::styled(BLOCKS[level].to_string(), Style::new().fg(palette::trait_color(index)))
            }
        })
        .collect()
}

/// A tune with no fingerprint, or not one yet.
pub fn none() -> Span<'static> {
    Span::styled("·".repeat(TRAITS), Style::new().fg(palette::faint()))
}

/// The barcode `rows` tall, bars two wide, with the labels under it.
pub fn tall(traits: &[f32], rows: usize) -> Vec<Line<'static>> {
    let mut lines = Vec::with_capacity(rows + 1);
    for row in (0..rows).rev() {
        let mut spans = Vec::with_capacity(TRAITS);
        for index in 0..TRAITS {
            let filled = (value(traits, index) * (rows * 8) as f32).round() as usize;
            let level = filled.saturating_sub(row * 8).min(8);
            let span = match (level, row) {
                (0, 0) => Span::styled("▁▁ ", Style::new().fg(palette::faint())),
                (0, _) => Span::raw("   "),
                _ => Span::styled(format!("{0}{0} ", BLOCKS[level]), Style::new().fg(palette::trait_color(index))),
            };
            spans.push(span);
        }
        lines.push(Line::from(spans));
    }
    lines.push(Line::styled(LABELS.join(" "), palette::dim()));
    lines
}

/// The waveforms' shares, largest first, with their colours as in the app.
fn shares(mix: &Mix) -> Vec<(&'static str, f32, Color)> {
    let total = (mix.triangle + mix.saw + mix.pulse + mix.noise).max(f32::EPSILON);
    let mut parts = vec![
        ("Pulse", mix.pulse / total, palette::cyan()),
        ("Noise", mix.noise / total, palette::orange()),
        ("Tri", mix.triangle / total, palette::green()),
        ("Saw", mix.saw / total, palette::violet()),
    ];
    parts.sort_by(|a, b| b.1.total_cmp(&a.1));
    parts
}

/// One bar in the waveforms' colours, and their names and shares as far as they fit.
pub fn mix_lines(mix: &Mix, width: usize) -> Vec<Line<'static>> {
    let parts = shares(mix);
    let mut bar = Vec::with_capacity(parts.len());
    let mut used = 0;
    let mut reach = 0.0;
    for (_, share, color) in &parts {
        reach += share;
        let end = ((reach * width as f32).round() as usize).min(width);
        bar.push(Span::styled("█".repeat(end - used), Style::new().fg(*color)));
        used = end;
    }
    let mut words = Vec::new();
    let mut room = width;
    for (name, share, color) in &parts {
        let percent = (share * 100.0).round() as u32;
        if percent == 0 {
            continue;
        }
        let word = format!("{name} {percent}");
        let needs = word.chars().count() + if words.is_empty() { 0 } else { 2 };
        if needs > room {
            break;
        }
        room -= needs;
        if !words.is_empty() {
            words.push(Span::raw("  "));
        }
        words.push(Span::styled(word, Style::new().fg(*color)));
    }
    vec![Line::from(bar), Line::from(words)]
}

/// How loud each voice is from the start of the tune to its end, against its
/// loudest moment on any voice.
pub fn voice_lines(activity: &[Vec<u8>], width: usize, ink: impl Fn(usize) -> Color) -> Vec<Line<'static>> {
    let bars = width.saturating_sub(3).max(1);
    let loudest = activity.iter().flatten().copied().max().unwrap_or(0).max(1);
    let mut lines: Vec<Line> = activity
        .iter()
        .take(3)
        .enumerate()
        .map(|(voice, levels)| {
            let mut spans = vec![Span::styled(format!("V{} ", voice + 1), palette::dim())];
            let text: String = (0..bars)
                .map(|bar| {
                    let from = bar * levels.len() / bars;
                    let to = ((bar + 1) * levels.len() / bars).max(from + 1).min(levels.len());
                    let stretch = levels.get(from..to).unwrap_or(&[]);
                    let mean = stretch.iter().map(|l| u32::from(*l)).sum::<u32>() / stretch.len().max(1) as u32;
                    BLOCKS[((mean * 8 / u32::from(loudest)) as usize).clamp(1, 8)]
                })
                .collect();
            spans.push(Span::styled(text, Style::new().fg(ink(voice))));
            Line::from(spans)
        })
        .collect();
    let gap = bars.saturating_sub("start".len() + "end".len());
    lines.push(Line::styled(format!("   start{}end", " ".repeat(gap)), palette::dim()));
    lines
}

/// What the `?` screen says about all of this.
pub fn legend() -> Vec<Line<'static>> {
    let mut lines = vec![Line::styled("Reading a fingerprint", Style::new().fg(palette::accent()).add_modifier(Modifier::BOLD))];
    for index in 0..TRAITS {
        lines.push(Line::from(vec![
            Span::styled("█ ", Style::new().fg(palette::trait_color(index))),
            Span::styled(format!("{} ", LABELS[index]), palette::dim()),
            Span::raw(MEANINGS[index]),
        ]));
    }
    lines.push(Line::raw(""));
    for text in ["Taller means more of it. Tunes that", "sound alike look alike.", "", "The panel also shows the waveforms", "used, and each voice's loudness", "from the start of the tune to the end."] {
        lines.push(Line::styled(text, palette::dim()));
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(line: &Line) -> String {
        line.spans.iter().map(|s| s.content.to_string()).collect()
    }

    const TUNE: [f32; TRAITS] = [0.5, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.25, 0.75];

    #[test]
    fn small_has_a_bar_for_every_trait_in_its_place() {
        let spans = small(&TUNE);
        let shown: String = spans.iter().map(|s| s.content.to_string()).collect();
        assert_eq!(shown, "▄▁█▁▁▁▁▂▆");
        assert_eq!(spans[1].style.fg, Some(palette::faint()));
        assert_eq!(spans[2].style.fg, Some(palette::trait_color(2)));
    }

    #[test]
    fn a_short_or_wild_print_still_makes_nine_bars() {
        assert_eq!(small(&[]).len(), TRAITS);
        let shown: String = small(&[9.0, -1.0]).iter().map(|s| s.content.to_string()).collect();
        assert!(shown.starts_with("█▁"));
    }

    #[test]
    fn tall_stacks_from_the_bottom_with_labels_under_it() {
        let lines = tall(&TUNE, 3);
        assert_eq!(lines.len(), 4);
        assert_eq!(text(&lines[3]), "Nt Ar Vb Fl Rm Sy Dg Nz Pw");
        // 0.5 of three rows: full, half and nothing.
        assert!(text(&lines[2]).starts_with("██ "));
        assert!(text(&lines[1]).starts_with("▄▄ "));
        assert!(text(&lines[0]).starts_with("   "));
        assert!(text(&lines[2]).contains("▁▁"));
        for line in &lines[..3] {
            assert_eq!(text(line).chars().count(), TRAITS * 3);
        }
    }

    #[test]
    fn the_mix_bar_fills_its_width_largest_first() {
        let mix = Mix { triangle: 0.1, saw: 0.0, pulse: 0.6, noise: 0.3 };
        let lines = mix_lines(&mix, 30);
        assert_eq!(text(&lines[0]).chars().count(), 30);
        assert_eq!(text(&lines[1]), "Pulse 60  Noise 30  Tri 10");
    }

    #[test]
    fn the_mix_names_only_what_fits_and_survives_silence() {
        let mix = Mix { triangle: 0.25, saw: 0.25, pulse: 0.25, noise: 0.25 };
        assert!(text(&mix_lines(&mix, 12)[1]).chars().count() <= 12);
        let nothing = Mix { triangle: 0.0, saw: 0.0, pulse: 0.0, noise: 0.0 };
        assert_eq!(text(&mix_lines(&nothing, 10)[1]), "");
    }

    #[test]
    fn voices_shrink_or_stretch_to_the_width() {
        let activity = vec![vec![0, 255], (0..=255).collect(), vec![]];
        let lines = voice_lines(&activity, 13, |_| palette::cyan());
        assert_eq!(lines.len(), 4);
        for line in &lines[..3] {
            assert_eq!(text(line).chars().count(), 13);
        }
        assert_eq!(text(&lines[0]), "V1 ▁▁▁▁▁█████");
        assert!(text(&lines[3]).ends_with("end"));
    }

    #[test]
    fn the_legend_names_every_trait() {
        let all: String = legend().iter().map(text).collect();
        for label in LABELS.iter().chain(MEANINGS.iter()) {
            assert!(all.contains(label), "{label}");
        }
    }
}
