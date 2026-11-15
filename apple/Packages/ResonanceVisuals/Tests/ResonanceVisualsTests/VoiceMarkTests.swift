import Foundation
import Testing
@testable import ResonanceVisuals

struct VoiceMeterTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func withNothingToFollowItRestsAsTheMark() {
        #expect(VoiceMarkMeter().update(levels: nil, at: start) == VoiceMarkMeter.rest)
    }

    @Test func barsRiseAtOnceAndFallSmoothly() {
        let meter = VoiceMarkMeter()
        #expect(meter.update(levels: [0.2, 0.2, 0.2], at: start).bars[0] == 0.2)
        #expect(meter.update(levels: [1, 0.2, 0.2], at: start.addingTimeInterval(0.01)).bars[0] == 1)
        let falling = meter.update(levels: [0.2, 0.2, 0.2], at: start.addingTimeInterval(0.11)).bars[0]
        #expect(falling < 1 && falling > 0.2)
    }

    @Test func aPeakHoldsThenFalls() {
        let meter = VoiceMarkMeter()
        _ = meter.update(levels: [1, 0.2, 0.2], at: start)
        let held = meter.update(levels: [0.2, 0.2, 0.2], at: start.addingTimeInterval(0.2))
        #expect(held.peaks[0] == 1)
        #expect(held.bars[0] < 1)
        let fallen = meter.update(levels: [0.2, 0.2, 0.2], at: start.addingTimeInterval(1))
        #expect(fallen.peaks[0] < 1)
    }

    @Test func aSilentVoiceKeepsASliverAndMissingVoicesAreSilent() {
        let reading = VoiceMarkMeter().update(levels: [0], at: start)
        #expect(reading.bars.count == 3)
        #expect(reading.bars.allSatisfy { $0 > 0 })
    }
}
