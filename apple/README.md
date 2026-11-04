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

- Everything Resonance writes is in `~/Library/Application Support/Resonance/`:
  My Playlist (`session.m3u`), your playlists (`Playlists/`), the fingerprints,
  and the files the engine sources keep in their config folder — favourites,
  play history, the HVSC search-index cache, the curated playlists cache and
  `phosphor-debug.log`. `core/src/config.rs` points upstream's `config_dir()`
  there, without changing `src/`. Settings are in its own user defaults
  (`nl.luimes.resonance`).
- The curated playlists are Phosphor's published playlists, from the
  `playlists/` folder at the top of this repository (it merges in from
  upstream): `core/src/curated.rs` brings them up to date at launch from
  this repository's `main` on GitHub, not Phosphor's. The app also ships
  the folder, which fills an empty cache on the first launch, offline too.
  Edit, add or remove a playlist there (with `index.json`, whose `sha256`
  tells apps a file changed), push, and every Resonance picks it up.
- The HVSC folder is `Resonance/HVSC` until you choose another; Download puts
  the collection there. Song lengths and STIL come from the collection's own
  `DOCUMENTS` folder.
- Phosphor's `~/Library/Application Support/phosphor/` is read only by
  *Settings → Advanced → Import from Phosphor* (and its *Use Phosphor's*
  button in Settings → Collection): its `config.json` (playback settings and
  HVSC folder), and `favorites.json`, `recently_played.json` and `heard.txt`,
  merged into Resonance's. Import also switches to Phosphor's collection when
  Resonance has none. Nothing is ever written there. Upstream's HTTP clients
  would take a proxy from that `config.json`; the shim's `apply_proxy` leaves
  them on the system's settings instead.
- Running both apps at once is safe; they don't write each other's files.

## Scope

- **Milestone 1:** playlist, transport, subtunes, auto-advance, visualizer,
  Now Playing and media keys, on the software engines (SIDLite and reSID).
- **Milestone 2:** the HVSC library in the sidebar (browse authors and
  sections, fuzzy search per category or across HVSC, Surprise Me) and STIL
  commentary in the inspector.
- **Sharing:** short links to HVSC tunes with a preview card, served by
  `share-server/` at useresonance.app (see Sharing tunes below).

USBSID-Pico and Ultimate 64, the DSP pedalboard and the HTTP remote are not
wired up yet. The core only includes the modules it needs, and the `usb`
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
no build step. Upstream's Phosphor site stays in `../docs`. Shared tune
links aren't part of it: `share-server/` serves them at useresonance.app,
whose other addresses redirect here (see Sharing tunes).

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
  `media/share-card.jpg`, in Features, is a real shared link's card
  (`https://useresonance.app/card/bQGey6gxqfhT.jpg`).

## Sharing tunes

Share… (Now Playing, the inspector, the menu bar player) and Share in a tune
row's context menu make a link to an HVSC tune:
`https://useresonance.app/t/bQGey6gxqfhT?s=2&v=85`. The code is the tune's
share code: the first 72 bits of its MD5 (the key Songlengths.md5 uses, so
the link names the same tune in every release) in base64url, 12
characters. It's computed, not stored: the server, the core and the app
each derive it (`short_code` in `share-server/src/tune.rs` and
`core/src/share.rs`, `SharedTuneLink.shortCode`; their tests share
examples), and a code two tunes shared would name neither (odds about one
in 10¹² for 100,000 tunes). A whole MD5 works in its place. `s` (the
subtune) is left out for the tune's start song, `v` is the sender's HVSC
release.

- **The share server** (`share-server/`, a small Rust service in Docker)
  answers those links with a page carrying Open Graph and Twitter tags, so
  chat apps and social media show a preview card: an 800×420 JPEG per
  tune, rendered once and kept on disk (title, composer, release, length,
  the strongest sound traits and the tune's barcode, as list rows draw it:
  it stays legible when chat apps shrink the card). The page itself shows
  the fingerprint sphere turning, the same maths as the app's
  `MorphSphere`, and its Open in Resonance button hands over to the app;
  Download Resonance goes to the website. GitHub Pages can't do this: crawlers don't run
  JavaScript, and ~60,000 pre-rendered images won't fit. Deploying it is in
  `share-server/README.md`.
- **The tune index** the server reads comes from a collection and a
  fingerprint store:
  `cargo run -p phosphor-apple --release --example share_index -- <HVSC folder> <copy of fingerprints.sqlite> > index.json`
  (16 MB for HVSC 85). Rebuild it for each HVSC release; links to tunes
  it doesn't know still open in the app, with a generic card.
- **Opening a link**: the page links to `resonance://tune/<md5>?s=&v=&p=&t=&a=`
  (`CFBundleURLTypes` in `Config/Resonance-Info.plist`); `p` is the HVSC
  path, `t`/`a` the title and author. `PlayerCore.find_shared_tune` looks
  the MD5 up in the collection's Songlengths.md5, then tries the path
  (`core/src/share.rs`), and the main window's sheet (`SharedTuneSheet`)
  offers Play / Show in Library, Update to HVSC N, Check for Update or
  Download HVSC (`SharedTuneOutcome`). Universal links (https links opening
  the app directly) need the Associated Domains entitlement, so they wait
  for a Developer ID; the parser already accepts web links to the server.
- **The server's address** is the `SHARE_BASE_URL` build setting
  (`ResonanceShareBaseURL` in the Info.plist): `https://useresonance.app`
  in Release builds, `http://localhost:8080` in Debug ones (run the server
  locally with
  `INDEX=index.json cargo run --manifest-path apple/share-server/Cargo.toml`).
  Empty hides the Share buttons. Links live forever in chats, so keep the
  domain answering `/t/<code>`, even if the server moves.

