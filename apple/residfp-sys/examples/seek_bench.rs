//! Measurements for scrubbing: how long skipping ahead in a tune takes with
//! each way of clocking the chips, against playing there, and how close the
//! chips' state and the audio after a digital-only skip are to a full one.
//!
//!     cargo run --release -p residfp-sys --example seek_bench -- <secs> <tune>...
//!     cargo run --release -p residfp-sys --example seek_bench -- survey <secs> <count> <dir>
//!
//! The survey picks `count` tunes under `dir` (the same ones each run) and
//! compares a digital-only skip with a full one on reSIDfp.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use residfp_sys::{Chip, ChipState, Config, Player, SkipMode};

const RATE: u32 = 48_000;
/// Audio compared after a skip, in four half-second segments; the first
/// starts after the settling time.
const COMPARE_SECS: f64 = 2.0;
/// SEEK_BENCH_SETTLE overrides the settling time.
fn settle_secs() -> f64 {
    std::env::var("SEEK_BENCH_SETTLE").ok().and_then(|s| s.parse().ok()).unwrap_or(0.1)
}
const SEGMENTS: usize = 4;

fn fresh(data: &[u8], chip: Chip) -> Result<(Player, f64), String> {
    let mut p = Player::new()?;
    p.load_bytes(data)?;
    let cfg = Config {
        sample_rate: RATE,
        chip,
        power_on_delay: Some(0x800),
        ..Config::default()
    };
    let started = p.start(0, &cfg)?;
    // SEEK_BENCH_FILTER=0 plays every chip without its filter.
    if std::env::var("SEEK_BENCH_FILTER").ok().as_deref() == Some("0") {
        for c in 0..p.chips() {
            p.filter(c, false);
        }
    }
    Ok((p, started.cpu_hz))
}

fn render_secs(p: &mut Player, secs: f64) -> Result<Vec<i16>, String> {
    let frames = (RATE as f64 * secs) as usize;
    let mut buf = vec![0i16; frames * 2];
    let mut done = 0;
    while done < frames {
        let n = (frames - done).min(2048);
        let got = p.render(&mut buf[done * 2..(done + n) * 2]);
        if got < n {
            return Err(format!("render stopped: {}", p.error()));
        }
        done += got;
    }
    Ok(buf)
}

/// Loudness envelopes (RMS per 10 ms window, left channel): relative RMS
/// of their difference per half-second segment after the settling time.
/// Insensitive to the sub-sample phase the resampler's position adds.
fn envelope_diffs(a: &[i16], b: &[i16]) -> [f64; SEGMENTS] {
    let from = (RATE as f64 * settle_secs()) as usize * 2;
    let win = (RATE / 100) as usize * 2;
    let env = |x: &[i16]| -> Vec<f64> {
        x[from..]
            .chunks(win)
            .map(|c| {
                (c.iter().step_by(2).map(|&v| (v as f64).powi(2)).sum::<f64>()
                    / (c.len() / 2) as f64)
                    .sqrt()
            })
            .collect()
    };
    let (ea, eb) = (env(a), env(b));
    let per = (RATE as f64 * (COMPARE_SECS - settle_secs()) / SEGMENTS as f64 / (win / 2) as f64)
        .floor() as usize;
    let mut out = [0.0; SEGMENTS];
    for (s, o) in out.iter_mut().enumerate() {
        let r = s * per..((s + 1) * per).min(ea.len()).min(eb.len());
        let num: f64 = r.clone().map(|i| (ea[i] - eb[i]).powi(2)).sum();
        let den: f64 = r.map(|i| ea[i] * ea[i]).sum();
        *o = if den == 0.0 { 0.0 } else { (num / den).sqrt() };
    }
    out
}

/// The C64 alone up to `DIGITAL_SECS` before the target, the chips' digital
/// parts from there, and everything for the last `RENDER_SECS`, so the
/// envelopes catch up and the filter settles before the audio resumes.
const RENDER_SECS: f64 = 0.5;
/// SEEK_BENCH_DIGITAL overrides the digital window.
fn digital_secs() -> f64 {
    std::env::var("SEEK_BENCH_DIGITAL").ok().and_then(|s| s.parse().ok()).unwrap_or(3.0)
}

fn skip_hybrid(p: &mut Player, cycles: u64, cpu_hz: f64) -> u64 {
    let render = (RENDER_SECS * cpu_hz) as u64;
    let digital = (digital_secs() * cpu_hz) as u64;
    let mut done = 0;
    let none_part = cycles.saturating_sub(render + digital);
    done += p.skip(none_part, SkipMode::None);
    let digital_part = cycles.saturating_sub(render).saturating_sub(none_part);
    done += p.skip(digital_part, SkipMode::Digital);
    done += p.skip(cycles - none_part - digital_part, SkipMode::Render);
    done
}

