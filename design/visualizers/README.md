# Resonance — visualizer handoff

Design reference for adding SID voice visualizers to Resonance, built iteratively with Claude Code.

## What's in here

| Path | What it is |
|---|---|
| `ROADMAP.md` | Phased plan. Each phase has a goal, the data it needs, acceptance criteria, the reference mockup, and a prompt to paste into Claude Code. |
| `IMPLEMENTATION_NOTES.md` | How the mockup concepts map to Swift/macOS (SwiftUI Canvas, Metal, vDSP), the shared data model, colours and fonts. |
| `reference/*.dc.html` | Source of every mockup from the design canvas. **Reference only**: they need the canvas runtime to render, but the JS in each `<script data-dc-script>` block holds the drawing maths (waveform shapes, envelope curves, ripples, spectrum mapping) you can port. |

The live canvas (all artboards, animated) stays here:
https://claude.ai/artifact/DL8ku3K4EKLA6CmM6oKu8y

### Reference files

| File | Concept |
|---|---|
| `Main.dc.html` | 1 · Oscilloscope (per voice) |
| `PitchTrail.dc.html` | 2 · Pitch trail |
| `Envelope.dc.html` | 3 · Envelope (ADSR) |
| `Lanes.dc.html` | 4 · Compact lanes (scope, note, keyboard, LED meter) |
| `Halo.dc.html` | 5 · Halo (glowing harmonic rings) |
| `Particles.dc.html` | 6 · Particle sphere |
| `Tracker.dc.html` | 7 · Tracker view |
| `RadialBars.dc.html` | 8 · Radial spectrum |
| `Registers.dc.html` | 9 · Register view ($D400–$D41C) |
| `Sweeps.dc.html` | 10 · Pulse width, filter & gate sweeps |
| `Spectrogram.dc.html` | 11 · Spectrogram waterfall |
| `AppInspector.dc.html` | A · Inspector card with mode switcher + overview strip in player bar |
| `AppNowPlaying.dc.html` | B · Now Playing full window |
| `AppDrawer.dc.html` | C · Under the hood drawer |
| `AppFingerprints.dc.html` | D · Tune fingerprints & "Sounds like" |

## How to use it with Claude Code

1. Copy this folder into the repo, e.g. `design/visualizers/`.
2. Add one line to the repo's `CLAUDE.md` so every session knows it exists:
   ```
   Visualizer design reference and roadmap: design/visualizers/ (start with ROADMAP.md).
   ```
3. Work phase by phase. Start a Claude Code session, paste the phase's prompt from `ROADMAP.md`, and let it plan before it edits (plan mode works well here).
4. After each phase, tick it off in `ROADMAP.md` and commit. That way the next session knows where you are.

Phase 0, the data foundation, matters most: every visualizer reads from it. Get it right once and the rest are mostly drawing code.
