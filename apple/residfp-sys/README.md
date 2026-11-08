# residfp-sys

libsidplayfp with its reSIDfp chip emulation (libresidfp) and its own
SIDLite chip, built from vendored sources behind a small C shim, for
Resonance's **reSIDfp** and **SIDLite direct** engines.
Unlike `sidplayfp-sys` (which runs libsidplayfp's C64 only to capture SID
register writes, for the fingerprint scan), this crate produces audio: the
player renders stereo samples on demand, so Resonance's audio output
callback drives the emulation directly.

## What's vendored

| Library | Version | License | Where |
| --- | --- | --- | --- |
| [libsidplayfp](https://github.com/libsidplayfp/libsidplayfp) | **3.1.2** (release tarball) | GPL-2.0-or-later | `csrc/libsidplayfp/` |
| [libresidfp](https://github.com/libsidplayfp/libresidfp) | **1.2.3** (release tarball) | GPL-2.0-or-later | `csrc/libresidfp/` |

From libsidplayfp: the player, the sidtune loaders (PSID/RSID, MUS+STR,
PRG, P00), the C64 (MOS 6510, CIAs, VIC-II, banks), the residfp builder,
the SIDLite chip (`builders/sidlite-builder/sidlite`, cRSID-based; its own
emu and builder are kept for reference but not compiled) and the
header-only hashlib MD5. Left out: the USBSID and exSID builders,
STILview, SidDatabase and the test suites. From libresidfp:
everything but its tests. Both `COPYING` files are kept next to the sources;
the crate's `LICENSE` is the same GPL-2.0-or-later.

Three small local changes, each marked `Resonance:` in the source, all
read-only accessors so the shim can read each voice's envelope counter and
waveform output for the visualizers: `csrc/libresidfp/SID.h` gains
`voiceRef(i)`; SIDLite's `SID.h` gains `envelopes()` and `waveforms()`, and
its `WavGen.h` `voiceOutput(i)`. Everything else is byte-for-byte upstream.

Symbols are renamed at compile time (`build.rs`): the `libsidplayfp` and
`reSIDfp` namespaces and the classes libsidplayfp declares at global scope
(`sidplayfp`, `SidTune`, `SidConfig`, …) get an `rsfp_`/`Rsfp` prefix via
`-D`. `sidplayfp-sys` compiles its own libsidplayfp 3.0.0 into the same
binary; without the renaming the linker would mix object files from the two
versions.

## The shim (`shim.h`)

- `rsfp_new` / `rsfp_free`, `rsfp_set_roms` (kernal, basic, chargen; each
  optional, libsidplayfp's stubs otherwise).
- `rsfp_load_bytes` / `rsfp_load_path` (by path, a MUS file's companion
  `.str` is picked up as libsidplayfp does); `rsfp_tune_info`,
  `rsfp_info_string`, `rsfp_comment_string`, `rsfp_format_string`,
  `rsfp_md5` (the HVSC MD5).
- `rsfp_start(song, config)`: the chip (reSIDfp, or SIDLite for output
  rates up to 48 kHz); PAL/NTSC and 6581/8580 follow the tune's header, with a default for tunes that don't say and a *force* option for
  each; the sample rate; the resampler (`INTERPOLATE`, reSIDfp's cheap
  zero-order resampler and libsidplayfp's default, or `RESAMPLE`, the sinc
  one); 8580 digi boost; a mono mix for 2SID tunes; how many C64 cycles
  apart to sample the voices for the scope; and the power-on delay (the
  cycles before the tune's init, which libsidplayfp otherwise picks at
  random), reported back in the play info so a second instance of the tune
  can be started in step with the first.
- `rsfp_render(stereo, frames)`: renders exactly that many stereo frames.
  One chip plays on both channels; two chips left and right; a third in the
  middle at half level — Phosphor's layout.
- For the visualizers: `rsfp_chip_state` (register shadow, envelope
  counters and inferred envelope phase per voice, OSC3/ENV3),
  `rsfp_take_scope` (per-voice waveform × envelope samples since the last
  call), `rsfp_take_writes` (register writes with cycle stamps since the
  last call), `rsfp_cycles`.
- `rsfp_mute`, `rsfp_filter`.
- `rsfp_skip(cycles, mode)`: runs the emulation ahead without producing
  audio, for seeking. `RSFP_SKIP_RENDER` clocks the chips as when playing
  and drops the audio; `RSFP_SKIP_DIGITAL` clocks reSIDfp's oscillators and
  envelopes only (libresidfp's `clockDigital`), which leaves the chip's
  digital state identical at about half the cost, the filter and resampler
  settling within a second; `RSFP_SKIP_NONE` runs the C64 alone and leaves
  the chips' state behind. `design/scrubbing/README.md` has the
  measurements, from `examples/seek_bench.rs`.

Every SID is a `sidemu` of this crate's own (`VizEmu` in `shim.cpp`, with
a subclass per chip) around libresidfp's `SID` or SIDLite's, the same way
libsidplayfp's `reSIDfpEmu` and `SIDLiteEmu` wrap them, plus the
bookkeeping above. The envelope *phase* is inferred from the
gate bit and the counter's direction, since the generator's state is
private; the counter itself is the chip's.

## Cost

SIDLite through the same player: about 8 ms of processor time per second
of audio, 0.8 % of a core, C64 included.

reSIDfp, measured on 2026-11-05 (Apple silicon, release build, Commando by Rob
Hubbard, one 6581): about 38 ms of processor time per second of audio, 3.8 %
of a core, all of it libsidplayfp's cycle-exact C64 and reSIDfp's chip
model; the scope sampling and write log add nothing measurable (38.2 vs
38.4 ms with the scope off), the sinc resampler adds about 20 %, and an
8580 costs about 10 % less than a 6581. Each extra chip adds the same
again (2SID and 3SID tunes: about 9.5 % of a core). For comparison, in
Resonance the SIDLite engine's whole process costs about 1.8 % and reSID's
about 6.5 % on the same tune.

## Tests

`cargo test -p residfp-sys` builds two tiny PSID files in memory
(`residfp_sys::testing::tiny_psid`) and renders them: a second of audio,
scope samples at the expected rate, write stamps one frame apart, song
selection, 2SID left/right, forced model and clock, both resamplers, the
HVSC MD5, error reporting, a digital skip against a full one, and the same
on the SIDLite chip.

## Updating

Download the two release tarballs, replace `csrc/libsidplayfp/` and
`csrc/libresidfp/` with the same subsets, re-apply the three accessors,
update the versions in `build.rs` (`SIDPLAYFP_VERSION`, `RESIDFP_VERSION`),
this file and `rsfp_version`'s test, and check the global-scope class list
in `build.rs` (`RENAMES`) against `grep -rn "^class" csrc/libsidplayfp`.
