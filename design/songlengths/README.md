# Learned song lengths

HVSC's `Songlengths.md5` only knows HVSC's tunes. CSDb downloads and tunes
from elsewhere have no length, so Resonance works it out by running the tune
without playing it. Code: `apple/core/src/learned`.

## Where they live

`learned_songlengths.md5` next to the session in Application Support, by MD5,
never in HVSC's own file: an HVSC update replaces that one. The order is HVSC,
then learned, then the default length in Settings, so a tune that later joins
HVSC gets its official length. `-` marks a subtune that gave no answer, `?` one
not run yet. Bump `DETECTOR_VERSION` to have old answers redone.

Learned lengths show with a `~`: they're estimates.

## Why not just silence

The app already moves on after 3 s without SID writes, but most tunes never
stop: they loop. Measured on 300 random HVSC tunes, one subtune each, against
Songlengths.md5 (research bench, seed below), 2026-11-06:

| Method | Within 3 s | Within 10% (or 3 s) | Too short | Too long | No answer |
| --- | --- | --- | --- | --- | --- |
| No writes, 3 s (the app's live check) | 5.0% | 5.0% | 0.7% | 0% | 94.3% |
| No writes, 10 s | 5.0% | 5.3% | 0% | 0% | 94.7% |
| Envelopes closed, 3 s | 12.3% | 19.7% | 1.3% | 0.3% | 78.7% |
| Envelopes closed, 10 s | 11.3% | 12.0% | 1.0% | 0% | 87.0% |
| Flat audio, 10 s | 4.0% | 4.3% | 0% | 0.7% | 95.0% |
| No register change, 10 s | 7.0% | 7.7% | 0% | 0% | 92.3% |
| Loop, all writes, 2 copies | 26.0% | 41.7% | 20.0% | 20.3% | 18.0% |
| Loop, all writes, 3 copies | 31.7% | 46.7% | 5.3% | 22.0% | 26.0% |
| Loop, note-ons, 2 copies | 41.0% | 51.0% | 26.3% | 8.7% | 14.0% |
| Loop, note-ons, 3 copies | 53.3% | 62.3% | 8.0% | 8.7% | 21.0% |

Worked out afterward from the same runs:

| Combination (earliest answer wins) | Within 3 s | Within 10% | Too short | Too long | No answer |
| --- | --- | --- | --- | --- | --- |
| Flat 10 s, all 3, notes 3 | 59.3% | 68.7% | 8.0% | 9.3% | 14.0% |
| **No writes, closed or flat 10 s, all 3, notes 3 (shipped)** | **64.7%** | **72.3%** | **9.0%** | **8.0%** | **10.7%** |

Those were chosen on the same tunes they're scored on. The shipped code on 300
other tunes (`songlength_bench`, seed 20261106):

| Within 3 s | Within 10% | Too short | Too long | No answer |
| --- | --- | --- | --- | --- |
| 63.7% | 78.3% | 5.3% | 11.7% | 4.7% |

That sample happened to hold far fewer tunes over 5 minutes (7, against 22),
which are the hardest, so part of the gain is luck. With 300 tunes either
number could be off by about 5 points. By method, 31 of the 32 answers from
silence were right, and 204 of the 254 from a loop. Processor time per subtune:
median 24 s, 90th percentile 53 s, most 105 s.

## The method

Run the subtune for up to 15 minutes of tune time at a low sample rate, then
take the earliest of:

- **Silence**: a 10 s run, not from the very start, of no SID writes, of all
  envelopes closed (or volume 0, with no volume-register digi), or of flat
  audio. Each catches tunes the others miss: a note held for good, writes to
  closed envelopes, a hum.
- **A loop**: the point from which the stream starts repeating what came
  before, for 3 whole copies. Two streams: every write (exact, but filter and
  pulse sweeps can keep a tune from ever repeating exactly) and just the
  note-ons (which still repeat then). Timing is left out of both on purpose,
  so CIA-timed and multispeed tunes need no frame alignment. 3 copies, because
  with 2 a verse played twice looks like the whole song. A repeat under 8 s
  doesn't count.

An answer stops the run, checked every 30 s of tune.

## What goes wrong

- **Too short** cuts a tune off, and is the one that matters. It's mostly
  tunes with a part that repeats for a long time before moving on.
- **Too long** only plays part of the tune again.
- **Long tunes**: 3 copies in 15 minutes finds loops up to 5 minutes. Longer
  ones get no answer and play for the default length. A longer limit costs
  processor time.
- **Very short tunes** do poorly: 1 of 12 under 10 s was right.
- The score is against HVSC only, which is where the right answers are. New
  CSDb releases may do differently.

## Measuring

`rsfp_skip` discards the writes it logs, so both benches render. A skip that
kept them would be several times cheaper.

    cd apple
    # What ships. Tune on one seed and quote another.
    cargo run --release -p phosphor-apple --example songlength_bench -- <hvsc> <count> <seed> [out.csv]
    # Every detector on its own, as in the first table; always to the 15-minute limit.
    cargo run --release -p residfp-sys --example songlength_bench -- <hvsc> <count> [out.csv]
