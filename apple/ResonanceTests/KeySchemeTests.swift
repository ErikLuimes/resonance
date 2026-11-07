import Testing
@testable import Resonance

@MainActor
struct KeySchemeTests {
    /// Two actions on one key: one of them would never run.
    @Test func noSchemeUsesAKeyTwice() {
        for scheme in KeyScheme.allCases {
            let sequences = KeyAction.allCases.map { $0.binding(in: scheme).sequence }
            #expect(Set(sequences).count == sequences.count, "\(scheme)")
        }
    }

    /// "g" waits for a second key, so nothing else can be plain "g".
    @Test func noKeyIsBothAKeyAndTheStartOfASequence() {
        for scheme in KeyScheme.allCases {
            let sequences = KeyAction.allCases.map { $0.binding(in: scheme).sequence }
            let starts = sequences.filter { $0.count > 1 }.compactMap(\.first)
            for start in starts {
                #expect(!sequences.contains([start]), "\(scheme) \(start)")
            }
        }
    }

    @Test func everyActionIsInTheColumnsOnce() {
        let shown = KeyAction.columns.flatMap(\.actions)
        #expect(shown.count == KeyAction.allCases.count)
        #expect(Set(shown) == Set(KeyAction.allCases))
    }

    /// The key that shows what the keys are can't depend on knowing them.
    @Test func helpKeyIsTheSameInEveryScheme() {
        for scheme in KeyScheme.allCases {
            #expect(KeyAction.shortcuts.binding(in: scheme).sequence == [KeyStroke("?")])
        }
    }

    @Test func vimSequencesNeedBothKeysInTime() {
        var matcher = KeySequenceMatcher()
        let g = KeyStroke("g")
        #expect(matcher.feed(g, in: .vim, at: 10) == .pending)
        #expect(matcher.feed(g, in: .vim, at: 10.5) == .action(.top))

        #expect(matcher.feed(g, in: .vim, at: 20) == .pending)
        #expect(matcher.feed(g, in: .vim, at: 22) == .pending)
    }

    @Test func aKeyAfterAnUnfinishedSequenceCountsOnItsOwn() {
        var matcher = KeySequenceMatcher()
        #expect(matcher.feed(KeyStroke("d"), in: .vim, at: 1) == .pending)
        #expect(matcher.feed(KeyStroke("j"), in: .vim, at: 1.1) == .action(.moveDown))
    }

    @Test func schemesDontLeakIntoEachOther() {
        var matcher = KeySequenceMatcher()
        #expect(matcher.feed(KeyStroke("j"), in: .normal, at: 1) == .none)
        #expect(matcher.feed(KeyStroke("j"), in: .emacs, at: 2) == .none)
        #expect(matcher.feed(KeyStroke("n", .control), in: .vim, at: 3) == .none)
        #expect(matcher.feed(KeyStroke("n", .control), in: .emacs, at: 4) == .action(.moveDown))
    }

    @Test func movingThroughThePanelStopsAtItsEdges() {
        #expect(KeyHelpMove.up.applied(to: .playPause) == .playPause)
        #expect(KeyHelpMove.left.applied(to: .playPause) == .playPause)
        #expect(KeyHelpMove.down.applied(to: .playPause) == .stop)
        #expect(KeyHelpMove.right.applied(to: .stop) == .moveUp)
        #expect(KeyHelpMove.down.applied(to: .close) == .close)
        #expect(KeyHelpMove.right.applied(to: .close) == .close)
    }

    @Test func eachSchemeMovesThroughThePanelWithItsOwnKeys() {
        #expect(KeyHelpMove.from(KeyStroke(KeyStroke.down), in: .normal) == .down)
        #expect(KeyHelpMove.from(KeyStroke(KeyStroke.down), in: .vim) == .down)
        #expect(KeyHelpMove.from(KeyStroke("j"), in: .vim) == .down)
        #expect(KeyHelpMove.from(KeyStroke("j"), in: .normal) == nil)
        #expect(KeyHelpMove.from(KeyStroke("n", .control), in: .emacs) == .down)
        #expect(KeyHelpMove.from(KeyStroke("n", .control), in: .vim) == nil)
    }

    @Test func schemesCycleBothWays() {
        #expect(KeyScheme.normal.cycled(by: 1) == .vim)
        #expect(KeyScheme.emacs.cycled(by: 1) == .normal)
        #expect(KeyScheme.normal.cycled(by: -1) == .emacs)
    }
}
