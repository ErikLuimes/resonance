import SwiftUI
import PhosphorCore

/// What the visualizers draw from: the core's SID frames, with each voice's
/// envelope and output samples from a visuals-only reSID (core/src/viz.rs).
///
/// Reads return what's being heard, which trails the emulation by the
/// engine's audio buffer and the output device. Read once per display frame,
/// inside a `TimelineView(.animation)`; every read copies, except that
/// `latest()` is shared by every visualizer ticking in the same frame.
nonisolated struct VisualizerFeed {
    let core: any PlayerCoreProtocol
    var frames = FrameCache()

    /// The visualizers' rate: 60 fps looks the same as a ProMotion
    /// display's 120 and costs half as much.
    static let framesPerSecond = 60
    static let frameInterval = 1.0 / Double(framesPerSecond)

    /// The frame being heard now; nil before the first one and while stopped.
    func latest() -> VizSidFrame? {
        frames.read { core.vizLatest() }
    }

    /// How far into the subtune what's being heard is, in seconds.
    var heardSecs: Double? { core.vizHeardSecs() }

    /// Up to `count` frames (about 10 s at most), oldest first, ending with
    /// the one being heard now.
    func history(_ count: Int) -> [VizSidFrame] {
        core.vizHistory(count: UInt32(clamping: count))
    }

    /// The last `count` samples (at most 2048) of each of `chip`'s three
    /// voices, −1…1, oldest first.
    func scope(chip: Int, count: Int) -> VizScope {
        VizScope(core.vizScope(chip: UInt32(clamping: chip), count: UInt32(clamping: count)))
    }

    var stats: VizStats {
        core.vizStats()
    }

    /// The output device's latency, from `OutputLatencyMonitor`.
    func setOutputLatency(_ latency: Duration) {
        core.setVizOutputLatencyMs(ms: UInt32(clamping: Int((latency / .milliseconds(1)).rounded())))
    }

    /// Fine-tuning on top of the modelled latency; positive shows frames later.
    func setOffset(milliseconds: Int) {
        core.setVizOffsetMs(ms: Int32(clamping: milliseconds))
    }
}

/// A scope read: three voices' samples, −1…1 (waveform × envelope), oldest
/// first. The core packs them as bytes (`VizScopeSamples`), one copy across
/// the FFI; this unpacks them with one copy more.
nonisolated struct VizScope {
    let sampleRate: Float
    let voices: [[Float]]

    init(sampleRate: Float, voices: [[Float]]) {
        self.sampleRate = sampleRate
        self.voices = voices
    }

    init(_ packed: VizScopeSamples) {
        sampleRate = packed.sampleRate
        let count = Int(packed.count)
        let stride = count * MemoryLayout<Float>.size
        voices = packed.samples.withUnsafeBytes { bytes in
            (0..<3).map { voice -> [Float] in
                let range = voice * stride..<(voice + 1) * stride
                guard range.upperBound <= bytes.count else { return [] }
                return [Float](unsafeUninitializedCapacity: count) { floats, filled in
                    UnsafeMutableRawBufferPointer(floats).copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[range]))
                    filled = count
                }
            }
        }
    }
}

nonisolated extension VizScopeSamples {
    /// Packs `voices` as the core does, for previews and tests. Voices are
    /// cut to the shortest; missing ones are silent.
    init(sampleRate: Float, voices: [[Float]]) {
        let count = voices.prefix(3).map(\.count).min() ?? 0
        var samples = Data(capacity: 3 * count * MemoryLayout<Float>.size)
        for voice in 0..<3 {
            let floats = voice < voices.count ? Array(voices[voice].prefix(count)) : [Float](repeating: 0, count: count)
            floats.withUnsafeBytes { samples.append(contentsOf: $0) }
        }
        self.init(sampleRate: sampleRate, count: UInt32(count), samples: samples)
    }
}

/// One `latest()` read per display frame. Several visualizers tick in the
/// same frame (Now Playing's and its voice chips, the inspector's), and each
/// read locks the feed and copies the frame out through the FFI; within a
/// few milliseconds they all get the same frame anyway.
nonisolated final class FrameCache: @unchecked Sendable {
    /// Reads closer together than this share a frame: well under a display
    /// frame, so a later tick never sees a stale one.
    private static let window = 0.003

    private let lock = NSLock()
    private var at: TimeInterval = -.infinity
    private var frame: VizSidFrame?

    func read(_ fetch: () -> VizSidFrame?) -> VizSidFrame? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        if now - at < Self.window { return frame }
        frame = fetch()
        at = now
        return frame
    }
}

extension PlayerStore {
    var visualizer: VisualizerFeed {
        VisualizerFeed(core: core, frames: vizFrames)
    }
}

nonisolated extension VizVoice {
    /// e.g. "TRI", "PUL+SAW"; empty when no waveform is selected.
    var waveformName: String {
        let names: [(UInt8, String)] = [(0x1, "TRI"), (0x2, "SAW"), (0x4, "PUL"), (0x8, "NOI")]
        return names.filter { waveform & $0.0 != 0 }.map(\.1).joined(separator: "+")
    }
}
