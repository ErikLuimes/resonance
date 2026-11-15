import Foundation
import Testing
@testable import Resonance

struct ComposerFactsTests {
    @Test func aFolderWithAHandleInFrontReadsAsTheRealName() {
        #expect(ComposerFacts.shownName("Red Kimmel, Jeroen", realName: "Jeroen Kimmel") == "Jeroen Kimmel")
        #expect(ComposerFacts.shownName("Tron Olsson, Mikael", realName: "Mikael Olsson") == "Mikael Olsson")
    }

    @Test func otherNamesStayAsTheyAre() {
        #expect(ComposerFacts.shownName("Hubbard, Rob", realName: "Rob Hubbard") == "Rob Hubbard")
        #expect(ComposerFacts.shownName("Stinsen", realName: "Johan Samuelson") == "Stinsen")
        #expect(ComposerFacts.shownName("The Mad Axeman", realName: "Some Person") == "The Mad Axeman")
        #expect(ComposerFacts.shownName("Tel, Jeroen", realName: nil) == "Jeroen Tel")
        // A single word in common isn't a name found.
        #expect(ComposerFacts.shownName("The Wise Man", realName: "Man") == "The Wise Man")
    }

    @Test func tuneCountSaysAsMuchAsIsKnown() {
        #expect(ComposerFacts.tunes(176, firstYear: 1986, lastYear: 2020) == "176 tunes from 1986 to 2020")
        #expect(ComposerFacts.tunes(1, firstYear: 1987, lastYear: 1987) == "1 tune from 1987")
        #expect(ComposerFacts.tunes(3, firstYear: nil, lastYear: nil) == "3 tunes")
        #expect(ComposerFacts.tunes(1376, kind: "demo", firstYear: 1983, lastYear: 2026) == "\(1376.formatted()) demo tunes from 1983 to 2026")
        #expect(ComposerFacts.tunes(1, kind: "demo", firstYear: nil, lastYear: nil) == "1 demo tune")
    }

    @Test func aRealNameThatRepeatsTheNameIsLeftOut() {
        #expect(ComposerFacts.realName("Matt Simmonds", shownAs: "4-Mat") == "Matt Simmonds")
        #expect(ComposerFacts.realName("Ari Yliaho", shownAs: "Ari Yliaho") == nil)
        #expect(ComposerFacts.realName("Hulsbeck Chris", shownAs: "Chris Hülsbeck") == nil)
        #expect(ComposerFacts.realName(nil, shownAs: "Agemixer") == nil)
    }
}

struct ComposerGroupsTests {
    @Test func aFormationDateOnlyGoesWithOneGroup() {
        #expect(ComposerFacts.groups(["Maniacs of Noise (MON)"], formed: "1987") == "Maniacs of Noise (MON), formed 1987")
        #expect(ComposerFacts.groups(["Ate Bit", "Orb"], formed: "1987") == "Ate Bit, Orb")
        #expect(ComposerFacts.groups(["Orb"], formed: nil) == "Orb")
        #expect(ComposerFacts.groups([], formed: "1987") == nil)
    }
}

struct ComposerCarouselTests {
    @Test func aWiderCarouselShowsMoreCardsButLeavesNoGap() {
        #expect(HeaderCards.perPage(width: 200, cards: 5) == 1)
        #expect(HeaderCards.perPage(width: 480, cards: 5) == 2)
        #expect(HeaderCards.perPage(width: 2000, cards: 5) == 3)
        #expect(HeaderCards.perPage(width: 480, cards: 1) == 1)
        #expect(HeaderCards.perPage(width: 480, cards: 0) == 1)
    }

    @Test func cardsFillPagesInOrder() {
        let cards = [1, 2, 3, 4, 5]
        #expect(HeaderCards.pages(cards, perPage: 1).count == 5)
        #expect(HeaderCards.pages(cards, perPage: 2) == [[1, 2], [3, 4], [5]])
        #expect(HeaderCards.pages([Int](), perPage: 2).isEmpty)
    }
}

struct StartPageTests {
    @Test func opensOnWhatWasChosen() {
        #expect(StartPage.favorites.item(csdbEnabled: true) == .favorites)
        #expect(StartPage.musicians.item(csdbEnabled: true) == .hvsc(.musicians))
    }

#if CSDB
    @Test func scenePulseFallsBackWithCSDbOff() {
        #expect(StartPage.scenePulse.item(csdbEnabled: true) == .scene)
        #expect(StartPage.scenePulse.item(csdbEnabled: false) == .hvscHome)
    }
#endif

    @Test func myPlaylistUntilChosen() {
        let defaults = UserDefaults(suiteName: "StartPage.\(UUID().uuidString)")!
        #expect(StartPage.saved(in: defaults) == .myPlaylist)
        defaults.set("favorites", forKey: Pref.startPage)
        #expect(StartPage.saved(in: defaults) == .favorites)
        defaults.set("gone", forKey: Pref.startPage)
        #expect(StartPage.saved(in: defaults) == .myPlaylist)
    }
}
