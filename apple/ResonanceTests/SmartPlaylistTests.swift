import Foundation
import PhosphorCore
import Testing
@testable import Resonance

struct SmartSettingsTests {
    @Test func aSentenceMakesItsRecipe() {
        var settings = SmartSettings()
        settings.understood = SmartUnderstanding(onlyUnheard: true, unlikeHeard: true)
        #expect(settings.recipe.kind == .different)
        #expect(settings.recipe.onlyUnheard)
        settings.understood = SmartUnderstanding(onlyUnheard: true)
        #expect(settings.recipe.kind == .shuffle)
    }

    @Test func itWaitsForASentenceAndItsTune() {
        var settings = SmartSettings()
        #expect(!settings.isReady)
        settings.understood = SmartUnderstanding(tuneNames: ["Commando"])
        #expect(!settings.isReady)
        settings.describedSeeds = [.init(path: "/c.sid", title: "Commando", author: "Rob Hubbard")]
        settings.closeness = .veryClose
        #expect(settings.isReady)
        #expect(settings.recipe.kind == .like)
        #expect(settings.recipe.seeds == ["/c.sid"])
        #expect(settings.recipe.top == 50)
        #expect(!settings.canRefresh)
    }

    @Test func itCarriesWhatWasUnderstood() {
        var settings = SmartSettings()
        settings.understood = SmartUnderstanding(energy: .intense, composers: [.init(folder: "Hubbard_Rob", name: "Rob Hubbard")], fromYear: 1985, toYear: 1986, minMinutes: 2)
        let recipe = settings.recipe
        #expect(recipe.kind == .shuffle)
        #expect(recipe.energy == .intense)
        #expect(recipe.composers == ["Hubbard_Rob"])
        #expect(recipe.fromYear == 1985)
        #expect(recipe.minSecs == 120)
    }

    @Test func aShapeBecomesARisingOrFallingList() {
        var settings = SmartSettings()
        settings.understood = SmartUnderstanding(shape: .falling)
        #expect(settings.recipe.kind == .falling)
    }

    @Test func refreshIsOnlyOnWhenItCanChangeTheList() {
        var settings = SmartSettings()
        #expect(!settings.canRefresh)
        settings.understood = SmartUnderstanding(shape: .rising)
        #expect(settings.canRefresh)
        settings.understood = SmartUnderstanding(energy: .intense, composers: [.init(folder: "Hubbard_Rob", name: "Rob Hubbard")])
        #expect(!settings.canRefresh)
        settings.understood = SmartUnderstanding(composers: [.init(folder: "Hubbard_Rob", name: "Rob Hubbard")])
        #expect(settings.canRefresh)
        settings.understood = SmartUnderstanding(titleWords: "airwolf")
        #expect(!settings.canRefresh)
        settings.understood = SmartUnderstanding(tuneNames: ["Commando"])
        settings.describedSeeds = [.init(path: "/c.sid", title: "Commando", author: "Rob Hubbard")]
        #expect(!settings.canRefresh)
    }

    @Test func refreshOnASetOrderShufflesIt() {
        var settings = SmartSettings()
        settings.understood = SmartUnderstanding(shape: .rising)
        settings.refresh()
        #expect(!settings.isReordered)
        settings.understood = SmartUnderstanding(titleWords: "airwolf")
        let before = settings.generation
        settings.refresh()
        #expect(settings.isReordered)
        #expect(settings.generation != before)
    }

    @Test func playsForSaysHowLong() {
        #expect(SmartSettings.lengthTitle(nil) == "All")
        #expect(SmartSettings.lengthTitle(60) == "1 Hour")
        #expect(SmartSettings.lengthTitle(1440) == "Whole Day")
        #expect(SmartSettings.lengthTitle(319) == "5 h 19 min")
    }

