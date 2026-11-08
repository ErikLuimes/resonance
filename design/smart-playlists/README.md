# Smart playlists

A playlist from a recipe: how tunes sound, how long they are and what's been
played. Code: `apple/core/src/smart.rs` (choosing), `apple/core/src/ffi.rs`
(`smart_playlist`), `apple/Resonance/Views/SmartPlaylistView.swift` and
`Model/SmartSentence.swift`. Change the choosing only against
`apple/core/examples/smart_bench.rs`. The terminal app's Describe row uses the
same reading through the `describe` command; nothing about choosing lives there.

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

Versions only get past the similarity rank, not what was asked for. "Like
Commando, dual SID" gave 4 one-SID versions before they had to fit too, and
gives none now. `smart_bench` checks this on that sentence.

Spelled-out ordinals meet digits, so "Second Reality" finds "2nd Reality". That
tune isn't in HVSC under the name of the demo it remakes.

## Composers by folder

A tune's composer is its nearest folder, as a person can sit inside a group
(`Tinnitus/Trompkins`). But 35 composers have a `Worktunes` folder, which read as
one composer: "like Drax" gave 1,199 tunes by many people, and 1,063 now, all his.
So `Worktunes` and `unreleased` count as their parent.

Handles that are also words need "by" on their own, since Rock, Moon, Sad and
Metal all compose. "Chill Hermit" has nothing else for the word to mean, so a word
counts as a handle when it's what remains of a sentence that said something else
and the composer has 30 tunes or more. Music styles (`notHandles`) stay out.

## Speech

Samples are all a tune's sound shows, and drums are samples too. So "with speech"
finds tunes with plenty of samples, and the line under the field says it can't tell.

## Intensity

There's no reference for "chill", so this is a judgment checked by proxies, not
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
It stops at under 25 heard tunes (`MIN_HISTORY`), which is a judgment.

This is the weakest of the recipes. With 283 heard tunes the average leans only
about a fifth of a standard deviation toward louder and higher, so "different"
is a mild signal, and it should get better with history. Features, not
embeddings: those all lie close together, and an average blurs them further.

## Describe

There's one field, and the suggestions under it (New to Me, Never Heard, Similar to
a Tune, Slow to Intense) are sentences like any other. Everything fits the height
of a playlist's header, so the tunes have the page; four cards and a row of controls
took about 340 points before the first tune. What was understood shows as chips,
so a wrong guess shows.

**Plain code reads the facts:** lengths, years and decades, never heard, games or
demos, and a tune after "like" or "similar to". They come out of the sentence
first, so "two hours" can't be read as something else.

**NLTagger reads composers and moods,** with an `NLGazetteer` of the composers'
names and a short list of mood words. The order of the moods is the shape: calm
then intense rises, intense then calm falls, and one mood holds throughout.
Unmistakable surnames count ("Hubbard"), and one-word names only after "by",
because many of them are ordinary words.

**"With love in the title" is plain code too,** and goes first, so "fast" in a title
isn't a mood. It matches whole words, so "love" isn't "lovely". This is also the
honest answer to genres: HVSC has no genre data, and "with techno in the title"
says exactly what it does.

**NSDataDetector reads "until 9PM",** "until midnight" and "until tomorrow morning".
It gives "until" as a range, so the end is its date plus its duration. Only a match
starting "until" or "till" counts, so "this evening" alone isn't an end. It finds
no durations ("2 hours"), years or Dutch ("tot 9 uur"), which stay with the plain
code. The length is worked out once, when the sentence is read.

**NLTagger's lemmas** catch word forms: "relaxes" and "harder" count as "relax" and
"hard". They don't catch everything: "building" stays "building".

**NLEmbedding doesn't help with moods.** Scoring words by distance to calm and
intense words, the margins were about zero: "gym", "reality" and "music" all came
out calm, and so did "sad" and "hectic". "Chill" is nearest "shiver" and "breeze",
its weather meaning. Sentence embeddings didn't separate them either. There's none
for Dutch.

