//! Can a song length be worked out by running the tune? Runs a random sample
//! of HVSC's tunes without audio, never looking at their lengths, and scores
//! each way of guessing against DOCUMENTS/Songlengths.md5.
//!
//!     cargo run --release -p residfp-sys --example songlength_bench -- <hvsc> <count> [out.csv]
//!
//! Silence: the tune's first run of N seconds without SID writes, without any
//! register changing, with no envelope open (all at 0, or volume 0), or with
//! the rendered audio itself flat.
//! Loop: the point where the stream of SID writes (or just its note-ons) starts
//! to repeat what came before, for 2 or 3 whole copies.

use std::collections::HashMap;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use residfp_sys::{Config, Player, Write as SidWrite};

/// How much of a tune to run. A loop needs 3 copies, so this finds loops up
/// to a third of it.
const CAP_SECS: f64 = 900.0;
/// No writes for this long: the tune is over, nothing more to learn.
const GIVE_UP_SILENT_SECS: f64 = 35.0;
const FRAMES_PER_SEC: f64 = 50.0;
/// Rendered, not skipped: `rsfp_skip` forgets the writes it logged. The rate
/// only has to show whether there is sound.
const RATE: u32 = 8_000;
/// Peak to peak, in a frame of 16-bit audio: about -70 dB.
const FLAT: i32 = 20;
/// Quiet from the very start is a tune that hasn't begun, not one that ended.
const MIN_ELAPSED_SECS: f64 = 1.0;
/// A repeat shorter than this is a held note or a drum pattern.
const MIN_PERIOD_SECS: f64 = 8.0;
/// More writes than this is a digi tune; the loop search would need gigabytes.
const MAX_TOKENS: usize = 3_000_000;

#[derive(Default)]
struct Trace {
    /// Per frame.
    wrote: Vec<bool>,
    changed: Vec<bool>,
    closed: Vec<bool>,
    flat: Vec<bool>,
    /// Every write: chip, register, value.
    exact: Vec<u32>,
    exact_at: Vec<f64>,
    /// Every note-on: chip, voice, waveform, frequency's high byte.
    notes: Vec<u32>,
    notes_at: Vec<f64>,
    lost_writes: u64,
    secs: f64,
    /// Ran to the end rather than giving up early on silence.
    hit_cap: bool,
}

fn run(data: &[u8], song: u16) -> Result<Trace, String> {
    let mut p = Player::new()?;
    p.load_bytes(data)?;
    let cfg = Config { sample_rate: RATE, power_on_delay: Some(0x800), ..Config::default() };
    let started = p.start(song, &cfg)?;
    let chips = p.chips();
    let mut audio = vec![0i16; (f64::from(RATE) / FRAMES_PER_SEC) as usize * 2];
    let mut tr = Trace::default();
    let mut log = vec![SidWrite { cycle: 0, reg: 0, val: 0 }; 16_384];
    let mut regs = vec![[0u8; 32]; chips];
    let mut gate = vec![[false; 3]; chips];
    let mut quiet_frames = 0u32;
    let cap_frames = (CAP_SECS * FRAMES_PER_SEC) as usize;
    let give_up = (GIVE_UP_SILENT_SECS * FRAMES_PER_SEC) as u32;

    for _ in 0..cap_frames {
        if p.render(&mut audio) < audio.len() / 2 {
            break;
        }
        let (lo, hi) = audio.iter().fold((i32::MAX, i32::MIN), |(lo, hi), &v| {
            (lo.min(i32::from(v)), hi.max(i32::from(v)))
        });
        let (mut wrote, mut changed, mut audible) = (false, false, false);
        let mut batch: Vec<(u32, u8, SidWrite)> = Vec::new();
        for c in 0..chips {
            let (copied, happened) = p.take_writes(c, &mut log);
            tr.lost_writes += u64::from(happened).saturating_sub(copied as u64);
            batch.extend(log[..copied].iter().map(|w| (w.cycle, c as u8, *w)));
        }
        batch.sort_by_key(|b| b.0);
        for (_, c, w) in &batch {
            wrote = true;
            let (c, r) = (*c as usize, (w.reg & 0x1f) as usize);
            if regs[c][r] != w.val {
                changed = true;
                // A changing volume is a digi: audible whatever the envelopes do.
                if r == 24 && regs[c][r] & 15 != w.val & 15 {
                    audible = true;
                }
            }
            regs[c][r] = w.val;
            let at = f64::from(w.cycle) / started.cpu_hz;
            if tr.exact.len() < MAX_TOKENS {
                tr.exact.push((c as u32) << 16 | (r as u32) << 8 | u32::from(w.val));
                tr.exact_at.push(at);
            }
            if r < 21 && r % 7 == 4 {
                let v = r / 7;
                let on = w.val & 1 != 0;
                if on && !gate[c][v] {
                    tr.notes.push(
                        (c as u32) << 20
                            | (v as u32) << 16
                            | u32::from(w.val & 0xf0) << 8
                            | u32::from(regs[c][v * 7 + 1]),
                    );
                    tr.notes_at.push(at);
                }
                gate[c][v] = on;
            }
        }
        for c in 0..chips {
            if let Some(s) = p.chip_state(c) {
                if s.regs[24] & 15 != 0 && s.env.iter().any(|&e| e > 0) {
                    audible = true;
                }
            }
        }
        tr.wrote.push(wrote);
        tr.changed.push(changed);
        tr.closed.push(!audible);
        tr.flat.push(hi - lo < FLAT);
        quiet_frames = if wrote { 0 } else { quiet_frames + 1 };
        if quiet_frames >= give_up {
            break;
        }
    }
    tr.secs = tr.wrote.len() as f64 / FRAMES_PER_SEC;
    tr.hit_cap = tr.wrote.len() >= cap_frames;
    Ok(tr)
}

