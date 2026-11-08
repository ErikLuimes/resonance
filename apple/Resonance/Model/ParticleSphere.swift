import Foundation
import PhosphorCore

/// The Particle sphere's state, advanced every display frame
/// (design/visualizers/reference/Particles.dc.html): each voice's smoothed
/// envelope, how fast its points ripple (from its note), and when its last
/// note started, which sends a wave across the sphere from that voice's own
/// pole. The points themselves are displaced on the GPU
/// (Shaders/Particles.metal); this only decides how.
nonisolated final class ParticleSphere {
    /// Seconds since this sphere started.
    private(set) var time: Double = 0
    /// Each voice's smoothed envelope, 0–1.
    private(set) var levels: [Float] = [0, 0, 0]
    /// Ripple frequency per voice, gliding from note to note.
    private(set) var frequencies: [Float] = [3, 3, 3]
    /// `time` of each voice's last note start; far in the past at first.
    private(set) var hits: [Double] = [-9, -9, -9]
    /// Each voice's waveform bits, for noise jitter.
    private(set) var waveforms: [UInt8] = [0, 0, 0]

    private var lastUpdate: Date?
    private var lastFrame: UInt64?

    /// Where each voice's waves start from, a third of the way around.
    static let poles: [SIMD3<Float>] = [[0, 1, 0], [0.87, -0.5, 0], [-0.87, -0.5, 0]]

    /// Advance to `date`. `history` is the last few SID frames, oldest
    /// first, ending with the one being heard: any note started in a frame
    /// not seen yet sets off that voice's wave.
    func update(history: [VizSidFrame], at date: Date) {
        let dt = lastUpdate.map { min(date.timeIntervalSince($0), 0.1) } ?? 0
        lastUpdate = date
        time += dt

        var previous: VizSidFrame?
        for frame in history {
            defer { previous = frame }
            guard let last = lastFrame, frame.index > last, let previous,
                  previous.index + 1 == frame.index else { continue }
            for v in 0..<3 {
                if Self.noteStarted(voice: v, from: previous, to: frame) { hits[v] = time }
            }
        }
        // A new subtune restarts the frame count.
        if let latest = history.last {
            if let last = lastFrame, latest.index < last { hits = [-9, -9, -9] }
            lastFrame = latest.index
        } else {
            lastFrame = nil
        }

        let voices = history.last?.chips.first?.voices ?? []
        // ~75 ms to settle, like the Halo.
        let follow = Float(1 - exp(-dt / 0.075))
        // A changed ripple rate re-forms the whole wave, so it glides.
        let glide = Float(1 - exp(-dt / 0.25))
        for v in 0..<3 {
            let voice = v < voices.count ? voices[v] : nil
            let sounding = voice.map { $0.gate || $0.envLevel > 0 } ?? false
            levels[v] += ((sounding ? voice!.envLevel : 0.02) - levels[v]) * follow
            // Silent voices keep their last rate.
            if sounding, let midi = voice?.midi, midi > 0 {
                frequencies[v] += (Float(2 + (midi - 30) / 9) - frequencies[v]) * glide
            }
            waveforms[v] = voice?.waveform ?? 0
        }
    }

    /// A gate opening, on chip 1.
    static func noteStarted(voice v: Int, from previous: VizSidFrame, to frame: VizSidFrame) -> Bool {
        guard let before = previous.chips.first?.voices, let now = frame.chips.first?.voices,
              v < before.count, v < now.count else { return false }
        return now[v].gate && !before[v].gate
    }
}
