## Working rules

- Commit only when asked. Erik does all pushing, tagging, releasing and PR merging; `.claude/settings.json` blocks agents from these, along with `publish.sh`, `release.sh` and edits to `appcast.xml`.
- Work on `main` in the main checkout unless asked otherwise. A session running alongside another one gets its own worktree, so they don't overwrite each other.
- Before calling a change done, run `apple/scripts/check.sh` (`--rust` for Rust-only changes). Report failures as they are.
- New work goes in `apple/`. Don't change the upstream Phosphor files, such as `src/` and the root `Cargo.toml`.
- New screens start with a mockup, and Erik click-tests them; say what hasn't been click-tested. Keep the toolbar static and don't use `HSplitView`: both have caused SwiftUI layout-loop crashes.
- Measure or derive sync and timing values. Don't ask Erik to tune them by ear.
- Visualizers are additive: add new ones as pages of the card, never replace or delete one.
- Don't recolour or resize the terminal app's ASCII logo without asking.
- Each release gets notes at `apple/release-notes/<version>.md`.
- Marketing material stays out of this public repo.

## Design docs

Visualizer design reference and roadmap: design/visualizers/ (start with ROADMAP.md).

STIL notes (parser spec, design, reference implementation): design/stil/ (start with README.md); the Swift parser is apple/Packages/STILKit.

Sounds Like's method and benchmark: design/similarity/README.md; change it only against apple/scripts/similarity-bench.

Scrubbing (seek) research and plan: design/scrubbing/README.md; the measurements come from apple/residfp-sys/examples/seek_bench.rs.

Learned song lengths (tunes outside HVSC): design/songlengths/README.md; change the detection only against apple/core/examples/songlength_bench.rs.

Smart playlists' reasoning and checks: design/smart-playlists/README.md; change the choosing only against apple/core/examples/smart_bench.rs.

Amiga mods (the 2.0 plan): design/mods/README.md.

Credits page, in the app and the terminal app: design/credits/README.md, with the approved mockups beside it.

Feature flags (what's in which build): design/feature-flags/README.md. Update channels never decide this.
