import Foundation

/// Each voice's spectrum in many log-spaced bands, for the Spectrum and
/// Terrain visualizers: finer than the Radial's `VoiceSpectrum`, and sharp
/// in the bass.
///
/// One FFT can't do both ends. Over 2048 samples (46 ms) a bass note is a
/// lump an octave wide; over 8192 (183 ms) it's a clean peak, but fast
/// notes smear. So this runs both and reads the lows from the long one
/// and the highs from the short one, crossing over between 250 and 900 Hz,
/// as multi-resolution analyzers do.
///
/// Levels are 0–1 on a −60…0 dB scale, rising fast and falling slowly;
/// `peaks` holds each band's recent highest and lets it sink.
nonisolated final class FineSpectrum {
    /// Samples to read from the feed for each update.
    static let samples = 8192
    static let lowHz: Float = 30
    static let highHz: Float = 16_000
    /// The scale's floor, in dB.
    static let floorDB: Float = -60

    let bands: Int
    /// `bands` levels per voice, voice after voice.
    private(set) var levels: [Float]
    private(set) var peaks: [Float]

    private let long: VoiceSpectrum
    private let short: VoiceSpectrum
    /// How much of each band comes from the long FFT.
    private let fromLong: [Float]
    private var lastUpdate: Date?

    init(bands: Int) {
        self.bands = bands
        levels = [Float](repeating: 0, count: 3 * bands)
        peaks = levels
        long = VoiceSpectrum(size: Self.samples, bands: bands, lowHz: Self.lowHz, highHz: Self.highHz, interpolates: true)
        short = VoiceSpectrum(size: 2048, bands: bands, lowHz: Self.lowHz, highHz: Self.highHz, interpolates: true)
        fromLong = (0..<bands).map { band in
            let hz = Self.frequency(at: (Float(band) + 0.5) / Float(bands))
            let t = min(1, max(0, log(hz / 250) / log(900 / 250)))
            return 1 - t * t * (3 - 2 * t)
        }
    }

    /// The frequency `x` of the way along the scale, 0–1.
    static func frequency(at x: Float) -> Float {
        lowHz * pow(highHz / lowHz, x)
    }

    /// Where `hz` is along the scale, 0–1 within it.
    static func position(of hz: Float) -> Float {
        log(max(hz, 1) / lowHz) / log(highHz / lowHz)
    }

    /// Advance to `date` with each voice's latest samples (−1…1, oldest
    /// first; missing voices fall silent).
    func update(voices: [[Float]], sampleRate: Float, at date: Date) {
        let dt = lastUpdate.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        lastUpdate = date
        // Per-frame factors at 60 fps, like the Radial's.
        let rise = Float(1 - pow(1 - 0.5, dt * 60))
        let fall = Float(1 - pow(1 - 0.1, dt * 60))
        // A peak sinks the whole scale in about 4 s.
        let sink = Float(dt) / 4
        for v in 0..<3 {
            let samples = v < voices.count ? voices[v] : []
            let low = long.bands(of: samples, sampleRate: sampleRate)
            let high = short.bands(of: samples, sampleRate: sampleRate)
            for b in 0..<bands {
                let i = v * bands + b
                let target = high[b] + (low[b] - high[b]) * fromLong[b]
                levels[i] += (target - levels[i]) * (target > levels[i] ? rise : fall)
                peaks[i] = max(levels[i], peaks[i] - sink)
            }
        }
    }

    /// The three voices together in each band: their powers added, back on
    /// the same scale.
    func mix() -> [Float] {
        (0..<bands).map { b in
            var power: Float = 0
            for v in 0..<3 {
                let level = levels[v * bands + b]
                guard level > 0 else { continue }
                power += pow(10, level * -Self.floorDB / 10)
            }
            return power > 0 ? min(1, 10 * log10(power) / -Self.floorDB) : 0
        }
    }
}