    @Test func lengthsSayAsMuchAsIsUseful() {
        #expect(SmartFacts.tunes(19, secs: 3678) == "19 tunes, 61 minutes")
        #expect(SmartFacts.tunes(1, secs: 60) == "1 tune, 1 minute")
        #expect(SmartFacts.tunes(155, secs: 32_280) == "155 tunes, 8 h 58 min")
        #expect(SmartFacts.tunes(59_888, secs: 8_452_800) == "\(59_888.formatted()) tunes, about \(2_348.formatted()) hours")
    }
}

struct SmartUnderstandingTests {
    @Test func itSaysWhatItUnderstood() {
        let understood = SmartUnderstanding(energy: .intense, composers: [.init(folder: "Hubbard_Rob", name: "Rob Hubbard")], fromYear: 1985, toYear: 1986)
        #expect(understood.description() == "Intense, by Rob Hubbard, from 1985 to 1986.")
        #expect(SmartUnderstanding(shape: .rising).description() == "Starts calm, ends intense.")
        #expect(SmartUnderstanding(tuneNames: ["Commando"], minMinutes: 3).description() == "Sounds like Commando, each over 3 minutes.")
        #expect(SmartUnderstanding(titleWords: "love").description() == "With “love” in the title.")
        #expect(SmartUnderstanding(totalMinutes: 120).description() == "Anything, shuffled.")
        let parts = SmartUnderstanding(energy: .intense, composers: [.init(folder: "Hubbard_Rob", name: "Rob Hubbard")], fromYear: 1985, toYear: 1986).parts()
        #expect(parts == ["Intense", "By Rob Hubbard", "From 1985 to 1986"])
        #expect(SmartUnderstanding(cantTell: ["dark"]).aside?.contains("dark") == true)
        #expect(SmartUnderstanding().aside == nil)
    }
}

/// The sentences the feature was asked for, and others NLTagger has to read.
struct SmartSentenceParserTests {
    private let parser = SmartSentenceParser(composers: [
        SmartComposer(name: "Rob Hubbard", folder: "Hubbard_Rob", aliases: ["Hubbard, Rob"], tunes: 10),
        SmartComposer(name: "Jeroen Tel", folder: "Tel_Jeroen", aliases: ["Tel, Jeroen"], tunes: 10),
        SmartComposer(name: "Martin Galway", folder: "Galway_Martin", aliases: ["Galway, Martin"], tunes: 10),
        SmartComposer(name: "Chris Hülsbeck", folder: "Huelsbeck_Chris", aliases: ["Huelsbeck, Chris"], tunes: 10),
        SmartComposer(name: "Johan Åstrand", folder: "Zyron", aliases: ["Zyron"], tunes: 10),
        SmartComposer(name: "Eye", folder: "Eye", aliases: ["Eye"], tunes: 10),
        SmartComposer(name: "Someone Fast", folder: "Fast_Someone", aliases: ["Fast, Someone"], tunes: 10),
    ], titles: ["Monty on the Run", "The Last Ninja", "Comic Bakery", "Party Music", "A Tune", "Something Nice", "Commando", "Love"])

    @Test func likeASong() throws {
        let parsed = try #require(parser.parse("Playlist with all songs like second reality"))
        #expect(parsed.tuneName == "second reality")
        #expect(parsed.minMinutes == nil)
        #expect(parsed.totalMinutes == nil)
    }

    @Test func slowChillRisingForAnHour() throws {
        let parsed = try #require(parser.parse("Playlist with slow chill music and increasing in intensity at the end, 1 hour playlist"))
        #expect(parsed.shape == .rising)
        #expect(parsed.totalMinutes == 60)
        #expect(parsed.tuneName == nil)
    }

    @Test(arguments: ["slow to intense", "start mellow and end with a bang", "build up slowly over two hours", "slow chill music that builds up"])
    func thisBuildsUp(sentence: String) throws {
        #expect(try #require(parser.parse(sentence)).shape == .rising)
    }

    @Test(arguments: ["start hard and wind down at the end", "fast to slow", "intense then calm"])
    func thisWindsDown(sentence: String) throws {
        #expect(try #require(parser.parse(sentence)).shape == .falling)
    }

