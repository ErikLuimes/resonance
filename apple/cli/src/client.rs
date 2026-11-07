//! The connection to the running app: one JSON object per line each way.

use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const BUNDLE_ID: &str = "nl.luimes.resonance";
/// A cold launch, with the collection's indexes, can take this long.
const LAUNCH_WAIT: Duration = Duration::from_secs(20);

pub struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next_id: u64,
}

/// Where the app listens, the sandboxed build's folder as well as the plain one.
fn socket_paths() -> Vec<PathBuf> {
    if let Some(path) = std::env::var_os("RESONANCE_SOCKET") {
        return vec![PathBuf::from(path)];
    }
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    let support = "Library/Application Support/Resonance/control.sock";
    vec![
        home.join(support),
        home.join("Library/Containers").join(BUNDLE_ID).join("Data").join(support),
    ]
}

/// This tool's own app, when it's the copy inside one.
pub fn own_app() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    exe.ancestors().find(|p| p.extension().is_some_and(|e| e == "app")).map(PathBuf::from)
}

fn launch() -> Result<(), String> {
    let mut open = Command::new("/usr/bin/open");
    open.arg("-g");
    match own_app() {
        Some(app) => open.arg(app),
        None => open.args(["-b", BUNDLE_ID]),
    };
    let done = open.stdout(Stdio::null()).stderr(Stdio::null()).status();
    match done {
        Ok(status) if status.success() => Ok(()),
        _ => Err("Couldn't start Resonance. Is it installed?".into()),
    }
}

impl Client {
    fn try_connect() -> Option<Client> {
        socket_paths().iter().find_map(|path| {
            let stream = UnixStream::connect(path).ok()?;
            Some(Client { reader: BufReader::new(stream.try_clone().ok()?), writer: stream, next_id: 1 })
        })
    }

    /// Connect, starting the app (in the background) if it isn't running.
    pub fn connect() -> Result<Client, String> {
        if let Some(client) = Self::try_connect() {
            return Ok(client);
        }
        if std::env::var_os("RESONANCE_NO_LAUNCH").is_some() {
            return Err("Resonance isn't running.".into());
        }
        launch()?;
        let deadline = Instant::now() + LAUNCH_WAIT;
        while Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(150));
            if let Some(client) = Self::try_connect() {
                return Ok(client);
            }
        }
        Err("Resonance didn't answer. It may be older than this tool: update it, then try again.".into())
    }

    /// Ask, and get the answer's `result` as JSON.
    pub fn call(&mut self, cmd: &str, args: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        let mut line = json!({ "id": id, "cmd": cmd, "args": args }).to_string();
        line.push('\n');
        let lost = |_| "Lost touch with Resonance.".to_string();
        self.writer.write_all(line.as_bytes()).map_err(lost)?;
        let mut answer = String::new();
        let read = self.reader.read_line(&mut answer).map_err(lost)?;
        if read == 0 {
            return Err("Lost touch with Resonance.".into());
        }
        let mut answer: Value =
            serde_json::from_str(&answer).map_err(|_| "Resonance's answer couldn't be read.".to_string())?;
        if answer["ok"] == json!(true) {
            Ok(answer["result"].take())
        } else {
            Err(answer["error"].as_str().unwrap_or("Something went wrong.").to_string())
        }
    }

    /// Ask, and get the answer as `T`.
    pub fn get<T: DeserializeOwned>(&mut self, cmd: &str, args: Value) -> Result<T, String> {
        let value = self.call(cmd, args)?;
        serde_json::from_value(value).map_err(|_| "Resonance's answer couldn't be read. Update both.".to_string())
    }
}
