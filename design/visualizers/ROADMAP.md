# Visualizer roadmap

Tick items off as they land. Each phase is a good size for one or two Claude Code sessions.
Paste the **Prompt** block into Claude Code to start a phase.

---

## Phase 0 — Data foundation (do this first)

- [x] Per-frame `SIDFrame` snapshot published from the player
- [x] Per-voice sample taps (ring buffers)
- [x] A `VisualizerFeed` the UI can read at display rate
- [x] Debug view that prints the live snapshot
- [x] Line the visuals up with the sound automatically (no ear-tuning)

**Goal:** one clean, thread-safe source of truth that all visualizers read.

**As built (2026-11-01):**
- **Shadow reSID.** The engines' chips live in upstream files, so `apple/core/src/viz.rs` runs a visuals-only resid-rs `Synth` per chip, fed each player status's registers on the session thread. That gives real envelope counters and per-voice samples (about 44.8 kHz, waveform × envelope, no DC offset) on both SIDLite and reSID, with no upstream edits. It costs about 20 µs per chip per frame. Register changes land on frame boundaries, so hard restarts within one frame and `$D418` digis don't show.
- **Sync with the sound.** A fixed delay can't work, because the lag changes: about 100 ms after a track starts (the engines queue 150 ms of silence, then wait 50 ms), close to zero after a pause (the buffer runs dry), and more on Bluetooth output. `viz.rs` models the engine's buffer from the frame timing. `OutputLatencyMonitor` adds the output device's latency from Core Audio, and updates it when the default output changes. A fine-tune offset (default 0) sits in the debug window, which also flashes each voice when a note starts, to check sync by eye.
- **API.** Swift calls `store.visualizer` (`Resonance/Model/VisualizerFeed.swift`): `latest()`, `history(_:)` (up to 512 frames) and `scope(chip:count:)` (up to 2048 samples per voice). Decoded fields follow IMPLEMENTATION_NOTES.
- **Multi-SID.** Show one chip's three voices at a time, with a SID 1/2/3 picker. The feed carries every chip.
- **Debug window.** Window › SID Monitor (Debug), Debug builds only.

