import AppKit
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
        #expect(CreditsScene.pages(tune: hubbard).dropLast().last == ["ACTUALLY DOING THE WORK", "ROB HUBBARD", "COMMANDO, NOW PLAYING"])
    }

    @Test func theLastPageThanksYou() {
        let you = ["AND MOST OF ALL", "YOU", "THANKS FOR LISTENING"]
        #expect(CreditsScene.pages(tune: hubbard).last == you)
        #expect(CreditsScene.pages(tune: nil).last == you)
    }

    @Test func anUnknownComposerLeavesTheTuneOnItsOwn() {
        let page = CreditsScene.pages(tune: .init(title: "Commando", author: "<?>")).dropLast().last
        #expect(page == ["ACTUALLY DOING THE WORK", "COMMANDO", "NOW PLAYING"])
    }

    @Test func accentsAndLongNamesStillFit() {
        let page = CreditsScene.pages(tune: .init(title: String(repeating: "Lön", count: 40), author: "Chris Hülsbeck")).dropLast().last
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

    private func inTheMiddle(_ elapsed: Double, _ from: Double) -> Int {
        CreditsScene.heartStars(elapsed: elapsed, endingFrom: from, still: false).filter { $0.alpha > 0 && abs($0.x - 160) < 85 && abs($0.y - 100) < 85 }.count
    }

    @Test func theHeartIsTwoThirdsOfTheStarsAndNothingElse() {
        let from = CreditsScene.endingFrom(tune: hubbard)
        let formed = CreditsScene.heartStars(elapsed: CreditsScene.collapse + 0.5, endingFrom: from, still: false).filter { $0.alpha > 0 }
        #expect(formed.count <= 500, "nothing but the stars")
        #expect(inTheMiddle(CreditsScene.collapse + 0.5, from) >= 325, "two-thirds of them")
        #expect(inTheMiddle(CreditsScene.collapse * 0.4, from) < inTheMiddle(CreditsScene.collapse, from) / 2, "they fly in")
    }

    @Test func someOfTheHeartIsInsideIt() {
        let inside = CreditsScene.heartPlaces.filter { abs($0[0]) < 0.8 && abs($0[1]) < 0.8 && abs($0[2]) < 0.8 }
        #expect(inside.count > 40, "\(inside.count)")
        let depths = CreditsScene.heartPlaces.map { $0[2] }
        #expect((depths.max() ?? 0) - (depths.min() ?? 0) > 1.5, "with depth to fly through")
    }

    @Test func itBeatsTwiceAndBurstsOnTheThird() {
        let onsets = stride(from: 0.0, to: CreditsScene.beating - 0.01, by: 0.005).filter { CreditsScene.beat($0) == 0 && CreditsScene.beat($0 + 0.005) > 0 }
        #expect(onsets.count == 2, "\(onsets)")
        #expect(CreditsScene.beating > 1.8 && CreditsScene.beating < 2.8, "\(CreditsScene.beating)")
    }

    @Test func theBurstThrowsTheHeartOutwardsAndItAllEndsInBlack() {
        let from = CreditsScene.endingFrom(tune: hubbard)
        let bursts = CreditsScene.collapse + CreditsScene.beating
        #expect(inTheMiddle(bursts + 3.5, from) < inTheMiddle(bursts - 0.1, from) * 3 / 4)
        let end = bursts + CreditsScene.burst + CreditsScene.fadeOut + 0.01
        #expect(CreditsScene.heartStars(elapsed: end, endingFrom: from, still: false).allSatisfy { $0.alpha == 0 })
        #expect(lit(CreditsRenderer().image(seconds: CreditsScene.length(tune: hubbard) - 0.1, tune: hubbard, still: false), above: 30) == 0)
        #expect(lit(CreditsRenderer().image(seconds: from + CreditsScene.collapse + 0.5, tune: hubbard, still: false), above: 150) > 100)
    }

    @Test func theSphereOnlySaysWhenAStarStartsToMove() {
        let near = [0.3, 0, 0], far = [2.0, 0, 0]
        // Near the middle it's started; further out the sphere hasn't arrived.
        #expect(CreditsScene.drifted(near, star: 1, seconds: 0.3)[0] > 0.3)
        #expect(CreditsScene.drifted(far, star: 1, seconds: 0.3)[0] == 2.0)
        // Starting gently, and each at its own speed.
        let at = { (s: Double, star: Int) in CreditsScene.drifted(near, star: star, seconds: s)[0] }
        #expect(at(0.3, 1) - 0.3 < at(1.5, 1) - at(1.2, 1), "it starts gently")
        let speeds = Set((0..<40).map { (at(2, $0) * 100).rounded() })
        #expect(speeds.count > 20, "\(speeds.count)")
        // Dead centre still goes somewhere.
        let centre = CreditsScene.drifted([0, 0, 0], star: 3, seconds: 1)
        #expect(centre.map(abs).max() ?? 0 > 0)
    }

    @Test func itDoesNotExplodeAsACircleOnScreen() {
        let from = CreditsScene.endingFrom(tune: nil)
        let stars = CreditsScene.heartStars(elapsed: CreditsScene.collapse + CreditsScene.beating + 2, endingFrom: from, still: false).filter { $0.alpha > 0.05 }
        let reaches = stars.map { hypot($0.x - 160, $0.y - 100) }
        let mean = reaches.reduce(0, +) / Double(max(reaches.count, 1))
        let spread = (reaches.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(reaches.count, 1))).squareRoot()
        #expect(reaches.count > 50)
        #expect(spread / mean > 0.3, "\(spread / mean): a filled scatter, not a ring")
        #expect(reaches.filter { $0 < mean / 2 }.count > 5, "with stars still in the middle")
    }

    @Test func theCameraMovesAfterTheFirstBeatAndNotBefore() {
        #expect(CreditsScene.firstBeat > 0.8 && CreditsScene.firstBeat < CreditsScene.beating)
        let from = CreditsScene.endingFrom(tune: nil)
        let at = { (s: Double) in CreditsScene.heartStars(elapsed: CreditsScene.collapse + s, endingFrom: from, still: false).map { ($0.x * 100).rounded() } }
        #expect(at(CreditsScene.firstBeat + 0.3) != at(CreditsScene.firstBeat + 0.9))
    }

    @Test func nothingFadesInDuringTheBurst() {
        let from = CreditsScene.endingFrom(tune: nil)
        let bursts = CreditsScene.collapse + CreditsScene.beating
        let bright = { (s: Double) in CreditsScene.heartStars(elapsed: bursts + s, endingFrom: from, still: false).reduce(0) { $0 + $1.alpha } }
        var last = bright(0)
        for tenth in 1...40 {
            let now = bright(Double(tenth) / 10)
            #expect(now <= last + 3, "at \(Double(tenth) / 10): \(last) then \(now)")
            last = now
        }
    }

    @Test func theHeartBeatsSoftlyThenRests() {
        let moments = stride(from: 0.0, to: 40, by: 0.005).map { ($0, CreditsScene.beat($0)) }
        let peak = moments.map(\.1).max() ?? 0
        #expect(peak > 0.03 && peak < 0.05, "\(peak)")
        #expect(Double(moments.filter { $0.1 == 0 }.count) / Double(moments.count) > 0.55, "a flat pause most of the time")
        var starts: [Double] = []
        for (before, now) in zip(moments, moments.dropFirst()) where before.1 == 0 && now.1 > 0 { starts.append(now.0) }
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }
        #expect(abs(Double(gaps.count) - 40 * 52 / 60) < 2, "about 52 a minute")
        #expect((gaps.max() ?? 0) - (gaps.min() ?? 0) > 0.08, "the gaps drift with the breath")
        #expect(CreditsScene.beat(12.3) == CreditsScene.beat(12.3))
    }

    @Test func theHeartIsDrawnFineAndTheNamesAreNot() {
        let renderer = CreditsRenderer()
        let from = CreditsScene.endingFrom(tune: hubbard)
        #expect(renderer.image(seconds: from - 1, tune: hubbard, still: false)?.width == 320)
        #expect(renderer.image(seconds: from + 4, tune: hubbard, still: false)?.width == 1280)
    }

    @Test func withReduceMotionTheHeartStandsStill() {
        let from = CreditsScene.endingFrom(tune: nil)
        let at = { (s: Double) in CreditsScene.heartStars(elapsed: s, endingFrom: from, still: true).map { ($0.x * 1000).rounded() } }
        #expect(at(0.1) == at(1.9))
    }

    /// With `CREDITS_RENDER` set to a folder, draws the ending there to look at.
    @Test func renders() throws {
        guard let folder = ProcessInfo.processInfo.environment["CREDITS_RENDER"] else { return }
        let from = CreditsScene.endingFrom(tune: hubbard)
        let renderer = CreditsRenderer()
        for (name, elapsed) in [("a", CreditsScene.collapse + 0.3), ("b", CreditsScene.collapse + CreditsScene.beating - 0.1), ("c", CreditsScene.collapse + CreditsScene.beating + 0.8), ("d", CreditsScene.collapse + CreditsScene.beating + 1.6), ("e", CreditsScene.collapse + CreditsScene.beating + 2.6), ("f", CreditsScene.collapse + CreditsScene.beating + 3.6)] {
            let image = try #require(renderer.image(seconds: from + elapsed, tune: hubbard, still: false))
            let rep = NSBitmapImageRep(cgImage: image)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(filePath: folder).appending(path: "credits-\(name).png"))
        }
        let began = Date.now
        for frame in 0..<120 { _ = renderer.image(seconds: from + 4 + Double(frame) / 60, tune: hubbard, still: false) }
        try "\(Date.now.timeIntervalSince(began) / 120 * 1000) ms a frame".write(to: URL(filePath: folder).appending(path: "speed.txt"), atomically: true, encoding: .utf8)
    }

    @Test func pastTheEndIsEmptySpaceNotACrash() {
        #expect(CreditsRenderer().image(seconds: CreditsScene.length(tune: nil) + 30, tune: nil, still: false) != nil)
    }
}
