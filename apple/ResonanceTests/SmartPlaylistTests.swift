import Testing
@testable import Resonance

struct SmartSettingsTests {
    @Test func eachStartSetsWhatItMeans() {
        var settings = SmartSettings()
        settings.begin(.neverHeard)
        #expect(settings.onlyUnheard)
        #expect(settings.totalMinutes == nil)
        settings.begin(.chillToIntense)
        #expect(!settings.onlyUnheard)
        #expect(settings.totalMinutes == 60)
        settings.begin(.like)
        #expect(settings.minMinutes == 2)
        #expect(settings.totalMinutes == nil)
    }

    @Test func aSeedStaysWhenGoingToAnotherStartAndBack() {
        var settings = SmartSettings()
        settings.seed = .init(path: "/a.sid", title: "2nd Reality (part 2)", author: "KB")
        settings.begin(.neverHeard)
        settings.begin(.like)
        #expect(settings.title == "Like 2nd Reality (part 2)")
    }

    @Test func theRecipeCarriesTheSettings() {
        var settings = SmartSettings()
        settings.seed = .init(path: "/a.sid", title: "A", author: "B")
        settings.closeness = .veryClose
        let recipe = settings.recipe
        #expect(recipe.kind == .like)
        #expect(recipe.seed == "/a.sid")
        #expect(recipe.top == 50)
        #expect(recipe.minSecs == 120)
    }

    @Test func lengthsSayAsMuchAsIsUseful() {
        #expect(SmartFacts.tunes(19, secs: 3678) == "19 tunes, 61 minutes")
        #expect(SmartFacts.tunes(1, secs: 60) == "1 tune, 1 minute")
        #expect(SmartFacts.tunes(155, secs: 32_280) == "155 tunes, 8 h 58 min")
        #expect(SmartFacts.tunes(59_888, secs: 8_452_800) == "\(59_888.formatted()) tunes, about \(2_348.formatted()) hours")
    }

    @Test func aSentenceBecomesSettings() {
        let parsed = SmartSentenceReader.map("chillToIntense", tuneName: " ", minimum: 0, total: 60, onlyUnheard: false)
        #expect(parsed.sentence.start == .chillToIntense)
        #expect(parsed.sentence.totalMinutes == 60)
        #expect(parsed.sentence.minMinutes == nil)
        #expect(parsed.tuneName == nil)
    }

    @Test func aSentenceKeepsTheTuneNameToLookUp() {
        let parsed = SmartSentenceReader.map("like", tuneName: "Second Reality", minimum: 2, total: 0, onlyUnheard: false)
        #expect(parsed.tuneName == "Second Reality")
        #expect(parsed.sentence.minMinutes == 2)
    }

    @Test func anUnknownStartFallsBackToLike() {
        #expect(SmartSentenceReader.map("party", tuneName: "", minimum: 0, total: 0, onlyUnheard: false).sentence.start == .like)
    }
}

/// The sentences the feature was asked for, and a few like them.
struct SmartSentenceParserTests {
    @Test func likeASong() throws {
        let parsed = try #require(SmartSentenceParser.parse("Playlist with all songs like second reality"))
        #expect(parsed.sentence.start == .like)
        #expect(parsed.tuneName == "second reality")
        #expect(parsed.sentence.minMinutes == nil)
        #expect(parsed.sentence.totalMinutes == nil)
    }

    @Test func chillToIntenseForAnHour() throws {
        let parsed = try #require(SmartSentenceParser.parse("Playlist with slow chill music and increasing in intensity at the end, 1 hour playlist"))
        #expect(parsed.sentence.start == .chillToIntense)
        #expect(parsed.sentence.totalMinutes == 60)
        #expect(parsed.tuneName == nil)
    }

    @Test func randomUnheard() throws {
        let parsed = try #require(SmartSentenceParser.parse("Random playlist all unheard songs"))
        #expect(parsed.sentence.start == .neverHeard)
        #expect(parsed.sentence.onlyUnheard)
    }

    @Test func longerThanAndSimilarTo() throws {
        let parsed = try #require(SmartSentenceParser.parse("Search all songs longer than 2 minutes similar to second reality"))
        #expect(parsed.sentence.start == .like)
        #expect(parsed.sentence.minMinutes == 2)
        #expect(parsed.sentence.totalMinutes == nil)
        #expect(parsed.tuneName == "second reality")
    }

    @Test func newToMe() throws {
        let parsed = try #require(SmartSentenceParser.parse("new to me: analyze play history and play something opposite"))
        #expect(parsed.sentence.start == .newToMe)
    }

    @Test func theNameEndsWhereTheSentenceMovesOn() throws {
        let parsed = try #require(SmartSentenceParser.parse("Tunes like Comic Bakery, over 3 minutes, for 2 hours"))
        #expect(parsed.tuneName == "Comic Bakery")
        #expect(parsed.sentence.minMinutes == 3)
        #expect(parsed.sentence.totalMinutes == 120)
    }

    @Test func nothingToGoOn() {
        #expect(SmartSentenceParser.parse("something nice please") == nil)
    }
}
