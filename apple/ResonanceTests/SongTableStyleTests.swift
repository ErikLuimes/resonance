import AppKit
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
