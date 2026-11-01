<p align="center">
  <a href="https://erikluimes.github.io/resonance/">
    <img src="https://raw.githubusercontent.com/ErikLuimes/resonance/main/apple/site/assets/og-card.png" alt="Resonance — SID music, native to your Mac" width="760">
  </a>
</p>

<p align="center">
  <strong>A native macOS player for Commodore 64 music.</strong><br>
  All of the High Voltage SID Collection in the sidebar, a visualizer that shows every note,<br>
  and an interface made of Liquid Glass.
</p>

<p align="center">
  <a href="https://erikluimes.github.io/resonance/"><img src="https://img.shields.io/badge/website-live%20demo-3FD0E8?style=flat-square&labelColor=12141F" alt="Website and live demo"></a>
  <img src="https://img.shields.io/badge/macOS-27%2B-9B6BFF?style=flat-square&logo=apple&logoColor=white&labelColor=12141F" alt="macOS 27 or later">
  <img src="https://img.shields.io/badge/Apple%20silicon-arm64-9B6BFF?style=flat-square&labelColor=12141F" alt="Apple silicon">
  <img src="https://img.shields.io/badge/Swift%206-SwiftUI-FF9A3C?style=flat-square&logo=swift&logoColor=white&labelColor=12141F" alt="Swift 6 and SwiftUI">
  <a href="https://github.com/ErikLuimes/resonance/blob/main/apple/LICENSE"><img src="https://img.shields.io/badge/license-MIT-3FD0E8?style=flat-square&labelColor=12141F" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://erikluimes.github.io/resonance/"><b>Website &amp; live demo</b></a> ·
  <a href="#features">Features</a> ·
  <a href="#getting-started">Getting started</a> ·
  <a href="#keyboard-shortcuts">Shortcuts</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="#built-on-phosphor">Built on Phosphor</a>
</p>

---

The SID chip inside the Commodore 64 had three voices, four waveforms and one resonant
filter, and composers turned that into some of the most loved music in gaming and the
demoscene. **Resonance** is a SwiftUI app made only for the Mac that brings the High Voltage
SID Collection — more than 60,000 tunes — to your desktop, and shows you exactly how each one
is played.

