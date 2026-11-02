import Accelerate
import Foundation

/// Each voice's spectrum, in `bands` log-spaced bands from about 40 Hz to
/// 10 kHz, 0–1, for the Radial visualizer. An FFT (vDSP) over the last 2048
/// samples of each voice's tap, Hann-windowed, on a −60…0 dB scale, with
/// a fast rise and slow fall so the bars stay calm
/// (design/visualizers/IMPLEMENTATION_NOTES.md).
nonisolated final class VoiceSpectrum {
    static let size = 2048
    static let bands = 64
    static let lowHz: Float = 40
    static let highHz: Float = 10_000

    /// `bands` levels per voice, voice after voice.
    private(set) var levels = [Float](repeating: 0, count: 3 * VoiceSpectrum.bands)

    private let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(VoiceSpectrum.size))), radix: .radix2,
                               ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: VoiceSpectrum.size, isHalfWindow: false)
    private var lastUpdate: Date?

    /// Advance to `date` with each voice's latest samples (−1…1, oldest
    /// first, any length; missing voices fall silent).
    func update(voices: [[Float]], sampleRate: Float, at date: Date) {
        let dt = lastUpdate.map { min(date.timeIntervalSince($0), 0.1) } ?? 0
        lastUpdate = date
        // The mockup's per-frame factors (0.45 up, 0.12 down) at 60 fps.
        let rise = Float(1 - pow(1 - 0.45, dt * 60))
        let fall = Float(1 - pow(1 - 0.12, dt * 60))
        for v in 0..<3 {
            let target = v < voices.count ? bands(of: voices[v], sampleRate: sampleRate) : nil
            for b in 0..<Self.bands {
                let i = v * Self.bands + b
                let t = target?[b] ?? 0
                levels[i] += (t - levels[i]) * (t > levels[i] ? rise : fall)
            }
        }
    }

    /// One voice's band levels right now, unsmoothed.
    func bands(of samples: [Float], sampleRate: Float) -> [Float] {
        let n = Self.size
        guard samples.count >= n / 4, sampleRate > 0 else {
            return [Float](repeating: 0, count: Self.bands)
        }
        // The newest samples, zero-padded at the front when there are fewer.
        var input = [Float](repeating: 0, count: n)
        let take = min(n, samples.count)
        input.replaceSubrange((n - take)..<n, with: samples.suffix(take))
        vDSP.multiply(input, window, result: &input)

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                input.withUnsafeBufferPointer { samples in
                    samples.withMemoryRebound(to: DSPComplex.self) {
                        vDSP_ctoz($0.baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                // Packed format: imagp[0] holds Nyquist; drop it with DC.
                im[0] = 0
                re[0] = 0
                vDSP.absolute(split, result: &magnitudes)
            }
        }
        // A sine of amplitude A peaks at A·Σwindow/2 = A·n/4 in the
        // textbook FFT, and vDSP's is twice that: so this gives A.
        let scale = 1 / Float(n / 2)

        let binHz = sampleRate / Float(n)
        let ratio = Self.highHz / Self.lowHz
        return (0..<Self.bands).map { b in
            let lo = Self.lowHz * pow(ratio, Float(b) / Float(Self.bands))
            let hi = Self.lowHz * pow(ratio, Float(b + 1) / Float(Self.bands))
            let first = max(1, Int((lo / binHz).rounded(.down)))
            let last = max(first, min(n / 2 - 1, Int((hi / binHz).rounded(.down))))
            let peak = magnitudes[first...last].max() ?? 0
            let db = 20 * log10(max(peak * scale, 1e-6))
            return min(1, max(0, (db + 60) / 60))
        }
    }
}
