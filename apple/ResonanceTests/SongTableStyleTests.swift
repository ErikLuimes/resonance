import AppKit
import PhosphorCore
import Testing
@testable import Resonance

@MainActor
struct SongTableStyleTests {
    /// A row within a row's cell, as a table nests them.
    private func rowWithMark() -> (NSTableRowView, PlayingRowMark.Mark) {
        let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let cell = NSView(frame: row.bounds)
        let mark = PlayingRowMark.Mark(frame: row.bounds)
        cell.addSubview(mark)
        row.addSubview(cell)
        return (row, mark)
    }

    @Test func theWashFollowsTheMarksValue() {
        let (row, mark) = rowWithMark()
        #expect(!row.holdsCurrentMark)
        mark.isCurrent = true
        #expect(row.holdsCurrentMark)
        mark.isCurrent = false
        #expect(!row.holdsCurrentMark)
    }

    /// Counts what `needsDisplay` is asked for: AppKit may not report it for a
    /// row that isn't in a window.
    private final class SpyRow: NSTableRowView {
        var redraws = 0
        override var needsDisplay: Bool {
            get { super.needsDisplay }
            set {
                if newValue { redraws += 1 }
                super.needsDisplay = newValue
            }
        }
    }

    /// The bug: the row kept the previous tune's wash until something else
    /// happened to redraw it.
    @Test func aRowThatStopsPlayingRedraws() async throws {
        let row = SpyRow(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let mark = PlayingRowMark.Mark(frame: row.bounds)
        row.addSubview(mark)
        mark.isCurrent = true
        try await Task.sleep(for: .milliseconds(50))
        let before = row.redraws
        mark.isCurrent = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(row.redraws == before + 1)
        // The same value again is no reason to redraw.
        mark.isCurrent = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(row.redraws == before + 1)
    }
}

/// Which tune a list's Play starts from: the player bar says whether it's shuffled.
struct FirstToPlayTests {
    private let rows = ["a", "b", "c", "d"].map { name in
        LibraryRow(item: HvscTuneItem(path: "/\(name).sid", title: name, author: "", released: "", songs: 1, startSong: 1,
                                      durationSecs: nil, hasStil: false, isRsid: nil, category: .musicians, durationIsEstimate: false))
    }

    @Test func fromTheTopWithoutShuffle() {
        #expect(LibraryStore.firstToPlay(rows, startAt: nil, shuffle: false) == rows[0])
    }

    @Test func anyWithShuffle() {
        let firsts = Set((0..<200).compactMap { _ in LibraryStore.firstToPlay(rows, startAt: nil, shuffle: true) })
        #expect(firsts.count > 1)
    }

    @Test func aChosenTuneStaysChosen() {
        #expect(LibraryStore.firstToPlay(rows, startAt: rows[2], shuffle: true) == rows[2])
    }

    @Test func nothingToPlay() {
        #expect(LibraryStore.firstToPlay([], startAt: nil, shuffle: true) == nil)
    }
}

/// Which columns a pane has room for, widest first.
struct LibraryColumnFitTests {
    @Test(arguments: [(900.0, LibraryColumnFit.all), (410, .all), (409, .noYear), (350, .noYear), (349, .noYearOrLength), (292, .noYearOrLength)])
    func aComposerPane(width: CGFloat, fit: LibraryColumnFit) {
        #expect(LibraryColumnFit(width: width, hasAuthor: false) == fit)
    }

    @Test func anAuthorColumnNeedsRoomToo() {
        #expect(LibraryColumnFit(width: 410, hasAuthor: true) == .noYearOrLength)
        #expect(LibraryColumnFit(width: 490, hasAuthor: true) == .all)
    }

    @Test func yearGoesBeforeLength() {
        #expect(LibraryColumnFit.noYear.showsLength)
        #expect(!LibraryColumnFit.noYear.showsYear)
        #expect(!LibraryColumnFit.noYearOrLength.showsLength)
    }
}