> **Hear it first:** the [website](https://erikluimes.github.io/resonance/) has an interactive
> copy of the Resonance window. Hit play and it composes a SID-style tune in your browser.

## Features

- **All of HVSC, one click away.** Musicians, Games and Demos live in the sidebar. Browse
  composers and their tunes, or just type: results are ranked across a category or all of
  HVSC, exact matches first, typos and accents forgiven.
- **Surprise Me.** A radio of random tunes from the whole collection, picked one ahead, never
  repeating anything you've heard since launch. Press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd>
  and let it run.
- **See every voice.** A live visualizer with a level bar and peak hold for each SID voice,
  plus the note and waveform it's playing, redrawn every display frame.
- **STIL in the inspector.** Composer comments and cover credits next to title, release, SID
  model, clock and MD5. Click the author to jump to all of their tunes.
- **A proper Mac app.** Now Playing in Control Center, your keyboard's media keys, a Playback
  menu with shortcuts, and drag and drop for SID files, folders and M3U playlists.
- **Two engines.** SIDLite (from libsidplayfp) picks the chip model from each tune's header;
  reSID emulates the chip cycle by cycle. Switch any time.
- **Stereo, your way.** 2SID and 3SID tunes, mirrored stereo for 2SID, and three widths of
  pseudo-stereo for mono tunes.
- **A playlist that stays put.** Sort by any column, drag to reorder, import M3U. Tunes you
  play from the library go to a temporary queue, so your playlist is never clobbered.
- **Song lengths and subtunes.** The HVSC Songlengths database moves on at the right moment,
  and subtunes are a click — or <kbd>⌥</kbd><kbd>⌘</kbd><kbd>←</kbd>/<kbd>→</kbd> — away.

## Getting started

**Requirements:** a Mac with Apple silicon running macOS 27 or later.

1. **Install.** Download the latest build from
   [Releases](https://github.com/ErikLuimes/resonance/releases), open it and drag Resonance into
   Applications. No release yet? [Build it yourself](#build-from-source) — it takes a few minutes.
2. **Add your collection.** In **Settings → HVSC**, choose the folder that holds `MUSICIANS`,
   `GAMES` and `DEMOS`, or click **Use Phosphor's**. No HVSC yet? Get it from
   [hvsc.c64.org](https://hvsc.c64.org).
3. **Press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd>.** Surprise Me starts the radio. Or drop SID
   files, folders and M3U playlists onto the window.

> [!NOTE]
> Song lengths and STIL comments are read from Phosphor's data folder
> (`~/Library/Application Support/phosphor/`). If you've run Phosphor, Resonance shares what it
> downloaded. Without them, tunes play for your default length in **Settings → Playback**.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| <kbd>Space</kbd> | Play / Pause (in the playlist) |
| <kbd>⌘</kbd> <kbd>.</kbd> | Stop |
| <kbd>⌘</kbd> <kbd>←</kbd> / <kbd>→</kbd> | Previous / next track |
| <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>←</kbd> / <kbd>→</kbd> | Previous / next subtune |
| <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>R</kbd> | Surprise Me |
| <kbd>⌘</kbd> <kbd>↑</kbd> / <kbd>↓</kbd> | Volume up / down |
| <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>S</kbd> | Shuffle |
| <kbd>⌘</kbd> <kbd>O</kbd> | Add files or folders |
| <kbd>⌘</kbd> <kbd>,</kbd> | Settings |

## Build from source

You'll need **Xcode 27** and **Rust**:

```bash
brew install rustup && rustup default stable
```

Then clone, build and launch:

```bash
git clone https://github.com/ErikLuimes/resonance.git
cd resonance
xcodebuild -project apple/Resonance.xcodeproj -scheme Resonance -derivedDataPath apple/build/DD build
open apple/build/DD/Build/Products/Debug/Resonance.app
```

Or open `apple/Resonance.xcodeproj` and run the **Resonance** scheme. The first build compiles
the Rust engine and takes a few minutes; after that Xcode rebuilds it incrementally.

How the app, the Rust bridge and the engine fit together, how to run the tests, and how to pull
in Phosphor updates is all in the [developer guide](https://github.com/ErikLuimes/resonance/blob/main/apple/README.md).

## Built on Phosphor

Resonance stands on the shoulders of
**[Phosphor](https://github.com/sandlbn/Phosphor)**, Marcin Spoczynski's open-source SID
player for macOS, Windows and Linux, written in Rust with an Iced interface. Resonance doesn't
reimplement SID playback: it compiles Phosphor's engine **unchanged** and talks to it through
[UniFFI](https://github.com/mozilla/uniffi-rs), so improvements upstream flow straight into the
Mac app.

```
Resonance.app            SwiftUI · Swift 6 · Liquid Glass
  └ PhosphorCore         UniFFI-generated Swift bindings
      └ phosphor-apple   Rust: session, driver thread, FFI
          └ Phosphor     reSID · SIDLite · HVSC · Songlengths · STIL — compiled from src/
```

This repository is based on Phosphor's, so you'll find both here:

| Path | What it is |
| --- | --- |
| [`apple/`](https://github.com/ErikLuimes/resonance/tree/main/apple) | **Resonance**: the SwiftUI app, the Rust bridge and the website |
| `src/`, `Cargo.toml` | Phosphor's engine and Iced app, kept identical to upstream |
| `README.md`, `docs/` | Phosphor's own README and website |

**Want real hardware?** Phosphor plays through a
[USBSID-Pico](https://github.com/LouDnl/USBSID-Pico) or an [Ultimate 64](https://ultimate64.com/),
and has HVSC sync, favourites, a DSP pedalboard, a web remote and karaoke for MUS files.
Resonance doesn't do those yet — for them, use [Phosphor](https://sandlbn.github.io/Phosphor/).

## License & credits

Resonance's own code (everything under `apple/`) is released under the
[MIT License](https://github.com/ErikLuimes/resonance/blob/main/apple/LICENSE), © 2026 Erik Luimes.
Phosphor is © 2026 Marcin Spoczynski, also
[MIT-licensed](https://github.com/ErikLuimes/resonance/blob/main/LICENSE).

SID emulation by reSID and libsidplayfp. Tunes, song lengths and STIL come from the
[High Voltage SID Collection](https://hvsc.c64.org); the music belongs to its composers.
