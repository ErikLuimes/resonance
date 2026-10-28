# Resonance — native macOS front-end

A SwiftUI app for macOS 27 (Apple silicon) that plays SID music through the
Phosphor engine. The Rust engine is shared with the Iced app; nothing under
`../src` was changed to make this work.

## Build and run

Requirements: Xcode 27 and Rust (`brew install rustup && rustup default stable`).

Open `Resonance.xcodeproj` and run the **Resonance** scheme. The first build
compiles the Rust engine (a few minutes); after that, Xcode rebuilds it
incrementally on every build.

From a terminal:

```bash
xcodebuild -project apple/Resonance.xcodeproj -scheme Resonance -derivedDataPath apple/build/DD build
```

```bash
open apple/build/DD/Build/Products/Debug/Resonance.app
```

Tests:

```bash
cd apple && cargo test -p phosphor-apple
```

```bash
xcodebuild test -project apple/Resonance.xcodeproj -scheme Resonance -destination 'platform=macOS,arch=arm64' -derivedDataPath apple/build/DD
```

Play tunes without any UI (handy when working on the Rust side):

```bash
cd apple && cargo run -p phosphor-apple --example headless -- path/to/tune.sid
```

## How it fits together

```
Resonance.app            SwiftUI (Swift 6, main-actor by default)    Resonance/
  └ PhosphorCore.framework  UniFFI-generated Swift bindings          PhosphorCore/Generated/
      └ libphosphor_apple.a Rust: session + FFI                      core/
          └ engine modules  compiled from ../src via #[path]         ../src/
```

- **`core/`** (`phosphor-apple`). `lib.rs` compiles the upstream engine sources
  in place with `#[path]` (player, SID engines, playlist, config, DSP, …), so
  upstream changes flow in with no merge conflicts. On top of that:
  - `session/` — the player logic the Iced app keeps in `src/main.rs`
    (play, auto-advance, subtunes, songlengths), ported as a plain state
    machine with unit tests. Each block names its `main.rs` origin.
  - `driver.rs` — one thread owns the session and serialises commands,
    player statuses and the auto-advance tick; a loader thread parses files.
    It publishes an immutable snapshot after every step.
  - `ffi.rs` — `PlayerCore`, the UniFFI object Swift talks to. Every call
    returns immediately; Swift polls `snapshot()` at 20 Hz and `viz_frame()`
    per display frame.
- **`iced-shim/`** — `src/hvsc_sync.rs` imports `iced::futures`; this maps
  that path to `futures-util` so the GUI toolkit isn't built.
- **`uniffi-bindgen/`** — the Swift binding generator, pinned to the same
  UniFFI version as `core`.
- **`scripts/build-core.sh`** — the PhosphorCore target's first build phase:
  builds the Rust library and regenerates the bindings, copying files only
  when they change so Xcode doesn't rebuild needlessly.
- **`Resonance/`** — the app. `PlayerStore` wraps the core and owns the
  settings; views bind to it.

## Data and settings

- Reads (never writes) Phosphor's `~/Library/Application Support/phosphor/`:
  `config.json` (HVSC location, and *Settings → Import Settings from Phosphor*)
  and `Songlengths.md5`.
- Keeps its own playlist in `~/Library/Application Support/Resonance/session.m3u`
  and its settings in its own user defaults (`nl.luimes.resonance`). The two apps
  can't overwrite each other's playlist or settings.
- Engine diagnostics are appended to Phosphor's `phosphor-debug.log` (shared
  `dlog!` code). Prefer not to run both apps at once.

## Scope (milestone 1)

Software emulation only: SIDLite and reSID. USBSID-Pico and Ultimate 64, the
HVSC browser, favourites, STIL, the DSP pedalboard and the HTTP remote are
not wired up yet. The core only includes the modules it needs, and the `usb`
feature is never enabled, so the USB bridge daemon and its admin prompt
can't be reached.

## Pulling in upstream changes

After merging upstream into this fork:

1. `cd apple && cargo test -p phosphor-apple` — compile errors mean drift:
   a new module or dependency used by an included file (add a `#[path]`
   module to `core/src/lib.rs` or the dependency to `core/Cargo.toml`, using
   the root `Cargo.toml`'s version), or a changed engine type.
2. If `src/main.rs` changed `play_track`, `play_cmd`, `poll_status` or
   `update_entry_subtune`, carry the change into `core/src/session/`.

## Notes

- `Cargo.toml` turns off overflow checks for `resid-rs` in debug builds: its
  resampler overflows an `i32` multiply (`sampler.rs:297`), which release
  builds wrap silently but debug builds turn into a panic on the reSID
  engine. Debug builds of the Iced app hit the same panic.
- No app icon yet; `Resonance/Assets.xcassets/AppIcon.appiconset` is empty.
