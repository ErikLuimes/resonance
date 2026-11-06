# Smart playlists

A playlist from a recipe: how tunes sound, how long they are and what's been
played. Code: `apple/core/src/smart.rs` (choosing), `apple/core/src/ffi.rs`
(`smart_playlist`), `apple/Resonance/Views/SmartPlaylistView.swift` and
`SmartSentenceField.swift`. Change the choosing only against
`apple/core/examples/smart_bench.rs`.

## Similar means a rank, not a score

A fixed score doesn't mean the same for every tune. At 0.7 or higher, on HVSC
85 with the shipped Sounds Like:

| Tune | Tunes at 0.7+ | Over 2 minutes |
|---|---|---|
| Comic Bakery | 23 | 12 |
| Brown Ice | 218 | 104 |
| Monty on the Run | 244 | 139 |
| Commando | 458 | 258 |

The score isn't a percentage either: it runs from about 0.95 down to −1.2. So
Very Close, Close and Loose are the closest 50, 200 and 1,000, and the count is
always on screen.

## Versions are found by name

Covers don't sound alike to Sounds Like. From `2nd Reality (part 2)` by KB, the
other 2nd Reality tunes rank 667th, 6,330th, 31,476th and 42,549th of 60,162. So
Other Versions matches titles, without what marks a part: "2nd Reality (part 2)"
and "2nd Reality" are one piece. A title with more than 12 matches is generic
("Tune", "Intro"), so it has none. Real cover detection, finding a cover with
another name, is a different feature, and not attempted.

Spelled-out ordinals meet digits, so "Second Reality" finds "2nd Reality". That
tune isn't in HVSC under the name of the demo it remakes.

## Intensity

There's no reference for "chill", so this is a judgement checked by proxies, not
a measured truth. The tune's rank against the pool on four measures, weighted,
then ranked again so 0 is the calmest and 1 the most intense:

| Measure | Weight |
|---|---|
| Notes per second | 0.4 |
| Noise hits (drums) | 0.25 |
| Voice levels added up | 0.2 |
| Arpeggios | 0.15 |

Chill also has hard limits: 3.5 notes per second or fewer, under one drum hit a
second, and in the bottom fifth. A first version without them let in tunes at
about 8 notes per second, which aren't slow.

The pool leaves out silence, digi samples, untitled tunes, and anything under 2
minutes or over 5.5, which would be a jingle or take over the arc. Of 60,162
tunes, 28,271 qualify.

Scanning covers at most three minutes of a subtune, so a slow intro to a fast
tune can read as calm. Intensity is the whole scanned stretch, not how a tune
moves.

## New to Me

The average of the heard tunes' feature vectors, then unheard music from 75% to
95% of the way out from it. Not the furthest tunes, which are mostly oddities.
It stops at under 25 heard tunes (`MIN_HISTORY`), which is a judgement.

This is the weakest of the recipes. With 283 heard tunes the average leans only
about a fifth of a standard deviation towards louder and higher, so "different"
is a mild signal, and it should get better with history. Features, not
embeddings: those all lie close together, and an average blurs them further.

## The sentence box

A plain parser reads it first, and the on-device model only gets what the parser
finds nothing in. Asked directly, the model read "slow chill music, increasing in
intensity, 1 hour" as Like, and invented a 3-minute minimum and 15-minute total
for a sentence with no numbers. So its lengths only count when the sentence has
digits, and either way it can only fill in the controls, where a wrong guess
shows. The parser needs no Apple Intelligence.

## Saved lists are frozen

Save as Playlist writes an ordinary playlist that stays as it was. A live one
would suit Never Heard, but it's more than this release needed.

## Checking it

`smart_bench`, 20 one-hour picks each, HVSC 85, 283 tunes heard:

| Chill to Intense | |
|---|---|
| Plays for | 60.0 to 64.7 minutes |
| Intensity by third of the hour | 0.04, 0.10, 0.64 |
| Last tune's intensity | 0.88 |
| Steps down during the climb | 0 of 126 |
| Composers repeated in a list | 5 of 384 tunes |
| Two lists share | 1.4% of their tunes |

| New to Me | |
|---|---|
| Plays for | 60.1 to 62.9 minutes |
| Pool | 7,652 tunes |
| Composers repeated in a list | 18 of 415 tunes |
| Two lists share | 0.3% of their tunes |
| Heard tunes picked | 0 |

These say the arcs have the right shape and don't repeat. On 2026-11-06 a
listen to a Chill to Intense list confirmed that it does become more intense.
That's one listener and one list, not a listening test, and New to Me hasn't had
that check. Composer checks use the
folder, so Games and Demos count one per section, and the app's own column shows
the header's author instead.

Lists overrun by up to one tune, about 5 minutes at worst. A list doesn't stop
halfway through a tune, so it ends long rather than short.
