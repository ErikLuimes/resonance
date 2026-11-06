//! How the smart playlist recipes behave over many picks. There is no
//! reference for "chill" or "different", so these are proxies: see
//! `design/smart-playlists`. Change `smart.rs` only against this.
//!
//!     cp ~/Library/Application\ Support/Resonance/{fingerprints.sqlite,heard.txt} "$TMPDIR/resonance-smart-bench/"
//!     cargo run -p phosphor-apple --release --example smart_bench -- <collection folder> [picks]
//!
//! Both are copies in the temp folder, so the app's are left alone.

use std::collections::HashSet;

use phosphor_apple::{
    CoreConfig, Engine, PlaybackOptions, PlayerCore, Repeat, SmartChip, SmartEnergy, SmartKind, SmartPlaylist, SmartRecipe,
    SmartSection,
};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let root = args.first().expect("the collection folder").clone();
    let picks: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(20);
    let dir = std::env::temp_dir().join("resonance-smart-bench");
    std::fs::create_dir_all(&dir).unwrap();
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
        hvsc_root: Some(root),
    });
    let recipe = |kind, shuffle| SmartRecipe {
        kind,
        seeds: Vec::new(),
        top: 200,
        other_versions: false,
        min_secs: 0,
        only_unheard: kind == SmartKind::Different,
        total_secs: Some(3600),
        title_words: None,
        composers: Vec::new(),
        sounds: Vec::new(),
        chip: SmartChip::Any,
        min_chips: None,
        max_chips: None,
        max_tunes: None,
        from_year: None,
        to_year: None,
        section: SmartSection::Any,
        energy: SmartEnergy::Any,
        shuffle,
    };
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();

    runtime.block_on(async {
        let run = |kind, shuffle| {
            let recipe = recipe(kind, shuffle);
            async { core.smart_playlist(recipe).await.expect("a playlist") }
        };

        let rising: Vec<SmartPlaylist> = {
            let mut lists = Vec::new();
            for shuffle in 0..picks {
                lists.push(run(SmartKind::Rising, shuffle).await);
            }
            lists
        };
        println!("Chill to Intense, {picks} one-hour picks from {} tunes", rising[0].pool);
        print_lengths(&rising);
        let mean = |levels: Vec<f32>| levels.iter().sum::<f32>() / levels.len().max(1) as f32;
        // Intensity by where in the hour a tune starts.
        let mut thirds = [Vec::new(), Vec::new(), Vec::new()];
        let mut ends = Vec::new();
        let mut falls = 0;
        let mut steps = 0;
        for list in &rising {
            let total = list.total_secs as f32;
            let mut elapsed = 0f32;
            let climb_from = list
                .tunes
                .iter()
                .scan(0f32, |e, t| {
                    let at = *e / total;
                    *e += t.item.duration_secs.unwrap_or(0) as f32;
                    Some(at)
                })
                .position(|at| at >= 0.6)
                .unwrap_or(0);
            for (i, tune) in list.tunes.iter().enumerate() {
                let level = tune.intensity.unwrap_or(0.0);
                thirds[((elapsed / total * 3.0) as usize).min(2)].push(level);
                elapsed += tune.item.duration_secs.unwrap_or(0) as f32;
                if i > climb_from {
                    steps += 1;
                    if level < list.tunes[i - 1].intensity.unwrap_or(0.0) {
                        falls += 1;
                    }
                }
            }
            ends.push(list.tunes.last().and_then(|t| t.intensity).unwrap_or(0.0));
        }
        println!(
            "  intensity by third of the hour: {:.2} {:.2} {:.2}, last tune {:.2}",
            mean(thirds[0].clone()),
            mean(thirds[1].clone()),
            mean(thirds[2].clone()),
            mean(ends)
        );
        println!("  steps down while climbing: {falls} of {steps}");
        print_composers(&rising);
        print_overlap(&rising);

        let mut different = Vec::new();
        for shuffle in 0..picks {
            different.push(run(SmartKind::Different, shuffle).await);
        }
        if different[0].needs_more_history {
            println!("New to Me: only {} tunes heard, too few", different[0].heard);
        } else {
            println!("New to Me, {picks} one-hour picks from {} tunes unlike {} heard", different[0].pool, different[0].heard);
            print_lengths(&different);
            print_composers(&different);
            print_overlap(&different);
            let heard: usize = different.iter().map(|l| l.tunes.iter().filter(|t| t.heard).count()).sum();
            println!("  heard tunes picked: {heard}");
        }

        // What's asked for holds for other versions too: they're added by name.
        let seed = format!("{}/MUSICIANS/H/Hubbard_Rob/Commando.sid", args[0]);
        let dual = core
            .smart_playlist(SmartRecipe { seeds: vec![seed], other_versions: true, min_chips: Some(2), ..recipe(SmartKind::Like, 0) })
            .await
            .expect("a playlist");
        let single: Vec<&str> =
            dual.tunes.iter().filter(|t| sid_chips(&t.item.path) < 2).map(|t| t.item.path.as_str()).collect();
        let versions = dual.tunes.iter().filter(|t| t.is_version).count();
        println!("Like Commando, dual SID: {} tunes, {versions} other versions, {} with one SID", dual.tunes.len(), single.len());
        for chips in [None, Some(1), Some(2), Some(3)] {
            let named = core
                .smart_playlist(SmartRecipe {
                    title_words: Some("commando".to_string()),
                    total_secs: None,
                    min_chips: chips,
                    max_chips: chips,
                    ..recipe(SmartKind::Shuffle, 0)
                })
                .await
                .expect("a playlist");
            let wrong = named.tunes.iter().filter(|t| chips.is_some_and(|n| sid_chips(&t.item.path) != n)).count();
            let titles: Vec<String> = named.tunes.iter().take(4).map(|t| format!("{} ({})", t.item.title, sid_chips(&t.item.path))).collect();
            println!("Commando in the title, {chips:?} SIDs: {} tunes, {wrong} with another count: {titles:?}", named.tunes.len());
        }
    });
}

