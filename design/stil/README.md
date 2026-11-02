# Resonance · STIL in the Inspector

How Resonance shows HVSC's STIL notes: the parsing/reflow algorithm, the enrichment rules, the
inspector design, and the code that implements them. Started from a hand-off package; this
folder keeps its spec and reference, the Swift package lives with the app.

```
design/stil/
  README.md            ← you are here
  SPEC.md              ← parsing, reflow, blocks/bylines, runs, typography, model (the contract)
  DESIGN.md            ← inspector layout, components, tokens, type, decisions log, open questions
  corpus-stats.json    ← counts from STIL v85 (what each feature affects)
  reference/
    stil_reference.py  ← executable spec (Python 3, stdlib only). Tested on all of STIL v85.
    make_fixtures.py   ← cuts fixtures out of a real STIL.txt and writes/checks golden output
    compare_dump.py    ← whole-corpus Swift ↔ Python parity check (with ParityTests.swift)
  mockups/             ← source of the three design artboards (.dc.html)
apple/Packages/STILKit/  ← Swift package (models, parser, reflow, enricher) and its tests;
                           the 15 fixtures are in Tests/STILKitTests/Fixtures
```

## In the app

- The Rust core (`apple/core/src/databases.rs`, `StilText`) keeps STIL.txt's entries as written,
  next to Phosphor's own STIL database. `PlayerCore.hvscStil(path:)` hands over a tune's or
  folder's entry, after the entries of the folders it's in (they declare whose initials sign
  comments).
- `LibraryStore.loadStil(path:sidAuthor:)` parses that with STILKit and enriches it, passing the
  PSID header author. The inspector loads the playing tune's; the composer card loads its folder's.
- `Views/StilNotesView.swift` draws the cards: the file's notes, then the playing song's, with
  covers, medley timeline, quotes with bylines, and tune links that reveal the tune in the library.

Built so far: quote/note cards with fold, per-song card (and its empty state), link runs, the
"Remix of" link card, cover chip, medley timeline, in memoriam card. Not yet: song chips in the
title block, seeking from medley rows (needs seeking in the player), the teaser line in the tune
list.

## Status

| Part | State |
|---|---|
| Python reference | Runs on the full STIL v85 (18,898 entries, ~1 s); all 15 fixtures pass |
| Swift `STILKit` | Builds on macOS and in Xcode. All fixture tests pass, and its output is **identical to the Python reference for all 18,898 entries** of STIL v85 (about 1 s to parse and enrich everything in a release build) |
| Fixtures | Generated from a pristine STIL v85 (Latin-1), so accented names are intact |
| Design | Dark mode artboards; the app derives light mode from system colours |

## Regenerate the fixtures

```sh
cd design/stil/reference
python3 make_fixtures.py /path/to/HVSC/DOCUMENTS/STIL.txt ../../../apple/Packages/STILKit/Tests/STILKitTests/Fixtures
python3 make_fixtures.py --check ../../../apple/Packages/STILKit/Tests/STILKitTests/Fixtures
python3 stil_reference.py /path/to/HVSC/DOCUMENTS/STIL.txt --stats > ../corpus-stats.json
```

Inspect one entry: `python3 stil_reference.py STIL.txt --entry /MUSICIANS/H/Hubbard_Rob/Commando.sid`

## Tests

```sh
cd apple/Packages/STILKit
swift test                                              # 15 golden fixtures + unit tests
STIL_TXT=/path/STIL.txt swift test                      # + whole-file smoke test
STIL_TXT=/path/STIL.txt DUMP_OUT=/tmp/all.json swift test -c release --filter ParityTests
python3 ../../../design/stil/reference/compare_dump.py /path/STIL.txt /tmp/all.json   # expect "0 differ"
```

The Python reference is the source of truth: if the Swift output differs, fix the Swift. Don't
change the expected JSON unless the Python reference changes too.

## Where the numbers come from

All counts (comments, quotes, links, medleys…) are from STIL v85 via `stil_reference.py --stats`.
An earlier estimate of "about 21,000 cross-references" counted entry header paths too; the real
number of links inside comments is **2,409** (645 of them name a subtune).
