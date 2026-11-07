# App Sandbox

The direct download runs in the App Sandbox from 0.1.0-alpha.6 on. This note
says what the sandbox changes and why each exception exists.

## No migration

Earlier builds weren't sandboxed and kept everything in
`~/Library/Application Support/Resonance`. The sandboxed app can't see that
folder, and it doesn't move it: only a few alpha testers have it, so the first
sandboxed launch starts fresh in
`~/Library/Containers/app.useresonance.resonance/Data/`, onboarding and all.

The old folder stays where it was. Its HVSC copy can be reused by choosing it
as the HVSC folder in Settings; anything else in it can go to the Trash.

The bundle identifier changed in the same release, and for the same reason
nothing is carried over from `nl.luimes.resonance`'s settings either: a
sandboxed app can only read its own.

## Files the user chose

Inside the sandbox the app opens only its container and what the user hands
it: a folder chosen in Settings or onboarding, files from Add Files, Finder's
Open With, or a drop. That access lasts until the app quits.

`FileAccess` (Services/FileAccess.swift) keeps it: each such folder or file is
saved as a security-scoped bookmark (`files.bookmarks.app-scope`), and at
launch, before anything reads a path, every bookmark is resolved and opened.
Paths stay paths everywhere else, so the Rust core, playlists and the session
are unchanged. A file inside a remembered folder needs no bookmark of its own.

What this can't cover: tunes a playlist file lists from folders the user never
chose. They show, but don't play, until their folder is added.

## Exceptions

Developer ID allows the sandbox's temporary exceptions, which the Mac App
Store would question. Each is narrow:

| Entitlement | Path | Why |
|---|---|---|
| `files.home-relative-path.read-write` | `/.local/bin/` | Install Command Line Tool links `resonance` there |
| `files.absolute-path.read-write` | `/opt/homebrew/bin/`, `/usr/local/bin/` | the same, in the folders shells already search |
| `mach-lookup.global-name` | `…-spks`, `…-spki` | Sparkle's installer, which runs outside the sandbox |

Other entitlements: `network.client` (sharing, HVSC downloads, updates,
photos), `files.user-selected.read-write` (choosing folders, exporting
playlists).

Import from Phosphor was removed rather than given an exception for
Phosphor's folder: few people come from Phosphor, and Phosphor's HVSC folder
can still be chosen like any other.

Code that means the user's home, not the container, asks `RealHome`: inside
the sandbox `HOME` and `NSHomeDirectory()` are the container.

## The command line tool, Raycast and the prompt

They stay unsandboxed and look in the container first, then the old folder
(`cli/src/client.rs`, `raycast/src/lib/client.ts`, the zsh plugin).

The socket is at the container's top, `Data/control.sock`, not in its
Application Support with the rest: a Unix socket's whole path must fit in 104
bytes, and that one is 112 for the user name `erik`. This one is 74, which
leaves room for a user name of 29 characters.

## Sparkle

Sparkle 2's sandbox setup: `SUEnableInstallerLauncherService` in the
Info.plist and the two mach-lookup exceptions above. Downloads go through the
app itself, which has `network.client`.
