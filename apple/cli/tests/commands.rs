//! The real binary against a stand-in for the app's socket.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::{Arc, Mutex};

struct FakeApp {
    socket: PathBuf,
    asked: Arc<Mutex<Vec<Value>>>,
}

impl FakeApp {
    /// Answers each command with `result`, or an error for one named "fail".
    fn start(result: Value) -> FakeApp {
        let socket = std::env::temp_dir().join(format!(
            "rc-{}-{:?}.sock",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket).unwrap();
        let asked = Arc::new(Mutex::new(Vec::new()));
        let log = asked.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = stream.unwrap();
                let reader = BufReader::new(stream.try_clone().unwrap());
                for line in reader.lines() {
                    let request: Value = serde_json::from_str(&line.unwrap()).unwrap();
                    let answer = if request["cmd"] == "fail" {
                        json!({ "id": request["id"], "ok": false, "error": "It went wrong." })
                    } else {
                        json!({ "id": request["id"], "ok": true, "result": result })
                    };
                    log.lock().unwrap().push(request);
                    writeln!(stream, "{answer}").unwrap();
                }
            }
        });
        FakeApp { socket, asked }
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_resonance"))
            .args(args)
            .env("RESONANCE_SOCKET", &self.socket)
            .env("RESONANCE_NO_LAUNCH", "1")
            .output()
            .unwrap()
    }

    fn last(&self) -> Value {
        self.asked.lock().unwrap().last().cloned().unwrap()
    }
}

