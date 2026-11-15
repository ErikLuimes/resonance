import CoreGraphics
import Foundation

// The app's mark, alive: the SID's three voices as bars, each with its peak
// above it. The Mac's song rows draw it (RowPlayCell's VoiceBars) and so
// does Resonance Remote's mini player; both take the motion and the shape
// from here.

/// Bars that rise at once and fall smoothly, and peaks that hold, then fall.
public final class VoiceMarkMeter {
    public struct Reading: Equatable, Sendable {
        public var bars: [Double]
        public var peaks: [Double]

        public init(bars: [Double], peaks: [Double]) {
            self.bars = bars
            self.peaks = peaks
        }
    }

    /// The mark as it's drawn in the icon, for when there's nothing to show.
    public static let rest = Reading(bars: [380.0 / 540, 1, 300.0 / 540], peaks: [380.0 / 540, 1, 300.0 / 540])

    private static let floor = 0.08
    private static let barFallPerSecond = 2.4
    private static let peakFallPerSecond = 0.7
    private static let peakHold = 0.35

    private var reading: Reading?
    private var heldSince: [Date] = []
    private var last: Date?

    public init() {}

    /// The reading at `date` for voice `levels`, 0–1; nil levels mean there's
    /// nothing playing to follow, and the mark rests.
    public func update(levels: [Double]?, at date: Date) -> Reading {
        guard let levels, !levels.isEmpty else {
            reading = nil
            last = nil
            return Self.rest
        }
        let voices = (0..<3).map { $0 < levels.count ? max(Self.floor, min(levels[$0], 1)) : Self.floor }
        guard var now = reading, let last else {
            reading = Reading(bars: voices, peaks: voices)
            heldSince = Array(repeating: date, count: 3)
            self.last = date
            return reading!
        }
        let elapsed = max(date.timeIntervalSince(last), 0)
        for voice in 0..<3 {
            now.bars[voice] = max(voices[voice], now.bars[voice] - Self.barFallPerSecond * elapsed)
            if now.bars[voice] >= now.peaks[voice] {
                now.peaks[voice] = now.bars[voice]
                heldSince[voice] = date
            } else if date.timeIntervalSince(heldSince[voice]) > Self.peakHold {
                now.peaks[voice] = max(now.bars[voice], now.peaks[voice] - Self.peakFallPerSecond * elapsed)
            }
        }
        reading = now
        self.last = date
        return now
    }
}

/// Where the mark's parts go in a box: proportions from the mark (Assets:
/// MenuBarIcon), bars 150 wide with gaps of 70 in 590, and the peak's line
/// 34 tall in 622. The origin is the bottom left, as Core Animation's is;
/// flip for a top-left canvas.
public enum VoiceMarkLayout {
    public struct Part: Equatable, Sendable {
        public var bar: CGRect
        public var barRadius: CGFloat
        public var peak: CGRect
    }

    public static func parts(in size: CGSize, reading: VoiceMarkMeter.Reading) -> [Part] {
        guard size.width > 0, size.height > 0 else { return [] }
        let barWidth = size.width * 150 / 590
        let step = size.width * 220 / 590
        let peakHeight = max(size.height * 34 / 622, 1)
        let gap = size.height * 48 / 622
        let room = size.height - peakHeight - gap
        return reading.bars.indices.prefix(3).map { voice in
            let x = CGFloat(voice) * step
            let barHeight = max(room * reading.bars[voice], 1)
            return Part(bar: CGRect(x: x, y: 0, width: barWidth, height: barHeight),
                        barRadius: min(barWidth * 0.24, barHeight / 2),
                        peak: CGRect(x: x, y: room * reading.peaks[voice] + gap, width: barWidth, height: peakHeight))
        }
    }
}
