//! `resonance`: control the Resonance app from the terminal. On its own it
//! opens the terminal app; with a command it does that and prints the answer.
//! The tool never plays anything itself: the app does, so the window, the
//! terminal and every shortcut stay the same player.

mod client;
mod credits;
mod fingerprint;
mod fire;
mod guess;
mod header;
mod keys;
mod mcp;
mod model;
mod palette;
mod pick;
mod sid;
mod skull;
mod sphere;
mod tesla;
mod tui;
mod viz;
mod water;

use clap::{CommandFactory, Parser, Subcommand};
use client::Client;
use model::{clock, Described, PlaylistInfo, Status, Tune};
use serde_json::{json, Value};
use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

#[derive(Parser)]
#[command(name = "resonance", version, about = "Control Resonance, the SID player, from the terminal")]
struct Cli {
    /// Print the answer as JSON
    #[arg(long, global = true)]
    json: bool,
    /// The terminal app's keys; otherwise RESONANCE_KEYS, then your editor, then Emacs
    #[arg(long, global = true, value_enum, value_name = "SET")]
    keys: Option<keys::KeyScheme>,
    /// Print the licences of the open-source software in Resonance and this tool
    #[arg(long)]
    licenses: bool,
    #[command(subcommand)]
    command: Option<Cmd>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Open the terminal app (the default with no command)
    Tui,
    /// Show the credits in the terminal app, then leave
    Credits,
    /// Play or carry on; with files, play those
    Play { files: Vec<PathBuf> },
    /// Pause
    Pause,
    /// Pause, or carry on playing
    Toggle,
    /// Stop
    Stop,
    /// Next tune
    Next,
    /// Previous tune
    Prev,
    /// Random tunes from all of HVSC, until something else plays
    Surprise,
    /// Add the tune playing to Favourites
    Fav {
        /// Take it out instead
        #[arg(long)]
        off: bool,
    },
    /// What's playing
    Now,
    /// Search the collection
    Search {
        #[arg(required = true)]
        words: Vec<String>,
        #[arg(long, default_value_t = 30)]
        limit: u32,
        /// Play the results
        #[arg(long)]
        play: bool,
    },
    /// The tunes that sound most like the one playing, or like a file
    Like {
        file: Option<PathBuf>,
        #[arg(long, default_value_t = 20)]
        limit: u32,
        /// Play them, most alike first
        #[arg(long)]
        play: bool,
    },
    /// What you've been listening to, most recent first
    Recent {
        #[arg(long, default_value_t = 30)]
        limit: u32,
    },
    /// An endless radio from the tune playing, or a file: each tune sounds like the last
    Drift { file: Option<PathBuf> },
    /// Guess today's tune from short clips (a prototype)
    Guess {
        /// A random tune, instead of today's
        #[arg(long)]
        practice: bool,
        /// How long clips are compared with normal, for tests
        #[arg(long, default_value_t = 1.0, hide = true)]
        clip_scale: f64,
    },
    /// Make a Smart Playlist from a sentence and play it
    Describe {
        #[arg(required = true)]
        words: Vec<String>,
        /// Only list the tunes
        #[arg(long)]
        no_play: bool,
    },
    /// What a SID file's header says (works without the app)
    Info { file: PathBuf },
    /// Show a tune in the window
    Show { file: PathBuf },
    /// Your playlists
    #[command(subcommand)]
    Playlist(PlaylistCmd),
    /// Choose tunes interactively and print their paths
    Pick {
        /// Choose several, with Space
        #[arg(long)]
        multi: bool,
        /// Choose from a playlist instead of searching
        #[arg(long)]
        playlist: Option<String>,
        /// Start with this search
        words: Vec<String>,
    },
    /// Serve Model Context Protocol on stdin and stdout, for assistants like Claude
    Mcp,
    /// Print a shell completion script
    Completions { shell: clap_complete::Shell },
}