## Notes

- The fingerprint set: so Sounds Like works without hours of scanning,
  Resonance downloads the published fingerprints the first time it has a
  mostly unscanned collection (Settings → Collection has a Download button
  too) and merges them in; the scan fills in the rest. They're keyed by
  MD5, so one set serves every HVSC release. To publish a new one, after a
  finished scan:
  `scripts/fingerprint-set.sh` (writes `build/fingerprints-x<N>.zip`, N the
  extractor version), then upload it to the GitHub release tagged
  `fingerprints`, replacing the old file. Bumping `EXTRACTOR_VERSION` means
  publishing a new set: the app asks for the file of its own version.
  Check a set end to end with
  `FINGERPRINT_SET=$PWD/build/fingerprints-x1.zip cargo test -p phosphor-apple published_set -- --ignored`.
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

## Releases

`scripts/release.sh` builds one: a Release archive signed with Developer
ID, notarized and stapled, in `build/release/Resonance-<version>.dmg`
(the version is the project's `MARKETING_VERSION` and `RELEASE_STAGE`,
`0.1.0-alpha.1`; About Resonance shows the same; an empty stage is a final
release). It needs a "Developer
ID Application" certificate and a notarytool keychain profile (the script
explains); without the certificate it makes an unsigned image to try the
build. Publish the `.dmg` on a GitHub release tagged `v<version>` (an alpha
or beta as a pre-release, `v0.1.0-alpha.1`); the website's Download button
takes the newest release with a `.dmg`.

### Updates

The app updates itself with [Sparkle](https://sparkle-project.org) (a
Swift package): Check for Updates… in the app menu, and Settings →
Advanced → Updates. It reads `site/appcast.xml` from the website
(`SUFeedURL`, the `SPARKLE_FEED_URL` build setting) and only installs an
update whose EdDSA signature matches the public key built into the app
(`SUPublicEDKey`, the `SPARKLE_PUBLIC_ED_KEY` build setting). Both are set
for Release only, so Debug builds don't update themselves.

The signature is what makes unsigned (ad-hoc) releases updatable: Sparkle
accepts an update that's either EdDSA-signed with the app's key or signed
with the same Developer ID, and ad-hoc builds never share an identity. It
also takes the quarantine off the new version, so only the first install
needs approving in System Settings; the app must run from Applications,
not the disk image. Once releases are signed with Developer ID, updates
from unsigned builds keep working, because the EdDSA key stays the same.
**Never change or lose that key**: apps with the old one can't update.

Once, before the first release with updates:

1. Make the key, which goes into the login keychain:
   `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`
   (run `scripts/release.sh` or `xcodebuild -resolvePackageDependencies
   -project Resonance.xcodeproj -clonedSourcePackagesDirPath
   build/SourcePackages` first to download the tools). It prints the
   public key.
2. Set `SPARKLE_PUBLIC_ED_KEY` in the Resonance target's Release settings
   to that public key, and commit it. It isn't secret.
3. Back up the private key somewhere safe outside the repository:
   `generate_keys -x sparkle-private-key.txt`, then store the file in a
   password manager and delete it. `generate_keys -f <file>` imports it
   on another Mac.

Each release:

1. Raise `CURRENT_PROJECT_VERSION` (the build number: Sparkle compares
   it, and it must go up every release) and `RELEASE_STAGE` (`alpha.2` →
   `alpha.3`), or `MARKETING_VERSION` for a new version.
2. Write `release-notes/<version>.md` (`release-notes/0.1.0-alpha.3.md`):
   a few lines of Markdown on what's new. The update dialog shows it to
   everyone being offered the update, so don't skip it.
3. Run `scripts/release.sh`. Besides the `.dmg`, it signs the image with
   the keychain's key and adds it, with the release notes, to
   `site/appcast.xml`, linking to
   `https://github.com/ErikLuimes/resonance/releases/download/v<version>/<name>.dmg`.
   It stops early if the key is missing or doesn't match the build
   setting, or if the build number isn't higher than the feed's newest.
4. Commit and push the version change and the release notes, but **not
   `site/appcast.xml` yet**.
5. On GitHub, draft a release tagged `v<version>` (`v0.1.0-alpha.3`) on
   that commit, a pre-release for an alpha or beta. Attach the `.dmg`
   from `build/release/` without renaming it (the feed links to that
   exact name and size), and publish.
6. Then commit and push `site/appcast.xml`. The website deploys it and
   copies of Resonance find the update within a day, or at once with
   Check for Updates….
7. Check: https://erikluimes.github.io/resonance/appcast.xml lists the new
   version, and Check for Updates… in the previous release offers it.

Why this order: the tag marks the source of the release, so it goes on
the commit with the version change. The `.dmg` isn't in git at all; it's
a file attached to the GitHub release. And the feed is the announcement:
pushing it tells every installed copy to download the `.dmg`, so the
release has to be published first, or they get a failed download.

The variables at the top of `release.sh` point a build at a local feed
and a test key, to try an update end to end without touching the real
feed.

Before a release, after changing dependencies: `scripts/acknowledgements.sh`
rewrites `Resonance/Acknowledgements.txt`, the licences About Resonance
shows.

## License

Resonance's own code — everything under `apple/` — is MIT-licensed; see
[`LICENSE`](LICENSE). The Phosphor engine it compiles from `../src` keeps
Phosphor's MIT license, in [`../LICENSE`](../LICENSE).

The app as built also includes GPL-licensed SID emulators (reSID through
resid-rs, SIDLite and libsidplayfp), so builds of Resonance are distributed
under the GNU GPL, version 3, with the source here. About Resonance →
Acknowledgements lists every library in the app and its licence.
