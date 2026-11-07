# resonance

The command line tool for [Resonance](https://useresonance.app). It's a remote
control: the app plays everything, so the window, the terminal and every shortcut
are the same player. If the app isn't running, it starts in the background.

Install it from **Resonance → Settings → Advanced → Install Command Line Tool**.

## The terminal app

`resonance` on its own opens it. Press `?` there for its keys.

## Commands

```text
resonance play [files…]         resonance search commando [--play]
resonance pause | toggle | stop  resonance like [file] [--play]
resonance next | prev            resonance describe fast arpeggios from 1987
resonance surprise               resonance info file.sid
resonance fav [--off]            resonance show file.sid
resonance now
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

## How it talks to the app

One JSON object per line over a Unix socket that only you can reach, at
`~/Library/Application Support/Resonance/control.sock`. The commands are in
`Resonance/Services/ControlCommands.swift`.