fn fmt_diffs(d: &[f64; SEGMENTS]) -> String {
    d.iter().map(|x| format!("{x:.3}")).collect::<Vec<_>>().join(" ")
}

/// The chips' digital state right after a skip, as the visualizers read it.
fn states(p: &Player) -> Vec<ChipState> {
    (0..p.chips()).map(|c| p.chip_state(c).unwrap()).collect()
}

fn state_diff(a: &[ChipState], b: &[ChipState]) -> String {
    let mut out = Vec::new();
    for (c, (x, y)) in a.iter().zip(b).enumerate() {
        if x.regs != y.regs {
            out.push(format!("chip {c} regs"));
        }
        if x.env != y.env {
            out.push(format!("chip {c} env {:?} vs {:?}", x.env, y.env));
        }
        if x.osc3 != y.osc3 {
            out.push(format!("chip {c} osc3 {} vs {}", x.osc3, y.osc3));
        }
        if x.env3 != y.env3 {
            out.push(format!("chip {c} env3 {} vs {}", x.env3, y.env3));
        }
    }
    if out.is_empty() {
        "identical".into()
    } else {
        out.join(", ")
    }
}

fn bench(secs: f64, path: &str) -> Result<(), String> {
    let data = fs::read(path).map_err(|e| e.to_string())?;
    println!("\n{path}: skipping {secs} s");
    for chip in [Chip::ReSidFp, Chip::SidLite] {
        let (mut p, cpu_hz) = fresh(&data, chip)?;
        println!("  {chip:?}, {} chip(s), {cpu_hz:.0} Hz", p.chips());

        // Playing there, as the baseline; the skips run exactly as many
        // cycles as playing did.
        let t = Instant::now();
        render_secs(&mut p, secs)?;
        let play = t.elapsed();
        let cycles = p.cycles();
        println!(
            "    play           {:7.0} ms  ({:5.1} ms per second of tune)",
            play.as_secs_f64() * 1e3,
            play.as_secs_f64() * 1e3 / secs
        );

        let mut reference: Option<(Vec<i16>, Vec<ChipState>)> = None;
        for mode in ["Render", "Render", "Digital", "None", "Hybrid"] {
            let (mut p, _) = fresh(&data, chip)?;
            let t = Instant::now();
            let done = match mode {
                "Render" => p.skip(cycles, SkipMode::Render),
                "Digital" => p.skip(cycles, SkipMode::Digital),
                "None" => p.skip(cycles, SkipMode::None),
                _ => skip_hybrid(&mut p, cycles, cpu_hz),
            };
            let took = t.elapsed();
            if done < cycles {
                return Err(format!("skip stopped: {}", p.error()));
            }
            let state = states(&p);
            let after = render_secs(&mut p, COMPARE_SECS + settle_secs())?;
            print!(
                "    skip {:<9} {:7.0} ms  ({:5.1} ms per second of tune)",
                mode,
                took.as_secs_f64() * 1e3,
                took.as_secs_f64() * 1e3 / secs
            );
            match &reference {
                Some((audio, st)) => {
                    println!(
                        "  vs Render: state {}; loudness diff per ½ s: {}",
                        state_diff(st, &state),
                        fmt_diffs(&envelope_diffs(audio, &after))
                    );
                    // SEEK_BENCH_DUMP=1 prints both loudness envelopes at 100 ms.
                    if std::env::var("SEEK_BENCH_DUMP").is_ok() {
                        let win = (RATE / 10) as usize * 2;
                        let env = |x: &[i16]| -> Vec<f64> {
                            x.chunks(win)
                                .map(|c| (c.iter().step_by(2).map(|&v| (v as f64).powi(2)).sum::<f64>() / (c.len() / 2) as f64).sqrt())
                                .collect()
                        };
                        let (ea, eb) = (env(audio), env(&after));
                        println!("      ref : {}", ea.iter().map(|v| format!("{v:5.0}")).collect::<Vec<_>>().join(" "));
                        println!("      this: {}", eb.iter().map(|v| format!("{v:5.0}")).collect::<Vec<_>>().join(" "));
                    }
                }
                None => {
                    println!("  (reference)");
                    reference = Some((after, state));
                }
            }
        }
    }
    Ok(())
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            collect(&p, out);
        } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("sid")) {
            out.push(p);
        }
    }
}

