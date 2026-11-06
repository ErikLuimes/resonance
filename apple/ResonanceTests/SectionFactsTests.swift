import PhosphorCore
import Testing
@testable import Resonance

private func row(_ title: String, released: String = "1987 Ocean", secs: UInt32? = 100, noted: Bool = false) -> LibraryRow {
    LibraryRow(item: HvscTuneItem(path: "/HVSC/GAMES/A-F/\(title).sid", title: title, author: "Somebody", released: released,
                                  songs: 1, startSong: 1, durationSecs: secs, hasStil: noted, isRsid: false, category: .games))
}

struct SectionIdentityTests {
    @Test func aLetterRangeSaysWhichCategoryItIsIn() {
        let games = SectionIdentity(name: "A-F", category: .games)
        #expect(games.title == "Games A-F")
        #expect(games.kind == nil)
        #expect(games.tile == "A-F")
        #expect(games.description == "Music from games, filed A to F by title, by composers with fewer than three tunes in HVSC, or none known.")
        let demos = SectionIdentity(name: "0-9", category: .demos)
        #expect(demos.title == "Demos 0-9")
        #expect(demos.description == "Music from demos, filed 0 to 9 by title, by composers with fewer than three tunes in HVSC.")
    }

    @Test func theSpecialFoldersGetTheirOwnWords() {
        let unknown = SectionIdentity(name: "UNKNOWN", category: .demos)
        #expect(unknown.title == "Unknown Composers")
        #expect(unknown.kind == "demo")
        #expect(unknown.tile == "?")
        #expect(unknown.description == "Music from demos whose composers aren't known.")
        let commodore = SectionIdentity(name: "Commodore", category: .demos)
        #expect(commodore.title == "Commodore")
        #expect(commodore.description?.contains("test disks") == true)
    }

    @Test func aFolderItKnowsNothingAboutJustKeepsItsName() {
        let other = SectionIdentity(name: "New_Folder", category: .games)
        #expect(other.title == "New_Folder")
        #expect(other.kind == "game")
        #expect(other.description == nil)
    }
}

struct SectionFactsTests {
    @Test func yearsRunFromFirstToLastWithQuietYearsIncluded() {
        let facts = SectionFacts(rows: [row("A", released: "1987 Ocean"), row("B", released: "1984 Ocean"),
                                        row("C", released: "1987 Firebird"), row("D", released: "198? Firebird")])
        #expect(facts.years.map(\.year) == [1984, 1985, 1986, 1987])
        #expect(facts.years.map(\.tunes) == [1, 0, 0, 2])
        #expect(facts.undated == 1)
        #expect(facts.withoutExactYear == "1 tune")
    }

    @Test func theBusiestYearIsTheEarliestOnATie() {
        let facts = SectionFacts(rows: [row("A", released: "1985"), row("B", released: "1984")])
        #expect(facts.busiest == .init(year: 1984, tunes: 1))
        #expect(facts.busiestText == "Most in 1984: 1 tune")
    }

    @Test func aTypoInAHeaderDoesNotMakeAChartOfCenturies() {
        let facts = SectionFacts(rows: [row("A", released: "0198 Oops"), row("B", released: "1987")])
        #expect(facts.years.map(\.year) == [1987])
        #expect(facts.undated == 1)
    }

    @Test func noDatesMeansNoChart() {
        let facts = SectionFacts(rows: [row("A", released: "19?? <?>")])
        #expect(facts.years.isEmpty)
        #expect(facts.busiest == nil)
        #expect(facts.oldest.isEmpty)
        #expect(facts.newest.isEmpty)
    }

    @Test func longestLeavesOutUnknownLengths() {
        let facts = SectionFacts(rows: [row("Short", secs: 10), row("Unknown", secs: nil), row("Long", secs: 500), row("Also long", secs: 500)])
        #expect(facts.longest.map(\.title) == ["Also long", "Long", "Short"])
        #expect(facts.playingSeconds == 1010)
    }

    @Test func newestNeverRepeatsWhatOldestLists() {
        let rows = (0..<7).map { row("T\($0)", released: "\(1980 + $0) Ocean") }
        let facts = SectionFacts(rows: rows)
        #expect(facts.oldest.map(\.title) == ["T0", "T1", "T2", "T3", "T4"])
        #expect(facts.newest.map(\.title) == ["T6", "T5"])
        #expect(SectionFacts(rows: Array(rows.prefix(2))).newest.isEmpty)
    }

    @Test func releasersCountFromTwoTunesUp() {
        let facts = SectionFacts(rows: [row("A", released: "1987 Ocean"), row("B", released: "1988 Ocean"), row("C", released: "1987 Firebird"),
                                        row("D", released: "198? Firebird <?>"), row("E", released: "1989 Firebird"), row("F", released: "1990 Lone Wolf")])
        #expect(facts.releasers == [.init(name: "Firebird", tunes: 3), .init(name: "Ocean", tunes: 2)])
    }

    @Test func aReleaserComesFromAfterTheYear() {
        #expect(row("A", released: "1984 Parker Bros").releaser == "Parker Bros")
        #expect(row("A", released: "198? S+S Soft Vertriebs GmbH").releaser == "S+S Soft Vertriebs GmbH")
        #expect(row("A", released: "1989-90 ShareData").releaser == "ShareData")
        #expect(row("A", released: "1987 Ocean <?>").releaser == "Ocean")
        #expect(row("A", released: "Firebird").releaser == "Firebird")
        #expect(row("A", released: "19?? <?>").releaser == nil)
        #expect(row("A", released: "<?>").releaser == nil)
        #expect(row("A", released: "1987").releaser == nil)
        #expect(row("A", released: "").releaser == nil)
    }

    @Test func playingTimeIsInWords() {
        func text(_ seconds: UInt32) -> String? { SectionFacts(rows: [row("A", secs: seconds)]).playingTime }
        #expect(text(0) == nil)
        #expect(text(20) == "Under a minute")
        #expect(text(70) == "About a minute")
        #expect(text(600) == "About 10 minutes")
        #expect(text(3600) == "About an hour")
        #expect(text(36000) == "About 10 hours")
    }

    @Test func notesAreCounted() {
        #expect(SectionFacts(rows: [row("A")]).notes == nil)
        #expect(SectionFacts(rows: [row("A", noted: true)]).notes == "On 1 tune")
        #expect(SectionFacts(rows: [row("A", noted: true), row("B", noted: true)]).notes == "On 2 tunes")
    }
}

struct SoundShareTests {
    @Test func mostCommonFirstWithoutTheOnesNotPresent() {
        let shares = SectionFacts.soundShares(tags: [[.noiseDrums, .arpeggios], [.noiseDrums], [], [.noiseDrums, .ringMod]],
                                              overall: [.noiseDrums: 0.76])
        #expect(shares.map(\.tag) == [.noiseDrums, .arpeggios, .ringMod])
        #expect(shares[0].share == 0.75)
        #expect(shares[0].overall == 0.76)
        #expect(shares[1].overall == nil)
    }

    @Test func nothingFingerprintedMeansNoCard() {
        #expect(SectionFacts.soundShares(tags: [], overall: [:]).isEmpty)
        #expect(SectionFacts.soundShares(tags: [[], []], overall: [:]).isEmpty)
    }

    @Test func itStopsAtTheLimit() {
        let shares = SectionFacts.soundShares(tags: [SoundTag.all], overall: [:], limit: 5)
        #expect(shares.count == 5)
        #expect(shares.map(\.tag) == Array(SoundTag.all.prefix(5)), "a tie keeps a fixed order")
    }
}