    @Test func randomUnheard() throws {
        let parsed = try #require(parser.parse("Random playlist all unheard songs"))
        #expect(parsed.onlyUnheard)
        #expect(parsed.justShuffle)
    }

    @Test func longerThanAndSimilarTo() throws {
        let parsed = try #require(parser.parse("Search all songs longer than 2 minutes similar to second reality"))
        #expect(parsed.minMinutes == 2)
        #expect(parsed.totalMinutes == nil)
        #expect(parsed.tuneName == "second reality")
    }

    @Test func newToMe() throws {
        let parsed = try #require(parser.parse("new to me: analyze play history and play something opposite"))
        #expect(parsed.unlikeHeard)
        #expect(parsed.onlyUnheard)
    }

    @Test func composerMoodAndYears() throws {
        let parsed = try #require(parser.parse("fast Rob Hubbard tunes from 1985 and 1986"))
        #expect(parsed.energy == .intense)
        #expect(parsed.composerFolder == "Hubbard_Rob")
        #expect(parsed.composerName == "Rob Hubbard")
        #expect(parsed.fromYear == 1985)
        #expect(parsed.toYear == 1986)
    }

    @Test func aComposerWithALength() throws {
        let parsed = try #require(parser.parse("chill Jeroen Tel for half an hour"))
        #expect(parsed.energy == .calm)
        #expect(parsed.composerFolder == "Tel_Jeroen")
        #expect(parsed.totalMinutes == 30)
    }

    @Test func aSurnameIsEnough() throws {
        #expect(try #require(parser.parse("hubbard")).composerFolder == "Hubbard_Rob")
        #expect(try #require(parser.parse("tunes by Martin Galway")).composerFolder == "Galway_Martin")
    }

    @Test func accentsMeetTheFolderName() throws {
        #expect(try #require(parser.parse("Chris Hülsbeck")).composerFolder == "Huelsbeck_Chris")
    }

    @Test func aOneWordNameNeedsBy() throws {
        #expect(parser.parse("eye") == nil)
        #expect(try #require(parser.parse("tunes by eye")).composerFolder == "Eye")
    }

    @Test func aMoodBeatsASurnameThatSoundsLikeIt() throws {
        let parsed = try #require(parser.parse("fast tunes"))
        #expect(parsed.energy == .intense)
        #expect(parsed.composerFolder == nil)
    }

    @Test func gameMusicFromADecade() throws {
        let parsed = try #require(parser.parse("calm game music from the eighties"))
        #expect(parsed.section == .games)
        #expect(parsed.energy == .calm)
        #expect(parsed.fromYear == 1980)
        #expect(parsed.toYear == 1989)
    }

    @Test func afterAYearNeverHeard() throws {
        let parsed = try #require(parser.parse("demo tunes after 2010 I haven't heard"))
        #expect(parsed.section == .demos)
        #expect(parsed.fromYear == 2011)
        #expect(parsed.toYear == nil)
        #expect(parsed.onlyUnheard)
    }

    @Test func numbersInWords() throws {
        #expect(try #require(parser.parse("two hours of calm music")).totalMinutes == 120)
        #expect(try #require(parser.parse("music for working out, 45 minutes")).totalMinutes == 45)
        #expect(try #require(parser.parse("calm music all day")).totalMinutes == 1440)
    }

    @Test func theNameEndsWhereTheSentenceMovesOn() throws {
        let parsed = try #require(parser.parse("Tunes like Comic Bakery, over 3 minutes, for 2 hours"))
        #expect(parsed.tuneName == "comic bakery")
        #expect(parsed.minMinutes == 3)
        #expect(parsed.totalMinutes == 120)
    }

    @Test func aMoodAfterLikeIsNotATune() throws {
        let parsed = try #require(parser.parse("songs like chill ones"))
        #expect(parsed.tuneName == nil)
        #expect(parsed.energy == .calm)
    }

