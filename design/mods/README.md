# Amiga mods (Resonance 2.0)

Plan, not built (2026-11-08). Resonance plays HVSC's SID tunes; 2.0 adds Amiga
music modules as a second collection beside it, with the same browsing, Sounds
Like, visualizers and smart playlists. Nothing here is decided until step 1 is.

## What's SID-shaped today

Playing a module is the small part. Almost everything around playback assumes
one chip and one collection:

- About 80 files in `apple/core`, `apple/cli`, `apple/Resonance` and
  `apple/share-server` name HVSC, and 41 assume a `.sid` file (count on
  2026-11-08, excluding build output).
- `Engine`, `PlaybackOptions` (chip model, pseudo-stereo) and subtunes in
  `core/src/ffi.rs` describe a SID.
- `core/src/library.rs` wraps upstream's `hvsc_browser` with three fixed
  categories: Musicians, Games, Demos.
- Sounds Like's 41 features (`core/src/fingerprint/extract.rs`) come from SID
  register writes.
- The visualizers (`core/src/viz.rs`) read 3 voices per chip: waveform bits,
  ADSR, filter.
- Under the Hood (`core/src/tracker.rs`) rebuilds patterns from register
  writes.
- Smart playlists filter on `SmartChip` and SID sound tags.
- Share links, fingerprints and learned lengths key on MD5 with no notion of
  which collection a file is from.

## 1. The collection, and permission first

| Archive | Size | Metadata | Bulk download |
|---|---|---|---|
| AMP, Amiga Music Preservation | about 160,000 Amiga modules (a third-party figure, not AMP's) | Composers: names, handles, groups, countries | No. Per-author archives on request, and downloads are checked to come from AMP's own site |
| Modland | over 400,000 modules in 300+ formats, every platform | Little beyond folders | Yes (FTP) |
| Lemon Amiga | Amiga collection | Little | Torrents with yearly updates |

AMP is the HVSC of the Amiga: one platform, composer-centred, with the data
the composer pages, STIL panel and Sounds Like benchmark need. Its download
rules mean Resonance can't fetch it without an agreement. The iOS app 4champ
already plays AMP's catalogue, so there's precedent to point to.

Before any code:

- Ask the AMP team whether Resonance may download and index the collection,
  and in what form (an archive they publish, a sync like HVSC's, or files
  users already have).
- Resonance never hosts a copy. Same stance as the CSDb plan.
- Fall back to "point Resonance at your own module folder" if there's no
  agreement. That keeps playback and Sounds Like, but loses composer data.

## 2. Playback

Two kinds of Amiga music:

- **Tracker modules** (ProTracker MOD and its family, plus OctaMED, and the PC
  formats XM, S3M, IT): the file holds patterns and samples. Most of AMP is
  these.
- **Custom formats** (TFMX, Future Composer, Hippel, Whittaker, SoundMon and
  hundreds of others): the file holds the composer's own 68000 player routine,
  the Amiga counterpart of SID player code.

Engines:

- **libopenmpt**, BSD-3-Clause, for tracker modules. It renders MOD, XM, S3M,
  IT and dozens of older formats, seeks, reports song length, and exposes the
  current order, pattern, row and per-channel levels. It has an Amiga
  resampler emulation (A500 and A1200 filter); confirm the control names
  against the version we pin.
- **UADE**, GPLv2+, for custom formats. It emulates the 68000 and Paula and
  runs the original EaglePlayer plugins. The licence fits Resonance's GPL, but
  each plugin's own terms need checking before bundling. This is 2.1, not 2.0.

In the core: a format-neutral player interface, with the existing SID players
and a libopenmpt one behind it. The session thread, queue, history, repeat and
scrubbing logic stay as they are. Scrubbing gets simpler for mods, since
libopenmpt seeks directly (compare `design/scrubbing/README.md`).

Song lengths come from libopenmpt, so mods need no Songlengths file and rarely
need learned lengths. Some modules hide extra songs at other order positions;
libopenmpt reports these as subsongs, which map onto subtunes.

## 3. Collection and metadata

- A collection layer above `library.rs`, so HVSC and AMP sit side by side in
  the sidebar, with search and Surprise Me able to cover one or both.
- AMP composer data in place of STIL, the bug list and HVSC's composer info:
  a new parser and cache, like STILKit.
- Tune identity scoped by collection. Share links (`/t/<code>`), the
  `resonance://` scheme, the share server's preview cards, fingerprints,
  history and playlists all need to tell a SID from a mod.
- Amiga modules are named by prefix (`MOD.title`), not extension, so file
  type detection reads the contents. That touches `UTType+SID.swift`, Quick
  Look, Spotlight, drag and drop, and Open With.
- The sandbox needs bookmark access to the module folder, as it has for HVSC.

## 4. Sounds Like

The shipped blend is 75% chip features and 25% MERT embedding
(`design/similarity/README.md`).

- The chip features don't carry over.
- MERT works on rendered audio, so it carries over unchanged.
- Mods need their own feature set, read from the file and the render:
  instrument and sample makeup (count, lengths, loops, likely drum samples),
  effect use (arpeggio, vibrato, portamento, volume slides), tempo and speed,
  channel count, note density per channel, stereo spread.
- Choose it the same way: a benchmark in `apple/scripts/similarity-bench`,
  same-composer precision@7 on AMP composers split 70/30, frozen weights
  scored once on held-out composers.
- Fingerprinting and embedding about 160,000 modules ships as precomputed
  downloads, like `fingerprints-x2.zip` and `embeddings-e1.zip`.

Across collections, only MERT is comparable, so "SID tunes that sound like
this mod" (and the reverse) would be MERT-only. Worth benchmarking: it ties
the two halves of the app together through its main feature.

## 5. Visualizers and Under the Hood

Visualizers are additive: mods get new pages, nothing SID-only is removed.

- A visualizer feed for modules: per channel, the note, instrument, volume,
  effect and a sample tap. Mods have 4 channels on the Amiga, up to 32 or more
  in the PC formats.
- Scope and Bars adapt per channel. Envelope, waveform mix and MorphSphere
  don't apply; mods get pages of their own (samples, channel activity, the
  pattern).