#[derive(Subcommand)]
enum PlaylistCmd {
    /// List your playlists
    List,
    /// List a playlist's tunes
    Show { name: String },
    /// Play a playlist
    Play { name: String },
    /// Make a playlist, optionally with tunes in it
    New { name: String, files: Vec<PathBuf> },
    /// Add tunes (paths from arguments, or one per line on stdin)
    Add { name: String, files: Vec<PathBuf> },
    /// Take tunes out
    Rm { name: String, files: Vec<PathBuf> },
    /// Move a tune, before another or to the end
    Mv {
        name: String,
        file: PathBuf,
        #[arg(long)]
        before: Option<PathBuf>,
    },
    /// Rename a playlist
    Rename { name: String, to: String },
    /// Delete a playlist
    Delete { name: String },
}

/// Absolute, as the app needs: it has its own working directory.
fn absolute(path: &Path) -> String {
    std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf()).to_string_lossy().into_owned()
}

fn paths(files: &[PathBuf]) -> Vec<String> {
    files.iter().map(|f| absolute(f)).collect()
}

/// `files`, or with none and piped input, a path per line from stdin, so
/// `resonance search x | cut -f1 | resonance playlist add Y` works.
fn paths_or_stdin(files: &[PathBuf]) -> Vec<String> {
    if !files.is_empty() || std::io::stdin().is_terminal() {
        return paths(files);
    }
    std::io::stdin()
        .lines()
        .map_while(Result::ok)
        .filter(|l| !l.trim().is_empty())
        .map(|l| absolute(Path::new(l.split('\t').next().unwrap_or(&l).trim())))
        .collect()
}

/// A line per tune: aligned for reading, or in a terminal-free pipe
/// tab-separated with the path first.
fn print_tunes(tunes: &[Tune]) {
    if !std::io::stdout().is_terminal() {
        for t in tunes {
            println!("{}\t{}\t{}\t{}", t.path, t.title, t.author, t.released);
        }
        return;
    }
    for line in tune_lines(tunes) {
        println!("{line}");
    }
}

fn tune_lines(tunes: &[Tune]) -> Vec<String> {
    let width = |f: fn(&Tune) -> &str| tunes.iter().map(|t| f(t).chars().count()).max().unwrap_or(0);
    let (title, author) = (width(|t| &t.title).min(40), width(|t| &t.author).min(26));
    tunes
        .iter()
        .map(|t| {
            let alike = t.score.map(|s| format!("{:>3.0}%  ", s * 100.0)).unwrap_or_default();
            let line = format!(
                "{alike}{:title$}  {:author$}  {}",
                cut(&t.title, title),
                cut(&t.author, author),
                t.released
            );
            line.trim_end().to_string()
        })
        .collect()
}

fn cut(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_string();
    }
    text.chars().take(width.saturating_sub(1)).chain(['…']).collect()
}

fn print_status(status: &Status) {
    let Some(now) = &status.now else {
        println!("Nothing is playing.");
        return;
    };
    let by = if now.author.is_empty() { String::new() } else { format!(" · {}", now.author) };
    let time = match status.duration {
        Some(duration) => format!("{} / {}", clock(status.elapsed), clock(duration)),
        None => clock(status.elapsed),
    };
    let song = if now.songs > 1 { format!("  ({} of {})", now.song, now.songs) } else { String::new() };
    let paused = if status.state == "paused" { "  paused" } else { "" };
    println!("♪ {}{by}  {time}{song}{paused}", now.title);
}

/// The same text as About Resonance's Acknowledgements, from the app this tool came
/// in. It's long, so a pager closing early isn't a failure.
fn print_licenses() -> Result<(), String> {
    let path = client::own_app()
        .map(|app| app.join("Contents/Resources/Acknowledgements.txt"))
        .ok_or("This copy isn't inside Resonance. The licences are in Acknowledgements.txt in the app, and at https://github.com/ErikLuimes/resonance.")?;
    let text = std::fs::read(&path).map_err(|e| format!("Can't read {}: {e}", path.display()))?;
    let _ = std::io::stdout().write_all(&text);
    Ok(())
}

