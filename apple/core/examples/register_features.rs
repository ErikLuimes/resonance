//! Research features for the similarity benchmark (candidate B in
//! `scripts/similarity-bench`): what the 22 fingerprint features leave out,
//! from the same register writes. Offline only: the app doesn't use this.
//!
//!     cargo run --release -p phosphor-apple --example register_features -- \
//!         <list.tsv> <hvsc root> <out.tsv> [threads]
//!
//! Each list line is `path<TAB>subtune<TAB>seconds`. Each output line is
//! `path<TAB>subtune<TAB>` and the values of `NAMES`, tab-separated.

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use sidplayfp_sys::Player;

const NAMES: [&str; 19] = [
    "attack", "decay", "sustain", "release", "attack_spread", "release_spread", "filter_lp", "filter_bp",
    "filter_hp", "resonance", "chip_8580", "chips", "combined_waves", "notes_over_time", "note_gap_spread",
    "same_note", "small_step", "mid_step", "big_step",
];

const TIME_BINS: usize = 8;

#[derive(Default)]
struct Running {
    n: f64,
    sum: f64,
    squares: f64,
}

impl Running {
    fn push(&mut self, x: f64) {
        self.n += 1.0;
        self.sum += x;
        self.squares += x * x;
    }
    fn mean(&self) -> f64 {
        if self.n > 0.0 { self.sum / self.n } else { 0.0 }
    }
    fn std(&self) -> f64 {
        if self.n > 1.0 { (self.squares / self.n - self.mean().powi(2)).max(0.0).sqrt() } else { 0.0 }
    }
}

fn is_8580(data: &[u8]) -> bool {
    let version = data.get(4..6).map_or(1, |b| u16::from_be_bytes([b[0], b[1]]));
    version >= 2 && data.get(0x76..0x78).is_some_and(|b| (u16::from_be_bytes([b[0], b[1]]) >> 4) & 3 == 2)
}

