# Feature flags

How a feature stays out of builds it isn't ready for. Adopted 2026-11-08.

## Tiers

| Tier | Your Mac | Debug from source | Alpha | Beta, final |
| --- | --- | --- | --- | --- |
| Restricted | Yes, if your local file sets it | No | No | No |
| Experimental | Yes | Yes | Yes | No |
| Shipped: the flag is gone | Yes | Yes | Yes | Yes |

**Restricted** is for what needs someone's permission. Anyone can download an
alpha, so an alpha counts as being in the wild. CSDb is here until its admins agree.

**Experimental** is for unfinished work that testers should try.

Update channels don't change any of this. A channel chooses who gets a build, and
a flag chooses what's in it. Never ship a feature by putting it on a channel.

## Why compile time

Excluded code isn't in the build at all, with `#if` on the flag. A hidden setting
would still ship the code and its URLs, and anyone can change a preference from a
terminal. It costs a build per state, so tests run in each state that ships.

There are no remote flags. A server deciding what's on would contradict what
Settings promises: nothing about your Mac is sent.

## How the build decides

- **Release builds:** `scripts/release.sh` passes
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS` itself, from `RELEASE_STAGE`, through
  `scripts/feature-flags.sh conditions`. `alpha.*` gets `ALPHA`, and anything else
  gets nothing. A local file can't add to it.
- **Debug builds:** the project sets `DEBUG ALPHA`. Restricted flags come only from
  the gitignored `Config/Signing.local.xcconfig`.
- **The check:** after archiving, `feature-flags.sh check` searches every file in
  the app for the markers of whatever that stage must not contain, and stops the
  release. Markers are strings, so a stage can pass with a feature's code present
  if none of its markers appear in the build. Pick markers the feature can't work
  without, such as its server's address, and keep the `#if` as the real boundary.

## Add a flag

1. Add a case to `Feature` in `apple/Resonance/Model/FeatureFlags.swift`, with its
   tier, title and what would let the flag go.
2. Add its line to `apple/scripts/feature-markers.tsv`. A restricted feature must
   have a marker. `apple/scripts/check.sh` fails if the two lists disagree.
3. Guard with `#if ALPHA`, or the feature's own flag if it's restricted. Guard the
   places a feature is entered, like a page, menu item or setting, not all through
   its code. CSDb touches 18 files, which is the cost to keep down.

A new restricted flag also goes in your local file, with a line in
`Config/Signing-Debug.xcconfig` saying how.

## Move or remove a flag

- **Restricted to experimental:** once permission is in hand, swap its `#if` for
  `#if ALPHA`, then change its tier in both lists.
- **Experimental to shipped:** delete the `#if`s, the case and the marker line.

## Live toggles (not built)

Experimental features get a live toggle in an Experiments section of Settings,
which exists only under `#if ALPHA`. It's built with the first experiment, mocked
up first. The plan:

- Default on, so experiments get tested. Anything that contacts a new third party
  defaults to off.
- Each toggle says if it needs a restart.

## Things to watch

- **Saved data:** someone can move from Alpha to Stable. A build without a feature
  must cope with what that feature saved, such as an unknown playlist field.
- **Alpha isn't beta:** a feature that worked behind a flag can behave differently
  once it's always on. Test it again in the first beta that has it.
- **Flags piling up:** `shipsWhen` says what ends each flag. Remove it when that
  happens.

The Rust core has no flags, so everything here is Swift. A feature in the core
would need a Cargo feature passed by `scripts/build-core.sh` too.
