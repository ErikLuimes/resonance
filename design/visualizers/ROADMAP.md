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
