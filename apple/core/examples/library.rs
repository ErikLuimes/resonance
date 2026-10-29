//! Exercise the HVSC library through `PlayerCore`, as Swift does.
//!
//!     cargo run -p phosphor-apple --example library -- authors [musicians|games|demos]
//!     cargo run -p phosphor-apple --example library -- tunes <author folder>
//!     cargo run -p phosphor-apple --example library -- search <query> [category]
//!     cargo run -p phosphor-apple --example library -- surprise [category]
//!
//! Uses Phosphor's HVSC folder, and its shared index cache: the first
//! search in a category builds the index (tens of seconds for Musicians),
//! later runs load it from the cache.

use std::time::Instant;

use phosphor_apple::{
    shared_defaults, CoreConfig, Engine, HvscCategory, PlaybackOptions, PlayerCore, Repeat,
};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let category = |arg: Option<&String>| match arg.map(|s| s.to_lowercase()).as_deref() {
        Some("games") => Some(HvscCategory::Games),
        Some("demos") => Some(HvscCategory::Demos),
        Some("musicians") => Some(HvscCategory::Musicians),
        _ => None,
    };
    let session =
        std::env::temp_dir().join(format!("resonance-library-{}.m3u", std::process::id()));
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
        session_path: session.to_string_lossy().into_owned(),
        hvsc_root: shared_defaults().hvsc_root,
    });
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let started = Instant::now();

    let outcome = runtime.block_on(async {
        match args.first().map(String::as_str) {
            Some("authors") => {
                let authors = core
                    .hvsc_authors(category(args.get(1)).unwrap_or(HvscCategory::Musicians))
                    .await?;
                for a in authors.iter().take(15) {
                    println!("{:>2}  {:<32} {}", a.letter, a.display_name, a.path);
                }
                println!("… {} in total", authors.len());
            }
            Some("tunes") => {
                let path = args.get(1).cloned().unwrap_or_default();
                for t in core.hvsc_tunes(path).await? {
                    println!(
                        "{:<36} {:<24} songs {:>2}  {:>5}  stil {}",
                        t.title,
                        t.released,
                        t.songs,
                        t.duration_secs.map_or("—".into(), |s| format!(
                            "{}:{:02}",
                            s / 60,
                            s % 60
                        )),
                        if t.has_stil { "✓" } else { " " },
                    );
                }
            }
            Some("search") => {
                let query = args.get(1).cloned().unwrap_or_default();
                let r = core.hvsc_search(query, category(args.get(2))).await?;
                for t in r.items.iter().take(10) {
                    println!("{:<36} {:<24} {:?}", t.title, t.author, t.category);
                }
                println!("{} matches among {} tunes", r.total_matches, r.indexed);
            }
            Some("surprise") => {
                println!("{:?}", core.hvsc_surprise(category(args.get(1))).await?);
            }
            _ => eprintln!("usage: library authors|tunes|search|surprise …"),
        }
        Ok::<_, phosphor_apple::HvscError>(())
    });
    if let Err(e) = outcome {
        eprintln!("error: {e}");
    }
    eprintln!("({:.2}s)", started.elapsed().as_secs_f32());
    core.shutdown();
    let _ = std::fs::remove_file(session);
}