fn survey(secs: f64, count: usize, dir: &str) {
    let mut files = Vec::new();
    collect(Path::new(dir), &mut files);
    files.sort();
    let mut idx: Vec<usize> = (0..files.len()).collect();
    let mut seed: u64 = 0x9E37_79B9_7F4A_7C15;
    for i in (1..idx.len()).rev() {
        seed = seed
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        idx.swap(i, (seed >> 33) as usize % (i + 1));
    }
    println!("{} tunes under {dir}; {count} of them, skipping {secs} s on reSIDfp", files.len());
    println!(
        "{:<58} {:<8} {:<23}   {:<8} {}",
        "tune", "digital", "loudness diff per ½ s", "hybrid", "loudness diff per ½ s"
    );
    let mut firsts = Vec::new();
    let mut lasts = Vec::new();
    let mut hfirsts = Vec::new();
    let mut hlasts = Vec::new();
    let mut identical = 0;
    let mut hybrid_identical = 0;
    let mut tried = 0;
    for &i in idx.iter().take(count) {
        let path = &files[i];
        let name = path.strip_prefix(dir).unwrap_or(path).display().to_string();
        let name: String = name.chars().rev().take(56).collect::<Vec<_>>().into_iter().rev().collect();
        let run = || -> Result<(String, [f64; SEGMENTS], String, [f64; SEGMENTS]), String> {
            let data = fs::read(path).map_err(|e| e.to_string())?;
            let (mut a, cpu_hz) = fresh(&data, Chip::ReSidFp)?;
            let cycles = (cpu_hz * secs) as u64;
            if a.skip(cycles, SkipMode::Render) < cycles {
                return Err(a.error());
            }
            let sa = states(&a);
            let aa = render_secs(&mut a, COMPARE_SECS + settle_secs())?;
            let (mut b, _) = fresh(&data, Chip::ReSidFp)?;
            if b.skip(cycles, SkipMode::Digital) < cycles {
                return Err(b.error());
            }
            let sb = states(&b);
            let ab = render_secs(&mut b, COMPARE_SECS + settle_secs())?;
            let (mut h, _) = fresh(&data, Chip::ReSidFp)?;
            if skip_hybrid(&mut h, cycles, cpu_hz) < cycles {
                return Err(h.error());
            }
            let sh = states(&h);
            let ah = render_secs(&mut h, COMPARE_SECS + settle_secs())?;
            Ok((state_diff(&sa, &sb), envelope_diffs(&aa, &ab), state_diff(&sa, &sh), envelope_diffs(&aa, &ah)))
        };
        match run() {
            Ok((st, d, sth, dh)) => {
                tried += 1;
                if st == "identical" {
                    identical += 1;
                }
                if sth == "identical" {
                    hybrid_identical += 1;
                }
                firsts.push(d[0]);
                lasts.push(d[SEGMENTS - 1]);
                hfirsts.push(dh[0]);
                hlasts.push(dh[SEGMENTS - 1]);
                println!(
                    "{name:<58} {:<8} {}   {:<8} {}",
                    if st == "identical" { "same" } else { "DIFFERS" },
                    fmt_diffs(&d),
                    if sth == "identical" { "same" } else { "DIFFERS" },
                    fmt_diffs(&dh)
                );
                if st != "identical" {
                    println!("    digital: {st}");
                }
                if sth != "identical" {
                    println!("    hybrid: {sth}");
                }
            }
            Err(e) => println!("{name:<58} skipped: {e}"),
        }
    }
    let stats = |v: &mut Vec<f64>| {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let n = v.len();
        if n == 0 {
            return "none".to_string();
        }
        format!("median {:.3}, 90th {:.3}, max {:.3}", v[n / 2], v[n * 9 / 10], v[n - 1])
    };
    println!(
        "\n{tried} tunes. digital skip: state identical on {identical}; loudness diff first ½ s: {}; last ½ s: {}",
        stats(&mut firsts),
        stats(&mut lasts)
    );
    println!(
        "hybrid skip ({} s digital, {RENDER_SECS} s full): state identical on {hybrid_identical}; loudness diff first ½ s: {}; last ½ s: {}",
        digital_secs(),
        stats(&mut hfirsts),
        stats(&mut hlasts)
    );
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("survey") {
        let secs: f64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(30.0);
        let count: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(50);
        let dir = args.get(3).map(String::as_str).unwrap_or(".");
        survey(secs, count, dir);
        return;
    }
    let secs: f64 = args.first().and_then(|s| s.parse().ok()).unwrap_or(60.0);
    for path in args.iter().skip(1) {
        if let Err(e) = bench(secs, path) {
            println!("  {e}");
        }
    }
}
