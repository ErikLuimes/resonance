# STIL in Resonance — Parsing & Enrichment Spec

This is the contract for turning HVSC's `STIL.txt` into the rich text shown in Resonance's inspector.
The executable version of this spec is `reference/stil_reference.py`; the Swift port is
`apple/Packages/STILKit`. When prose and code disagree, the fixtures in
`apple/Packages/STILKit/Tests/STILKitTests/Fixtures` decide.

Corpus numbers below come from STIL v85 (June 28, 2026), see `corpus-stats.json`.

---

## 0. Pipeline

```
STIL.txt bytes
  → decode (UTF-8, else ISO-8859-1; CRLF → LF)
  → parse      → [path: RawEntry]           sections per subtune, fields with raw lines
  → initials   → [folder: [initials: name]] from folder entries ("/MUSICIANS/P/Paco/")
  → per tune, lazily when shown:
      reflow   → paragraphs
      blocks   → note / quote blocks with bylines
      runs     → styled runs (link, url, em, tech) + typography
      covers   → title / source / timestamps / artist; medley timeline
  → STILEntry (render-ready, Codable)
```

Parse the whole file once and keep the raw index in memory or cache it. Enrich an entry when it's
displayed, or in a background pass if you want teasers in the tune table and full-text search over
notes. (Parsing + enriching all 18,898 entries: ~1 s in Python, ~9 s in a debug Swift build on
Linux, where NSRegularExpression is slow. Measure on macOS before enriching everything eagerly.)

---

## 1. File format (what STIL actually looks like)

```
### /DEMOS/0-9 ######################################      ← divider, ignore (any line starting "#")

/MUSICIANS/H/Hubbard_Rob/Commando.sid                       ← entry: an HVSC path
COMMENT: "There is an interesting story behind Commando. I  ← file-level field (before any (#n))
         went down to their office and started working on   ← continuation: exactly 9 spaces
         …a train home by 10.00 am..." (RH)                 ← quote + attribution (initials)
(#1)                                                        ← subtune section
  TITLE: BGM1 [from the arcade game Commando] (0:00)        ← keys are right-aligned to col 9
 ARTIST: Tamayo Kawamoto
  TITLE: Base [from the arcade game Commando] (0:53)        ← several TITLE/ARTIST pairs = medley
 ARTIST: Tamayo Kawamoto
(#3)
  TITLE: <?> [from the arcade game Commando]                ← <?> = unknown
 ARTIST: Tamayo Kawamoto
                                                            ← blank line ends the entry
/MUSICIANS/P/Paco/                                          ← folder entry (path ends in "/")
COMMENT: Paco's (Ádám Papp) own comments are denoted (AP).
```

- Keys: `NAME`, `AUTHOR`, `TITLE`, `ARTIST`, `COMMENT` (and `BUG` in BUGlist.txt). Regex:
  `^ {0,4}(NAME|AUTHOR|TITLE|ARTIST|COMMENT|BUG): ?(.*)$`.
- Continuation lines start with exactly 9 spaces; text starts at column 9 for both the first and the
  continuation lines. That's why the reflow width test adds a constant `INDENT = 9`.
- 18,898 entries; 248 are folder entries; 2,115 entries have subtune sections (7,129 `(#n)`).
- Folder entries describe a musician or group and belong on the **musician page**, and they
  declare which initials sign that musician's comments (see §4.3).

### Encoding — important

HVSC ships `STIL.txt` as **ISO-8859-1 (Latin-1) with CRLF**. Decode UTF-8 first (some mirrors
re-encode), fall back to Latin-1. The hand-off's fixtures came from a copy that had been through a
lossy conversion (**2,661 characters were U+FFFD**, e.g. `B�la K�ler`); they've since been
regenerated from a pristine HVSC v85 copy (`reference/make_fixtures.py`), so the expected outputs
hold the real accented characters. The Rust core decodes the same way before handing entries over.

---

## 2. Reflow (unwrap)

Comments are hand-wrapped at ~79 columns with no blank lines between paragraphs. We recover the
author's paragraphs by **inverting greedy word-wrap**: at each line break, ask whether the first
word of the next line would have fitted on this line. If it would, the author broke the line on
purpose.

```
break before next line  ⇔  (wouldHaveFit ∧ endsSentence) ∨ structural

wouldHaveFit   = 9 + len(line) + 1 + len(firstWord(next)) ≤ 79 − 3
endsSentence   = last char of line ∈ { . ! ? " ) }          (NOT ':' — "I learned one thing:" continues)
structural     = next matches ^\(?\d{1,2}[.)]\s             (numbered list; 2 digits max so "1990." is not a list)
               ∨ next matches ^[A-Z]{1,3}:\s                (interview: "Q: ", "A: ", "JT: ")
               ∨ (next matches ^[-*•]\s ∧ endsSentence)     (bullet only after a finished sentence;
                                                            otherwise "- " is a dash continuing the text)
join           = "line + ' ' + next", except a word hyphenated across lines
                 (prev ends "-", not " -", next starts lowercase) → no space
```

