//! Render stretches of SID tunes to raw audio for the similarity benchmark
//! (`scripts/similarity-bench`). Offline only: the app doesn't use this.
//!
//!     cargo run --release -p phosphor-apple --example render_audio -- \
//!         <list.tsv> <hvsc root> <out dir> [threads] [limit]
//!
//! Each list line is `path<TAB>subtune<TAB>seconds`. Each subtune gives three
//! 10-second segments as 48 kHz mono 16-bit samples, in `<out>/<line>.s16`,
//! and a line in `<out>/manifest.tsv`:
//! `line<TAB>path<TAB>subtune<TAB>samples per segment, comma-separated`.
//! A second run skips lines already in the manifest.
//!
//! Emulation runs the whole tune, but reSID only runs for the segments and one
//! second before each, which rebuilds the voices' envelopes and oscillators
//! from the register writes applied in between.

use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use resid::{ChipModel, SamplingMethod, Sid};
use sidplayfp_sys::Player;

const SAMPLE_RATE: u32 = 48_000;
const SEGMENT_SECS: f64 = 10.0;
const WARM_UP_SECS: f64 = 1.0;
const PAL_CYCLES_PER_FRAME: u32 = 19_656;
const NTSC_CYCLES_PER_FRAME: u32 = 17_095;
const PAL_CLOCK: u32 = 985_248;
const NTSC_CLOCK: u32 = 1_022_727;

struct Job {
    line: usize,
    path: String,
    subtune: u16,
    secs: f64,
}

/// Where each segment starts, in seconds. Short tunes play from the top;
/// longer ones are sampled away from intros and endings.
fn segment_starts(secs: f64) -> Vec<f64> {
    if secs <= 3.0 * SEGMENT_SECS {
        let mut starts = Vec::new();
        let mut at = 0.0;
        while at < secs {
            starts.push(at);
            at += SEGMENT_SECS;
        }
        starts
    } else {
        [0.2, 0.5, 0.8].iter().map(|f| secs * f - SEGMENT_SECS / 2.0).collect()
    }
}

/// The chip the header asks for; 6581 when it doesn't care, like the player.
fn chip_model(data: &[u8]) -> ChipModel {
    let version = data.get(4..6).map_or(1, |b| u16::from_be_bytes([b[0], b[1]]));
    let flags = if version >= 2 {
        data.get(0x76..0x78).map_or(0, |b| u16::from_be_bytes([b[0], b[1]]))
    } else {
        0
    };
    if (flags >> 4) & 0x03 == 2 {
        ChipModel::Mos8580
    } else {
        ChipModel::Mos6581
    }
}

/// Clock every chip by `delta` cycles, adding the mix to `out` when wanted.
fn clock(sids: &mut [Sid], delta: u32, out: &mut Vec<i16>, keep: bool, scratch: &mut [Vec<i16>]) {
    if delta == 0 {
        return;
    }
    let mut buffer = [0i16; 2048];
    for (sid, chip_out) in sids.iter_mut().zip(scratch.iter_mut()) {
        chip_out.clear();
        let mut remaining = delta;
        while remaining > 0 {
            let (samples, next) = sid.sample(remaining, &mut buffer, 1);
            chip_out.extend_from_slice(&buffer[..samples]);
            if samples == 0 && next >= remaining {
                sid.clock_delta(remaining);
                break;
            }
            remaining = next;
        }
    }
    if keep {
        let n = scratch.iter().take(sids.len()).map(Vec::len).min().unwrap_or(0);
        let chips = sids.len() as i32;
        out.extend((0..n).map(|i| {
            let sum: i32 = scratch.iter().take(sids.len()).map(|c| c[i] as i32).sum();
            (sum / chips) as i16
        }));
    }
}

