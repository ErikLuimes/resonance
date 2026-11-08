# resonance

The command line tool for [Resonance](https://useresonance.app). It's a remote
control: the app plays everything, so the window, the terminal and every shortcut
are the same player. If the app isn't running, it starts in the background.

Install it from **Resonance → Settings → Integrations → Command Line Tool**.

## The terminal app

`resonance` on its own opens it. Press `?` there for its keys.

The header and columns scale with the window: at least 120 columns by 38 rows shows the
large header, and it keeps growing in bigger windows, leaving the player over a third. From 110 columns, a panel beside the list says how the tune under the cursor
sounds and what it sounds like.

### Fingerprints

Every tune has a barcode of nine bars, always in the same order, so tunes that sound
alike look alike down a list:

```text
Nt Ar Vb Fl Rm Sy Dg Nz Pw
notes, arpeggios, vibrato, filter, ring modulation, hard sync, digi samples, noise, pulse width
```

The list shows it small. The panel shows it large, with a bar of the waveforms the tune
uses and, when there's room, each voice's loudness from start to end. In Sounds
Like, the tune being compared sits over the column, so you can see why each one matched.
`?` explains the bars. A row of dots means no fingerprint yet.

Press `v` for the music, full screen, set out like Now Playing in the app: the views to
pick from at the top, the music in the middle with room around it, then the tune, its
voices and the time. The picker and the keys go after three seconds without a key press.
`s` shows the skull, a 3D model in ASCII whose eyes
glow with the voices and whose jaw chomps on the hits. `f` shows fire, where each voice
feeds its own part of the flames and hits throw sparks; `c` colors each flame by its
voice, to see which is which. `t` shows Tesla coils, where each voice's pitch sets how
high its lightning strikes and hits fire across all three. `w` shows a pool, where each
new note drops in, low notes making wide ripples and high notes tight ones; `c` colors
those by voice too. `o` shows the app's Particle sphere. `v` steps through them.

All of this looks best on a terminal with millions of colors, such as iTerm2, Ghostty
or Kitty. Notes are worked out from the voices' sound, so they can be off on a very low
note or a filtered one.

### Under the hood

`u` slides up a tracker over the list. It shows what the player writes to the chip, with the
row being heard in the middle and what's coming below it: notes, instruments, arpeggios, slides
and vibrato, and the filter. A `.sid` file holds code rather than patterns, so all of this is
rebuilt by running the tune once, which takes a second or two. Some tunes have no steady beat,
and it says so. `↑ ↓` looks around, `f` follows the music again, and `esc` closes it.

`tab` steps on to Registers, where bytes light up as the player writes them; Sweeps, with pulse
width, the filter and gates over the last few seconds; and Pitch, where each voice has been. These
three show every SID of a tune with more than one where there's room. The tracker, and these three
in a small terminal, show one at a time: `s` steps through them, or `1`, `2` and `3` go straight to
one.

### Describe

The Describe row in the sidebar makes a Smart Playlist from a sentence, or from New to Me,
Never Heard, Similar to a Tune and Slow to Intense. It says what it understood, and what it
can't tell. `↵` plays from a tune, `/` changes the sentence, `n` saves the list as a playlist,
and `esc` starts over. It reads sentences just as the app does, and the app's Smart Playlist
pane follows along.

### The collection

The sidebar has HVSC under your library. Home has the release, what's new in it, the curated
playlists and the tunes you played last; `S` shuffles the whole collection and `T` plays the
Top 100. Musicians, Demos and Games list the folders with how each sounds on average: `/` finds
one as you type, `↵` opens its tunes and `esc` comes back to the same row. Downloading the
collection happens in the app.

### Vim and Emacs keys

The terminal app answers to one of three sets of keys. To choose, use `--keys`, or set
it for good in your shell:

```sh
export RESONANCE_KEYS=vim    # or emacs, or normal
```

Without either, it goes by `$VISUAL`, then `$EDITOR`: Vim and Neovim mean Vim keys, and
Emacs means Emacs keys. Anything else gets Emacs keys, as macOS's own text fields and
shells have them. The tool can't see a shell's `bindkey -v`, as zsh keeps that to itself.
The window's own set, in Settings, is separate. `?` shows the keys in use and why.

| | Normal | Vim | Emacs |
|---|---|---|---|
| Move | `↑ ↓` `j k` | `j k` | `⌃N ⌃P` |
| Page up, down | `PgUp PgDn` | `⌃U ⌃D` `⌃B ⌃F` | `⌥V ⌃V` |
| Top, end | `Home End` | `gg G` | `⌥< ⌥>` |
| Sidebar, list | `← →` | `h l` | `⌃B ⌃F` |
| Search | `/` | `/` | `/` `⌃S` |
| Take out of a playlist | `x` | `x` `dd` | `x` `⌃D` |
| Sounds Like | `l` | `L` | `l` |
| Sound Drift | `d` | `D` | `d` |

The other keys are the same in all three. `⌥` needs your terminal to send Option as
Meta, which Terminal has as a setting under its Keyboard profile; `Home`, `End` and the
page keys work regardless. While typing, letters are letters in every set, `⌃U` clears
the line, `⌃W` takes a word and `⌃G` cancels. In `resonance pick`, `⌃N` and `⌃P` move
too.

### Credits

Press `c`, or run `resonance credits`, for the credits, with a nod to the demoscene. If nothing
is playing they start your Favorites, or Surprise Me if that can't play, and they name the tune
playing. They close by themselves, or with `esc`.

## Commands

```text
resonance play [files…]         resonance search commando [--play]
resonance pause | toggle | stop  resonance like [file] [--play]
resonance next | prev            resonance describe fast arpeggios from 1987
resonance surprise               resonance info file.sid
resonance fav [--off]            resonance show file.sid
resonance now                    resonance drift [file]
resonance guess [--practice]     resonance recent [--limit N]
resonance credits
```

```text
resonance playlist list | show NAME | play NAME
resonance playlist new NAME [files…] | rename NAME TO | delete NAME
resonance playlist add NAME [files…] | rm NAME [files…] | mv NAME FILE [--before FILE]
```

`resonance pick [--multi] [--playlist NAME] [search]` opens a small list to choose
from and prints the paths, for use inside other commands:

```sh
resonance playlist add "Late Night" $(resonance pick --multi)
```

Piped, lists print tab-separated with the path first. Anything that answers takes
`--json`. `playlist add`, `new` and `rm` read paths from a pipe:

```sh
resonance search hubbard | resonance playlist add Hubbard
```

## zsh and Oh My Zsh

[zsh/resonance.plugin.zsh](zsh/resonance.plugin.zsh) adds completions (playlist
names too), short commands (`rn`, `rp`, `rs`, `rl`, `rf`, `rq`), `rdone make
release` for a surprise when something slow ends, and `resonance_prompt_info` for
your prompt.

## Claude and other assistants

`resonance mcp` is a [Model Context Protocol](https://modelcontextprotocol.io)
server, so an assistant can search, play, make playlists and start a drift. Then
you can ask for "something like Commando but darker". It can add to playlists and
take tunes out of them, but it can't delete a playlist.

```sh
claude mcp add resonance -- resonance mcp
```

## Licenses

`resonance --licenses` prints the licenses of the open-source software in Resonance and
this tool, the same text as Acknowledgments in About Resonance.

## How it talks to the app

One JSON object per line over a Unix socket that only you can reach, in the
sandboxed app's folder:
`~/Library/Containers/app.useresonance.resonance/Data/control.sock`
(builds before alpha.6 used `~/Library/Application Support/Resonance`, which
the tool still tries). The commands are in
`Resonance/Services/ControlCommands.swift`.
