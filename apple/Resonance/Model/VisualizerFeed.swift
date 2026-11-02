import SwiftUI
import PhosphorCore

/// What the visualizers draw from: the core's SID frames, with each voice's
/// envelope and output samples from a visuals-only reSID (core/src/viz.rs).
///
/// Reads return what's being heard, which trails the emulation by the
/// engine's audio buffer and the output device. Read once per display frame,
/// inside a `TimelineView(.animation)`; every read copies.
nonisolated struct VisualizerFeed {
    let core: any PlayerCoreProtocol

    /// The frame being heard now; nil before the first one and while stopped.
    func latest() -> VizSidFrame? {
        core.vizLatest()
    }

    /// Up to `count` frames (about 10 s at most), oldest first, ending with
    /// the one being heard now.
    func history(_ count: Int) -> [VizSidFrame] {
        core.vizHistory(count: UInt32(clamping: count))
    }

    /// The last `count` samples (at most 2048) of each of `chip`'s three
    /// voices, −1…1, oldest first.
    func scope(chip: Int, count: Int) -> VizScope {
        core.vizScope(chip: UInt32(clamping: chip), count: UInt32(clamping: count))
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

extension PlayerStore {
    var visualizer: VisualizerFeed {
        VisualizerFeed(core: core)
    }
}

nonisolated extension VizVoice {
    /// e.g. "TRI", "PUL+SAW"; empty when no waveform is selected.
    var waveformName: String {
        let names: [(UInt8, String)] = [(0x1, "TRI"), (0x2, "SAW"), (0x4, "PUL"), (0x8, "NOI")]
        return names.filter { waveform & $0.0 != 0 }.map(\.1).joined(separator: "+")
    }
}
