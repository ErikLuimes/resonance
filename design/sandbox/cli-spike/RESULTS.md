# Spike: a sandboxed `resonance` CLI and an app group socket

2026-11-14, macOS 27.0.1 (26A434). Throwaway: nothing here goes into the app.

Setup:
- `Spike.app` is a sandboxed stand-in for Resonance (`Listener/main.swift`). It joins the app group `R4D8QN85WK.spike`, listens on `control.sock` in the group container, and writes `now-playing.txt` there. It answers every request with an empty list.
- `Spike.app/Contents/Helpers/resonance` is the real CLI (apple/cli, built from this worktree), sandboxed, in the same group.
- Both are signed with the Developer ID Application identity, team R4D8QN85WK, with the hardened runtime.

## Results

| Question | Answer | How |
|---|---|---|
| Developer ID + Mac-style group (`R4D8QN85WK.…`) without a provisioning profile | **Works.** The container came up at once, with no prompt seen. | ran the stand-in |
| A sandboxed command-line tool | **Needs an embedded Info.plist** (`-sectcreate __TEXT __info_plist`, here via `RUSTFLAGS`). Without one it traps in `_libsecinit_appsandbox` at launch, even with `app-sandbox` alone. | crash report, then a rebuild |
| Sandboxed CLI reaches the group socket | **Works** (`playlist list`, exit 0). | ran it |
| Does the group container keep other programs away from the **socket**? | **No.** An ad-hoc C program, `/usr/bin/python3` and Homebrew Node (ad-hoc) all connected and got answers. So did the ad-hoc program run as a launchd job, with no parent app. | probes |
| Does it keep them away from **files**? | **Yes.** zsh and the ad-hoc reader (also as a launchd job) got "Operation not permitted" reading `now-playing.txt`. Resonance's own app container blocks them the same way: even `ls` of its Preferences folder is refused. | probes |
| Terminal app (`resonance tui`) in the sandbox | **Fails.** `tcsetattr` (raw mode) is refused on stdin and on `/dev/tty`, also with a read-write exception for `/dev/tty`. Reading the settings, the window size and opening `/dev/tty` are allowed. Without raw mode there's no terminal app. | `ttytest.c` under `script` (a pseudo-terminal, not Terminal.app) |
| Sandboxed CLI starts the app when nothing answers (`open -g`) | **Works.** It launched the stand-in and then got its answer. | ran it |
| `resonance info <file>` on a file outside the sandbox | **Fails** ("Operation not permitted"). | ran it |
| `--licenses` (reads the app bundle's Acknowledgments.txt) | **Fails.** A sandboxed helper can't read its app's Resources. It could be fixed by compiling the text in. | ran it |

## What it means

- **Moving the socket to an app group doesn't decide who connects.** macOS's container protection covers file access, not connecting to a socket. Any program of the user's still gets in, so L3 and L5 stay as they are. Only a peer code-signature check (`LOCAL_PEERTOKEN`, then `SecCodeCreateWithAuditToken` with a team requirement) would decide that.
- **The CLI can't be sandboxed whole** while it carries the terminal app.
- **The MCP server could be.** It needs no terminal, no `info` and no licenses, only the socket. A separate sandboxed `resonance-mcp` binary in the same group would box in the part an AI client drives.
- **Probably a bug today:** the zsh prompt line reads `now-playing.txt` inside Resonance's container. On macOS 27, programs from other teams get "Operation not permitted" there. I saw that from zsh run under the Claude app, not from Terminal.app, which may hold a grant. Worth checking in your own prompt. If it's broken, the file has to live outside the container, or the plugin asks the (team-signed) CLI instead.

## Left behind

- The group container `~/Library/Group Containers/R4D8QN85WK.spike/` holds `control.sock` and `now-playing.txt`. It can't be removed from outside the group: macOS refused `rm`. Deleting it in Finder or with Full Disk Access works.
- The stand-in was unregistered from LaunchServices. Both launchd jobs were removed.