/// Where the first run of `secs` of `quiet` frames starts, past the intro.
fn first_run(quiet: &[bool], secs: f64) -> Option<f64> {
    let need = (secs * FRAMES_PER_SEC) as usize;
    let min = (MIN_ELAPSED_SECS * FRAMES_PER_SEC) as usize;
    let mut len = 0;
    for (i, &q) in quiet.iter().enumerate() {
        len = if q { len + 1 } else { 0 };
        let start = i + 1 - len;
        if len >= need && start >= min {
            return Some(start as f64 / FRAMES_PER_SEC);
        }
    }
    None
}

/// The first point from which the stream repeats what came before it, for
/// `copies` whole copies counting the one before. A(A)B doesn't pass with 3.
fn find_loop(tokens: &[u32], at: &[f64], window: usize, copies: usize) -> Option<f64> {
    let n = tokens.len();
    if n <= window {
        return None;
    }
    const B: u64 = 0x100_0000_01B3;
    let top = (0..window - 1).fold(1u64, |h, _| h.wrapping_mul(B));
    let mut h = tokens[..window]
        .iter()
        .fold(0u64, |h, &t| h.wrapping_mul(B).wrapping_add(u64::from(t) + 1));
    let mut seen: HashMap<u64, u32> = HashMap::with_capacity(n / 2);
    let mut skip_until = 0;
    for i in 0..=n - window {
        if i >= skip_until {
            if let Some(&p) = seen.get(&h) {
                let p = p as usize;
                let period = i - p;
                if at[i] - at[p] >= MIN_PERIOD_SECS {
                    let need = (copies - 1) * period;
                    match (0..need.min(n - i)).find(|&k| tokens[i + k] != tokens[i + k - period]) {
                        Some(k) => skip_until = i + k + 1,
                        // Ran out of tune before the copies were all there.
                        None if i + need > n => return None,
                        None => return Some(at[i]),
                    }
                }
            }
        }
        seen.entry(h).or_insert(i as u32);
        if i + window < n {
            h = h
                .wrapping_sub((u64::from(tokens[i]) + 1).wrapping_mul(top))
                .wrapping_mul(B)
                .wrapping_add(u64::from(tokens[i + window]) + 1);
        }
    }
    None
}

const DETECTORS: [&str; 18] = [
    "no writes 3 s (the app today)",
    "no writes 10 s",
    "no writes 30 s",
    "envelopes closed 3 s",
    "envelopes closed 10 s",
    "envelopes closed 30 s",
    "flat audio 3 s",
    "flat audio 10 s",
    "flat audio 30 s",
    "no register change 3 s",
    "no register change 10 s",
    "no register change 30 s",
    "loop, all writes, 2 copies",
    "loop, all writes, 3 copies",
    "loop, note-ons, 2 copies",
    "loop, note-ons, 3 copies",
    "flat 10 s or loop all-3",
    "flat 10 s, all-3 or notes-3",
];