    @Test(arguments: ["all songs with love in the title", "tunes with love in the name", "love as the title", "tunes titled love", "tunes called love", "title contains love"])
    func wordsInTheTitle(sentence: String) throws {
        #expect(try #require(parser.parse(sentence)).titleWords == "love")
    }

    @Test func aMoodWordInATitleIsNotAMood() throws {
        let parsed = try #require(parser.parse("all songs with fast in the title"))
        #expect(parsed.titleWords == "fast")
        #expect(parsed.energy == .any)
    }

    @Test func aTitleCombinesWithTheRest() throws {
        let parsed = try #require(parser.parse("calm Rob Hubbard tunes called monty, over 2 minutes"))
        #expect(parsed.titleWords == "monty")
        #expect(parsed.composerFolder == "Hubbard_Rob")
        #expect(parsed.energy == .calm)
        #expect(parsed.minMinutes == 2)
    }

    @Test func whatComesBeforeTheTitleStillCounts() throws {
        let calm = try #require(parser.parse("calm tunes with night in the title"))
        #expect(calm.titleWords == "night")
        #expect(calm.energy == .calm)
        let hubbard = try #require(parser.parse("rob hubbard tunes with commando in the name"))
        #expect(hubbard.titleWords == "commando")
        #expect(hubbard.composerFolder == "Hubbard_Rob")
    }

    @Test func playsUntilATime() throws {
        let parsed = try #require(parser.parse("playlist with songs like 2nd reality that play until 9PM"))
        #expect(parsed.tuneName == "2nd reality")
        let until = try #require(parsed.until)
        #expect(Calendar.current.component(.hour, from: until) == 21)
        #expect(Calendar.current.component(.minute, from: until) == 0)
        let minutes = try #require(parsed.totalMinutes)
        #expect(minutes >= 1 && minutes <= 1440)
    }

    @Test func untilWithAMood() throws {
        let parsed = try #require(parser.parse("calm music until midnight"))
        #expect(parsed.energy == .calm)
        #expect(parsed.until != nil)
    }

    @Test func aTimeWithoutUntilIsNotAnEnd() {
        #expect(parser.parse("this evening") == nil)
    }

    @Test func anHourAndAHalf() throws {
        #expect(try #require(parser.parse("calm music for an hour and a half")).totalMinutes == 90)
    }

    @Test(arguments: ["relaxes", "harder tunes"])
    func wordFormsCount(sentence: String) throws {
        #expect(try #require(parser.parse(sentence)).energy != .any)
    }

    @Test func nothingToGoOn() {
        #expect(parser.parse("something nice please") == nil)
        #expect(parser.parse("Commando") == nil)
    }

    @Test(arguments: ["Jeroen Tel", "jeroen tel", "Tel Jeroen", "Tel, Jeroen", "tel", "tunes by tel"])
    func everyFormOfAName(sentence: String) throws {
        let parsed = try #require(parser.parse(sentence))
        #expect(parsed.composerFolder == "Tel_Jeroen")
        #expect(parsed.composerName == "Jeroen Tel")
        #expect(!parsed.composerWasGuessed)
    }

    @Test func aSharedSurnameMeansWhoeverHasMostTunes() throws {
        let parser = SmartSentenceParser(composers: [
            SmartComposer(name: "Big Tel", folder: "Tel_Big", aliases: [], tunes: 200),
            SmartComposer(name: "Small Tel", folder: "Tel_Small", aliases: [], tunes: 2),
        ])
        #expect(try #require(parser.parse("tel")).composerFolder == "Tel_Big")
        #expect(try #require(parser.parse("small tel")).composerFolder == "Tel_Small")
    }

    @Test func aNicknameFromTheHeaders() throws {
        #expect(try #require(parser.parse("zyron")).composerFolder == "Zyron")
        #expect(try #require(parser.parse("calm tunes by Zyron")).composerFolder == "Zyron")
    }