- `len` counts Unicode scalars (Python `len`), not grapheme clusters or UTF-16.
- Slack 3: STIL is wrapped by many hands; lines run 76–80 wide. On v85 this finds 645 paragraph
  breaks in 573 comments. Random samples of the breaks showed no false ones after ':' was dropped
  as a sentence end (it caused the only false break found: "I learned one thing:").
- Long single paragraphs are left alone (the author wrote them that way). If you want shorter
  chunks for the UI, add a *display* rule (e.g. split > 600 chars at the sentence nearest the
  middle); don't change the model.

---

## 3. Titles, covers and medleys

`TITLE` parses as:

```
^(?<title>.*?)
 (?:\s*\[(?<src>[Ff]rom …)\])?                 "[from the arcade game Commando]"  (11,102)
 (?:\s*\((?<t1>\d{1,2}:\d\d)(?:-(?<t2>\d{1,2}:\d\d))?\))?$     "(0:53)" or "(1:16-1:32)"
```

- `title == "<?>"` → `title: nil, unknown: true` (126 cases). Show **“Title unknown”**.
- `ARTIST: <?>` → `artist: nil`.
- `(1984)`-style years are not timestamps (the timestamp needs a colon); they stay in the title.
- An `ARTIST` attaches to the preceding `TITLE`; an `ARTIST` with no `TITLE` becomes its own cover.
- `NAME` gives the proper name of the tune or subtune when the file name doesn't ("ASM Chronicles:
  Tea for the Seasick"); `AUTHOR` credits the file or a subtune to specific people (per-subtune
  authors in `/GAMES/S-Z/Wastelands.sid`). Both are kept as plain strings per section; show NAME as
  the song title and AUTHOR in the byline/credits.
- Any `TITLE`/`ARTIST` in a tune's STIL means the tune is (partly) a cover/version of something
  else, so it gets the **Cover chip**. The ARTIST is the *original* artist, not the SID composer.
- **Medley** = a section with ≥ 2 timestamped covers (769 sections). Segments: a range is used as
  is; a single timestamp runs **until the next timestamped part starts**, or the song end for the
  last one (`medleySegments`). Gaps between segments are **not labeled**; STIL doesn't say what's
  in them.

---

## 4. Comments → blocks → runs

### 4.1 Blocks

A comment is a list of **blocks**: `note` (STIL editors' voice), `quote` (someone speaking in the
first person) or `question` (an interviewer's question, see Interviews below). 221 comments mix both, e.g. a note ("Won the Big Chip Compo #6.") followed by the
composer's quote.

- A quote block starts with a paragraph that begins with `"` and runs until the paragraph where the
  **running count of `"` is even** and the paragraph ends with `"` or `" (Attribution)`.
- Attribution forms: `" (RH)`, `" (Freaky DNA)`, `" (Comment by Chris Harvey)`, or the attribution
  alone as the next paragraph: `(Comment by game programmer Chris Harvey)`.
- **Inline quotes**: `Demo version of X. "This is a track I wrote…" (AB)` is split at the earliest
  opening `"` that follows sentence punctuation and leaves a balanced quote to the end.
- **Lead-in quotes** (no sentence break before the quote): `Same as /…/Remoteness.sid "Used in the
  game without my permission…" (Geir Tjelta)`, `SW1.8 "Title is a direct reference…" (NP)`. Split at
  the earliest opening `"` whose rest is balanced when the attribution is a **byline** (every word
  capitalized, a digit or a name particle: so not "(German children's song)") and the quote is a
  phrase (≥ 4 words) or follows a short label (≤ 3 words). A quote that opens after such a lead-in
  (≤ 3 words, or ending in a `.sid` path) and closes, signed with a byline, in a **later**
  paragraph is split the same way. ~150 more quotes on v85; short inline quotes inside a sentence
  ("used "for a fee." (GT)") stay notes.
- A lead-in that is only a **tool label** (≤ 3 words, no sentence end, no path: NecroPolo's 138
  "GMC1.6", "SW1.9-EMU", "NT2.03" … trackers) is not a note: it becomes the quote block's `label`
  (absent from the JSON when there is none), so the comment's teaser starts with the quote. The
  app shows it as "Made with LABEL" under the byline.
- The outer quote marks are removed from the text; the UI draws them.
- An unclosed leading quote (`"Remix" of …`) is just a note.
- **Interviews** (3 entries in v85): a paragraph starting `Q: ` is a `question` block (prefix
  dropped). The `A: ` or `XY: ` paragraph right after it is the answer, a `quote` block: when its
  text opens with `"` it is a normal quote (to its closing quote and attribution), else it runs to
  the next `Q: ` paragraph or the comment's end. Initials other than `A` sign an answer that has no
  attribution (`JT: …` → by `JT`). Interview paragraphs are never split as inline quotes.

### 4.2 Bylines and roles

`by` is the display name; `role` is `composer` or `nil`. Resolution order:

1. Initials declared in a folder entry above this tune (§4.3) → declared name. Role is `composer` if
   that name matches the tune's musician.
2. Otherwise match against the tune's musician: aliases from the path (`Hubbard_Rob` → `Rob Hubbard`,
   `RH`, `Rob`, `Hubbard`) and, in the app, the **PSID header author** (`Jeroen Tel (WMC)` → full,
   plain, handle `WMC`, initials `JT`). A match gives `role = composer`, and bare initials are
   replaced by the full name.
