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

**Acceptance:** smooth at display refresh rate, under ~3% CPU on Apple Silicon, correct colours per voice, and gate-off and rests look calm rather than jittery.

**Prompt:**
```
Phase 1 from design/visualizers/ROADMAP.md. Using VisualizerFeed from Phase 0, replace the current
bar visualizer in the inspector card with the oscilloscope from reference/Main.dc.html, then add the
mode switcher from reference/AppInspector.dc.html with Lanes and Envelope modes. Port the drawing
logic from the JS in each reference file's data-dc-script block to SwiftUI Canvas + TimelineView.
Use the colours and fonts in IMPLEMENTATION_NOTES.md. Start with the scope only, show me, then add
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

- [ ] Drawer that slides up over the list, toggled from the player bar — `reference/AppDrawer.dc.html`
- [ ] Registers tab (bytes flash on change, CTRL bits decoded) — `reference/Registers.dc.html`
- [ ] Sweeps tab (PW, cutoff + resonance, gates) — `reference/Sweeps.dc.html`
- [ ] Pitch trail tab — `reference/PitchTrail.dc.html`
- [ ] Tracker tab, rebuilt from register writes — `reference/Tracker.dc.html`
- [ ] "Open in window" → separate SID Monitor window

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

- [ ] Full-window view opened from the inspector card's expand button — `reference/AppNowPlaying.dc.html`
- [ ] Per-voice FFT (vDSP) on the sample taps
- [ ] Halo (Metal fragment shader) — `reference/Halo.dc.html`
- [ ] Radial spectrum — `reference/RadialBars.dc.html`
- [ ] Particle sphere (Metal compute + instanced points, 50k+) — `reference/Particles.dc.html`
- [ ] Spectrogram waterfall (texture scroll) — `reference/Spectrogram.dc.html`

**Prompt:**
```
Phase 4 from design/visualizers/ROADMAP.md. Add the Now Playing window from
reference/AppNowPlaying.dc.html. First add a per-voice FFT stage (vDSP) fed by the sample taps.
Then implement the Halo as a Metal view, porting the shape logic from reference/Halo.dc.html,
followed by Radial spectrum, Particles and Spectrogram. Keep one MTKView and switch pipelines per mode.
```

---

## Phase 5 — Fingerprints & discovery

- [ ] Batch scanner over HVSC (reuse the Phase 2 pre-scan) computing a feature vector per subtune
- [ ] Store in SQLite next to the library index (MD5 + subtune)
- [ ] Sound column with mini fingerprint in the list — `reference/AppFingerprints.dc.html`
- [ ] Hover card (fingerprint, waveform mix, tags, Play / Find similar)
- [ ] Filter chips (Arpeggios, Filter sweeps, Noise drums, Ring mod, Sync leads, Digi samples)
- [ ] "Sounds like" panel in the inspector (cosine similarity on the feature vector)

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
