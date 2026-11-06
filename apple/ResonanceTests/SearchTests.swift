import Foundation
import Testing
import PhosphorCore
@testable import Resonance

struct SearchTopResultTests {
    private func composer(_ displayName: String, folder: String) -> HvscAuthorItem {
        HvscAuthorItem(name: folder, displayName: displayName, letter: String(displayName.prefix(1)),
                       path: "/HVSC/MUSICIANS/\(folder)")
    }

    private func tune(_ title: String) -> LibraryRow {
        LibraryRow(item: HvscTuneItem(path: "/HVSC/\(title).sid", title: title, author: "Someone", released: "1987",
                                      songs: 1, startSong: 1, durationSecs: 120, hasStil: false, isRsid: false,
                                      category: .musicians))
    }

    private let galway = "Galway, Martin"

    @Test func anExactComposerNameComesFirst() {
        let wells = composer("Wells, Galway", folder: "Wells_Galway")
        let martin = composer(galway, folder: "Galway_Martin")
        // In any word order, and ahead of a composer ranked higher.
        #expect(SearchTopResult.pick(query: "martin galway", composers: [wells, martin], tunes: [tune("Galway")])
                == .composer(martin))
        #expect(SearchTopResult.pick(query: "GALWAY, MARTIN", composers: [wells, martin], tunes: [])
                == .composer(martin))
    }

    @Test func theBestComposerBeatsTheBestTune() {
        let martin = composer(galway, folder: "Galway_Martin")
        #expect(SearchTopResult.pick(query: "galway", composers: [martin], tunes: [tune("Galway")])
                == .composer(martin))
    }

    @Test func aTuneWhenNoComposerMatches() {
        let commando = tune("Commando")
        #expect(SearchTopResult.pick(query: "commando", composers: [], tunes: [commando, tune("Commando 2")])
                == .tune(commando))
    }

    @Test func nothingWhenNothingMatches() {
        #expect(SearchTopResult.pick(query: "zzz", composers: [], tunes: []) == nil)
    }
}