fn run(cli: Cli) -> Result<(), String> {
    if cli.licenses {
        return print_licenses();
    }
    let json_out = cli.json;
    let keys = keys::Choice::resolve(cli.keys);
    let show = |value: &Value| {
        if json_out {
            println!("{value}");
        }
    };
    let Some(command) = cli.command else {
        if !std::io::stdout().is_terminal() {
            return Err("The terminal app needs a terminal. Try `resonance --help`.".into());
        }
        return tui::run(keys, false);
    };

    // These don't need the app.
    match &command {
        Cmd::Completions { shell } => {
            clap_complete::generate(*shell, &mut Cli::command(), "resonance", &mut std::io::stdout());
            return Ok(());
        }
        Cmd::Info { file } => {
            let data = std::fs::read(file).map_err(|e| format!("Can't read {}: {e}", file.display()))?;
            let header = sid::parse(&data).ok_or_else(|| format!("{} isn't a PSID or RSID file.", file.display()))?;
            if json_out {
                println!("{}", serde_json::to_string(&header).unwrap_or_default());
                return Ok(());
            }
            println!("Title     {}", header.title);
            println!("Composer  {}", header.author);
            println!("Released  {}", header.released);
            println!("Subtunes  {}", header.songs);
            if let Some(model) = header.model {
                println!("Chip      {model}");
            }
            if let Some(clock) = header.clock {
                println!("Clock     {clock}");
            }
            if header.chips > 1 {
                println!("SIDs      {}", header.chips);
            }
            println!("Format    {}", header.format);
            return Ok(());
        }
        Cmd::Tui => return tui::run(keys, false),
        Cmd::Credits => return tui::run(keys, true),
        // Connects when first asked to do something.
        Cmd::Mcp => return mcp::run(),
        _ => {}
    }

    let mut client = Client::connect()?;
    match command {
        Cmd::Tui | Cmd::Credits | Cmd::Mcp | Cmd::Completions { .. } | Cmd::Info { .. } => unreachable!("handled above"),
        Cmd::Play { files } => {
            let paths = paths(&files);
            if paths.is_empty() {
                client.call("play", json!({}))?;
            } else {
                client.call("play", json!({ "paths": paths }))?;
            }
        }
        Cmd::Pause => drop(client.call("pause", json!({}))?),
        Cmd::Toggle => drop(client.call("toggle", json!({}))?),
        Cmd::Stop => drop(client.call("stop", json!({}))?),
        Cmd::Next => drop(client.call("next", json!({}))?),
        Cmd::Prev => drop(client.call("prev", json!({}))?),
        Cmd::Surprise => drop(client.call("surprise", json!({}))?),
        Cmd::Fav { off } => {
            let tune: Tune = client.get("fav", json!({ "on": !off }))?;
            if json_out {
                println!("{}", serde_json::to_string(&tune).unwrap_or_default());
            } else if off {
                println!("Took {} out of Favourites.", tune.title);
            } else {
                println!("Added {} to Favourites.", tune.title);
            }
        }
        Cmd::Now => {
            let value = client.call("status", json!({}))?;
            if json_out {
                show(&value);
            } else {
                let status: Status = serde_json::from_value(value).map_err(|e| e.to_string())?;
                print_status(&status);
            }
        }
        Cmd::Search { words, limit, play } => {
            let text = words.join(" ");
            let tunes: Vec<Tune> = client.get("search", json!({ "text": text, "limit": limit }))?;
            if tunes.is_empty() {
                return Err(format!("Nothing found for “{text}”."));
            }
            if play {
                let list: Vec<&str> = tunes.iter().map(|t| t.path.as_str()).collect();
                client.call("play", json!({ "paths": list, "text": text }))?;
            }
            output(json_out, &tunes);
        }
        Cmd::Like { file, limit, play } => {
            let mut args = json!({ "limit": limit, "play": play });
            if let Some(file) = file {
                args["path"] = json!(absolute(&file));
            }
            let tunes: Vec<Tune> = client.get("like", args)?;
            output(json_out, &tunes);
        }
        Cmd::Recent { limit } => {
            let tunes: Vec<Tune> = client.get("recent", json!({ "limit": limit }))?;
            output(json_out, &tunes);
        }
        Cmd::Drift { file } => {
            let args = match file {
                Some(file) => json!({ "path": absolute(&file) }),
                None => json!({}),
            };
            client.call("drift", args)?;
        }
        Cmd::Guess { practice, clip_scale } => guess::run(&mut client, practice, clip_scale)?,
        Cmd::Describe { words, no_play } => {
            let made: Described = client.get("describe", json!({ "text": words.join(" "), "play": !no_play }))?;
            if json_out {
                println!("{}", serde_json::to_string(&made).unwrap_or_default());
            } else {
                if std::io::stdout().is_terminal() {
                    println!("{}", made.title);
                    if let Some(note) = &made.note {
                        println!("{note}");
                    }
                }
                print_tunes(&made.tunes);
            }
        }
        Cmd::Show { file } => drop(client.call("show", json!({ "path": absolute(&file) }))?),
        Cmd::Pick { multi, playlist, words } => {
            let chosen = pick::run(&mut client, multi, playlist.as_deref(), &words.join(" "))?;
            if json_out {
                println!("{}", json!(chosen));
            } else {
                for path in chosen {
                    println!("{path}");
                }
            }
        }
        Cmd::Playlist(cmd) => run_playlist(&mut client, cmd, json_out)?,
    }
    Ok(())
}

