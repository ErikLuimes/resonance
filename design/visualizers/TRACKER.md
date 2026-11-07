# The tracker, rebuilt

Under the hood's tracker, in the app's drawer and the terminal app's (`u`). Code:
`apple/core/src/tracker.rs`, `apple/Resonance/Views/UnderTheHoodView.swift` and
`apple/cli/src/tui.rs`. Change the rebuild only against
`apple/core/examples/tracker_bench.rs`, and keep what it prints out of the repo: register data
and tune data stay private.

## Ahead of time, not live

A `.sid` file holds player code, so there are no patterns to read. The live feed could only show
rows up to now, and holds about 10 seconds. The fingerprint scan's capture-only SID runs a tune at
about 200× speed (120 s of tune in a median 0.6 s, worst 0.9 s, over 300 tunes), so the whole tune
is rebuilt once when the drawer opens. That gives rows still to come, which is what makes it read
as a tracker, plus looking around and surviving a seek. It also sees every write rather than the
end of each frame, so a gate closed and reopened within one frame is still a note.

The playhead is time, not a frame count: what's being heard (`viz_heard_secs`, after the engine's
buffer and the output device) times the frame rate, so a seek should need nothing special, though
that hasn't been tried. Against the live player on Commando, sampled for 15 s, the rows agree with
what's sounding 99.6% of the time at an offset of −10 ms and 97.7% at zero, falling to about 70% at
±100 ms: within one frame. That's arpeggio-free notes on one tune.

## Finding the row length

Notes alone set the grid. With note endings in it too, players that close a gate two frames in
forced rows of 2 frames, 25 rows a second, which can't be read. An ending can only halve a long row,
when nine in ten land midway through it.

A grid's score is how many notes it catches beyond what it would catch by luck, and the longest
row within 97% of the best wins, since multiples of the true row also score well. Rows of 6 frames
and up allow a frame either way, as players often start a voice a frame late.

Over 300 tunes spread across HVSC: 79% have a grid (0 failed, 7 have no notes at all), and rows
fall where trackers put them: 6 frames for 104 tunes, then 8 (30), 4 (25), 5 and 10 (11 each).
The other 21% say they have no steady beat and use a 6-frame ruler; notes still land on the
nearest row.

## What isn't known

There's no ground truth in HVSC to score against, so these are plausibility checks and a read of
well-known tunes (Commando at 6 frames with every note on the grid and its chords as arpeggios).
GoatTracker `.sng` files would make a real check. A few tunes read as 2-frame rows; Ocean Loader 2
is one, with 99% of its notes on that grid.

"Instrument" means a distinct waveform and envelope, so one instrument of the composer's can
appear as several here, and pulse width isn't part of it. Effects are inferred: arpeggio is big
steps coming back, vibrato is small moves crossing their middle, slide is steady in one direction.
A multi-SID tune shows one chip at a time in the tracker, with a picker, as each chip gets its own
rebuild and their rows needn't line up. Registers, Sweeps and Pitch Trail show every chip at once:
a line per voice, a column per chip and a band per chip. With no room for that they collapse to the
chosen chip, and the picker comes back.

Chips can look the same and be right. Over 120 s of Aliens (2SID), the chips agree on pulse width,
gates, cutoff and resonance in every frame, and differ only in frequency, in a third of frames; so
Sweeps looks the same on both while Tracker and Pitch Trail don't. Hallows Eve (2SID) differs nearly
everywhere. `tracker_bench chips <file>` measures it.