fn detect(t: &Trace) -> Vec<Option<f64>> {
    let no_writes: Vec<bool> = t.wrote.iter().map(|w| !w).collect();
    let no_change: Vec<bool> = t.changed.iter().map(|c| !c).collect();
    let exact = |copies| {
        (t.exact.len() < MAX_TOKENS)
            .then(|| find_loop(&t.exact, &t.exact_at, 512, copies))
            .flatten()
    };
    let notes = |copies| find_loop(&t.notes, &t.notes_at, 24, copies);
    let (quiet10, all3, notes3) = (first_run(&t.flat, 10.0), exact(3), notes(3));
    let earliest = |v: &[Option<f64>]| {
        v.iter().flatten().copied().min_by(|a, b| a.partial_cmp(b).unwrap())
    };
    vec![
        first_run(&no_writes, 3.0),
        first_run(&no_writes, 10.0),
        first_run(&no_writes, 30.0),
        first_run(&t.closed, 3.0),
        first_run(&t.closed, 10.0),
        first_run(&t.closed, 30.0),
        first_run(&t.flat, 3.0),
        quiet10,
        first_run(&t.flat, 30.0),
        first_run(&no_change, 3.0),
        first_run(&no_change, 10.0),
        first_run(&no_change, 30.0),
        exact(2),
        all3,
        notes(2),
        notes3,
        earliest(&[quiet10, all3]),
        earliest(&[quiet10, all3, notes3]),
    ]
}

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
    let bytes = fs::read(path).expect("Songlengths.md5");
    let text = String::from_utf8_lossy(&bytes);
    let mut out = Vec::new();
    let mut pending = None;
    for line in text.lines() {
        if let Some(p) = line.strip_prefix("; ") {
            pending = Some(p.trim().to_string());
        } else if let Some((_, times)) = line.split_once('=') {
            if let Some(p) = pending.take() {
                out.push((p, times.split_whitespace().filter_map(parse_time).collect()));
            }
        }
    }
    out
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let root = PathBuf::from(&args[0]);
    let count: usize = args[1].parse().unwrap();
    let out_path = args.get(2).cloned();
    let mut db = read_db(&root.join("DOCUMENTS/Songlengths.md5"));
    db.sort_by(|a, b| a.0.cmp(&b.0));

    // The same tunes each run; one subtune of each.
    let mut seed: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut next = move || {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (seed >> 33) as usize
    };
    for i in (1..db.len()).rev() {
        db.swap(i, next() % (i + 1));
    }
    let cases: Vec<Case> = db
        .iter()
        .filter(|(_, t)| !t.is_empty())
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
    let started = std::time::Instant::now();
    let workers: Vec<_> = (0..threads)
        .map(|_| {
            let (cases, results, root) = (cases.clone(), results.clone(), root.clone());
            std::thread::spawn(move || loop {
                let Some(c) = cases.lock().unwrap().next() else { return };
                let file = root.join(c.path.trim_start_matches('/'));
                let t0 = std::time::Instant::now();
                let outcome = fs::read(&file)
                    .map_err(|e| e.to_string())
                    .and_then(|d| run(&d, c.song).map(|t| (detect(&t), t.lost_writes, t.secs, t.hit_cap)));
                let took = t0.elapsed().as_secs_f64();
                results.lock().unwrap().push((c, outcome, took));
            })
        })
        .collect();
    for w in workers {
        w.join().unwrap();
    }
    let results = Arc::try_unwrap(results).ok().unwrap().into_inner().unwrap();

    let mut csv = out_path.map(|p| fs::File::create(p).unwrap());
    if let Some(f) = csv.as_mut() {
        let names: Vec<String> = DETECTORS.iter().map(|d| format!("\"{d}\"")).collect();
        writeln!(f, "path,song,truth,{}", names.join(",")).unwrap();
    }
    let ok: Vec<_> = results.iter().filter_map(|(c, r, took)| r.as_ref().ok().map(|r| (c, r, *took))).collect();
    let failed = results.len() - ok.len();
    println!(
        "{} of {total} tunes ran ({failed} failed) in {:.0} s on {threads} threads; {:.2} s of processor time per tune; {} with writes lost",
        ok.len(),
        started.elapsed().as_secs_f64(),
        ok.iter().map(|r| r.2).sum::<f64>() / ok.len().max(1) as f64,
        ok.iter().filter(|r| r.1 .1 > 0).count(),
    );
    println!(
        "{:<32} {:>6} {:>6} {:>6} {:>6} {:>6} {:>6}",
        "", "±1 s", "±3 s", "±10%", "early", "late", "none"
    );
    let pct = |n: usize| 100.0 * n as f64 / ok.len().max(1) as f64;
    for (d, name) in DETECTORS.iter().enumerate() {
        let (mut one, mut three, mut tenth, mut early, mut late, mut none) = (0, 0, 0, 0, 0, 0);
        for (c, r, _) in &ok {
            match r.0[d] {
                None => none += 1,
                Some(g) => {
                    let e = g - c.truth;
                    if e.abs() <= 1.0 {
                        one += 1;
                    }
                    if e.abs() <= 3.0 {
                        three += 1;
                    }
                    if e.abs() <= (c.truth * 0.1).max(3.0) {
                        tenth += 1;
                    } else if e < 0.0 {
                        early += 1;
                    } else {
                        late += 1;
                    }
                }
            }
        }
        println!(
            "{name:<32} {:>5.1}% {:>5.1}% {:>5.1}% {:>5.1}% {:>5.1}% {:>5.1}%",
            pct(one), pct(three), pct(tenth), pct(early), pct(late), pct(none)
        );
    }
    if let Some(f) = csv.as_mut() {
        for (c, r, _) in &ok {
            let cols: Vec<String> = r.0.iter().map(|g| g.map_or(String::new(), |g| format!("{g:.2}"))).collect();
            writeln!(f, "\"{}\",{},{:.2},{}", c.path, c.song, c.truth, cols.join(",")).unwrap();
        }
    }
    for (c, r, _) in &results {
        if let Err(e) = r {
            println!("failed: {} song {}: {e}", c.path, c.song);
        }
    }
}
