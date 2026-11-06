//! Scores the detection Resonance ships against HVSC's own song lengths: runs
//! a random sample of tunes, never looking at their lengths, and compares.
//! See design/songlengths/README.md.
//!
//!     cargo run --release -p phosphor-apple --example songlength_bench -- <hvsc> <count> <seed> [out.csv]
//!
//! Tuning against one seed and quoting another keeps the score honest.

use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use phosphor_apple::{estimate_length, LengthEstimate, LengthMethod};

struct Case {
    path: String,
    song: u16,
    truth: f64,
}

fn parse_time(s: &str) -> Option<f64> {
    let s = s.split('(').next()?;
    let (m, sec) = s.split_once(':')?;
    Some(m.parse::<f64>().ok()? * 60.0 + sec.parse::<f64>().ok()?)
}

fn read_db(path: &Path) -> Vec<(String, Vec<f64>)> {
    let bytes = fs::read(path).expect("DOCUMENTS/Songlengths.md5");
    let text = String::from_utf8_lossy(&bytes);
    let mut out = Vec::new();
    let mut pending = None;
    for line in text.lines() {
        if let Some(p) = line.strip_prefix("; ") {
            pending = Some(p.trim().to_string());
        } else if let Some((_, times)) = line.split_once('=') {
            if let Some(p) = pending.take() {
                out.push((p, times.split_whitespace().filter_map(parse_time).collect::<Vec<_>>()));
            }
        }
    }
    out.retain(|(_, t)| !t.is_empty());
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let root = PathBuf::from(&args[0]);
    let count: usize = args[1].parse().unwrap();
    let mut seed: u64 = args[2].parse().unwrap();
    let mut next = move || {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (seed >> 33) as usize
    };
    let mut db = read_db(&root.join("DOCUMENTS/Songlengths.md5"));
    for i in (1..db.len()).rev() {
        db.swap(i, next() % (i + 1));
    }
    let cases: Vec<Case> = db
        .iter()
        .take(count)
        .map(|(p, t)| {
            let i = next() % t.len();
            Case { path: p.clone(), song: i as u16 + 1, truth: t[i] }
        })
        .collect();

    let total = cases.len();
    let cases = Arc::new(Mutex::new(cases.into_iter()));
    let results = Arc::new(Mutex::new(Vec::new()));
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get().saturating_sub(2).max(1));
    let started = Instant::now();
    let workers: Vec<_> = (0..threads)
        .map(|_| {
            let (cases, results, root) = (cases.clone(), results.clone(), root.clone());
            std::thread::spawn(move || loop {
                let Some(c) = cases.lock().unwrap().next() else { return };
                let file = root.join(c.path.trim_start_matches('/'));
                let t0 = Instant::now();
                let outcome = fs::read(&file)
                    .map_err(|e| e.to_string())
                    .and_then(|d| estimate_length(&d, c.song, &|| false));
                results.lock().unwrap().push((c, outcome, t0.elapsed().as_secs_f64()));
            })
        })
        .collect();
    for w in workers {
        w.join().unwrap();
    }
    let results = Arc::try_unwrap(results).ok().unwrap().into_inner().unwrap();

    let ran: Vec<(&Case, Option<LengthEstimate>, f64)> = results
        .iter()
        .filter_map(|(c, r, took)| r.as_ref().ok().map(|e| (c, *e, *took)))
        .collect();
    let mut took: Vec<f64> = ran.iter().map(|r| r.2).collect();
    took.sort_by(f64::total_cmp);
    println!(
        "{} of {total} ran in {:.0} s on {threads} threads; processor time per subtune: median {:.1} s, 90th {:.1} s, max {:.1} s",
        ran.len(),
        started.elapsed().as_secs_f64(),
        took[took.len() / 2],
        took[took.len() * 9 / 10],
        took[took.len() - 1],
    );
    let (mut three, mut right, mut early, mut late, mut none) = (0, 0, 0, 0, 0);
    let (mut by_silence, mut by_loop) = (0, 0);
    for (c, e, _) in &ran {
        let Some(e) = e else {
            none += 1;
            continue;
        };
        match e.method {
            LengthMethod::Silence => by_silence += 1,
            LengthMethod::Loop => by_loop += 1,
        }
        let off = e.secs - c.truth;
        if off.abs() <= 3.0 {
            three += 1;
        }
        if off.abs() <= (c.truth * 0.1).max(3.0) {
            right += 1;
        } else if off < 0.0 {
            early += 1;
        } else {
            late += 1;
        }
    }
    let pct = |n: i32| 100.0 * f64::from(n) / ran.len().max(1) as f64;
    println!(
        "within 3 s {:.1}%, within 10% {:.1}%, too short {:.1}%, too long {:.1}%, no answer {:.1}%",
        pct(three), pct(right), pct(early), pct(late), pct(none)
    );
    println!("answers from silence {:.1}%, from a loop {:.1}%", pct(by_silence), pct(by_loop));

    if let Some(out) = args.get(3) {
        let mut f = fs::File::create(out).unwrap();
        writeln!(f, "path,song,truth,estimate,method").unwrap();
        for (c, e, _) in &ran {
            let (secs, method) = e.map_or((String::new(), ""), |e| {
                (format!("{:.2}", e.secs), if e.method == LengthMethod::Loop { "loop" } else { "silence" })
            });
            writeln!(f, "\"{}\",{},{:.2},{secs},{method}", c.path, c.song, c.truth).unwrap();
        }
    }
    for (c, r, _) in &results {
        if let Err(e) = r {
            println!("failed: {} song {}: {e}", c.path, c.song);
        }
    }
}
