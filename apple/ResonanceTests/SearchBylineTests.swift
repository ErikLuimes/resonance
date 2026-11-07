import PhosphorCore
import Testing
@testable import Resonance

@MainActor
struct SearchBylineTests {
    @Test func aComposerSoundsLikeOne() {
        #expect(SearchByline.text(author: "Tel, Jeroen", category: .musicians, length: "0:32") == "Jeroen Tel \u{B7} 0:32")
        #expect(SearchByline.text(author: "SLO", category: .musicians, length: "1:05") == "SLO \u{B7} 1:05")
    }

    /// The folders of Games and Demos, which say nothing about who made a tune.
    @Test(arguments: ["S-Z", "G-L", "A-F", "0-9"])
    func aLetterRangeIsNoName(folder: String) {
        #expect(SearchByline.text(author: folder, category: .games, length: "1:00") == "1:00")
        #expect(SearchByline.text(author: folder, category: .demos, length: "1:00") == "1:00")
    }

    /// In MUSICIANS a folder is a person, whatever it looks like.
    @Test func aComposerCanHaveAHyphen() {
        #expect(SearchByline.text(author: "A-Man", category: .musicians, length: "2:00") == "A-Man \u{B7} 2:00")
        #expect(SearchByline.text(author: "4-Mat", category: .musicians, length: "2:00") == "4-Mat \u{B7} 2:00")
    }

    @Test(arguments: ["UNKNOWN", "<?>"])
    func unknownSaysSo(author: String) {
        #expect(SearchByline.text(author: author, category: .demos, length: "1:46") == "Unknown \u{B7} 1:46")
    }
}
