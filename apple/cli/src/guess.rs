//! `resonance guess`: name today's tune from short clips. A prototype, to find
//! out whether it's any fun before it goes in the app. It doesn't hide the tune
//! from the window, the menu bar or history, so don't look.

use crate::client::Client;
use crate::model::{Status, Tune};
use crate::pick;
use serde_json::json;
use std::io::{IsTerminal, Write};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Seconds heard before each guess.
const CLIPS: [u64; 6] = [2, 4, 8, 15, 30, 60];

/// Today's tune, the same for everyone with the same list.
pub fn daily_index(day: u64, pool: usize) -> usize {
    // FNV-1a, so neighbouring days don't pick neighbouring tunes.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in day.to_le_bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    (hash % pool.max(1) as u64) as usize
}

/// The composer's folder in MUSICIANS: search results name it that way and a
/// header another, so this is what's compared. `.../MUSICIANS/H/Hubbard_Rob/x.sid`.
pub fn composer_key(path: &str) -> Option<&str> {
    let mut parts = path.split('/').skip_while(|p| *p != "MUSICIANS");
    parts.next()?;
    parts.next()?;
    let folder = parts.next()?;
    (!folder.ends_with(".sid")).then_some(folder)
}

/// "Rob Hubbard" → "R. H."
pub fn initials(name: &str) -> String {
    name.split_whitespace()
        .filter_map(|word| word.chars().next())
        .map(|c| format!("{c}."))
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Try {
    Miss,
    Composer,
    Tune,
}

/// A day's game, apart from the sound and the terminal.
#[derive(Debug, Default)]
pub struct Game {
    pub tries: Vec<Try>,
}

impl Game {
    pub fn guess(&mut self, guessed: &str, answer: &str) -> Try {
        let result = if guessed == answer {
            Try::Tune
        } else if composer_key(guessed).is_some() && composer_key(guessed) == composer_key(answer) {
            Try::Composer
        } else {
            Try::Miss
        };
        self.tries.push(result);
        result
    }

    pub fn skip(&mut self) {
        self.tries.push(Try::Miss);
    }

    pub fn won(&self) -> bool {
        self.tries.last() == Some(&Try::Tune)
    }

    pub fn over(&self) -> bool {
        self.won() || self.tries.len() >= CLIPS.len()
    }

    /// Spoiler-free, to share: "Resonance #142  ⬛🟨🟩".
    pub fn share(&self, number: u64) -> String {
        let squares: String = self
            .tries
            .iter()
            .map(|t| match t {
                Try::Miss => '⬛',
                Try::Composer => '🟨',
                Try::Tune => '🟩',
            })
            .collect();
        format!("Resonance #{number}  {squares}")
    }
}

/// What a round's clue says, the more the further in. `tries` are the guesses made.
pub fn hint(tries: usize, sound: Option<&str>, tune: &Tune) -> Option<String> {
    match tries {
        1 => sound.map(|s| format!("It sounds like this: {s}")),
        2 => tune.released.get(..4).map(|year| format!("It came out in {year}.")),
        3 => Some(format!("Its header says the composer's initials are {}.", initials(&tune.author))),
        _ => None,
    }
}

fn today() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() / 86_400)
}

