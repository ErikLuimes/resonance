import CoreGraphics
import Testing
@testable import Resonance

@MainActor
struct CreditsTests {
    private let hubbard = CreditsScene.Tune(title: "Commando", author: "Rob Hubbard")

    /// Pixels at least this bright in the picture.
    private func lit(_ image: CGImage?, above level: UInt8 = 200) -> Int {
        guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * image.bytesPerRow + x * 4 + 1] >= level { count += 1 }
        }
        return count
    }

    @Test func itRunsInTheOrderOfTheScript() {
        let t = CreditsScene.timing
        #expect(0 < t.cameraStarts)
        #expect(t.cameraStarts < t.lettersStart)
        #expect(t.lettersStart < t.settleFrom)
        #expect(t.settleFrom < t.namesFrom)
    }

    @Test func thePictureIsTheSizeItWasDesignedAt() {
        let image = CreditsRenderer().image(seconds: 3, tune: nil, still: false)
        #expect(image?.width == 320)
        #expect(image?.height == 200)
    }

    @Test func nameAndFirstWordsAreOnScreenWhenTheyShouldBe() {
        #expect(!CreditsScene.letters(seconds: 3).isEmpty)
        #expect(!CreditsScene.letters(seconds: CreditsScene.timing.lettersStart + 1).isEmpty)
        #expect(lit(CreditsRenderer().image(seconds: 3, tune: nil, still: false)) > 500)
    }

    @Test func theLettersAreGoneBeforeTheStarsSettle() {
        #expect(CreditsScene.letters(seconds: CreditsScene.timing.settleFrom + 0.01).allSatisfy { letter in
            letter.shapes.allSatisfy { shape in shape.allSatisfy { $0.0 < 0 || $0.0 > 320 || $0.1 < 0 || $0.1 > 200 } }
        })
    }

    @Test func theLettersNeverSpinFast() {
        let t = CreditsScene.timing
        var fastest = 0.0, s = t.lettersStart
        while s < t.namesFrom {
            let at = { (s: Double) in CreditsScene.turned(s, rate: CreditsScene.spinRate, from: t.lettersStart) }
            fastest = max(fastest, (at(s + 0.02) - at(s)) / 0.02)
            s += 0.02
        }
        #expect(fastest <= CreditsScene.spinRate + 0.01)
    }

    @Test func nothingJumpsOnceSettled() {
        let t = CreditsScene.timing
        let end = t.settleFrom + 3
        #expect(CreditsScene.turned(end, rate: 0.55, from: t.cameraStarts) == CreditsScene.turned(end + 20, rate: 0.55, from: t.cameraStarts))
    }

    @Test func starsAreThereAllTheWay() {
        for seconds in [0.5, 10, CreditsScene.timing.namesFrom + 1] {
            #expect(CreditsScene.stars(seconds: seconds).count > 20)
        }
    }

    @Test func theNamesAreAllHereAndFit() {
        let pages = CreditsScene.pages(tune: hubbard)
        for name in ["ERIK LUIMES", "CLAUDE", "TRITON", "INIGO QUILEZ", "ROB HUBBARD"] {
            #expect(pages.contains { $0[1] == name }, "\(name)")
        }
        #expect(pages.contains(["SKULL SURGEON", "INIGO QUILEZ", "DISTANCE FUNCTIONS"]))
        #expect(pages.contains(["ALL RESPECT TO THE DEMOSCENE", "TRITON", "WE FORGIVE THE PC"]))
        for page in pages {
            #expect(page[0].count * 6 <= 320 && page[1].count * 12 <= 320 && page[2].count * 6 <= 320, "\(page)")
        }
    }

    @Test func everyLetterOfTheNamesCanBeDrawn() {
        for page in CreditsScene.pages(tune: hubbard) {
            for letter in page.joined() where letter != " " {
                #expect(!CreditsScene.bitmapColumns(letter).isEmpty, "\(letter)")
            }
        }
    }

    @Test func theLastPageNamesWhatIsPlaying() {
        #expect(CreditsScene.pages(tune: hubbard).last == ["ACTUALLY DOING THE WORK", "ROB HUBBARD", "COMMANDO, NOW PLAYING"])
    }

    @Test func anUnknownComposerLeavesTheTuneOnItsOwn() {
        let page = CreditsScene.pages(tune: .init(title: "Commando", author: "<?>")).last
        #expect(page == ["ACTUALLY DOING THE WORK", "COMMANDO", "NOW PLAYING"])
    }

    @Test func accentsAndLongNamesStillFit() {
        let page = CreditsScene.pages(tune: .init(title: String(repeating: "Lön", count: 40), author: "Chris Hülsbeck")).last
        #expect(page?[1] == "CHRIS HULSBECK")
        #expect((page?[2].count ?? 99) <= 53)
    }

    @Test func nothingPlayingLeavesThatPageOutAndItRunsShorter() {
        #expect(CreditsScene.pages(tune: nil).count + 1 == CreditsScene.pages(tune: hubbard).count)
        #expect(CreditsScene.length(tune: nil) + CreditsScene.hold == CreditsScene.length(tune: hubbard))
    }

    @Test func aMomentAlwaysDrawsTheSame() {
        let renderer = CreditsRenderer()
        #expect(lit(renderer.image(seconds: 12.3, tune: nil, still: false)) == lit(CreditsRenderer().image(seconds: 12.3, tune: nil, still: false)))
    }

    @Test func aNameIsPlacedAndOnScreenMidway() {
        let place = CreditsScene.placed(letter: 2, of: 11, row: 1, moment: 0.5, elapsed: 2)
        #expect(place.isOn && place.x == 0 && place.y == 0)
        #expect(!CreditsScene.placed(letter: 2, of: 11, row: 1, moment: 0, elapsed: 0).isOn)
        #expect(!CreditsScene.placed(letter: 2, of: 11, row: 1, moment: 0.99, elapsed: 3).isOn)
    }

    @Test func withReduceMotionTheNamesStandStill() {
        let t = CreditsScene.timing.namesFrom
        let renderer = CreditsRenderer()
        let first = lit(renderer.image(seconds: t + 0.1, tune: nil, still: true), above: 240)
        let second = lit(renderer.image(seconds: t + 3.9, tune: nil, still: true), above: 240)
        #expect(first > 50)
        #expect(first == second)
    }

    @Test func pastTheEndIsEmptySpaceNotACrash() {
        #expect(CreditsRenderer().image(seconds: CreditsScene.length(tune: nil) + 30, tune: nil, still: false) != nil)
    }
}