/// How many SIDs a tune's header asks for: the second and third chip's
/// addresses are in the header from versions 3 and 4.
fn sid_chips(path: &str) -> u8 {
    let Ok(bytes) = std::fs::read(path) else { return 0 };
    let version = u16::from_be_bytes([bytes[4], bytes[5]]);
    1 + u8::from(version >= 3 && bytes[0x7A] != 0) + u8::from(version >= 4 && bytes[0x7B] != 0)
}

fn print_lengths(lists: &[SmartPlaylist]) {
    let minutes: Vec<f64> = lists.iter().map(|l| l.total_secs as f64 / 60.0).collect();
    let (low, high) = minutes.iter().fold((f64::MAX, 0f64), |(a, b), &m| (a.min(m), b.max(m)));
    println!("  plays for {low:.1} to {high:.1} minutes");
}

/// How often a list repeats a composer.
fn print_composers(lists: &[SmartPlaylist]) {
    let (mut tunes, mut repeats) = (0, 0);
    for list in lists {
        let names: HashSet<&str> = list.tunes.iter().map(|t| t.item.author.as_str()).collect();
        tunes += list.tunes.len();
        repeats += list.tunes.len() - names.len();
    }
    println!("  composers repeated in a list: {repeats} of {tunes} tunes");
}

/// How much two lists share, so a pick feels new.
fn print_overlap(lists: &[SmartPlaylist]) {
    let sets: Vec<HashSet<&str>> = lists.iter().map(|l| l.tunes.iter().map(|t| t.item.path.as_str()).collect()).collect();
    let (mut shared, mut pairs) = (0.0, 0);
    for (i, a) in sets.iter().enumerate() {
        for b in &sets[i + 1..] {
            shared += a.intersection(b).count() as f64 / a.len().max(1) as f64;
            pairs += 1;
        }
    }
    println!("  two lists share {:.1}% of their tunes", shared / f64::from(pairs.max(1)) * 100.0);
}