/// Play the tune from the start, for `secs` of it heard (not of waiting: a load
/// takes as long as it takes), then pause.
fn play_clip(client: &mut Client, path: &str, secs: f64) -> Result<(), String> {
    client.call("play", json!({ "paths": [path] }))?;
    let deadline = Instant::now() + Duration::from_secs_f64(secs + 8.0);
    while Instant::now() < deadline {
        let status: Status = client.get("status", json!({}))?;
        let playing = status.now.as_ref().is_some_and(|n| n.path == path) && status.state == "playing";
        if playing && status.elapsed >= secs {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    client.call("pause", json!({}))?;
    Ok(())
}

fn ask_line(prompt: &str) -> Result<Option<String>, String> {
    print!("{prompt}");
    std::io::stdout().flush().map_err(|e| e.to_string())?;
    let mut line = String::new();
    let read = std::io::stdin().read_line(&mut line).map_err(|e| e.to_string())?;
    Ok((read > 0).then(|| line.trim().to_string()))
}

pub fn run(client: &mut Client, practice: bool, clip_scale: f64) -> Result<(), String> {
    let mut pool: Vec<Tune> = client.get("guess.pool", json!({}))?;
    if pool.is_empty() {
        return Err("There are no tunes to guess yet.".into());
    }
    pool.sort_by(|a, b| a.path.cmp(&b.path));
    // Practice takes tomorrow-and-on, by the clock's nanoseconds.
    let day = today();
    let index = if practice {
        let spin = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| u64::from(d.subsec_nanos()));
        daily_index(spin, pool.len())
    } else {
        daily_index(day, pool.len())
    };
    let answer = pool[index].clone();
    let sound: Option<String> = client
        .call("sound", json!({ "path": answer.path }))
        .ok()
        .and_then(|v| v["summary"].as_str().map(str::to_string));

    println!("Guess the tune. Six clips, each longer. Don't look at the window!");
    println!("Press ↵ to guess, type s to hear more, q to give up.\n");
    let mut game = Game::default();
    while !game.over() {
        let clip = CLIPS[game.tries.len()];
        println!("Clip {} of {}: {clip} seconds…", game.tries.len() + 1, CLIPS.len());
        play_clip(client, &answer.path, clip as f64 * clip_scale)?;
        let Some(choice) = ask_line("↵ guess  s skip  q give up > ")? else { break };
        match choice.as_str() {
            "q" => break,
            "s" => game.skip(),
            _ if !std::io::stdout().is_terminal() => game.skip(),
            _ => match pick::run(client, false, None, "") {
                Ok(chosen) => match chosen.first() {
                    Some(guess) => match game.guess(guess, &answer.path) {
                        Try::Tune => println!("Yes!"),
                        Try::Composer => println!("Right composer, wrong tune."),
                        Try::Miss => println!("Not that one."),
                    },
                    None => game.skip(),
                },
                Err(_) => game.skip(),
            },
        }
        if !game.over() {
            if let Some(clue) = hint(game.tries.len(), sound.as_deref(), &answer) {
                println!("{clue}");
            }
            println!();
        }
    }

    println!("\nIt's {} by {} ({}).", answer.title, answer.author, answer.released);
    println!("{}", game.share(day));
    client.call("play", json!({ "paths": [answer.path] }))?;
    if let Ok(alike) = client.get::<Vec<Tune>>("like", json!({ "path": answer.path, "limit": 3 })) {
        if !alike.is_empty() {
            println!("\nIf you like it, these sound alike:");
            for tune in alike {
                println!("  {}  {}", tune.title, tune.author);
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const HUBBARD: &str = "/h/MUSICIANS/H/Hubbard_Rob/Commando.sid";
    const HUBBARD_2: &str = "/h/MUSICIANS/H/Hubbard_Rob/Sanxion.sid";
    const GALWAY: &str = "/h/MUSICIANS/G/Galway_Martin/Wizball.sid";

    fn tune(released: &str) -> Tune {
        Tune {
            path: HUBBARD.into(),
            title: "Commando".into(),
            author: "Rob Hubbard".into(),
            released: released.into(),
            songs: 1,
            secs: None,
            score: None,
            played_at: None,
        }
    }

    #[test]
    fn a_day_always_picks_the_same_tune() {
        assert_eq!(daily_index(20_000, 100), daily_index(20_000, 100));
        assert!(daily_index(20_000, 100) < 100);
    }

    #[test]
    fn days_spread_over_the_list() {
        let days: std::collections::BTreeSet<_> = (20_000..20_100).map(|d| daily_index(d, 100)).collect();
        assert!(days.len() > 40, "only {} of 100 days differ", days.len());
    }

    #[test]
    fn an_empty_list_doesnt_crash_the_maths() {
        assert_eq!(daily_index(1, 0), 0);
    }

    #[test]
    fn finds_the_composers_folder() {
        assert_eq!(composer_key(HUBBARD), Some("Hubbard_Rob"));
        assert_eq!(composer_key("/h/GAMES/A-F/Ace.sid"), None);
        assert_eq!(composer_key("/h/MUSICIANS/H/Tune.sid"), None);
    }

    #[test]
    fn the_right_tune_wins() {
        let mut game = Game::default();
        assert_eq!(game.guess(HUBBARD, HUBBARD), Try::Tune);
        assert!(game.won() && game.over());
    }

    #[test]
    fn the_right_composer_counts_but_goes_on() {
        let mut game = Game::default();
        assert_eq!(game.guess(HUBBARD_2, HUBBARD), Try::Composer);
        assert!(!game.over());
    }

    #[test]
    fn unfiled_tunes_arent_all_one_composer() {
        let mut game = Game::default();
        assert_eq!(game.guess("/h/GAMES/A-F/B.sid", "/h/GAMES/A-F/A.sid"), Try::Miss);
    }

    #[test]
    fn six_misses_end_it() {
        let mut game = Game::default();
        for _ in 0..5 {
            game.skip();
        }
        assert!(!game.over());
        assert_eq!(game.guess(GALWAY, HUBBARD), Try::Miss);
        assert!(game.over() && !game.won());
    }

    #[test]
    fn sharing_gives_nothing_away() {
        let mut game = Game::default();
        game.skip();
        game.guess(HUBBARD_2, HUBBARD);
        game.guess(HUBBARD, HUBBARD);
        assert_eq!(game.share(142), "Resonance #142  ⬛🟨🟩");
    }

    #[test]
    fn clues_get_more_telling() {
        let tune = tune("1985 Elite");
        assert_eq!(hint(0, Some("Pulse."), &tune), None);
        assert_eq!(hint(1, Some("Pulse."), &tune).unwrap(), "It sounds like this: Pulse.");
        assert_eq!(hint(1, None, &tune), None);
        assert_eq!(hint(2, None, &tune).unwrap(), "It came out in 1985.");
        assert!(hint(3, None, &tune).unwrap().contains("R. H."));
    }

    #[test]
    fn a_short_release_field_gives_no_year() {
        assert_eq!(hint(2, None, &tune("")), None);
    }
}