fn output(json_out: bool, tunes: &[Tune]) {
    if json_out {
        println!("{}", serde_json::to_string(tunes).unwrap_or_default());
    } else {
        print_tunes(tunes);
    }
}

fn run_playlist(client: &mut Client, cmd: PlaylistCmd, json_out: bool) -> Result<(), String> {
    match cmd {
        PlaylistCmd::List => {
            let lists: Vec<PlaylistInfo> = client.get("playlist.list", json!({}))?;
            if json_out {
                println!("{}", serde_json::to_string(&lists).unwrap_or_default());
            } else if std::io::stdout().is_terminal() {
                for list in lists {
                    let unit = if list.count == 1 { "tune" } else { "tunes" };
                    println!("{}  ({} {unit})", list.name, list.count);
                }
            } else {
                // For completions and scripts: names alone.
                for list in lists {
                    println!("{}", list.name);
                }
            }
        }
        PlaylistCmd::Show { name } => {
            let tunes: Vec<Tune> = client.get("playlist.show", json!({ "name": name }))?;
            output(json_out, &tunes);
        }
        PlaylistCmd::Play { name } => drop(client.call("playlist.play", json!({ "name": name }))?),
        PlaylistCmd::New { name, files } => {
            let list: PlaylistInfo = client.get("playlist.new", json!({ "name": name, "paths": paths_or_stdin(&files) }))?;
            if !json_out {
                println!("Made {}.", list.name);
            }
        }
        PlaylistCmd::Add { name, files } => {
            let paths = paths_or_stdin(&files);
            if paths.is_empty() {
                return Err("Which tunes? Give some paths, or pipe them in.".into());
            }
            client.call("playlist.add", json!({ "name": name, "paths": paths }))?;
        }
        PlaylistCmd::Rm { name, files } => {
            client.call("playlist.rm", json!({ "name": name, "paths": paths_or_stdin(&files) }))?;
        }
        PlaylistCmd::Mv { name, file, before } => {
            let mut args = json!({ "name": name, "paths": [absolute(&file)] });
            if let Some(before) = before {
                args["before"] = json!(absolute(&before));
            }
            client.call("playlist.mv", args)?;
        }
        PlaylistCmd::Rename { name, to } => drop(client.call("playlist.rename", json!({ "name": name, "to": to }))?),
        PlaylistCmd::Delete { name } => drop(client.call("playlist.delete", json!({ "name": name }))?),
    }
    Ok(())
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("resonance: {message}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tune(title: &str, author: &str, score: Option<f64>) -> Tune {
        Tune {
            path: format!("/{title}.sid"),
            title: title.into(),
            author: author.into(),
            released: "1985".into(),
            songs: 1,
            secs: None,
            score,
            played_at: None,
        }
    }

    #[test]
    fn the_command_line_is_well_formed() {
        Cli::command().debug_assert();
    }

    #[test]
    fn lines_line_up() {
        let lines = tune_lines(&[tune("Commando", "Rob Hubbard", None), tune("Ace", "Galway", None)]);
        assert_eq!(lines, ["Commando  Rob Hubbard  1985", "Ace       Galway       1985"]);
    }

    #[test]
    fn sounds_like_shows_how_alike() {
        let lines = tune_lines(&[tune("Ace", "Galway", Some(0.94))]);
        assert_eq!(lines, [" 94%  Ace  Galway  1985"]);
    }

    #[test]
    fn long_names_are_cut() {
        assert_eq!(cut("abcdef", 4), "abc…");
        assert_eq!(cut("abc", 4), "abc");
    }
}