    @Test func theNameShowsAsTheHeadersSpellIt() throws {
        #expect(try #require(parser.parse("huelsbeck")).composerName == "Chris Hülsbeck")
    }

    @Test(arguments: ["hubard", "rob hubard", "tunes by hubbbard"])
    func aTypoInAName(sentence: String) throws {
        let parsed = try #require(parser.parse(sentence))
        #expect(parsed.composerFolder == "Hubbard_Rob")
        #expect(parsed.composerWasGuessed)
    }

    @Test(arguments: ["Comic Bakery", "the last ninja", "monty on the run"])
    func aTitleAloneIsThatTune(sentence: String) throws {
        let parsed = try #require(parser.parse(sentence))
        #expect(parsed.titleWords == sentence.lowercased())
        #expect(parsed.tuneNames.isEmpty)
    }

    @Test func aTitleInASentenceIsWhatItSoundsLike() throws {
        #expect(try #require(parser.parse("music from the last ninja please")).tuneName == "the last ninja")
    }

    @Test(arguments: [("play Commando", "commando"), ("Play monty on the run please", "monty on the run"),
                      ("put on commando", "commando"), ("play the last ninja.", "the last ninja")])
    func playATitle(sentence: String, title: String) throws {
        let parsed = try #require(parser.parse(sentence))
        #expect(parsed.titleWords == title)
        #expect(parsed.tuneNames.isEmpty)
    }

    @Test func playIsNotAlwaysATitle() throws {
        #expect(try #require(parser.parse("play rob hubbard")).composerFolder == "Hubbard_Rob")
        #expect(parser.parse("play something") == nil)
        #expect(try #require(parser.parse("play party music")).energy == .intense)
        #expect(parser.parse("play party music")?.titleWords == nil)
    }

    @Test func aTitleAndItsComposer() throws {
        let parsed = try #require(parser.parse("Monty on the Run by Hubbard"))
        #expect(parsed.tuneName == "monty on the run")
        #expect(parsed.composerFolder == "Hubbard_Rob")
    }

    @Test(arguments: ["party music", "a tune", "two hours of calm music", "slow to intense"])
    func plainWordsAreNotTitles(sentence: String) {
        #expect(parser.parse(sentence)?.tuneName == nil)
    }

    @Test func aSearchForANameIsNotAList() throws {
        #expect(!(try #require(parser.parse("rob hubbard"))).asksForAList)
        #expect(try #require(parser.parse("calm rob hubbard")).asksForAList)
    }
}

/// The sentences the user wrote for this feature, with what each should mean.
/// What isn't checked here isn't promised; the design note lists the gaps.
struct SmartUserSentenceTests {
    private let parser = SmartSentenceParser(composers: [
        SmartComposer(name: "Rob Hubbard", folder: "Hubbard_Rob", aliases: ["Hubbard, Rob"], tunes: 96),
        SmartComposer(name: "Martin Galway", folder: "Galway_Martin", aliases: ["Galway, Martin"], tunes: 40),
        SmartComposer(name: "Ben Daglish", folder: "Daglish_Ben", aliases: ["Daglish, Ben"], tunes: 89),
        SmartComposer(name: "Anthony Lees", folder: "Lees_Anthony", aliases: ["Lees, Anthony"], tunes: 9),
        SmartComposer(name: "Jeroen Tel", folder: "Tel_Jeroen", aliases: ["Tel, Jeroen"], tunes: 176),
        SmartComposer(name: "Tim Follin", folder: "Follin_Tim", aliases: ["Follin, Tim"], tunes: 18),
        SmartComposer(name: "Fred Gray", folder: "Gray_Fred", aliases: ["Gray, Fred"], tunes: 20),
        SmartComposer(name: "Matt Gray", folder: "Gray_Matt", aliases: ["Gray, Matt"], tunes: 30),
        SmartComposer(name: "Mark Cooksey", folder: "Cooksey_Mark", aliases: ["Cooksey, Mark"], tunes: 41),
        SmartComposer(name: "James Long", folder: "Long_James", aliases: ["Long, James"], tunes: 14),
        SmartComposer(name: "Wayne Pace", folder: "Pace_Wayne", aliases: ["Pace, Wayne"], tunes: 3),
        SmartComposer(name: "Michael", folder: "Sid", aliases: ["Sid"], tunes: 17),
        SmartComposer(name: "Rastislav Smutný", folder: "Top_Secret", aliases: ["Top Secret", "Top, Secret"], tunes: 40),
        SmartComposer(name: "Razy", folder: "Razy", aliases: ["Razy"], tunes: 2),
    ], titles: ["Commando", "Last Ninja", "The Last Ninja", "Last Ninja 2", "Wizball", "International Karate", "Sanxion", "Delta",
                "Monty on the Run", "Auf Wiedersehen Monty", "Cybernoid", "Cybernoid II", "Knucklebusters", "Crazy Comets",
                "Ghouls 'n' Ghosts", "Ghosts 'n' Goblins", "Parallax", "Nemesis the Warlock", "Top", "Slow", "Alternative"])

