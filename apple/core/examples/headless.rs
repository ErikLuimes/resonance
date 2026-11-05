//! Play tunes through `PlayerCore` from the terminal, without any UI.
//!
//!     cargo run -p phosphor-apple --example headless -- <file.sid|folder|list.m3u>...
//!
//! Env: RESONANCE_ENGINE=resid switches from SIDLite to reSID, =residfp to
//! reSIDfp (libsidplayfp), =sidlite-direct to SIDLite direct;
//! RESONANCE_LENGTH=<secs> sets the default song length (default 8, so
//! auto-advance shows up quickly); RESONANCE_VOLUME=<0–1> (default 0.8).
//! Uses a throwaway session file.

use std::time::Duration;

use phosphor_apple::{
    shared_defaults, CoreConfig, Engine, PlaybackOptions, PlaybackState, PlayerCore, Repeat,
};

fn main() {
    let paths: Vec<String> = std::env::args().skip(1).collect();
    if paths.is_empty() {
        eprintln!("usage: headless <file.sid|folder|list.m3u>...");
        std::process::exit(2);
    }
    let engine = match std::env::var("RESONANCE_ENGINE").as_deref() {
        Ok("resid") => Engine::ReSid,
        Ok("residfp") => Engine::ReSidFp,
        Ok("sidlite-direct") => Engine::SidLiteDirect,
        _ => Engine::SidLite,
    };
    let length = std::env::var("RESONANCE_LENGTH")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8);
    let session =
        std::env::temp_dir().join(format!("resonance-headless-{}.m3u", std::process::id()));

    let volume = std::env::var("RESONANCE_VOLUME")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0.8);
    let core = PlayerCore::new(CoreConfig {
        engine,
        volume,
        options: PlaybackOptions {
            skip_rsid: false,
            default_song_length_secs: length,
            force_stereo_2sid: false,
            pseudo_stereo: None,
        },
        shuffle: false,
        repeat: Repeat::Off,
        session_path: session.to_string_lossy().into_owned(),
        hvsc_root: shared_defaults().hvsc_root,
    });
    core.add_paths(paths, true);

    let mut last_revision = u64::MAX;
    let mut started = false;
    loop {
        std::thread::sleep(Duration::from_millis(250));
        let s = core.snapshot();
        if let Some(loading) = &s.loading {
            println!("… {loading}");
        }
        if let Some(e) = &s.error {
            println!("! {e}");
        }
        if s.track_revision != last_revision {
            last_revision = s.track_revision;
            if let Some(t) = &s.track {
                println!(
                    "▶ [{}] {} — {} ({}), song {}/{}, length {:?}s, engine {:?}",
                    s.current_index.map_or(-1, |i| i as i64),
                    t.title,
                    t.author,
                    t.released,
                    t.current_song,
                    t.songs,
                    s.duration_ms.map(|d| d / 1000),
                    s.engine,
                );
            }
        }
        if s.state == PlaybackState::Playing {
            started = true;
            let bars: String = core
                .viz_latest()
                .iter()
                .flat_map(|f| &f.chips)
                .flat_map(|c| &c.voices)
                .map(|v| {
                    [' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█']
                        [(v.env_level.clamp(0.0, 1.0) * 8.0) as usize]
                })
                .collect();
            let shadow = core.viz_stats().shadow_micros;
            print!(
                "\r  {:>5.1}s |{bars}|  shadow {shadow:>4.0} µs/frame   ",
                s.elapsed_ms as f64 / 1000.0
            );
            use std::io::Write;
            let _ = std::io::stdout().flush();
        } else if started && s.state == PlaybackState::Stopped {
            println!("\n■ playlist finished");
            break;
        }
    }
    core.shutdown();
    let _ = std::fs::remove_file(session);
}