**Data:**
- All 29 registers ($D400–$D41C) after each player call (50 Hz PAL / 60 Hz NTSC).
- Derived per voice: frequency in Hz, MIDI note, note name, gate, waveform bits, test/ring/sync, pulse width (12-bit), AD/SR, **envelope level 0–1** (from the emulator's envelope counter, not just ENV3).
- Derived filter: cutoff (11-bit), resonance, routing bits, mode, volume.
- Per-voice output samples: the last ~2048 samples per voice, for the scope and FFT.

**Acceptance:**
- No allocations or locks on the audio thread beyond a lock-free write.
- UI can read the latest frame and the last N frames (history ring of ~512 frames, about 10 s at 50 Hz).
- Debug view shows note, gate, waveform, PW, ADSR and env level per voice, updating live.

**Prompt:**
```
Read design/visualizers/README.md, ROADMAP.md (Phase 0) and IMPLEMENTATION_NOTES.md.
Then study how playback works in this repo: where SID emulation runs, which thread, and how audio
reaches the output. Propose (plan only, no edits yet) how to add a per-frame SIDFrame snapshot, a
frame history ring, and per-voice sample taps, published through a VisualizerFeed the SwiftUI layer
can read at display rate without blocking the audio thread. Include where envelope levels per voice
can be read from our emulator. After I approve, implement it plus a small debug view.
```

---

## Phase 1 — Inspector card visualizers

- [x] Oscilloscope, alongside the bars (not replacing them) — `reference/Main.dc.html`
- [x] Switching on the card: swipeable pages with dots inside the card's bottom edge (name by the dots on hover), remembers last choice. Chosen over the reference's segmented control.
- [x] Envelope (ADSR with live playhead) — `reference/Envelope.dc.html`. The core reports each voice's phase (attack, decay, sustain, release) from the visuals' reSID.

**Nice to have (parked 2026-11-01; pick up only when asked):**
- [ ] Compact lanes, as another page — `reference/Lanes.dc.html`
- [ ] Chip picker for 2SID/3SID tunes (SID 1 / 2 / 3); Scope and Envelope show SID 1 only for now
- [ ] Pop-out button → floating always-on-top mini window

Visualizers are additive: every one stays available as a page of the card. Each one is its own view (`ScopeVisualizer`, `BarsVisualizer`, `EnvelopeVisualizer`) behind `VisualizerView`, with note labels drawn by the shared `VoiceLabels`.

**Acceptance:** smooth at display refresh rate, under ~3% CPU on Apple Silicon, correct colors per voice, and gate-off and rests look calm rather than jittery.

**Prompt:**
```
Phase 1 from design/visualizers/ROADMAP.md. Using VisualizerFeed from Phase 0, replace the current
bar visualizer in the inspector card with the oscilloscope from reference/Main.dc.html, then add the
mode switcher from reference/AppInspector.dc.html with Lanes and Envelope modes. Port the drawing
logic from the JS in each reference file's data-dc-script block to SwiftUI Canvas + TimelineView.
Use the colors and fonts in IMPLEMENTATION_NOTES.md. Start with the scope only, show me, then add
the other modes.
```

---

## Phase 2 — Overview strip in the player bar

- [ ] Fast pre-scan of a tune (emulate without audio output) → per-voice activity bins
- [ ] Cache results on disk keyed by HVSC MD5 + subtune
- [ ] Replace the progress bar with the 3-lane strip (played bright, rest dimmed, click to seek) — `reference/AppInspector.dc.html`

**Acceptance:** a 5-minute tune scans in well under a second in the background; the strip appears without blocking playback; seeking still works.

**Prompt:**
```
Phase 2 from design/visualizers/ROADMAP.md. Add a background pre-scanner that runs our SID engine
faster than realtime with no audio output and records per-voice activity (envelope level and gate)
into ~200 time bins per subtune. Cache it on disk keyed by MD5 + subtune. Then replace the player
bar's progress bar with the overview strip from reference/AppInspector.dc.html, keeping seek.
```

---

## Phase 3 — "Under the hood" drawer

- [x] Drawer that slides up over the list, toggled from the player bar, and in the terminal app on `u` — `Views/UnderTheHoodView.swift`, `reference/AppDrawer.dc.html`
- [x] Registers tab (bytes flash on change, CTRL bits decoded) — `reference/Registers.dc.html`
- [x] Sweeps tab (PW, cutoff + resonance, gates) — `reference/Sweeps.dc.html`
- [x] Pitch trail tab — `reference/PitchTrail.dc.html`
- [x] Tracker, rebuilt from register writes — `TRACKER.md`, `reference/Tracker.dc.html`. The mock's order list isn't there: nothing's known about patterns to list.
- Dropped: "Open in window". It's a drawer only, as a second window was more mess than it was worth.

**Tracker note:** `.sid` files hold player code, not patterns. Rebuild rows from the frame history:
a new row on each gate-on or note change; note from frequency; "instrument" = a distinct
waveform + AD + SR combination; commands inferred (slide = steady frequency change, vibrato =
oscillating frequency, `---` = gate off). Optionally load GoatTracker `.sng` / SID-Wizard files later for real patterns.

**Prompt:**
```
Phase 3 from design/visualizers/ROADMAP.md. Build the Under the hood drawer from
reference/AppDrawer.dc.html with tabs Registers, Sweeps, Pitch trail and Tracker, all reading
VisualizerFeed and its frame history. Start with Registers (reference/Registers.dc.html), then
Sweeps, then Pitch trail. Plan the register-derived tracker reconstruction separately before
building it (see the tracker note in ROADMAP.md).
```

---

## Phase 4 — Now Playing (full window / full screen)

- [x] Now Playing — `reference/AppNowPlaying.dc.html`, with the mockup's Halo / Particles / Radial tabs at the top (the choice is remembered). The main window's second mode: it slides up over the library like Music's player (full screen when the window is). Opened from the player bar's button, its track title, or View › Show Now Playing (⇧⌘F); Esc or its top-right button slides it away. A thin progress bar stands in for the overview strip until Phase 2.
- [x] Per-voice FFT (vDSP) on the sample taps — `VoiceSpectrum`: 2048 samples, Hann window, 64 log bands from 40 Hz to 10 kHz on a −60…0 dB scale, fast rise and slow fall.
- [x] Halo (Metal fragment shader) — `reference/Halo.dc.html`. `HaloShape` builds each ring's radii on the CPU from the waveform's harmonics and the envelope; `Shaders/Halo.metal` draws them through SwiftUI's shader API. Building needs Xcode's Metal Toolchain component.
- [x] Radial spectrum — `reference/RadialBars.dc.html`. `RadialView`, a Canvas over `VoiceSpectrum`.
- [x] Particle sphere — `reference/Particles.dc.html`. `ParticlesView`: an MTKView with 24,000 points. The vertex shader (`Shaders/Particles.metal`) does the displacement, so no compute pass is needed. `ParticleSphere` keeps each voice's level, ripple rate and last note start (gate opening) on the CPU.
- [ ] Spectrogram waterfall (texture scroll) — `reference/Spectrogram.dc.html`
- [x] Choosing them. Seven is too many for the picker, so Settings › Appearance chooses up to three (`NowPlayingVisual.lineup`; Particles, Sound Map and Notes to start with), and Now Playing's picker offers those.
- [x] Notes, after a picture the user shared: sheet music lying flat and running into the distance, a staff per voice, dark beads for the notes to come, and a ball per voice hopping from note to note and lighting each as it lands. It has to know the notes ahead of time, which the live feed can't give, so it uses the tracker's rebuild of the whole tune (`tracker_song`, Phase 3) and places it by the feed's heard time, as the Tracker tab does. `NoteTrack` holds the notes and works out each ball's place from the time alone (a hop is a real throw: its height is gravity × time² / 8, so quick runs skip low), so seeking needs nothing reset. The feed's heard time moves in 20 ms steps; `SmoothPlayhead` runs with the display's clock within the frame being heard, so the staves don't judder. `NotesRenderer` projects it on the CPU and Shaders/Notes.metal draws capsules into a half-float scene with bloom; things blur by their distance from the balls, like the picture's depth of field.
- [x] Spectrum, an analyzer like a mixing desk's: a filled curve per voice from 30 Hz to 16 kHz on a −60…0 dB grid, peak-hold lines, a white line for the three together, and each voice's note marked at its fundamental, which comes from the frequency register and so is exact. `FineSpectrum` reads the lows from an 8192-sample FFT and the highs from a 2048-sample one, crossing over between 250 and 900 Hz: over 2048 samples a bass note is a lump an octave wide. The feed's scope read went from 2048 to 8192 samples for it (`MAX_SCOPE_SAMPLES`). `SpectrumView` is a Canvas.
- [x] Terrain, the spectrum in 3D: frequency left to right, the newest moment at the front, four seconds sliding away behind it as ridge lines, in the color of the voices sounding there. `TerrainRenderer` keeps 120 rows of `FineSpectrum` in a ring texture, one row per 1/30 s, and Shaders/Terrain.metal builds the mesh from it in the vertex shader, with a depth buffer so near ridges hide far ones. This does what the spectrogram waterfall above was for; that one is still open as a flat page.
- [x] Ink and Liquid Light: one fluid, shown two ways. `InkRenderer` runs a stable-fluids solver on the GPU each frame (Shaders/Ink.metal: pour, vorticity, divergence, 22 rounds of pressure, gradient, advect), velocities on a grid 176 cells high carrying dye on one four times finer. `InkJets` stands the voices on a ring around the middle: a voice's level is how hard it pours, a note's start is a puff, and the note within its octave steers the stream. Ink is thin dye that halves in about three seconds; Liquid Light pours more, keeps it about eight, and shades it as oil on a projector's glass (tinted backlight bent at each blob's rim, a highlight on top). About 1.3 ms a frame.
- [x] Ferrofluid: a pool of black liquid standing in spikes over a magnet per voice (`FerroField`: pull follows the level, kicked by each note; the note slides the magnet in and out). Shaders/Ferro.metal walks every pixel's line of sight down to a honeycomb height field and lights it with the room and each voice's colored light; it's sampled once a point rather than a pixel. The camera circles and sways (several slow sines drifting in and out of step). About 4 ms a full-screen frame.
- [x] Chip: the SID with its lid off, from above, as under a microscope. `ChipDie` draws the still picture once with Core Graphics (the ceramic body, the gold cavity, 28 leads named in package order with a bond wire each, and a die laid out by function: three voices side by side, the filter, the register file, the mixer); `ChipDrawing` lights it every frame in a Canvas. Every lit cell is a real register bit, so it shows nothing that isn't in the feed. The floor plan is in the manner of the 6581's die, not a trace of its mask, and the filter's curve is a two-pole model for the picture, not the chip's measured response.
- [x] Rasters: a C64 demo screen on the C64's own 384 × 272 grid (Shaders/Rasters.metal, four samples a pixel so the blocks stay clean at any size). `RasterShow` puts each voice's copper bar on its note's line with its last five notes fading behind; noise flashes the border. The top line prints each voice's waveform and note, and the sine scroller carries the tune's title, composer and release. Its letters are the system's monospaced font drawn unsmoothed at 16 pixels, not the C64's character ROM, which is Commodore's.
- [x] Silicon: a 6581 in 3D, lid off, around the R3's real die from its mask layers. See `silicon/README.md` for where the layers come from and their license (CC BY-SA, Tommi Lempinen). `pack-layers.swift` scales the five 16820 × 14629 one-bit layers to a quarter and packs them as RGBA coverage (4.7 MB, `Scenes/SIDDie6581R3.lzfse`). `SiliconScene` is a SceneKit scene in die widths: the ceramic body with its cavity, shelf and gold well, a bond wire from each of the die's pads (found on the metal layer) to a finger, and 28 pins. The die's material is a shader modifier that stacks the layers with a look each (oxide over diffusion and polysilicon, grainy aluminum with a lit edge and a shadow, contacts as pits), sharpens their edges close up, and is physically lit, so the aluminum glints as the camera moves. `SiliconDie` holds the blocks' places (read off his map of the die, turned half a turn to match the layers) and says what's lit: each block faintly, and each of its bits where it's 1, in even slices along the block. `SiliconOverlay` draws that into a texture the die's material lets through along its own wiring, and draws a second one that floats above the die: beads running the signals' ways, the three voices' waveforms and the output's. The pins glow with their wires as on Chip. The package is aged (`SiliconWear`): one seamless texture of grain, scratches, blotches and specks, read by world position from three directions, gives the ceramic its grain, handled patches, dust and chipped edges and the gold its tarnish, with dull tin on the legs and ink rubbed thin on the marking. The package follows photographs of a ceramic MOS chip of those years with its lid off (a 6569, on retronn.de): gray-purple alumina that glitters, a sandy gold lead frame in rows round the well, straight thin bond wires, a silvery pool under the die, clear glue left on the sealing band, a gold stripe and cross at the pin 1 end, legs with wide shoulders, and the gold lid, which carries the marking, set down on the other end; the camera adds contact shadows and stops its lens down as it comes in close. Nothing on it is true or sharp: the body, cavity, well and printed gold are extruded from outlines that wander a little, with rounded corners and bevelled top edges, and every bond wire has its own loop, bow, neck and flattened stitch. It's lit as on a workbench: one warm lamp whose pool of light thins toward the package's ends, a dim room, a faint cool fill, and a soft vignette. The camera's tour is shot like a product's reveal and never stops: eleven moves over about two and a quarter minutes (low along the package from pin 1, up and round it, down over the cavity, low round the bond wires, onto the die, then slides across the voices, the envelope generators, the filter and the address decoder, and back out), each at a steady pace and running into the next over its last 3 s or more (longer the more it has to pull back or come in, so a close-up never snaps out to the whole package). Ours, not the chip's: which way the bits run in a block, the signals' routes (they follow the gaps, not the real wires), and which voice column is voice 1.
- [x] Silicon shows the chip the tune asks for. `SiliconDie` is now a value with two instances: `mos6581` (as above) and `mos8580`, the R5, from the same source and under the same license (`Scenes/SIDDie8580R5.lzfse`, 4.5 MB). He drew no block map of the 8580, so its blocks are placed by eye on his photograph of its die, which is laid out like the 6581's: each voice's blocks are the 6581 map's, fitted to where the 8580's voices are. The 8580 gets the package it came in: black molded plastic with a notch and an ejector mark, pale printed marking, tinned legs from the sides' middle, and a ragged two-step pit etched down to the die on its lead-frame paddle, with the frame's fingers pointing in from all round. `SiliconView` picks by the tune's header (8580 when it says so, else 6581) and builds the scene afresh when it changes.
- [x] Silicon opens without holding the app up. Measured in an unoptimized build, opening it cost about 1.2 s on the main thread the first time: 0.38 s making the wear texture, 0.77 s compiling the scene's shaders for its first frame, about 25 ms unpacking the die and about 40 ms building the scene's nodes. The wear texture is now made ahead of time by `silicon/make-wear.swift` and shipped (`Scenes/SiliconWear.lzfse`, 0.6 MB; 3 ms to load). `SiliconAssets` loads it and the die's layers on another thread and keeps them (the wear for good, the last die's layers), SceneKit's `prepare` compiles the shaders before the scene is shown, and the view fades in when it's ready. About 40 ms stays on the main thread. Not yet timed in the app itself.
- [x] Chip and Rasters are out of the app (the user's call, 2026-11-11): Silicon does what Chip did, on the real die, and Rasters is lo-fi on purpose and didn't sit with the rest. `NowPlayingVisual.offered` leaves them out of the chooser and of any stored lineup; their code and tests stay, and Silicon uses Chip's `ChipState`, `ChipModel` and pin list. These are the exceptions to visualizers being additive. Eleven are offered.
- [x] Nimbus, in Rasters' place: a volumetric cloud in the dusk sky, after a Shadertoy the user shared (dathor's "Metamorphosis Volume"; the idea only, since it's non-commercial share-alike and Resonance is GPL). Shaders/Nimbus.metal walks each line of sight through the cloud in up to 64 steps, taking its thickness from a 64³ block of noise read at four scales and pushed about by slower noise, with four looks toward the sun at each step for self-shadow. `NimbusVoices` makes it move with the music: the cloud is metaballs (the user's idea), six soft balls, two a voice, whose pulls add up so they run together where they meet; they roam on wide, uneven orbits worked out on the CPU, each trailing smoke back along its way, and the noise is stirred harder where two overlap; a voice's pair follows its level closely in size and jumps on every note, rides higher with its pitch and glows from inside in its color, and they all drift and churn at a pace set by how loud the music is. The sky is pale (the user asked for a light background), the one visualizer that isn't dark. It lowers its own quality like Ferrofluid. Tried and taken out again at the user's word: rings on water for each note, water and then a sea under it, and the voices as bars of light across the sky.
- [x] Quality that lowers itself (`VisualizerQuality`), on Ferrofluid, Ink and Liquid Light, the ones whose cost is per pixel or per solver round. It goes by each frame's GPU time from the command buffer: above 60% of a 60 fps frame the level drops a step, below 15% for 8 s it rises one, and Low Power Mode or a hot Mac keeps it a step down. Ferrofluid samples coarser and takes fewer steps (3.6 ms a full-screen frame at full, 1.0 ms at low, on an M5 Pro); the fluid does 22, 14 or 10 pressure rounds; the lowest level also halves the frame rate. Not yet tried on a slow Mac.
- [x] The chooser (`VisualizerChooser`), in Settings › Appearance and behind Now Playing's Visualizers… button: a card per visualizer with a picture of it. Chosen cards and the one under the pointer run live; the rest run for 3 s to draw a picture and then hold it.
- [x] Sound Map, after a bird-song "map of sound" the user shared. `SoundMap` reads each voice's timbre 35 ms after every note start (gate on, or a pitch change of over half a semitone): 40 MFCCs (vDSP FFT over 2048 samples, 40 mel bands from 40 Hz to 11 kHz, DCT), plus RMS, spectral centroid and spread. `TimbrePCA` reduces c1–c39 to 3D with a slowly forgetting covariance, refitted every 2 s from the last axes and turned to line up with them, and the drawn axes ease over, so the map never jumps. Each node links to up to 4 earlier ones nearest in MFCC space and to its voice's previous note; 1,200 nodes at most, reset when the tune restarts. `SoundMapView` draws it with Metal (Shaders/SoundMap.metal): additive lines, squares and SF Mono glyph-atlas labels in a half-float scene, with MPS bloom. A new note flashes white for 1 s, then fades in its centroid's color (0–10 kHz scale); by 4 s its labels and lines are gone and only a faint dot stays. The camera orbits the whole map, faster while notes keep coming. Timings and camera are measured from the user's reference recording (IMPLEMENTATION_NOTES.md). Visualization only, no HUD (the user's choice). About 5 ms per full-screen frame, Debug build, including the GPU.

**Prompt:**
```
Phase 4 from design/visualizers/ROADMAP.md. Add the Now Playing window from
reference/AppNowPlaying.dc.html. First add a per-voice FFT stage (vDSP) fed by the sample taps.
Then implement the Halo as a Metal view, porting the shape logic from reference/Halo.dc.html,
followed by Radial spectrum, Particles and Spectrogram. Keep one MTKView and switch pipelines per mode.
```

---

## Phase 5 — Fingerprints & discovery

- [x] Batch scanner over HVSC computing a feature vector per subtune (Phase 2's pre-scan didn't exist yet, so this is the first one)
- [x] Store in SQLite next to the library index (MD5 + subtune)
- [x] Sound column with mini fingerprint in the list — `reference/AppFingerprints.dc.html`. Built as a nine-bar trait barcode (`SoundBarcode`), not voice lanes: every trait sits in the same place, so tunes that sound alike look alike down a column.
- [x] Hover card (fingerprint, waveform mix, tags, Play / Find similar). The card shows the tune's `MorphSphere`, a particle sphere that bulges toward its traits. Find Similar sorts the list by likeness, with a Match column.
- [x] Filter chips (Arpeggios, Filter sweeps, Noise drums, Ring mod, Sync leads, Digi samples). A tune needs every chip that's on.
- [x] "Sounds like" panel in the inspector (cosine similarity on the feature vector): the sphere, the sound in a sentence, seven matches as links, Play These. Scan progress and Pause are in Settings › Sound Fingerprints.

**As built (2026-11-03), core side:**
- **Extractor.** `apple/core/src/fingerprint/extract.rs` runs each subtune through libsidplayfp with its capture-only SID (the same emulation the player uses, minus synthesis), up to 3 minutes (the Songlengths length, else 2 minutes). Each video frame's cycle-stamped writes feed a register model with a frame-rate ADSR envelope (datasheet times). It records 128 activity bins per SID 1 voice and the features below, plus pitch mean/spread, pulse bass and vibrato. Tags come from fixed thresholds.
- **Scan.** `fingerprint/scan.rs`: worker threads at utility QoS (half the cores, at most 6). Pass 1 scans every tune's start song, pass 2 the other subtunes. About 5.6 subtunes/s on an M5 Pro, so all of HVSC (≈88k subtunes) takes about 4½ hours and the start songs about 3. Each subtune is marked `scanning` before it runs, so one that takes the app down is retried once and then skipped.
- **Store.** `fingerprints.sqlite` next to the session in Resonance's Application Support: `fingerprints` keyed by MD5 + subtune, `tunes` mapping collection paths to MD5s. Bump `EXTRACTOR_VERSION` to rescan.
- **"Sounds like".** `fingerprint/similar.rs`: cosine similarity on z-scored, weighted feature vectors, brute force over the whole store, one subtune per file.
- **FFI.** `start_fingerprint_scan`, `stop_fingerprint_scan`, `set_fingerprint_scan_paused`, `fingerprint_scan_status`, `fingerprints(paths)`, `fingerprint(path, subtune)`, `similar_tunes(path, subtune, limit)`. Try them with `cargo run -p phosphor-apple --example fingerprints -- scan|show|similar`.

**Features to compute:** per-voice activity over time; waveform mix %; notes per second; arpeggio
rate (pitch changes per frame on one voice); filter usage (cutoff variance, routing); ring/sync bit
usage; digi detection (high-rate $D418 volume writes); average pulse-width modulation depth.

**Prompt:**
```
Phase 5 from design/visualizers/ROADMAP.md. Extend the Phase 2 pre-scanner into a feature extractor
(features listed in the roadmap), run it as a resumable background job over the HVSC library, and
store results in SQLite keyed by MD5 + subtune. Then add the Sound column, hover card, filter chips
and the "Sounds like" panel from reference/AppFingerprints.dc.html.
```
