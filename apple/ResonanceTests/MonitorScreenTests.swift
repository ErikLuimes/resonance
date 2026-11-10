import QuartzCore
import Testing
@testable import Resonance

@MainActor
struct MonitorScreenTests {
    @Test func startupListsTheSkullBeforeLoadingResonance() throws {
        let monitor = MonitorModel()
        var keys = ""
        monitor.typed = { keys.append($0) }
        monitor.hostGrown = true
        monitor.powerOn(store: nil)
        let start = CACurrentMediaTime()

        let listKeys = "LOAD\"$\",8\nLIST\n"
        var firstDirectoryStep: Int?
        var lastDirectoryStep: Int?
        var directory: C64Frame?
        for step in 0..<400 {
            _ = monitor.tick(store: nil, now: start + Double(step) / 20)
            if keys == listKeys, monitor.cursor?.y == C64Frame.rows - 1 {
                firstDirectoryStep = firstDirectoryStep ?? step
                lastDirectoryStep = step
                directory = monitor.frame
            }
            if monitor.mode == .player { break }
        }

        let frame = try #require(directory)
        let first = try #require(firstDirectoryStep)
        let last = try #require(lastDirectoryStep)
        #expect(last - first >= 38)
        let filenameColumn = 6
        let caption = 19 * C64Frame.columns + filenameColumn
        #expect(Array(frame.cells[caption..<(caption + 15)]) == "STILL LISTENING".map { UInt16(C64Font.glyph($0)) })
        let art = (3 * C64Frame.columns)..<(19 * C64Frame.columns)
        #expect(!frame.cells[art].contains(UInt16(C64Font.glyph("?"))))
        #expect(frame.reversed[2 * C64Frame.columns + 2])
        #expect(keys == listKeys + "LOAD\"RESONANCE\",8,1\nRUN\n")
        #expect(monitor.mode == .player)
    }
}