fn extract(data: &[u8], subtune: u16, secs: f64) -> Result<[f64; NAMES.len()], String> {
    let mut player = Player::new()?;
    player.set_roms(None, None, None);
    player.load(data, subtune)?;
    let (cycles, clock) = if player.is_pal() { (19_656u32, 985_248.0) } else { (17_095u32, 1_022_727.0) };
    let chips = player.num_sids().clamp(1, 3);
    let frames = (secs * clock / cycles as f64).ceil().max(1.0) as usize;

    let mut regs = [[0u8; 32]; 3];
    let (mut attack, mut decay, mut sustain, mut release) =
        (Running::default(), Running::default(), Running::default(), Running::default());
    let mut filter_frames = 0.0f64;
    let (mut lp, mut bp, mut hp) = (0.0f64, 0.0f64, 0.0f64);
    let mut resonance = Running::default();
    let (mut sounding, mut combined) = (0.0f64, 0.0f64);
    let mut notes_in_bin = [0.0f64; TIME_BINS];
    let mut last_note_frame = [None::<usize>; 9];
    let mut last_midi = [None::<f64>; 9];
    let mut gaps = Running::default();
    let mut intervals = [0.0f64; 4];

    for frame in 0..frames {
        player.play(cycles)?;
        let mut started = [false; 9];
        for w in player.get_writes() {
            let chip = w.sid_num as usize;
            let reg = (w.reg & 0x1F) as usize;
            if chip >= chips {
                continue;
            }
            if reg < 0x15 && reg % 7 == 4 && regs[chip][reg] & 1 == 0 && w.val & 1 == 1 {
                started[chip * 3 + reg / 7] = true;
            }
            regs[chip][reg] = w.val;
        }
        for chip in 0..chips {
            let r = &regs[chip];
            let routed = r[0x17] & 0x0F != 0;
            if routed {
                filter_frames += 1.0;
                lp += ((r[0x18] >> 4) & 1) as f64;
                bp += ((r[0x18] >> 5) & 1) as f64;
                hp += ((r[0x18] >> 6) & 1) as f64;
                resonance.push((r[0x17] >> 4) as f64 / 15.0);
            }
            for v in 0..3 {
                let base = v * 7;
                let id = chip * 3 + v;
                let waves = r[base + 4] >> 4;
                if r[base + 4] & 1 == 1 && waves != 0 {
                    sounding += 1.0;
                    combined += (waves.count_ones() > 1) as u8 as f64;
                }
                if !started[id] {
                    continue;
                }
                attack.push((r[base + 5] >> 4) as f64 / 15.0);
                decay.push((r[base + 5] & 15) as f64 / 15.0);
                sustain.push((r[base + 6] >> 4) as f64 / 15.0);
                release.push((r[base + 6] & 15) as f64 / 15.0);
                notes_in_bin[frame * TIME_BINS / frames] += 1.0;
                if let Some(last) = last_note_frame[id] {
                    gaps.push((1.0 + (frame - last) as f64).ln());
                }
                last_note_frame[id] = Some(frame);
                let freq = (r[base] as u16 | ((r[base + 1] as u16) << 8)) as f64 * clock / 16_777_216.0;
                if freq > 8.0 && waves & 8 == 0 {
                    let midi = 69.0 + 12.0 * (freq / 440.0).log2();
                    if let Some(last) = last_midi[id] {
                        let step = (midi - last).abs();
                        let bin = if step < 0.5 {
                            0
                        } else if step < 2.5 {
                            1
                        } else if step < 7.5 {
                            2
                        } else {
                            3
                        };
                        intervals[bin] += 1.0;
                    }
                    last_midi[id] = Some(midi);
                }
            }
        }
    }

    let filter_total = filter_frames.max(1.0);
    let bin_mean = notes_in_bin.iter().sum::<f64>() / TIME_BINS as f64;
    let bin_spread = (notes_in_bin.iter().map(|n| (n - bin_mean).powi(2)).sum::<f64>() / TIME_BINS as f64).sqrt();
    let interval_total = intervals.iter().sum::<f64>().max(1.0);
    Ok([
        attack.mean(),
        decay.mean(),
        sustain.mean(),
        release.mean(),
        attack.std(),
        release.std(),
        lp / filter_total,
        bp / filter_total,
        hp / filter_total,
        resonance.mean(),
        is_8580(data) as u8 as f64,
        chips as f64,
        combined / sounding.max(1.0),
        if bin_mean > 0.0 { bin_spread / bin_mean } else { 0.0 },
        gaps.std(),
        intervals[0] / interval_total,
        intervals[1] / interval_total,
        intervals[2] / interval_total,
        intervals[3] / interval_total,
    ])
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        eprintln!("usage: register_features <list.tsv> <hvsc root> <out.tsv> [threads]");
        std::process::exit(2);
    }
    let root = PathBuf::from(&args[1]);
    let threads: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(12);
    let jobs: Arc<Vec<(String, u16, f64)>> = Arc::new(
        fs::read_to_string(&args[0])
            .expect("list")
            .lines()
            .filter_map(|l| {
                let mut p = l.split('\t');
                Some((p.next()?.to_string(), p.next()?.parse().ok()?, p.next()?.parse().ok()?))
            })
            .collect(),
    );
    let mut file = fs::File::create(&args[2]).expect("out");
    writeln!(file, "path\tsubtune\t{}", NAMES.join("\t")).expect("write");
    let out = Arc::new(Mutex::new(file));
    let next = Arc::new(AtomicUsize::new(0));
    let failed = Arc::new(AtomicUsize::new(0));
    let workers: Vec<_> = (0..threads)
        .map(|_| {
            let (jobs, next, failed, out, root) =
                (jobs.clone(), next.clone(), failed.clone(), out.clone(), root.clone());
            std::thread::spawn(move || loop {
                let Some((path, subtune, secs)) = jobs.get(next.fetch_add(1, Ordering::Relaxed)) else { break };
                let result = fs::read(root.join(path)).map_err(|e| e.to_string()).and_then(|data| {
                    std::panic::catch_unwind(|| extract(&data, *subtune, *secs))
                        .unwrap_or_else(|_| Err("panicked".to_string()))
                });
                match result {
                    Ok(values) => {
                        let text: Vec<String> = values.iter().map(|v| format!("{v:.5}")).collect();
                        let _ = writeln!(out.lock().unwrap(), "{path}\t{subtune}\t{}", text.join("\t"));
                    }
                    Err(e) => {
                        failed.fetch_add(1, Ordering::Relaxed);
                        eprintln!("{path} #{subtune}: {e}");
                    }
                }
            })
        })
        .collect();
    for worker in workers {
        let _ = worker.join();
    }
    println!("{} done, {} failed", jobs.len(), failed.load(Ordering::Relaxed));
}
