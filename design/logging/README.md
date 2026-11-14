# Logging

Resonance logs to macOS's unified log, the one `log show`, `log stream` and
Console read. Nothing goes to a file of our own, and nothing to stderr.

## What it was before (2026-11-14)

- **Swift:** next to nothing. One `Logger` (the About desk's sounds), no
  `print` or `NSLog`. Errors went to the screen (an alert, a notice) or nowhere
  (`try?`, "quietly" catches), so after the fact there was nothing to read.
- **Rust core:** about 40 `eprintln!("[resonance] …")` / `("[residfp] …")` in
  `apple/core`, and the included Phosphor sources in `src/` print a lot more
  (`[phosphor]`, `[player]`, `[hvsc]` …). A GUI app's stderr goes nowhere, so all
  of it was lost unless the app ran from Xcode or a terminal.
- **The command line tool, terminal app and MCP server** (`apple/cli`) print to
  the terminal on purpose. They don't link the core and stay as they are.

## Subsystem and categories

Subsystem `app.useresonance.resonance`, for the app and the core alike. The
categories, in Swift as `Log.<name>` (`Resonance/Model/Log.swift`), in Rust as
`log::Category` (`apple/core/src/logging.rs`):

| Category   | What                                                             |
|------------|------------------------------------------------------------------|
| `app`      | Launch, quit, settings, Spotlight, the command line tool's links |
| `playback` | The player: starting tunes, engines, audio output, seeking       |
| `library`  | HVSC, playlists, favorites, fingerprints, song lengths           |
| `control`  | The control socket: who connected and what they asked            |
| `sharing`  | Tune links, CSDb                                                 |
| `remote`   | The iPhone remote and listening on the phone                     |
| `updates`  | Sparkle                                                          |
| `core`     | What the Phosphor engine in `src/` prints                        |

The About desk's sounds keep their category, `MonitorSounds`: it's an easter egg
and nobody filters for it.

## Levels

| Level     | For                                                            | Kept          |
|-----------|----------------------------------------------------------------|---------------|
| `debug`   | Chatter: read-only socket commands, per-tune engine details    | Not unless streaming |
| `info`    | Useful while looking, not after: progress, timings             | Memory only   |
| `default` | Things that happened: a connection, a playlist changed, a tune failed to start | On disk |
| `error`   | Something went wrong the user may have seen                    | On disk       |
| `fault`   | A bug: a panic caught, a thread that died                      | On disk       |

Hot paths (the audio render, the visualizers' frames, the scope) log nothing
above `debug`, and preferably nothing at all.

## Privacy

The unified log redacts dynamic values unless they're marked public, and
`<private>` is what `log show` prints in their place. Mark these **private**:

- file paths and names (tunes, playlists, folders)
- search text, describe text, smart playlist sentences
- tune titles, composers, playlist names
- anything a command's arguments carry

These are **public**: command names, counts, durations, error kinds and codes
(`NSCocoaErrorDomain 4`), engine names, process names, pids, signing
identifiers and team IDs.

When in doubt, private. Xcode's console shows private values for a run it
started; to see them in `log show` on your own Mac, install a configuration
profile that enables private data for the subsystem (a `com.apple.system.logging`
payload with `Subsystems → app.useresonance.resonance → DEFAULT-OPTIONS →
Enable-Private-Data = true`), and remove it afterward.

## Rust: why our own small backend

Both crates the task suggested route to os_log, but both log every message
with `%{public}s` (`oslog`'s `wrapper.c`, and `tracing-oslog` likewise), which
would put paths and titles in the clear. `oslog` also shifts levels by one
(`warn` → error, `error` → fault). And the core has exactly one sink and no
dependency we want logs from, so a facade buys nothing yet.

So `apple/core/src/logging.rs` is a small backend of its own: a C shim
(`apple/core/oslog.c`, built with `cc`, already in the lockfile) calls
`os_log_with_type` with the format `"%{public}s%{private}s"`. The macros
(`log::debug!(Category::Library, "…{}…", x)` and friends) pass the format
string's literal text as the public part, and the filled-in message as the
private part. A message without arguments is all public. So `log show` reads

    surprise: skipping {}: {e} <private>

and the private half shows once private data is on.

### The Phosphor sources in `src/`

`src/` stays untouched: `apple/core/src/lib.rs` defines an `eprintln!` of its
own before it includes those files, and a crate's own `macro_rules!` shadow the
standard library's. (They don't use `println!`.) Each line goes to category
`core`: at `error` when its format string says fail, error or panic, otherwise
`info`. Info stays in memory, and the system writes it to disk along with an
error or fault that follows, which is when it's wanted: the engine prints a
diagnostic every five seconds while playing, too much for `default`. Unit
tests keep the standard macro, and so do the examples and benchmarks (they're
separate crates).

If one day a dependency's `log` output matters, a `log::Log` implementation on
top of the same shim is a few lines.

## The control socket audit

The socket (`ControlServer.swift`) accepts any process running as the user:
the `resonance` tool, Raycast, Claude's MCP server, or anything else. It checks
the owner and uid, and that stays the access control. The log is for finding
out afterward who did what. Category `control`:

- **One line per connection** (default), with a connection number:
  `#3 from resonance (pid 4512, app.useresonance.resonance-cli, team ABCDE12345), started by zsh (pid 4100)`.
  The pid comes from `LOCAL_PEERTOKEN`'s audit token, the signing identifier
  and team from `SecCodeCopyGuestWithAttributes` with that token (so a reused
  pid can't stand in for the process that connected), the executable and
  parent from `proc_pidpath` and `proc_pidinfo`. The executable's name is
  public, its full path private. Unsigned or
  ad-hoc signed programs say `unsigned`/no team.
- **One line per command**, tied to its connection: `#3 playlist.add <private>`.
  Commands that change things (`play`, `fav`, `playlist.*` except `list` and
  `show`, `myplaylist.play`, `hvsc.playlist.play`, `hvsc.shuffle`, `surprise`,
  `pause`, `toggle`, `stop`, `next`, `prev`, `seek`, and `show`, which brings
  the window up) at default; read-only ones (`status`, `search`, `like`, …) at
  debug. A command the app doesn't know logs at default as `unknown command`,
  its name private. Arguments are private; their shape (`name, paths: 2`) is
  public.
- A request that can't be read logs at default with its byte count, a
  connection from another user (the uid check turns it away) at error, and a
  closed connection at debug.

The formatting lives in `ControlAudit` (pure functions, tested in
`ResonanceTests/ControlAuditTests.swift`).

## Reading it

Everything from the last hour:

    log show --last 1h --info --debug --predicate 'subsystem == "app.useresonance.resonance"'

Just the socket:

    log show --last 1d --debug --predicate 'subsystem == "app.useresonance.resonance" AND category == "control"'

Live, while trying something:

    log stream --level debug --predicate 'subsystem == "app.useresonance.resonance"'

Add `--style compact` for shorter lines. `--info` and `--debug` matter only for
what's still in memory: those levels aren't written to disk.

To check a change without touching the installed app, run a Debug build with a
socket of its own (`RESONANCE_SOCKET=/tmp/r.sock`) and point the tool at it with
the same variable.
