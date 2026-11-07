# Resonance for Raycast

Search, play and discover Commodore 64 SID music in
[Resonance](https://useresonance.app) from Raycast. Resonance has to be installed; if
it isn't running, it starts in the background.

| Command | What it does |
|---|---|
| Search Tunes | Find tunes by title or composer, and see how each one sounds |
| Sounds Like This | Tunes that sound like the one playing |
| Describe Sound | A list from words, such as "fast arpeggios from 1987" |
| Now Playing | The tune playing and how it sounds, with its controls |
| Playlists | Open and play Favourites and your playlists |
| Recently Played | Go back to a tune you played |
| Play or Pause, Next Tune, Previous Tune | Control playback without opening a window |
| Surprise Me | Play something from the collection you may not know |
| Favourite Tune | Add the tune playing to Favourites, or take it out |

Give the ones you use most a hotkey or an alias in Raycast's settings. Search Tunes and
Describe Sound take what you type after their alias, as in `rs commando`.

## In a list of tunes

`Return` plays from that tune on. `⌘L` shows what sounds like it, `⌘D` shows or hides
how it sounds, and `⌘K` has the rest: Sound Drift, Add to Playlist, Show in Resonance.

With the sound pane closed, each row shows the tune's fingerprint: nine bars, always in
the same order, so tunes that sound alike look alike down the list. They are notes,
arpeggios, vibrato, filter, ring modulation, hard sync, digi samples, noise and pulse
width.

## How it talks to the app

It uses the same socket as the `resonance` command line tool (see
[../cli/README.md](../cli/README.md)), so the command line tool doesn't need to be
installed.

## Working on it

```sh
npm install
npm run dev     # Loads it into Raycast, reloading on changes
npm test        # The socket client and formatting, against a stand-in for the app
npm run lint
npm run build
```
