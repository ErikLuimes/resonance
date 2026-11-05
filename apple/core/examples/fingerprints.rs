//! Drive the fingerprint scan and "Sounds like" through `PlayerCore`.
//!
//!     cargo run -p phosphor-apple --example fingerprints -- scan [seconds]
//!     cargo run -p phosphor-apple --example fingerprints -- show <tune path>
//!     cargo run -p phosphor-apple --example fingerprints -- similar <tune path>
//!
//! Uses Phosphor's HVSC folder. The store lives in the temp folder
//! (`resonance-fingerprints/`), not the app's, and persists between runs,
//! so a second `scan` resumes the first.

use std::time::{Duration, Instant};

use phosphor_apple::{
    shared_defaults, CoreConfig, Engine, PlaybackOptions, PlayerCore, Repeat, TuneFingerprint,
};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dir = std::env::temp_dir().join("resonance-fingerprints");
    std::fs::create_dir_all(&dir).unwrap();
    let root = shared_defaults().hvsc_root;
    let core = PlayerCore::new(CoreConfig {
        engine: Engine::SidLite,
        volume: 0.0,
        options: PlaybackOptions {
            skip_rsid: false,
            default_song_length_secs: 0,
            force_stereo_2sid: false,
            pseudo_stereo: None,
        },
        shuffle: false,
        repeat: Repeat::Off,
        session_path: dir.join("session.m3u").to_string_lossy().into_owned(),
        hvsc_root: root.clone(),
    });
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    // A path relative to the collection, or absolute.
    let tune = |arg: Option<&String>| {
        let arg = arg.cloned().unwrap_or_default();
        match &root {
            Some(r) if !arg.starts_with('/') => format!("{r}/{arg}"),
            _ => arg,
        }
    };

    runtime.block_on(async {
        match args.first().map(String::as_str) {
            Some("scan") => {
                let secs: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(30);
                let started = Instant::now();
                if let Err(e) = core.start_fingerprint_scan().await {
                    eprintln!("{e}");
                    return;
                }
                let first = core.fingerprint_scan_status();
                println!("started in {:?}: {first:?}", started.elapsed());
                let t0 = Instant::now();
                while t0.elapsed() < Duration::from_secs(secs) {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    let s = core.fingerprint_scan_status();
                    let rate = (s.done - first.done) as f64 / t0.elapsed().as_secs_f64();
                    println!(
                        "pass {} · {} / {} done, {} failed · {rate:.1} subtunes/s",
                        s.pass, s.done, s.total, s.failed
                    );
                    if s.finished || !s.running {
                        break;
                    }
                }
                core.shutdown();
            }
            Some("show") => match core.fingerprint(tune(args.get(1)), None).await {
                Some(fp) => print_fingerprint(&fp),
                None => println!("not scanned yet"),
            },
            Some("similar") => match core.similar_tunes(tune(args.get(1)), None, 12).await {
                Ok(hits) if hits.is_empty() => println!("not scanned yet"),
                Ok(hits) => {
                    for h in hits {
                        println!(
                            "{:>4.0}%  {:<36} {:<28} #{}  {}",
                            h.score.max(0.0) * 100.0,
                            h.item.title,
                            h.item.author,
                            h.subtune,
                            h.item.path
                        );
                    }
                }
                Err(e) => eprintln!("{e}"),
            },
            _ => eprintln!("usage: fingerprints scan [seconds] | show <path> | similar <path>"),
        }
    });
}

fn print_fingerprint(fp: &TuneFingerprint) {
    let bins = fp.bins as usize;
    for voice in 0..3 {
        let lane: String = fp.activity[voice * bins..(voice + 1) * bins]
            .iter()
            .step_by(2)
            .map(|&a| b" .:-=+*#%@"[a as usize * 9 / 255] as char)
            .collect();
        println!("  {lane}");
    }
    println!(
        "  #{} · {:.0}s · tri {:.0}% saw {:.0}% pul {:.0}% noi {:.0}%",
        fp.subtune,
        fp.scanned_secs,
        fp.mix.triangle * 100.0,
        fp.mix.saw * 100.0,
        fp.mix.pulse * 100.0,
        fp.mix.noise * 100.0
    );
    println!("  {:?}", fp.tags);
}
