//! The connection to the running app: one JSON object per line each way.

use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const BUNDLE_ID: &str = "app.useresonance.resonance";
/// The app group the app and the sandboxed `resonance-mcp` share; the socket
/// is in its container. The team's ID first, as macOS app groups are named.
const APP_GROUP: &str = "R4D8QN85WK.resonance";
/// A cold launch, with the collection's indexes, can take this long.
const LAUNCH_WAIT: Duration = Duration::from_secs(20);

/// The app went away mid-question.
pub const LOST: &str = "Lost touch with Resonance.";

pub struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next_id: u64,
}

/// Where the app listens: the app group's container, which `resonance-mcp`
/// can reach from its sandbox, else where builds without a team put it.
fn socket_paths() -> Vec<PathBuf> {
    if let Some(path) = std::env::var_os("RESONANCE_SOCKET") {
        return vec![PathBuf::from(path)];
    }
    let home = real_home();
    vec![
        home.join("Library/Group Containers").join(APP_GROUP).join("control.sock"),
        // A build signed without the team has no group: the app's container
        // itself, as a socket's path must fit in 104 bytes.
        home.join("Library/Containers").join(BUNDLE_ID).join("Data/control.sock"),
    ]
}

/// The user's home. In `resonance-mcp`'s sandbox `HOME` is its own container,
/// so ask the user database, as the app does.
fn real_home() -> PathBuf {
    use std::os::unix::ffi::OsStrExt;
    // SAFETY: getpwuid gives static storage or null, read at once here.
    unsafe {
        let entry = libc::getpwuid(libc::getuid());
        if !entry.is_null() && !(*entry).pw_dir.is_null() {
            let dir = std::ffi::CStr::from_ptr((*entry).pw_dir);
            return PathBuf::from(std::ffi::OsStr::from_bytes(dir.to_bytes()));
        }
    }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

/// This tool's own app, when it's the copy inside one.
pub fn own_app() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    exe.ancestors().find(|p| p.extension().is_some_and(|e| e == "app")).map(PathBuf::from)
}

/// Start the app without its window or Dock icon, if this tool starts it.
static HEADLESS: AtomicBool = AtomicBool::new(false);

/// `--headless`: the terminal is all of Resonance. An app that's already
/// running stays as it is.
pub fn start_headless() {
    HEADLESS.store(true, Ordering::Relaxed);
}

fn launch() -> Result<(), String> {
    let mut open = Command::new("/usr/bin/open");
    open.arg("-g");
    match own_app() {
        Some(app) => open.arg(app),
        None => open.args(["-b", BUNDLE_ID]),
    };
    if HEADLESS.load(Ordering::Relaxed) || std::env::var_os("RESONANCE_HEADLESS").is_some() {
        // Headless.swift reads the first; an app from before headless starts
        // as usual. The second keeps macOS from reopening the window that was
        // open at the last quit, which the app can't stop by itself.
        open.args(["--args", "-headlessForTerminal", "YES", "-ApplePersistenceIgnoreState", "YES"]);
    }
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

    /// The app if it's running; never starts it.
    pub fn running() -> Option<Client> {
        Self::try_connect()
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
        let lost = |_| LOST.to_string();
        self.writer.write_all(line.as_bytes()).map_err(lost)?;
        let mut answer = String::new();
        let read = self.reader.read_line(&mut answer).map_err(lost)?;
        if read == 0 {
            return Err(LOST.into());
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
