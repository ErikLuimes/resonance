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

Play tunes, or query the HVSC library, without any UI (handy when working on
the Rust side):

```bash
cd apple && cargo run -p phosphor-apple --example headless -- path/to/tune.sid
```

```bash
cd apple && cargo run -p phosphor-apple --example library -- search commando
```

The library example also takes `authors [category]`, `tunes <author folder>`
and `surprise [category]`.

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
    machine with unit tests. Each block names its `main.rs` origin. One
    addition of its own: a temporary play queue. Tunes played from the HVSC
    library go there instead of into the playlist (as they do upstream), and
    transport walks the queue until a playlist row is played. Surprise Me
    is the queue as a radio: the session asks for a random pick one tune
    ahead, the driver's loader picks it from all of HVSC (skipping anything
    heard since launch), and each pick plays only its default subtune.
  - `driver.rs` — one thread owns the session and serialises commands,
    player statuses and the auto-advance tick; a loader thread parses files
    and loads the Songlengths/STIL databases (`databases.rs`). It publishes
    an immutable snapshot after every step.
  - `library.rs` — the HVSC collection: authors, tunes, fuzzy search and
    random picks, wrapping upstream's `hvsc_browser` model (one per
    category) and its index cache. Index builds wait for the databases and
    run detached, so a cancelled search can't leave one stuck.
  - `ffi.rs` — `PlayerCore`, the UniFFI object Swift talks to. Playback calls
    return immediately; Swift polls `snapshot()` at 20 Hz and `viz_frame()`
    per display frame. Library calls are `async` (Swift `await`s them) and
    run on tokio's blocking pool.
  - `build.rs` — reads upstream's version from the root `Cargo.toml`, so
    `phosphor_version()` (shown in About Resonance) follows upstream merges.
- **`iced-shim/`** — `src/hvsc_sync.rs` imports `iced::futures`; this maps
  that path to `futures-util` so the GUI toolkit isn't built.
- **`uniffi-bindgen/`** — the Swift binding generator, pinned to the same
  UniFFI version as `core`.
- **`scripts/build-core.sh`** — the PhosphorCore target's first build phase:
  builds the Rust library and regenerates the bindings, copying files only
  when they change so Xcode doesn't rebuild needlessly.
- **`Resonance/`** — the app. `PlayerStore` wraps the core and owns the
  settings; `LibraryStore` caches the HVSC lists; views bind to both.

## Data and settings

- Reads Phosphor's `~/Library/Application Support/phosphor/`: `config.json`
  (default HVSC folder, and *Settings → Import Settings from Phosphor*),
  `Songlengths.md5` and `STIL.txt`. It never writes there, with one exception:
  the HVSC search-index cache in `hvsc_index/`, which both apps share. It's
  disposable and self-validating, and either app's index build saves the
  other one (Musicians takes ~6 s cold on an SSD).
- The HVSC folder defaults to Phosphor's and can be changed in Settings.
- Keeps its own playlist in `~/Library/Application Support/Resonance/session.m3u`
  and its settings in its own user defaults (`nl.luimes.resonance`). The two apps
  can't overwrite each other's playlist or settings.
- Engine diagnostics are appended to Phosphor's `phosphor-debug.log` (shared
  `dlog!` code). Prefer not to run both apps at once.

## Scope

- **Milestone 1:** playlist, transport, subtunes, auto-advance, visualizer,
  Now Playing and media keys, on the software engines (SIDLite and reSID).
- **Milestone 2:** the HVSC library in the sidebar (browse authors and
  sections, fuzzy search per category or across HVSC, Surprise Me) and STIL
  commentary in the inspector.

USBSID-Pico and Ultimate 64, HVSC sync, favourites and recently played, the DSP
pedalboard and the HTTP remote are not wired up yet. The core only includes the modules it needs, and the `usb`
feature is never enabled, so the USB bridge daemon and its admin prompt
can't be reached.

