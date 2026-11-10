import QuartzCore
import Testing
@testable import Resonance

@MainActor
struct MonitorScreenTests {
    @Test func rasterMatchesEveryGlyphInBothVideoModesAndWithACursor() {
        var frame = C64Frame()
        let glyphCount = C64Font.rows.count / 8
        for cell in frame.cells.indices {
            frame.cells[cell] = UInt16(cell % glyphCount)
            frame.reversed[cell] = (cell / glyphCount) % 2 == 1
        }
        for cursor: (x: Int, y: Int)? in [nil, (0, 0), (39, 24), (17, 12)] {
            var pixels = [UInt32](repeating: 0, count: C64Frame.width * C64Frame.height)
            frame.render(into: &pixels, cursor: cursor)
            var expected = [UInt32](repeating: C64Frame.foreground, count: pixels.count)
            for y in 0..<C64Frame.rows {
                for x in 0..<C64Frame.columns {
                    let cell = y * C64Frame.columns + x
                    let reversed = frame.reversed[cell] != (cursor?.x == x && cursor?.y == y)
                    for row in 0..<8 {
                        let bits = C64Font.rows[Int(frame.cells[cell]) * 8 + row]
                        for bit in 0..<8 {
                            let lit = bits & (1 << (7 - bit)) != 0
                            let offset = (C64Frame.originY + y * 8 + row) * C64Frame.width + C64Frame.originX + x * 8 + bit
                            expected[offset] = lit != reversed ? C64Frame.foreground : C64Frame.background
                        }
                    }
                }
            }
            #expect(pixels == expected)
        }
    }

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
