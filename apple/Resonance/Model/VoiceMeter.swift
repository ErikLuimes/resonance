import Foundation

/// Bar levels with fast attack, slow release and a peak-hold marker — the
/// Iced visualizer's smoothing (src/ui/visualizer.rs `update`), made
/// frame-rate independent: its per-frame factors were tuned at ~30 fps.
///
/// The input is the voices' real envelopes, so a held note stays at its
/// sustain level; the smoothing only softens fast drops.
nonisolated final class VoiceMeter {
    private(set) var levels: [Double] = []
    private(set) var peaks: [Double] = []
    private var lastUpdate: Date?

    private static let decayPerFrame = 0.92
    private static let peakDecayPerFrame = 0.985
    private static let referenceFPS = 30.0

    func update(levels input: [Float], at date: Date) {
        let dt = lastUpdate.map { min(date.timeIntervalSince($0), 0.25) } ?? 0
        lastUpdate = date
        let frames = dt * Self.referenceFPS
        let decay = pow(Self.decayPerFrame, frames)
        let peakDecay = pow(Self.peakDecayPerFrame, frames)

        if levels.count != input.count {
            levels = Array(repeating: 0, count: input.count)
            peaks = levels
        }
        for i in input.indices {
            let new = Double(min(max(input[i], 0), 1))
            levels[i] = max(new, levels[i] * decay)
            peaks[i] = max(levels[i], peaks[i] * peakDecay)
        }
    }

    func reset() {
        levels = levels.map { _ in 0 }
        peaks = levels
        lastUpdate = nil
    }
}
