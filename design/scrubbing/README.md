# Scrubbing

Research, 2026-11-05: which engine can seek, how, and what it costs. The
numbers come from `apple/residfp-sys/examples/seek_bench.rs`:

    cd apple
    cargo run --release -p residfp-sys --example seek_bench -- <secs> <tune>...
    cargo run --release -p residfp-sys --example seek_bench -- survey <secs> <count> <hvsc>/MUSICIANS

## The engines

Resonance plays through four engines in two players.

| Engine | Player | Seekable |
| --- | --- | --- |
| reSIDfp (default) | `apple/core/src/residfp_player`: libsidplayfp's C64 with libresidfp, pulled by the audio callback through `apple/residfp-sys` | yes, from Resonance's own code |
| SIDLite direct | the same player with libsidplayfp's SIDLite chip | yes, the same way |
| SIDLite | upstream Phosphor's player thread (`src/player/mod.rs`), frame-paced, its own 6502 | no: the loop has no seek command, and upstream files stay untouched |
| reSID | the same upstream thread with resid-rs | no |

So scrubbing goes into the pull-driven player and covers reSIDfp and
SIDLite direct. On the two upstream engines the bar stays read-only,
saying that scrubbing needs one of the other two.

## How a seek works

libsidplayfp has no state save or restore, so reaching a point means
running the emulation there without producing audio: from the current
position for a forward seek, from the start for a backward one. The C64
must run cycle-exact either way; the question is how to clock the chips
meanwhile. `rsfp_skip` offers three ways:

- **Render**: as when playing, the audio dropped.
- **Digital**: libresidfp's `clockDigital`, the oscillators and envelopes
  without the filter and resampler. SIDLite has no such mode and renders.
- **None**: the C64 alone; the chips take the register writes but aren't
  clocked.

Processor time per second of tune, release build, Apple silicon
(Commando by Rob Hubbard, 6581; 1983 Sauna Tango by Laxity, 8580; Antipop
by Jammer, 2SID):

| ms per second of tune | reSIDfp, 1 chip | reSIDfp, 2SID | SIDLite |
| --- | --- | --- | --- |
| playing | 27–28 | 43 | 6.5–7.5 |
| skip, Render | 25–27 | 43 | 6.2–7.4 |
| skip, Digital | 16 | 24 | 6.2–7.4 |
| skip, None | 5.2–5.6 | 5.4 | 5.4 |

The C64 alone costs about 5.5 ms per second; reSIDfp's chip about 21 ms,
of which 10 ms are the digital parts and 11 ms the filter and resampler.
(libsidplayfp's `play(n)` runs n scheduler events, fewer than n cycles;
`rsfp_skip` goes by the chips' cycle counter, so these are per real second
of tune.)

What a wait looks like with the Digital skip: 16 ms per second of tune on
reSIDfp with one chip, so reaching the end of the median HVSC subtune
(93 s) takes about 1.5 s, the 90th-percentile one (233 s) about 3.7 s; a
2SID tune one and a half times that; SIDLite direct about 0.6 s and 1.5 s.
A forward seek from the live instance only runs the distance: 10 s ahead
is about 0.16 s.

## What was checked

**Determinism.** libsidplayfp waits a random 0–8191 cycles (seeded from
the clock) between power-on and the tune's init, so two instances of a tune
drift apart by up to 8 ms, with everything after that shifted. The shim now
takes a fixed delay (`rsfp_config.power_on_delay`) and reports the one used
(`rsfp_play_info.power_on_delay`). With the same delay, two full skips end
in identical chip state and identical audio.

**The Digital skip is exact.** On 59 random HVSC tunes (30 s in) plus the
three above, the chip state after a Digital skip (registers, envelope
counters, OSC3, ENV3) was identical to the state after a full one in every
case. The audio afterward differs only while the filter and resampler
settle: the loudness envelope (RMS per 10 ms) deviated by 5 % median and
24 % at the 90th percentile in the first half second, 0.2 % median and
0.5 % at most after 1.5 s (the worst first half second, 490 %, is a tune
that is nearly silent there). Rendering the last half second before the
target instead of skipping it digitally removes the transient for 13 ms
of work.

**The hybrid (None, then Digital for the last stretch) is not exact.** It
would cut the cost to the C64's 5.5 ms per second, but with a 3 s digital
window the envelopes still differed in 13 of 59 tunes, and with 12 s still
in 13; loudness deviations of 7 % median persisted (long envelopes, and
the beat phase of detuned voices). Rejected for the reference engine;
worth revisiting only if the waits prove too long.

## Implementation (2026-11-05)

- `apple/residfp-sys`: `rsfp_skip` / `Player::skip` (which also clear the
  scope and write logs), `power_on_delay` in `Config` and `Started`.
- The pull-driven player (`apple/core/src/residfp_player/mod.rs`) has a
  `Seeker` beside upstream's `PlayerCmd` channel: a target position and a
  `seeking` flag. A seek silences the audio and sets elapsed time to the
  target at once; a worker thread runs the emulation there (digitally,
  the last half second in full) and the control thread swaps the engine in
  with a new report id, so nothing from before the seek shows. Forward,
  the callback hands the playing engine back (`ToAudio::Return`) and it
  runs on from where it was; backward, a fresh instance with the track's
  power-on delay starts from the top. A seek asked for while one runs
  starts when it lands; a track change or stop drops the result. Seeking
  while paused lands paused.
- The driver (`apple/core/src/driver.rs`): `Command::Seek`, clamped a
  second short of the song's length so the last second plays before the
  session advances; `can_seek` and `seeking` in the published view; the
  silence clock is held while a seek runs. `PlayerCore.seek(position_ms)`
  in the FFI, with `can_seek` and `seeking` in the snapshot.
- The app: `ScrubBar` (Views/ScrubBar.swift) in the player bar, Now
  Playing and the menu bar player, with the time under the pointer while
  dragging; on the two upstream engines a click explains. Control
  Center's position slider and 15-second skips work on the seekable
  engines.
- The wait ("catching up", chosen over a sheen on 2026-11-05): the fill at
  the target goes faint and a solid fill races up to it from where the run
  started (the top for a backward seek), while the elapsed clock counts up
  with it. The racing fill is the emulation's real position: the worker
  stores it every tenth of a second of tune (`Seeker::position_ms`), the
  snapshot carries it as `seek_position_ms` while seeking, and the bar
  animates between polls. No spinner.

Not done: keyboard shortcuts for skipping within a tune.
