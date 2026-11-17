# The terminal app's page

A page for the `resonance` command and its terminal app, at `useresonance.app/terminal`.
Written and built 2026-11-15.

- [mockup.html](mockup.html): the page. Serve the repo root (launch config `site-mockups`,
  port 8644) and open `/design/site-cli/mockup.html`. It loads the real site's `styles.css`
  and icons through `<base>`, so it looks like the live site.
- The real page is `apple/site/terminal/index.html`, with its styles in
  `apple/site/terminal.css`, its script in `apple/site/js/terminal.js` and its tunes in
  `apple/site/js/terminal-data.js`. Change the page there; the mockup stays as it was approved.
- [make-data.py](make-data.py) makes the tunes file from the running app. To refresh the
  site's:

```bash
python3 design/site-cli/make-data.py apple/site/js/terminal-data.js
```

  [data.js](data.js) is the mockup's copy. Both are left out of `apple/scripts/us-english.sh`,
  as tunes keep their own titles.

The home page links to it from its footer and from the Integrations section's terminal tab.
The share server sends `/terminal` to it with a 307, as it does `/remote`
(`the_terminal_app_goes_to_its_page_on_the_website`); that needs a deploy of the share server.

## The idea

The Remote's page shows recordings. This one lets you use the thing: the hero is the terminal
app, drawn in HTML and working. It moves, plays, finds similar tunes, scrubs and searches, and
makes no sound. The rest of the page explains what you just used: fingerprints, the visuals,
the commands, the three sets of keys.

## The terminal on the page

It's drawn from the app's own look (screenshots of 2026-11-15) and colors
(`apple/cli/src/palette.rs`), sized in `ch` and `em` with the font following the window's
width, so the grid of characters scales as one. Like the app, it drops the panel in a narrow
window and then the sidebar.

What works, with the app's own keys (`help_lines` and `key_scrub` in `apple/cli/src/tui.rs`):

| Keys | What it does |
| --- | --- |
| `↑ ↓`, `j k`, `⌃N ⌃P` (Emacs), `Home End`, `G` (Vim) | Move |
| `↵`, or a double click | Play from here |
| `p`, `.`, `,`, `r` | Pause, next, previous, Surprise Me |
| `l` (`L` in Vim) | Find similar: the list, with the tune compared over the column. `esc` goes back |
| `t` | Scrub: `← →` 5 s, with `⇧` 30 s, `0`–`9` to that tenth, `Home End`, `↵` goes there, `esc` or `t` cancels. Vim uses `h l`, Emacs `⌃B ⌃F`. The bar fills gray to the point chosen while the playhead catches up |
| `/` | Search, over the tunes the page knows |
| `f`, `i` | Favorite, hide or show the panel |
| `?` | All keys, as the app shows them, for the set chosen. Any key closes it |
| `v` | Scrolls to the Visuals section |
| `q` | Says there's nothing to quit |

The progress bar is the app's own (`progress` in `apple/cli/src/viz.rs`): one character to a
cell, ▰ in the accent for what's played, a white ● for the head and ▱ for what's left, with
the glint two cells wide that runs along the played part, a cell every 50 ms while it plays.

The key set follows the Keys section's Normal, Vim and Emacs control. The accent follows the
swatches under the terminal, which are macOS's eight (`accent_numbered` in `palette.rs`), and
it only colors what the app colors: ❯, ● and the played part of the bar.

Left to the real thing: marking, playlists (`a`, `n`, `x`, moving tunes), Sound Drift, `gg`
and `dd`, the sidebar, Under the hood and the credits.

## The data is real

`make-data.py` asks the app, over its control socket, for the Favorites playlist, each tune's
fingerprint (`prints`, with the waveform mix and each voice's loudness), its sentence (`sound`)
and the tunes that sound like it (`like`). On 2026-11-15 that gave 807 tunes and 247 lists,
158 KB. No file paths go in. One favorite outside HVSC is left out, so the footer's line about
HVSC holds.

Find similar goes one hop: from a favorite to its 18 closest. A second hop says "That's as far
as this page goes", since every hop would need another 18 lists.

## Open

- **The visualizers' recording.** The Visuals section has a slot for it. Erik's screen
  recordings of 2026-11-15 (the visualizers, and scrubbing) were in a temporary folder that
  was gone or unreadable by the time they were read, so they aren't in the page, which says "Recording coming soon" there. Save them to
  `~/Documents/Resonance/site-recordings/terminal/` and convert them with
  `apple/scripts/site-videos.sh`, uncut.
- **Not click-tested by Erik.** Checked in the browser pane at 1280 and 375 wide: moving,
  Find similar, play, scrubbing with a digit and `↵`, the all-keys overlay, the Vim set, and
  each section. Not checked: Safari, Firefox, a real phone, Emacs chords, search.
- The home page's terminal screenshots (`integration-terminal-*.webp`) are from before the
  alpha.11 look and want replacing either way.