fn text(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn tunes() -> Value {
    json!([{ "path": "/hvsc/Commando.sid", "title": "Commando", "author": "Hubbard, Rob", "released": "1985 Elite", "songs": 3, "secs": 252 }])
}

#[test]
fn transport_commands_say_what_they_are() {
    let app = FakeApp::start(json!({}));
    for (arg, cmd) in [("pause", "pause"), ("toggle", "toggle"), ("stop", "stop"), ("next", "next"), ("prev", "prev"), ("surprise", "surprise")] {
        assert!(app.run(&[arg]).status.success());
        assert_eq!(app.last()["cmd"], cmd);
    }
}

#[test]
fn search_pipes_as_tabs_with_the_path_first() {
    let app = FakeApp::start(tunes());
    let output = app.run(&["search", "com", "ando"]);
    assert_eq!(text(&output), "/hvsc/Commando.sid\tCommando\tHubbard, Rob\t1985 Elite\n");
    assert_eq!(app.last()["args"]["text"], "com ando");
}

#[test]
fn json_gives_json() {
    let app = FakeApp::start(tunes());
    let parsed: Value = serde_json::from_str(&text(&app.run(&["search", "x", "--json"]))).unwrap();
    assert_eq!(parsed[0]["title"], "Commando");
}

#[test]
fn search_can_play_what_it_found() {
    let app = FakeApp::start(tunes());
    app.run(&["search", "commando", "--play"]);
    let log = app.asked.lock().unwrap();
    let play = log.iter().find(|r| r["cmd"] == "play").unwrap();
    assert_eq!(play["args"]["paths"], json!(["/hvsc/Commando.sid"]));
}

#[test]
fn now_says_nothing_is_playing() {
    let app = FakeApp::start(json!({ "state": "stopped", "now": null, "elapsed": 0.0, "hasCollection": true, "favourite": false }));
    assert_eq!(text(&app.run(&["now"])), "Nothing is playing.\n");
}

#[test]
fn now_shows_the_tune_and_time() {
    let app = FakeApp::start(json!({
        "state": "paused",
        "now": { "path": "/a.sid", "title": "Commando", "author": "Rob Hubbard", "released": "1985", "song": 2, "songs": 3 },
        "elapsed": 84.0, "duration": 252.0, "hasCollection": true, "favourite": false
    }));
    assert_eq!(text(&app.run(&["now"])), "♪ Commando · Rob Hubbard  1:24 / 4:12  (2 of 3)  paused\n");
}

#[test]
fn relative_files_become_absolute() {
    let app = FakeApp::start(json!({}));
    app.run(&["play", "a.sid"]);
    let path = app.last()["args"]["paths"][0].as_str().unwrap().to_string();
    assert!(path.starts_with('/') && path.ends_with("/a.sid"), "{path}");
}

#[test]
fn playlist_commands_name_the_list() {
    let app = FakeApp::start(json!({ "name": "Mix", "count": 0, "isFavourites": false }));
    app.run(&["playlist", "new", "Mix"]);
    assert_eq!(app.last()["cmd"], "playlist.new");
    app.run(&["playlist", "rename", "Mix", "Max"]);
    assert_eq!(app.last()["args"], json!({ "name": "Mix", "to": "Max" }));
    app.run(&["playlist", "delete", "Max"]);
    assert_eq!(app.last()["cmd"], "playlist.delete");
    app.run(&["playlist", "mv", "Mix", "/a.sid", "--before", "/b.sid"]);
    assert_eq!(app.last()["args"], json!({ "name": "Mix", "paths": ["/a.sid"], "before": "/b.sid" }));
}

#[test]
fn playlist_add_reads_paths_from_a_pipe() {
    let app = FakeApp::start(json!({}));
    let mut child = Command::new(env!("CARGO_BIN_EXE_resonance"))
        .args(["playlist", "add", "Mix"])
        .env("RESONANCE_SOCKET", &app.socket)
        .env("RESONANCE_NO_LAUNCH", "1")
        .stdin(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    // As `resonance search` prints them: only the path counts.
    child.stdin.take().unwrap().write_all(b"/a.sid\tA\tB\t1985\n/b.sid\n").unwrap();
    assert!(child.wait().unwrap().success());
    assert_eq!(app.last()["args"]["paths"], json!(["/a.sid", "/b.sid"]));
}

#[test]
fn playlist_names_alone_in_a_pipe_for_completions() {
    let app = FakeApp::start(json!([{ "name": "Favourites", "count": 2, "isFavourites": true }, { "name": "Mix", "count": 1, "isFavourites": false }]));
    assert_eq!(text(&app.run(&["playlist", "list"])), "Favourites\nMix\n");
}

#[test]
fn an_error_goes_to_stderr_and_fails() {
    let app = FakeApp::start(json!({}));
    // `fav` with an answer that isn't a tune: the app's answer can't be read.
    let output = app.run(&["fav"]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).starts_with("resonance: "));
}

#[test]
fn says_so_when_the_app_isnt_running() {
    let output = Command::new(env!("CARGO_BIN_EXE_resonance"))
        .arg("next")
        .env("RESONANCE_SOCKET", "/tmp/resonance-nothing-here.sock")
        .env("RESONANCE_NO_LAUNCH", "1")
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(String::from_utf8_lossy(&output.stderr), "resonance: Resonance isn't running.\n");
}

#[test]
fn info_needs_no_app() {
    let dir = std::env::temp_dir().join(format!("rc-info-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.sid");
    let mut bytes = vec![0u8; 124];
    bytes[..4].copy_from_slice(b"PSID");
    bytes[5] = 2;
    bytes[15] = 1;
    bytes[22..30].copy_from_slice(b"Commando");
    std::fs::write(&file, bytes).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_resonance"))
        .args(["info", file.to_str().unwrap()])
        .env("RESONANCE_SOCKET", "/tmp/resonance-nothing-here.sock")
        .env("RESONANCE_NO_LAUNCH", "1")
        .output()
        .unwrap();
    assert!(text(&output).starts_with("Title     Commando\n"), "{}", text(&output));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn the_terminal_app_needs_a_terminal() {
    let output = Command::new(env!("CARGO_BIN_EXE_resonance"))
        .env("RESONANCE_NO_LAUNCH", "1")
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("needs a terminal"));
}

#[test]
fn completions_mention_the_commands() {
    let output = Command::new(env!("CARGO_BIN_EXE_resonance")).args(["completions", "zsh"]).output().unwrap();
    let script = text(&output);
    assert!(script.contains("#compdef resonance"));
    assert!(script.contains("surprise"));
}