**Create ML's `MLWordTagger` was tried and not used.** Trained on 12,450 made-up
sentences from 45 patterns, with a fifth of the names held back: on patterns it had
seen with names it hadn't, 98% of sentences came out right, but on 14 new patterns
33%. It's close to all or nothing per pattern: "give me songs like X" got 141 of 141
and "find tunes like X" 0 of 126; "best X tunes" got 140 of 142 and "play X" 0 of
145. `transferLearning(.dynamicEmbedding)` took 382 s against 2 s, scored 27%, and
changed which patterns fail, not how many. Spans also overrun ("Commando but only
ones") and it can't tell a title from a name alone ("Comic Bakery" as a composer),
so a word list would have to check its answers anyway. It trains easily and runs
fast (946 KB, under 0.1 ms a sentence), so it may be worth another look with real
sentences from people to train on.

**Titles aren't in the gazetteer.** Tried with all 52,207, "like", "start", "music",
"the", "I", "1986" and "two hours" all came back as tunes, because tunes are called
that. So a title counts after "like", as words inside a sentence when at least two
of them say something ("the last ninja", not "a tune"), or as the whole sentence,
with or without "play". On its own it means that tune and its versions, the exact
title first and each oldest first: "Airwolf" should be Airwolf, and finding what
sounds like it takes "like".
Of several tunes with one title the oldest comes first, more often the original
than a cover: "Comic Bakery" is Galway's. "Rainy day" does come out as the tune "A
Rainy Day", which the line under the field shows.

**Names.** "Jeroen Tel", "Tel Jeroen" and "Tel, Jeroen" are one person. A name's the
one their tunes' headers give most, and nicknames come from those headers too
("Johan Åstrand (Zyron)"), from a tenth of a folder's tunes: other names in a
folder are mostly covers' credits, and treating them as nicknames made "Chris
Hülsbeck" Thomas Mogensen. A shared surname means whoever has the most tunes. A
nickname that's an English word ("Eye") needs "by". Close spellings count from
five letters, and the note says so: "Did you mean Rob Hubbard?"

**It always answers.** Once Return is pressed, a sentence with nothing recognized
becomes tunes with one of its words in the title, or else a random mix, and the note
says which. While typing, it leaves the list alone until the words mean something.

**Apple's on-device model isn't used.** Tried on 24 sentences first, it got mood
and shape right on 20, but filled tune names with "slow chill" and "unheard",
said games on most sentences that never mentioned them, missed "two hours" and
"after 2010", and on an earlier try invented lengths for sentences with none. It
also needs Apple Intelligence. The gazetteer took 0.2 s to build with every title,
and 0.01 s with what's used; a sentence takes about a millisecond, and the same
sentence always gives the same answer, which tests can hold it to. The cost: a
mood word not on the list isn't understood, and the fix is adding it.

A composer's tunes in GAMES or DEMOS aren't included, as composers are found by their MUSICIANS folder.

A list that's calm or intense throughout is rated against the whole collection:
calm is the lower 35% with 6 notes a second or fewer, intense the top 40%. An arc
is rated against what the sentence allows, so one composer's calm tunes are their
calmest, however they'd rank against everybody. Single-composer calm isn't
reliable yet: "Turbo Outrun" comes out as calm Jeroen Tel.

## Checked against real sentences

`sentences.txt` here holds about 135 sentences the app's author wrote for this,
and `SmartUserSentenceTests` holds what they should mean. On the first run about a
third came out right, with some flipped outright ("no demos" gave demos, "not too
intense" gave intense, "SID" gave a composer called Michael).

What the data can't tell is said, not faked: dark, moody, happy and the like show
as "Can't tell “dark” from how tunes sound yet", and asking for local files says
they aren't included. Ratings aren't known, so "best" and "good" mean nothing, and
"more like that last one" doesn't know what the last one was. "Top 100" opens HVSC's
own playlist, on Return.

Several composers or tunes are read as a list. Several tunes take turns, closest
first. A title list needs two or more, and a one-word title only counts if the rest
of its part says nothing, so "title screens" isn't the tune "Title". A mood with a
tune is relative to it: "similar to Cybernoid II but slower" is slower than that
tune. Sounds and chips are the top quarter of the music for that sound, or the top
half within given composers, and "8580" is what the tune's header asks for, not what
it sounds like. "Dual SID", "triple SID", "single SID" and "stereo" go by how many
chips the tune uses, as scanned. Sound words aren't in the benchmark.

## Left for later

"Top 10 by Hubbard" and "famous musicians" could use the curated playlists as a
stand-in for popularity, since HVSC has no ratings. Not in this release. In HVSC's
Top 100, Hubbard has 22 tunes, Tel 13, Galway 12, Daglish 7, Hülsbeck 6 and
Bjerregaard 5. Only 647 of about 60,000 tunes are in those lists, 28 of the 35 lists
are Zyron's own albums, and most of a composer's tunes tie, so it could say "best
known" but not rank them. CSDb's ratings could do better once CSDb ships.

## Arranging

A list of a set length leaves out tunes under a minute and tunes that scanned as
silence; All still has them, as it says. Lists of up to 500 flow: each next tune is
the closest to the one before by another composer, by Sounds Like's feature vectors.
On three Never Heard hours, neighboring tunes scored 0.31, 0.34 and 0.42 against
0.06, 0.13 and 0.19 for the same tunes shuffled, with no composer twice in a row. In
a rising list only the calm stretch flows, since the climb's order is the point.

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
