# STIL in the Inspector — Design Decisions

Mockups: `mockups/*.dc.html` (source of the canvas "STIL in the Inspector"; they need the canvas
runtime to render, so treat them as a spec to read, not pages to open). The interactive versions
are on the claude.ai canvas.

| Artboard | What it shows |
|---|---|
| A · Inspector with STIL (Commando) | Full window; quote card, song chips, medley timeline, empty state, unknown title |
| B · Raw STIL → rendered | Freaky DNA essay: hard-wrapped source vs. reflowed, typeset card with Read more |
| C · Entry patterns | Cover + "Remix of" link card, quote with unknown role, in memoriam, teaser rows in the tune list |

---

## Principles

1. **Whose voice is it?** The main thing STIL tells you is whether *the composer* is talking or the
   STIL editors are. First-person quotes get a serif pull-quote with a byline; editorial notes stay
   plain sans text. This one distinction is what makes the panel feel like liner notes.
2. **Turn references into navigation.** Paths, covers and subtune references become things you can
   tap. Resonance is about discovery; STIL is a graph of related tunes hiding in prose.
3. **Follow the playing song.** File-level notes are always shown; subtune notes appear when that song plays.
4. **Never invent.** Don't fill gaps STIL leaves (unlabelled medley gaps, unknown roles, missing
   song lengths). Show "Title unknown" rather than `<?>`, and say nothing rather than guess.
5. **The visualizer stays visible.** STIL lives below the visualizer and folds long text, so the
   inspector doesn't become a reading pane by default.

---

## Inspector layout (top → bottom)

1. Visualizer (existing).
2. Title block: title 26/700, "Released YEAR by PUBLISHER" 15 secondary, **song chips** (`Song 1`, `Song 2`…) when the tune has > 1 song.
3. **Notes card** for file-level blocks: quote and note blocks in STIL order.
4. **Song card** for the current subtune's section: covers, medley timeline, subtune comments.
   No STIL for this song → dashed empty state "No notes for this song yet." (only when *other*
   songs have notes; otherwise show nothing).
5. Details grid (existing).

Inspector width 400 pt, 16 pt side padding, 18 pt gap between cards.

---

## Components

### Quote block ("In their words")
- Card: `cardBg`, radius 14, padding 18, 14 gap.
- Header row: overline "IN THEIR WORDS" (12/600, +0.06em tracking, uppercase, secondary) and a
  tiny monospace "STIL" source tag (11, tertiary) on the right.
- Large opening quote glyph “ (serif 44, `accent`) hanging left of the text; the closing ” is
  appended to the last paragraph's text.
- Body: **serif 17, line height 1.55**, `quoteText`; 12 pt between paragraphs.
- Byline row: 32 pt initials avatar (`avatarBg`/`avatarFg`), name 14/600, and the role line
  "Composer" (12, secondary) **only when `role == .composer`**. If `role == nil`, show the name only.