    private func parsed(_ sentence: String) throws -> SmartUnderstanding { try #require(parser.parse(sentence)) }
    private func folders(_ sentence: String) throws -> Set<String> { Set(try parsed(sentence).composers.map(\.folder)) }

    @Test func ordinaryWordsAreNotComposers() throws {
        for sentence in ["Slow SID tunes.", "Fast, energetic C64 music.", "Driving, fast-paced tracks for working.",
                         "Long background playlist.", "Top-rated HVSC tunes only.", "Stuff from crazy things",
                         "Alternative / experimental SID tracks."] {
            #expect(parser.parse(sentence)?.composers.isEmpty != false, "\(sentence)")
        }
    }

    @Test func oneComposer() throws {
        for (sentence, folder) in [("Make me a playlist of Rob Hubbard SIDs.", "Hubbard_Rob"), ("Play all the best Martin Galway tunes.", "Galway_Martin"),
                                   ("Jeroen Tel only, please.", "Tel_Jeroen"), ("Tim Follin tracks, especially the more complex ones.", "Follin_Tim"),
                                   ("Rob Hubbard bangers.", "Hubbard_Rob"), ("Wizball and other Galway classics.", "Galway_Martin")] {
            #expect(try folders(sentence) == [folder], "\(sentence)")
        }
    }

    @Test func severalComposers() throws {
        #expect(try folders("Give me a mix of Ben Daglish and Anthony Lees.") == ["Daglish_Ben", "Lees_Anthony"])
        #expect(try folders("Fred Gray and Mark Cooksey.") == ["Gray_Fred", "Cooksey_Mark"])
        let mix = try parsed("High-energy mix of Tel, Hubbard, and Follin.")
        #expect(Set(mix.composers.map(\.folder)) == ["Tel_Jeroen", "Hubbard_Rob", "Follin_Tim"])
        #expect(mix.energy == .intense)
    }

    @Test func negativesAreNotFlipped() throws {
        #expect(try parsed("Game music only, no demos.").section == .games)
        #expect(try parsed("Exclude demos, only commercial games.").section == .games)
        #expect(try parsed("Background SIDs, not too intense.").energy == .medium)
        let scene = try parsed("Alternative demoscene SIDs that are not too fast.")
        #expect(scene.section == .demos)
        #expect(scene.energy == .medium)
        #expect(try parsed("Slow and alternative SIDs only, no pure action stuff.").energy == .calm)
    }

    @Test func sectionsAndDecades() throws {
        #expect(try parsed("Demoscene SIDs.").section == .demos)
        let classic = try parsed("Classic 1980s game soundtracks.")
        #expect(classic.section == .games)
        #expect(classic.fromYear == 1980)
        let hubbard = try parsed("Any good Hubbard from the mid-80s.")
        #expect(hubbard.composers.first?.folder == "Hubbard_Rob")
        #expect(hubbard.fromYear == 1984)
        #expect(hubbard.toYear == 1986)
    }

    @Test func aTuneToSoundLike() throws {
        for (sentence, tune) in [("Songs that sound like Commando.", "commando"), ("Tunes similar to Wizball.", "wizball"),
                                 ("Anything that fingerprints close to Last Ninja.", "last ninja"),
                                 ("Playlists of tracks with the same vibe as Monty on the Run.", "monty on the run"),
                                 ("Find SIDs similar to this one: Commando", "commando"), ("Fingerprinted matches for Delta.", "delta"),
                                 ("Whatever is most similar to Wizball.", "wizball"), ("Playlist based on Commando by Rob Hubbard.", "commando")] {
            #expect(try parsed(sentence).tuneName == tune, "\(sentence)")
        }
    }

    @Test func severalTunes() throws {
        #expect(try parsed("More like Sanxion and International Karate.").tuneNames == ["sanxion", "international karate"])
        #expect(try parsed("International Karate, Sanxion, Delta.").tuneNames == ["international karate", "sanxion", "delta"])
        #expect(try parsed("Monty on the Run and Auf Wiedersehen Monty.").tuneNames == ["monty on the run", "auf wiedersehen monty"])
        #expect(try parsed("Cybernoid and Cybernoid II.").tuneNames == ["cybernoid", "cybernoid ii"])
        #expect(try parsed("Stuff from Delta, Knucklebusters, Crazy Comets.").tuneNames == ["delta", "knucklebusters", "crazy comets"])
        #expect(try parsed("Dark and moody, like Nemesis the Warlock or Parallax.").tuneNames == ["nemesis the warlock", "parallax"])
    }

    @Test func likeAComposerMeansThem() throws {
        let hubbard = try parsed("Tracks with strong bass and drums like Hubbard.")
        #expect(hubbard.composers.first?.folder == "Hubbard_Rob")
        #expect(hubbard.tuneNames.isEmpty)
        #expect(Set(hubbard.sounds) == [.bass, .drums])
        let galway = try parsed("Atmospheric filtered pieces like Galway.")
        #expect(galway.composers.first?.folder == "Galway_Martin")
        #expect(galway.sounds == [.filter])
        #expect(galway.energy == .calm)
    }

    @Test func aMoodWithATuneIsRelativeToIt() throws {
        let slower = try parsed("Similar to Cybernoid II but a bit slower.")
        #expect(slower.tuneName == "cybernoid ii")
        #expect(slower.energy == .calm)
        let fast = try parsed("Fast Rob Hubbard tracks similar to Commando.")
        #expect(fast.tuneName == "commando")
        #expect(fast.energy == .intense)
        #expect(fast.composers.first?.folder == "Hubbard_Rob")
    }

    @Test func soundsAndChips() throws {
        #expect(try parsed("Fast arpeggio-heavy tracks.").sounds == [.arpeggios])
        #expect(try parsed("Fast arpeggio-heavy tracks.").energy == .intense)
        #expect(try parsed("Songs that use heavy pulse-width modulation.").sounds == [.pulseWidth])
        #expect(try parsed("6581 SID chip preference.").chip == .mos6581)
        #expect(try parsed("8580 style if available.").chip == .mos8580)
        let chip = try parsed("Prefer 6581 filter character.")
        #expect(chip.chip == .mos6581)
        #expect(chip.sounds == [.filter])
    }

    @Test func lengthsAndCounts() throws {
        #expect(try parsed("A 30-minute SID playlist.").totalMinutes == 30)
        #expect(try parsed("One hour of continuous C64 music.").totalMinutes == 60)
        #expect(try parsed("About 20 tracks.").maxTunes == 20)
        #expect(try parsed("Short playlist, 10 songs max.").maxTunes == 10)
        #expect(try parsed("Long background playlist.").totalMinutes == 180)
    }

    @Test func shapes() throws {
        #expect(try parsed("A playlist that starts slow and gets faster.").shape == .rising)
        #expect(try parsed("Alternate between slow and fast.").shape == .alternating)
        #expect(try parsed("Something between slow and fast, mid-tempo.").energy == .medium)
    }

    @Test func whatCantBeToldIsSaid() throws {
        let moody = try parsed("Moody and dark Commodore 64 tunes.")
        #expect(moody.cantTell == ["dark", "moody"])
        #expect(moody.aside?.contains("Can't tell") == true)
        #expect(try parsed("Slow and melancholic.").energy == .calm)
        #expect(try parsed("Mix HVSC with my local SID collection.").asksForLocalFiles)
    }

    @Test(arguments: ["dual SID tunes", "dual sid", "2SID", "2 SID tunes", "two SID music", "double-SID"])
    func dualSid(sentence: String) throws {
        let parsed = try parsed(sentence)
        #expect(parsed.minChips == 2)
        #expect(parsed.maxChips == 2)
        #expect(parsed.maxTunes == nil)
        #expect(parsed.description().contains("Dual SID"))
    }

    @Test func otherChipCounts() throws {
        #expect(try parsed("triple SID").minChips == 3)
        #expect(try parsed("3SID tunes").maxChips == 3)
        #expect(try parsed("single SID only").maxChips == 1)
        let stereo = try parsed("stereo Rob Hubbard")
        #expect(stereo.minChips == 2)
        #expect(stereo.maxChips == nil)
        #expect(stereo.composers.first?.folder == "Hubbard_Rob")
    }

    @Test func dualSidCombines() throws {
        let parsed = try parsed("fast dual SID 8580 tunes from the 2010s")
        #expect(parsed.minChips == 2)
        #expect(parsed.chip == .mos8580)
        #expect(parsed.energy == .intense)
        #expect(parsed.fromYear == 2010)
    }

    @Test func twentySidsIsStillACount() throws {
        #expect(try parsed("20 SIDs").maxTunes == 20)
        #expect(try parsed("20 SIDs").minChips == nil)
    }

    @Test func moodsInAListAreNotTitles() throws {
        let parser = SmartSentenceParser(composers: [], titles: ["Slow Music", "Party Music", "Crazy Comets", "Delta"])
        let moods = try #require(parser.parse("play slow music, party music"))
        #expect(moods.tuneNames.isEmpty)
        #expect(moods.shape == .rising)
        #expect(try #require(parser.parse("Delta and Crazy Comets")).tuneNames == ["delta", "crazy comets"])
    }

    @Test func commodore64IsNotACount() throws {
        #expect(parser.parse("Best Commodore 64 tunes.")?.maxTunes == nil)
        #expect(try parsed("Fast, energetic C64 music.").energy == .intense)
    }

    @Test func aTuneAndWhatFollowsItsName() throws {
        #expect(try parsed("The Last Ninja trilogy.").tuneName == "the last ninja")
        #expect(try parsed("Anything close to the Last Ninja 2 theme.").tuneName == "the last ninja 2")
        #expect(try folders("Songs that match the style of Hubbard's drum patterns.") == ["Hubbard_Rob"])
        #expect(try parsed("Songs that match the style of Hubbard's drum patterns.").sounds == [.drums])
    }

    @Test func aTitleListDoesntBecomeAMood() throws {
        let comets = try parsed("Stuff from Delta, Knucklebusters, Crazy Comets.")
        #expect(comets.energy == .any)
        #expect(parser.parse("Moody and dark Commodore 64 tunes.")?.tuneNames == [])
        #expect(try parsed("Songs that use heavy pulse-width modulation.").energy == .any)
    }

    @Test func aNameIsStillJustASearch() throws {
        #expect(!(try parsed("Rob Hubbard")).asksForAList)
        #expect(!(try parsed("Songs similar to Last Ninja.")).asksForAList)
        #expect(try parsed("Tel and Hubbard").asksForAList)
    }
}
