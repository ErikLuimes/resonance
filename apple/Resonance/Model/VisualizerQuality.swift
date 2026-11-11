import Foundation
import Metal

/// Lowers a visualizer's quality by itself on a Mac that can't keep up,
/// and raises it again when there's room. It goes by what each frame
/// actually cost the GPU (the command buffer's own start and end times),
/// not by a list of models, so it's right for whatever Mac and whatever
/// window size it finds itself on.
///
/// A frame at 60 a second has 16.7 ms. When the GPU's share of that stays
/// above 60%, the level drops a step; when it stays below 15% for a
/// while, it rises one. The gap is wide on purpose: a step up can cost
/// three times as much (the Ferrofluid's does), and 15% × 3 is still
/// under 60%, so it never bounces between two levels. It stays at least
/// a step down in Low Power Mode and when the Mac is hot.
nonisolated final class VisualizerQuality: @unchecked Sendable {
    enum Level: Int, Comparable {
        case full, reduced, low

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// A frame's time at the visualizers' full rate.
    static let frame = VisualizerFeed.frameInterval
    /// The GPU's share of a frame that's too much, and that leaves room.
    static let tooMuch = 0.6
    static let room = 0.15
    /// Seconds a level is kept before it may drop again, or rise.
    static let dropAfter = 1.5
    static let riseAfter = 8.0

    private let lock = NSLock()
    private var current: Level
    /// The GPU's recent share of a frame, smoothed over about ten frames.
    private var load = 0.0
    private var frames = 0
    /// Frames to see before judging: the first few include setting up.
    static let settle = 20
    private var lastChange = -Double.infinity
    /// The best level allowed right now: a step down while saving power.
    private let ceiling: @Sendable () -> Level

    init(startingAt level: Level, ceiling: @escaping @Sendable () -> Level = { .full }) {
        current = max(level, ceiling())
        self.ceiling = ceiling
    }

    /// For a visualizer on this Mac as it is now.
    convenience init() {
        self.init(startingAt: .full) {
            let process = ProcessInfo.processInfo
            let hot = process.thermalState == .serious || process.thermalState == .critical
            return hot || process.isLowPowerModeEnabled ? .reduced : .full
        }
    }

    var level: Level {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// The rate to draw at: half at the lowest level, where each frame
    /// then has twice as long.
    var framesPerSecond: Int {
        level == .low ? VisualizerFeed.framesPerSecond / 2 : VisualizerFeed.framesPerSecond
    }

    /// Call before committing a frame's commands: its GPU time is counted
    /// when it finishes.
    func track(_ commands: MTLCommandBuffer) {
        commands.addCompletedHandler { [weak self] finished in
            let seconds = finished.gpuEndTime - finished.gpuStartTime
            guard seconds > 0 else { return }
            self?.record(gpuSeconds: seconds, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// One frame took the GPU `gpuSeconds`, at `now` (any steady clock).
    func record(gpuSeconds: Double, at now: Double) {
        lock.lock()
        defer { lock.unlock() }
        let share = gpuSeconds / Self.frame
        frames += 1
        load = frames == 1 ? share : load + (share - load) * 0.1
        let best = ceiling()
        if current < best {
            current = best
            lastChange = now
        } else if frames < Self.settle {
            return
        } else if load > Self.tooMuch, current < .low, now - lastChange > Self.dropAfter {
            current = Level(rawValue: current.rawValue + 1) ?? .low
            lastChange = now
            // The next level should cost less; don't judge it by this one.
            load *= 0.5
        } else if load < Self.room, current > best, now - lastChange > Self.riseAfter {
            current = Level(rawValue: current.rawValue - 1) ?? .full
            lastChange = now
        }
    }
}