- Fold: collapsed = first paragraph, clamped to 5 lines. Button "Read more" (or "Read more · N
  paragraphs" when more paragraphs are hidden) → "Show less". Pill button, 32 high, `raisedBg`,
  `accentText`.

### Note block
- Same card, sans 15/1.5 `primary` text, no quote glyph, no byline.
- When a comment has a note followed by a quote, render both blocks in one card: the note first in
  sans, the quote underneath in serif with its byline. They're one STIL comment.

### Runs inside text
- **link**: resolve the HVSC path in the library → "Tune Title ▸" in `accent`, 600 weight; tap opens
  the tune (and subtune). If it can't be resolved, show the file name without `.sid`.
- **em**: italic. **url**: `accent`, opens the browser.
- **tech**: SF Mono at 0.85× size, `techText` colour.

### Cover / version
- Chip "Cover" (`coverChipBg` / `coverChipFg`, 22 high, radius 11, 12/600). In medleys of a game
  original, "Arcade cover" is nicer when `source` starts with "the arcade game".
- Line under it: "Quotes the arcade game *Commando*, music by Tamayo Kawamoto". The source title is in
  italic; the artist is a link to search/library when the artist exists in HVSC.
- Unknown title: "Song 3 · Title unknown" with "Title unknown" in secondary weight 500.

### Remix-of / Same-as link card
When a note *starts* with a relation and a link ("Remix of", "Same as", "Covers", "Inspired by",
"See also", "Edit of"), lift the link into a card: 56 high, play button (36 circle, `selection`), tune title
14/600, composer · category 12 secondary, chevron. Keep the rest of the sentence as text.

### Medley timeline (`isMedley`)
- Header "Song N · Medley" 16/700 + Cover chip; line "Quotes the arcade game *X*, music by Y".
- Bar 28 high, `timelineBg`, radius 6; quoted segments in `coverChipFg`, the active one lighter
  (`coverActive`); 2 pt white playhead. Axis labels in mono 11 tertiary at 0:00 and each minute,
  plus the song length at the end.
- Segment list: rows 34 high: colour dot, title, mono time range. The active row gets `coverChipBg`
  and weight 600. **Tap = seek** to the segment start.
- Needs the song length (HVSC Songlengths.md5). Without it: show the list only, no bar.
- Gaps between quoted segments stay unlabelled.

### In memoriam (`memoriam`)
- Quiet: 1 pt `border` outline, no fill, thin line candle icon, "In memory of NAME" 15/600 and the
  date sentence in secondary. Put it on the **musician page** (folder entry) and at the top of the
  tune's notes. No black banners or crosses.

### Tune list teaser
- Second line under the title (row height 58) with `teaser`, ellipsised. Quote teasers in **serif
  italic** with "— Name"; note teasers in plain sans. Cover/version chip inline after the title.
- Make it a list display option (dense rows without teaser vs. comfortable rows with teaser).

---

## Tokens (dark, from the existing Resonance mockups)

| Token | Hex | Use |
|---|---|---|
| windowBg | `#1c1d20` | window / inspector background |
| sidebarBg | `#232428` | sidebar |
| border | `#2c2d31` | dividers, memoriam outline (`#34353a`) |
| cardBg | `#25272b` | quote/note/song cards, details grid |
| raisedBg | `#2f3136` | pill buttons, link cards |
| controlBg | `#2a2b2f` | search, inactive song chips |
| timelineBg | `#1a1a1d` | medley bar track |
| primary | `#ececf0` | main text |
| quoteText | `#e8e8ec` | serif quote body |
| secondary | `#a3a3ab` | supporting text, overlines |
| tertiary | `#8d8e96` | axis labels, row numbers |
| accent | `#4c9bff` | links, quote glyph |
| accentText | `#7ab4ff` | text on raised buttons, avatar initials |
| selection | `#2f7cf6` | active song chip, play button |
| selectedRow | `#2b3a52` | selected tune row |
| avatarBg | `#3a4656` | initials avatar |
| coverChipBg | `#3a2c1c` | cover chip, active medley row |
| coverChipFg | `#f2a154` | cover chip text, medley segments (= voice 3 orange) |
| coverActive | `#ffc685` | active medley segment |
| techText | `#b9c9e0` | monospace tech tokens |

Voice colours (unchanged): `#5ac8e8`, `#a27cf6`, `#f2a154`.
Contrast (WCAG): secondary on cardBg 6.0:1, tertiary on windowBg 5.2:1 and on cardBg 4.6:1, cover chip 6.4:1, accent on cardBg 5.3:1.
**Fix:** white text on `selection #2f7cf6` (active song chip, 13 pt) is only 3.9:1. Use `#2a6be6` (4.8:1) for selection behind small text.

Light mode isn't designed yet; derive it from the same roles.

## Type

| Role | Mockup (web) | macOS |
|---|---|---|
| UI | SF Pro / Inter | `.system` |
| Quote body, teaser quotes | Source Serif 4 | **New York**: `.system(size: 17, design: .serif)` |
| Tech tokens, timestamps | JetBrains Mono | **SF Mono**: `.system(.body, design: .monospaced)` |

The web mockups use Source Serif 4 and JetBrains Mono only because New York and SF Mono aren't
available on the web. Use the system faces in the app.

---

## Decisions log

| # | Decision | Why |
|---|---|---|
| 1 | Reflow by inverting greedy wrap, not a fixed "join everything" | Keeps the author's real paragraph breaks; no ML or dictionary needed |
| 2 | Serif for quotes, sans for notes | Makes "whose voice" readable at a glance |
| 3 | Show role "Composer" only when confirmed; no "not the composer" label | Initials often belong to the musician's real name while the folder uses a handle; a wrong "not the composer" is worse than no label |
| 4 | Resolve initials via folder entries + PSID author | 81 folders declare initials; the SID header gives real name and handle |
| 5 | Paths become tune links; relations ("Remix of" …) become link cards | 2,409 links in comments; discovery is the app's purpose |
| 6 | Notes follow the playing subtune | 7,129 subtune sections; the info is song-specific |
| 7 | Medley timeline with seek; single timestamp runs to the next one | 769 medleys; it's the most "only-in-Resonance" feature |
| 8 | Don't label medley gaps | STIL doesn't say what's there |
| 9 | Fold long text at 5 lines | Keep the visualizer and details on screen |
| 10 | C64 font only for tiny labels, never body text | Readability; long comments in PETSCII are tiring |
| 11 | memoriam = "passed away" / "R.I.P", not "died" | "died" matches song titles |
| 12 | Curly quotes, em dashes, ellipses; tokens masked during typography | Typeset text without breaking paths/URLs |
| 13 | Parse once, enrich lazily, cache | 3.6 MB file; enrichment is per entry |

## Open questions

- Light mode.
- Musician page: how to present folder-entry text (bio, initials note, in memoriam).
- Search: index `teaser` only, or full comment text? (All comment text is ~1 MB; fine for an in-memory index.)
- Where "Referenced by" back-links go (from the reverse index of `links`).