- Under the Hood gets easier: the patterns and sample list are in the file, so
  the tracker view shows the real thing, not a reconstruction.

## 6. Everything else that names a SID

- Smart playlists: a format/collection filter in place of, or beside,
  `SmartChip`; mod sound tags; Describe's word-to-tag reading
  (`smart_bench` gets mod cases).
- Song table columns, the inspector, the Now Playing card.
- Onboarding, Help, What's New, keyboard help.
- The terminal app (`apple/cli`): browsing, playback, its visualizers.
- The MCP server: tool descriptions say "C64 SID player", and tools take HVSC
  paths. The Raycast extension.
- Credits and `Acknowledgements.txt`: libopenmpt now, UADE in 2.1.
- The site and FAQ.
- `apple/release-notes/2.0.0.md`.

## Order

1. Contact AMP; decide the collection.
2. Core: player interface and libopenmpt backend. Play, pause, seek, length,
   subsongs, from a folder of modules. A bench for playback and length
   against libopenmpt's own reference player.
3. Collection layer, AMP metadata, scoped identity including share links.
4. Mod fingerprints: features plus MERT, with the benchmark.
5. App: sidebar, browsing, tables, visualizer pages, Under the Hood, smart
   playlists, onboarding.
6. Terminal app and MCP.
7. 2.1: UADE and custom formats.

Step 2 is a few sessions. Steps 3 and 4 are most of the work, about the size
of the SID collection and Sounds Like work again.

## Open questions

- Will AMP allow it, and in what form?
- Tracker modules only, or PC formats (XM, S3M, IT) too? libopenmpt plays
  them anyway; the question is whether the collection includes them.
- One app with two collections, or a mode switch?
- Is cross-collection Sounds Like good enough to ship? Only the benchmark can
  say.

## Sources

- AMP: [about](https://amp.dascene.net/about.php), [FAQ](https://amp.dascene.net/faq.php)
- AMP size and an AMP-based player: [4champ](https://github.com/sitomani/4champ)
- Modland: [ExoticA wiki](https://exotica.org.uk/wiki/Modland)
- Lemon Amiga torrents: [Amiga mod file sources](https://maidavale.org/blog/amiga-mod-file-sources/)
- libopenmpt: [repository](https://www.github.com/OpenMPT/openmpt), [README](https://lib.openmpt.org/doc/md_README.html)
- UADE: [uade123 man page](https://www.mankier.com/1/uade123)