## Pulling in upstream changes

After merging upstream into this fork:

1. `cd apple && cargo test -p phosphor-apple` — compile errors mean drift:
   a new module or dependency used by an included file (add a `#[path]`
   module to `core/src/lib.rs` or the dependency to `core/Cargo.toml`, using
   the root `Cargo.toml`'s version), or a changed engine type.
2. Two small mirrors of upstream code: the `SortDirection` stand-in in
   `core/src/lib.rs` (from `src/ui/mod.rs`) and `display_name` in
   `core/src/ffi.rs` (upstream's private `derive_display_name` in
   `src/hvsc_browser.rs`). Update them if those change.
3. If `src/main.rs` changed `play_track`, `play_cmd`, `poll_status` or
   `update_entry_subtune`, carry the change into `core/src/session/`.

## Website

`site/` is Resonance's GitHub Pages site: static HTML, CSS and ES modules,
no build step. Upstream's Phosphor site stays in `../docs`.

Preview it locally (the JavaScript modules need HTTP, not `file://`):

```bash
python3 -m http.server 8642 --directory apple/site
```

- The hero is a tour of the app: screen recordings in `media/`, one per
  chapter (`CHAPTERS` in `js/main.js`), each also shown in its own section.
  Videos start muted (browsers only autoplay muted video); the Sound button
  turns sound on for all of them, and each plays only while on screen.
- Recordings become those files with `scripts/site-videos.sh`: it finds the
  window inside a ⇧⌘5 selection, scales to 1600 wide, evens out loudness
  and writes `<name>.mp4` and a poster `<name>.jpg`. Record the app at
  1440 × 900 (Debug builds: Window → Size for Recording), 16:10 like the
  page's video frames. Raw recordings stay out of git.
- "The chip" animates its scopes silently: `js/chip.js` steps a stand-in
  tune composed by `js/tune.js` through a 50 Hz SID-style music driver, and
  `js/visualizer.js` draws it, after `VisualizerView` and `VoiceMeter`.
- Download buttons follow the latest GitHub release of
  `ErikLuimes/resonance` (`REPO` in `js/main.js`), preferring a `.dmg`,
  then `.zip` or `.pkg`. Until there's a public release, they point to the
  build instructions.
- Scripts and the stylesheet are loaded with a `?v=` version (in
  `index.html` and the `import`s in `js/`). Bump it with every site change
  that touches them: GitHub Pages lets browsers cache files for ten
  minutes, and an old cached `main.js` against a new page can leave it
  blank. (If `main.js` doesn't run at all, `index.html` shows the content
  after four seconds anyway.)
- `.github/workflows/resonance-site.yml` deploys `site/` on pushes to main
  that touch it. Set the repository's Pages source to "GitHub Actions"
  first.
- The icons in `assets/` are exported from `Resonance/AppIcon.icon` with
  `ictool` (see Notes); `og-card.png` is the 1200×630 social preview.

## Notes

- `Cargo.toml` turns off overflow checks for `resid-rs` in debug builds: its
  resampler overflows an `i32` multiply (`sampler.rs:297`), which release
  builds wrap silently but debug builds turn into a panic on the reSID
  engine. Debug builds of the Iced app hit the same panic.
- The app icon is an Icon Composer document, `Resonance/AppIcon.icon`: its
  layers are SVGs in `Assets/`. Edit it in Icon Composer (in Xcode's
  Applications folder), or preview a change from the terminal with
  `ictool Resonance/AppIcon.icon --export-image --output-file icon.png
  --platform macOS --rendition Default --width 512 --height 512 --scale 1`
  (`ictool` is in `Icon Composer.app/Contents/Executables`).

## License

Resonance's own code — everything under `apple/` — is MIT-licensed; see
[`LICENSE`](LICENSE). The Phosphor engine it compiles from `../src` keeps
Phosphor's MIT license, in [`../LICENSE`](../LICENSE).