3. No match → `by` stays as written, **`role = nil`**.

**Never claim "not the composer".** STIL often signs with the initials of a musician's *real name*
while the folder uses their handle (`/MUSICIANS/P/Phobos/…` signed `(KM)`). Show the role line
only when it's `composer`.

Results on v85: 2,450 quotes have a byline, 1,627 are confirmed as the composer.

### 4.3 Folder-declared initials

81 folder entries declare initials, e.g. `Paco's (Ádám Papp) own comments are denoted (AP).`,
`All comments by David "Ben" Hayes are marked with (BH).` Build `folder → [initials: name]` once; a tune
gets the union of all folders above it (inner folders win). The name is cleaned up: take the text
after the last `". "`, strip a trailing possessive `'`, and if it's one word that appears in the
folder's composer name, use the full name ("Glenn" → "Glenn Gallefoss").

### 4.4 Runs

Each paragraph becomes an array of runs `{t, link?, subtune?, url?, em?, tech?}`:

| Run | Pattern | v85 count | Render |
|---|---|---|---|
| link | `/(?:MUSICIANS\|DEMOS\|GAMES)/\S+?\.sid` | 2,409 | tappable tune name + composer (resolve the path in the library; show the path only if it doesn't resolve) |
| …subtune | after a link: `, Tune #2` / `(subtune #1)` | 645 | open that subtune |
| url | `https?://…` / `www.…` minus trailing punctuation | 19 | link |
| em | `*word*` (≤ 40 chars, not inside words) | 13 | italic |
| tech | `$04b3`, `6581`, `8580`, `6581/8580`, `PAL`, `NTSC`, `PAL/NTSC` | 241 | monospace, slightly tinted |

### 4.5 Typography

Applied to the whole paragraph with tokens **masked** by a private-use placeholder (U+E000), so a
closing quote right after a link is still a closing quote and paths/URLs are never altered:

```
"etc.."        → "etc."
"..." (3+)     → "…"
" - " / " -- " → " — "        "--" → "—"
x'y            → x’y          (it’s)
'  after space/start/( [   → ‘      remaining '  → ’
"  after space/start/( [ — → “      remaining "  → ”
```

### 4.6 Other derived fields

- `memoriam`: `passed away` or `R.I.P` (72). Don't use "died": it matches song titles ("Died In
  Your Arms").
- `teaser`: first sentence of the first block, max 140 chars (cut at a word, then `…`), typeset. For
  the tune-table second line.
- `links`: sorted unique paths, useful for "Referenced by" back-links on the target tune.

---

## 5. Model (Swift: `STILModel.swift`)

```
STILEntry   { path, composer?: {name, initials, aliases}, sections: [STILSection] }
STILSection { subtune?: Int, names, authors, covers: [STILCover], isMedley, comments: [STILComment] }
STILCover   { title?, unknown, source?, at?: sec, until?: sec, artist? }
STILComment { blocks: [STILBlock], memoriam, teaser, links }
STILBlock   { kind: note|quote, by?, role?: composer, paragraphs: [[STILRun]] }
STILRun     { t, link?, subtune?, url?, em?, tech? }
```

Section with `subtune == nil` applies to the whole file: show it regardless of the playing song.
Sections with a subtune are shown for that song only.

---

## 6. Known limits (deliberately not handled)

- Name strings in prose (e.g. "by Drax") are not linked; only paths are.
- Initials that match neither a folder declaration nor the tune's musician stay as initials (`— XY`).
- Tables, ASCII art and track listings are rare; they reflow as prose.
- The mid-paragraph quote split can mis-split when the note itself contains quoted titles with an
  odd quote count. Not seen in sampling, but watch for it.
