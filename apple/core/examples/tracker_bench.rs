//! How well the tracker view's rebuild does on real tunes: the check for changing
//! `core/src/tracker.rs`. Prints numbers, and with `show`, rows to read; it writes no
//! tune data anywhere.
//!
//!     cargo run --release -p phosphor-apple --example tracker_bench -- sample <hvsc root> [count]
//!     cargo run --release -p phosphor-apple --example tracker_bench -- show <file> [subtune] [first row]
//!     cargo run --release -p phosphor-apple --example tracker_bench -- chips <file> [subtune]

use std::path::{Path, PathBuf};
use std::time::Instant;

use phosphor_apple::{chip_agreement, tracker_song, TrackerEffect, TrackerSong};

const SECONDS: f64 = 120.0;

fn walk(dir: &Path, found: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk(&path, found);
        } else if path.extension().is_some_and(|e| e.eq_ignore_ascii_case("sid")) {
            found.push(path);
        }
    }
}

fn counts(song: &TrackerSong) -> (usize, usize, usize, usize) {
    let cells = song.rows.iter().flat_map(|r| r.voices.iter());
    let (mut notes, mut arps, mut slides, mut vibs) = (0, 0, 0, 0);
    for cell in cells {
        notes += cell.note.is_some() as usize;
        match cell.effect {
            TrackerEffect::Arpeggio => arps += 1,
            TrackerEffect::Slide => slides += 1,
            TrackerEffect::Vibrato => vibs += 1,
            TrackerEffect::None => {}
        }
    }
    (notes, arps, slides, vibs)
}

fn show(path: &str, subtune: u16, first: usize) {
    let data = std::fs::read(path).unwrap();
    let began = Instant::now();
    let song = tracker_song(&data, subtune, SECONDS, 0, &|| false).unwrap().unwrap();
    let (notes, arps, slides, vibs) = counts(&song);
    println!(
        "{path}\n  {:.2}s to rebuild, {:.0} frames/s, {} frames a row, {:.0}% on grid, grid {}; {} rows, {notes} notes, {arps} arp {slides} slide {vibs} vib, {} instruments",
        began.elapsed().as_secs_f32(), song.frame_rate, song.frames_per_row, song.on_grid * 100.0, song.has_grid, song.rows.len(), song.instruments.len(),
    );
    for (n, i) in song.instruments.iter().enumerate().take(8) {
        println!("  {:02X} {:<16} {:02X} {:02X}", n + 1, i.name, i.attack_decay, i.sustain_release);
    }
    for (n, row) in song.rows.iter().enumerate().skip(first).take(32) {
        let cells: Vec<String> = row.voices.iter().map(|c| {
            let note = match (&c.note, c.off) { (Some(n), _) => n.clone(), (None, true) => "---".into(), _ => "···".into() };
            let inst = if c.instrument > 0 { format!("{:02X}", c.instrument) } else { "··".into() };
            let fx = match c.effect { TrackerEffect::Arpeggio => "ARP", TrackerEffect::Slide => "SLD", TrackerEffect::Vibrato => "VIB", TrackerEffect::None => "···" };
            format!("{note} {inst} {fx}")
        }).collect();
        println!("  {n:04X}  {}", cells.join("  "));
    }
}

/// How much a multi-SID tune's chips differ, by what notes they start.
fn chips(path: &str, subtune: u16) {
    let data = std::fs::read(path).unwrap();
    let first = tracker_song(&data, subtune, SECONDS, 0, &|| false).unwrap().unwrap();
    println!("{path}: {} chips, {} rows", first.chips, first.rows.len());
    for chip in 1..first.chips as usize {
        let other = tracker_song(&data, subtune, SECONDS, chip, &|| false).unwrap().unwrap();
        let rows = first.rows.len().min(other.rows.len());
        for v in 0..3 {
            let notes = |song: &TrackerSong| song.rows.iter().filter(|r| r.voices[v].note.is_some()).count();
            let same = (0..rows).filter(|&n| first.rows[n].voices[v].note.is_some() && first.rows[n].voices[v].note == other.rows[n].voices[v].note).count();
            println!("  SID {} V{}: {} notes against SID 1's {}, {same} the same on the same row", chip + 1, v + 1, notes(&other), notes(&first));
        }
        let (voices, filter) = chip_agreement(&data, subtune, SECONDS, 0, chip).unwrap();
        for (v, [freq, pulse, gate]) in voices.iter().enumerate() {
            println!("  V{}: same frequency {:.0}% of frames, pulse width {:.0}%, gate {:.0}%", v + 1, freq * 100.0, pulse * 100.0, gate * 100.0);
        }
        println!("  filter: same cutoff {:.0}%, resonance {:.0}%", filter[0] * 100.0, filter[1] * 100.0);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("show") => show(&args[1], args.get(2).and_then(|a| a.parse().ok()).unwrap_or(1), args.get(3).and_then(|a| a.parse().ok()).unwrap_or(0)),
        Some("chips") => chips(&args[1], args.get(2).and_then(|a| a.parse().ok()).unwrap_or(1)),
        Some("sample") => {
            let mut all = Vec::new();
            walk(Path::new(&args[1]), &mut all);
            all.sort();
            let count: usize = args.get(2).and_then(|a| a.parse().ok()).unwrap_or(200);
            let step = (all.len() / count).max(1);
            let (mut gridded, mut total, mut failed) = (0, 0, 0);
            let mut times = Vec::new();
            let mut periods = std::collections::BTreeMap::<String, usize>::new();
            let mut scores = Vec::new();
            let mut no_notes = 0;
            for path in all.iter().step_by(step).take(count) {
                let data = std::fs::read(path).unwrap();
                let began = Instant::now();
                match tracker_song(&data, 1, SECONDS, 0, &|| false) {
                    Ok(Some(song)) => {
                        times.push(began.elapsed().as_secs_f32());
                        total += 1;
                        gridded += song.has_grid as usize;
                        scores.push(song.on_grid);
                        *periods.entry(if song.has_grid { format!("{:>4}", song.frames_per_row) } else { "none".into() }).or_default() += 1;
                        no_notes += (counts(&song).0 == 0) as usize;
                    }
                    _ => failed += 1,
                }
            }
            times.sort_by(f32::total_cmp);
            scores.sort_by(f32::total_cmp);
            println!("{total} tunes, {failed} failed, {gridded} on a grid ({:.0}%), {no_notes} with no notes", gridded as f32 * 100.0 / total as f32);
            println!("time for {SECONDS} s of tune: median {:.3}s, worst {:.3}s", times[times.len() / 2], times[times.len() - 1]);
            println!("on-grid: p10 {:.2} median {:.2} p90 {:.2}", scores[scores.len() / 10], scores[scores.len() / 2], scores[scores.len() * 9 / 10]);
            println!("frames a row: {periods:?}");
        }
        _ => eprintln!("sample <root> [count], or show <file> [subtune] [first row]"),
    }
}