fn render(data: &[u8], subtune: u16, secs: f64) -> Result<Vec<Vec<i16>>, String> {
    let mut player = Player::new()?;
    player.set_roms(None, None, None);
    player.load(data, subtune)?;
    let (cycles, clock_hz) = if player.is_pal() {
        (PAL_CYCLES_PER_FRAME, PAL_CLOCK)
    } else {
        (NTSC_CYCLES_PER_FRAME, NTSC_CLOCK)
    };
    let frame_secs = cycles as f64 / clock_hz as f64;
    let model = chip_model(data);
    let chips = player.num_sids().max(1);
    let mut sids: Vec<Sid> = (0..chips)
        .map(|_| {
            let mut sid = Sid::new(model);
            sid.set_sampling_parameters(SamplingMethod::Resample, clock_hz, SAMPLE_RATE);
            sid
        })
        .collect();
    let mut scratch = vec![Vec::new(); chips];

    let starts = segment_starts(secs);
    let last_end = starts.last().copied().unwrap_or(0.0) + SEGMENT_SECS;
    let total_frames = (last_end.min(secs.max(SEGMENT_SECS)) / frame_secs).ceil() as u32;
    let mut segments: Vec<Vec<i16>> = vec![Vec::new(); starts.len()];
    let mut writes = Vec::with_capacity(256);

    for frame in 0..total_frames {
        let t = frame as f64 * frame_secs;
        let segment = starts.iter().position(|&s| t >= s && t < s + SEGMENT_SECS);
        let warming = starts.iter().any(|&s| t >= s - WARM_UP_SECS && t < s);
        let elapsed = player.play(cycles)?;
        writes.clear();
        writes.extend(player.get_writes().iter().map(|w| (w.cycle, w.sid_num, w.reg, w.val)));

        if segment.is_none() && !warming {
            // Between segments: registers only, nothing is clocked.
            for &(_, chip, reg, val) in &writes {
                if let Some(sid) = sids.get_mut(chip as usize) {
                    sid.write(reg & 0x1F, val);
                }
            }
            continue;
        }

        let mut local = Vec::new();
        let mut at = 0;
        for &(cycle, chip, reg, val) in &writes {
            let cycle = cycle.min(elapsed);
            clock(&mut sids, cycle.saturating_sub(at), &mut local, segment.is_some(), &mut scratch);
            at = at.max(cycle);
            if let Some(sid) = sids.get_mut(chip as usize) {
                sid.write(reg & 0x1F, val);
            }
        }
        clock(&mut sids, elapsed.saturating_sub(at), &mut local, segment.is_some(), &mut scratch);
        if let Some(index) = segment {
            segments[index].extend_from_slice(&local);
        }
    }
    Ok(segments)
}

fn write_samples(path: &Path, segments: &[Vec<i16>]) -> std::io::Result<()> {
    let mut bytes = Vec::with_capacity(segments.iter().map(|s| s.len() * 2).sum());
    for sample in segments.iter().flatten() {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    fs::write(path, bytes)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        eprintln!("usage: render_audio <list.tsv> <hvsc root> <out dir> [threads] [limit]");
        std::process::exit(2);
    }
    let root = PathBuf::from(&args[1]);
    let out = PathBuf::from(&args[2]);
    let threads: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(12);
    let limit: usize = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(usize::MAX);
    fs::create_dir_all(&out).expect("out dir");

    let manifest_path = out.join("manifest.tsv");
    let done: HashSet<usize> = fs::read_to_string(&manifest_path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split('\t').next()?.parse().ok())
        .collect();
    let jobs: Vec<Job> = fs::read_to_string(&args[0])
        .expect("list")
        .lines()
        .enumerate()
        .take(limit)
        .filter(|(line, _)| !done.contains(line))
        .filter_map(|(line, text)| {
            let mut parts = text.split('\t');
            Some(Job {
                line,
                path: parts.next()?.to_string(),
                subtune: parts.next()?.parse().ok()?,
                secs: parts.next()?.parse().ok()?,
            })
        })
        .collect();
    let total = jobs.len();
    println!("{total} subtunes to render, {threads} threads");

    let jobs = Arc::new(jobs);
    let next = Arc::new(AtomicUsize::new(0));
    let failed = Arc::new(AtomicUsize::new(0));
    let manifest = Arc::new(Mutex::new(
        fs::OpenOptions::new().create(true).append(true).open(&manifest_path).expect("manifest"),
    ));
    let started = Instant::now();
    let workers: Vec<_> = (0..threads)
        .map(|_| {
            let (jobs, next, failed, manifest, root, out) =
                (jobs.clone(), next.clone(), failed.clone(), manifest.clone(), root.clone(), out.clone());
            std::thread::spawn(move || loop {
                let at = next.fetch_add(1, Ordering::Relaxed);
                let Some(job) = jobs.get(at) else { break };
                let result = fs::read(root.join(&job.path)).map_err(|e| e.to_string()).and_then(|data| {
                    std::panic::catch_unwind(|| render(&data, job.subtune, job.secs))
                        .unwrap_or_else(|_| Err("panicked".to_string()))
                });
                match result {
                    Ok(segments) => {
                        let file = out.join(format!("{}.s16", job.line));
                        if write_samples(&file, &segments).is_ok() {
                            let lengths: Vec<String> = segments.iter().map(|s| s.len().to_string()).collect();
                            let mut m = manifest.lock().unwrap();
                            let _ = writeln!(m, "{}\t{}\t{}\t{}", job.line, job.path, job.subtune, lengths.join(","));
                        }
                    }
                    Err(e) => {
                        failed.fetch_add(1, Ordering::Relaxed);
                        eprintln!("{} #{}: {e}", job.path, job.subtune);
                    }
                }
                if at > 0 && at % 200 == 0 {
                    let rate = at as f64 / started.elapsed().as_secs_f64();
                    println!("{at}/{total} · {rate:.1} subtunes/s");
                }
            })
        })
        .collect();
    for worker in workers {
        let _ = worker.join();
    }
    let secs = started.elapsed().as_secs_f64();
    println!(
        "{total} in {secs:.1}s · {:.1} subtunes/s · {} failed",
        total as f64 / secs.max(1e-9),
        failed.load(Ordering::Relaxed)
    );
}
