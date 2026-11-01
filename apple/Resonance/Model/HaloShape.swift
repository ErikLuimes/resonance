import Foundation
import PhosphorCore

/// The Halo's rings: each voice's radius at `samples` angles around the
/// centre, rebuilt every display frame from its waveform, pulse width, note
/// and envelope (design/visualizers/reference/Halo.dc.html). The shader
/// draws them; this decides their shape.
///
/// A ring's wobble comes from its waveform's harmonics — saw: every
/// harmonic at 1/k; pulse: odd ones weighted by |sin(πk·pw)|/k; triangle:
/// odd ones at 1/k²; noise: random, re-rolled each SID frame — scaled by
/// the envelope, so a silent voice settles to a plain circle.
nonisolated final class HaloShape {
    static let samples = 256
    /// Ring radii at rest, in units of half the view's shorter side.
    static let baseRadii: [Float] = [0.50, 0.55, 0.60]

    /// `samples` radii per voice, voice after voice, starting at −π.
    private(set) var radii: [Float]
    /// Each voice's smoothed envelope, 0–1.
    private(set) var levels: [Float] = [0, 0, 0]

    private var rotation: [Double] = [0, 0, 0]
    private var time: Double = 0
    private var lastUpdate: Date?

    init() {
        radii = Self.baseRadii.flatMap { Array(repeating: $0, count: Self.samples) }
    }

    /// Advance to `date` and rebuild the rings from `voices` (missing ones
    /// fade out). `frame` seeds the noise, so it changes once per SID frame.
    func update(voices: [VizVoice], frame: UInt64?, at date: Date) {
        let dt = lastUpdate.map { min(date.timeIntervalSince($0), 0.1) } ?? 0
        lastUpdate = date
        time += dt
        // Envelope smoothing: ~75 ms to settle, like the mockup at 60 fps.
        let follow = Float(1 - exp(-dt / 0.075))

        for v in 0..<3 {
            let voice = v < voices.count ? voices[v] : nil
            let target = voice?.envLevel ?? 0
            levels[v] += (target - levels[v]) * follow
            // Higher notes turn faster; neighbours turn opposite ways.
            let midi = voice.map { $0.midi > 0 ? $0.midi : 40 } ?? 40
            rotation[v] += dt * (0.12 + midi / 900) * (v % 2 == 0 ? 1 : -1)

            let wave = Wave(voice: voice, noiseSeed: frame.map { $0 &* 3 &+ UInt64(v) } ?? 0)
            let level = levels[v]
            let amplitude = level * (0.08 + level * 0.22)
            for j in 0..<Self.samples {
                let theta = -Double.pi + 2 * Double.pi * Double(j) / Double(Self.samples)
                let wobble = wave.shape(at: theta + rotation[v], time: time)
                radii[v * Self.samples + j] = Self.baseRadii[v] + amplitude * wobble + level * 0.056
            }
        }
    }

    /// One voice's waveform as a function of angle.
    struct Wave {
        let waveform: UInt8
        /// 0–1.
        let pulseWidth: Double
        let noisePhases: [Double]

        init(waveform: UInt8, pulseWidth: Double, noiseSeed: UInt64) {
            self.waveform = waveform
            self.pulseWidth = pulseWidth
            noisePhases = (0..<5).map { Self.random(noiseSeed &* 31 &+ UInt64($0)) * 2 * .pi }
        }

        init(voice: VizVoice?, noiseSeed: UInt64) {
            self.init(waveform: voice?.waveform ?? 0, pulseWidth: Double(voice?.pulseWidth ?? 2048) / 4096,
                      noiseSeed: noiseSeed)
        }

        /// The ring's offset at angle `theta`, roughly −1…1. Each harmonic
        /// drifts at its own speed, so the shape keeps morphing.
        func shape(at theta: Double, time t: Double) -> Float {
            var s = 0.0
            if waveform & 0x2 != 0 {
                for k in 2...10 {
                    s += sin(Double(k) * theta + t * (0.6 + Double(k) * 0.08)) / Double(k)
                }
            }
            if waveform & 0x4 != 0 {
                for k in stride(from: 3, through: 13, by: 2) {
                    let weight = abs(sin(.pi * Double(k) * pulseWidth)) / Double(k) * 1.6
                    s += sin(Double(k) * theta - t * (0.4 + Double(k) * 0.05)) * weight
                }
            }
            if waveform & 0x1 != 0 {
                for k in stride(from: 3, through: 9, by: 2) {
                    s += sin(Double(k) * theta + t * (0.5 + Double(k) * 0.06)) / Double(k * k) * 4
                }
            }
            if waveform & 0x8 != 0 {
                for (n, k) in [9, 12, 15, 18, 21].enumerated() {
                    s += sin(Double(k) * theta + noisePhases[n]) / 3.2
                }
            }
            return Float(s)
        }

        /// 0..<1, the same for the same seed.
        static func random(_ seed: UInt64) -> Double {
            let x = sin(Double(seed % 100_000) * 12.9898) * 43_758.5453
            return x - x.rounded(.down)
        }
    }
}
