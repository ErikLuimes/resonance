import Accelerate
import Foundation
import PhosphorCore
import simd

/// The timbre of a short stretch of one voice: 40 mel-frequency cepstral
/// coefficients, plus its loudness, spectral centroid and spread.
nonisolated struct Timbre {
    var mfcc: [Float]
    /// RMS of the newest half of the window, 0–1.
    var amplitude: Float
    /// Hz.
    var centroid: Float
    /// Hz: the spectrum's standard deviation around its centroid.
    var spread: Float
}

/// Works out a `Timbre` from a voice's newest samples: an FFT (vDSP) over
/// 2048 samples, Hann-windowed like `VoiceSpectrum`, 40 triangular mel bands
/// from 40 Hz to 11 kHz on its power, then a DCT of their logs.
nonisolated final class MFCCExtractor {
    static let size = 2048
    static let bands = 40
    static let lowHz: Float = 40
    static let highHz: Float = 11_000

    private let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(MFCCExtractor.size))), radix: .radix2,
                               ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: MFCCExtractor.size, isHalfWindow: false)
    /// Orthonormal DCT-II, `bands` × `bands`, row-major.
    private let dct: [Float] = {
        let n = MFCCExtractor.bands
        return (0..<n * n).map { i in
            let k = i / n, m = i % n
            let scale = k == 0 ? (1 / Float(n)).squareRoot() : (2 / Float(n)).squareRoot()
            return scale * cos(Float.pi * Float(k) * (Float(m) + 0.5) / Float(n))
        }
    }()
    /// Each band's first FFT bin and weights, for `filterRate`.
    private var filters: [(first: Int, weights: [Float])] = []
    private var filterRate: Float = 0

    /// Nil when there are too few samples or they're silent.
    func timbre(of samples: [Float], sampleRate: Float) -> Timbre? {
        let n = Self.size
        guard samples.count >= n / 2, sampleRate > 0 else { return nil }
        var input = [Float](repeating: 0, count: n)
        let take = min(n, samples.count)
        input.replaceSubrange((n - take)..<n, with: samples.suffix(take))
        let amplitude = vDSP.rootMeanSquare(input[(n / 2)...])
        guard amplitude > 1e-4 else { return nil }
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
        // As in VoiceSpectrum: a sine of amplitude A peaks at A.
        vDSP.multiply(1 / Float(n / 2), magnitudes, result: &magnitudes)
        let binHz = sampleRate / Float(n)

        // Centroid and spread from the magnitude spectrum.
        let total = vDSP.sum(magnitudes)
        guard total > 0 else { return nil }
        let frequencies = (0..<n / 2).map { Float($0) * binHz }
        let centroid = vDSP.dot(frequencies, magnitudes) / total
        let deviations = vDSP.add(-centroid, frequencies)
        let spread = (vDSP.dot(vDSP.multiply(deviations, deviations), magnitudes) / total).squareRoot()

        if filterRate != sampleRate { makeFilters(binHz: binHz, sampleRate: sampleRate) }
        let power = vDSP.multiply(magnitudes, magnitudes)
        var energies = filters.map { filter in
            power.withUnsafeBufferPointer { p in
                vDSP.dot(UnsafeBufferPointer(rebasing: p[filter.first..<(filter.first + filter.weights.count)]),
                         filter.weights)
            }
        }
        // A floor 80 dB under the loudest band, not an absolute one, so a
        // louder note changes only c0 and keeps its place on the map.
        let floor = max(energies.max() ?? 0, 1e-20) * 1e-8
        energies = energies.map { 10 * log10(max($0, floor)) }
        var mfcc = [Float](repeating: 0, count: Self.bands)
        vDSP_mmul(dct, 1, energies, 1, &mfcc, 1, vDSP_Length(Self.bands), 1, vDSP_Length(Self.bands))
        return Timbre(mfcc: mfcc, amplitude: amplitude, centroid: centroid, spread: spread)
    }

    private func makeFilters(binHz: Float, sampleRate: Float) {
        func mel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func hz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }
        let lo = mel(Self.lowHz), hi = mel(min(Self.highHz, sampleRate / 2))
        let edges = (0..<(Self.bands + 2)).map { hz(lo + (hi - lo) * Float($0) / Float(Self.bands + 1)) }
        let lastBin = Self.size / 2 - 1
        filters = (0..<Self.bands).map { b in
            let (left, center, right) = (edges[b], edges[b + 1], edges[b + 2])
            let first = max(1, Int((left / binHz).rounded(.up)))
            let last = min(lastBin, max(first, Int((right / binHz).rounded(.down))))
            var weights = (first...last).map { bin -> Float in
                let f = Float(bin) * binHz
                return f <= center ? (f - left) / (center - left) : (right - f) / (right - center)
            }.map { max(0, $0) }
            // The lowest bands are narrower than a bin: take the nearest one.
            if weights.allSatisfy({ $0 == 0 }) {
                let nearest = min(lastBin, max(1, Int((center / binHz).rounded())))
                return (nearest, [1])
            }
            while weights.last == 0 { weights.removeLast() }
            return (first, weights)
        }
        filterRate = sampleRate
    }
}

/// Principal components of the MFCCs seen so far (all but c0, which is
/// loudness), with older ones slowly forgotten. Refitting starts from the
/// last axes and then turns the new ones to line up with them as closely as
/// possible, so a refit never flips or swaps an axis.
nonisolated struct TimbrePCA {
    static let dims = MFCCExtractor.bands - 1

    /// Half of an observation's weight is gone after this many more.
    var halfLife: Float = 400
    private(set) var weight: Float = 0
    private var sum = [Float](repeating: 0, count: dims)
    private var products = [Float](repeating: 0, count: dims * dims)

    /// Three unit axes in MFCC space (c1…c39), each `dims` long.
    private(set) var axes: [[Float]] = (0..<3).map { a in (0..<dims).map { $0 == a ? 1 : 0 } }
    /// The variance along each axis.
    private(set) var variances: [Float] = [1, 1, 1]

    var mean: [Float] { weight > 0 ? vDSP.divide(sum, weight) : sum }

    /// The total variance: the sum of the covariance's diagonal.
    var totalVariance: Float {
        let c = covariance()
        return (0..<Self.dims).reduce(0) { $0 + c[$1 * Self.dims + $1] }
    }

    mutating func add(_ coefficients: ArraySlice<Float>) {
        let x = Array(coefficients)
        let decay = pow(0.5, 1 / halfLife)
        weight = weight * decay + 1
        vDSP.multiply(decay, sum, result: &sum)
        vDSP.add(sum, x, result: &sum)
        vDSP.multiply(decay, products, result: &products)
        // products += x xᵀ
        var outer = [Float](repeating: 0, count: Self.dims * Self.dims)
        vDSP_mmul(x, 1, x, 1, &outer, 1, vDSP_Length(Self.dims), vDSP_Length(Self.dims), 1)
        vDSP.add(products, outer, result: &products)
    }

    func covariance() -> [Float] {
        guard weight > 0 else { return products }
        let m = mean
        var meanOuter = [Float](repeating: 0, count: Self.dims * Self.dims)
        vDSP_mmul(m, 1, m, 1, &meanOuter, 1, vDSP_Length(Self.dims), vDSP_Length(Self.dims), 1)
        return vDSP.subtract(vDSP.divide(products, weight), meanOuter)
    }

    /// Finds the three main axes again (subspace iteration from the current
    /// ones), turned to match the current ones.
    mutating func refit(iterations: Int = 40) {
        let d = Self.dims
        let c = covariance()
        var q = axes
        for _ in 0..<iterations {
            q = Self.orthonormalized(q.map { v in
                var out = [Float](repeating: 0, count: d)
                vDSP_mmul(c, 1, v, 1, &out, 1, vDSP_Length(d), 1, vDSP_Length(d))
                return out
            })
        }
        // Turn the new axes to line up with the old: R = polar(Qᵀ_new Q_old).
        var m = simd_float3x3()
        for i in 0..<3 { for j in 0..<3 { m[j][i] = vDSP.dot(q[i], axes[j]) } }
        if abs(m.determinant) > 1e-3 {
            var r = m
            for _ in 0..<12 { r = 0.5 * (r + r.inverse.transpose) }
            q = (0..<3).map { j in
                (0..<d).map { k in (0..<3).reduce(Float(0)) { $0 + q[$1][k] * r[j][$1] } }
            }
            q = Self.orthonormalized(q)
        }
        axes = q
        measure()
    }

    /// The variances along the current axes, without moving them: for the
    /// warm-up, so the map has the right size before the first fit.
    mutating func measure() {
        let d = Self.dims
        let c = covariance()
        variances = axes.map { v in
            var cv = [Float](repeating: 0, count: d)
            vDSP_mmul(c, 1, v, 1, &cv, 1, vDSP_Length(d), 1, vDSP_Length(d))
            return max(vDSP.dot(v, cv), 1e-6)
        }
    }

    /// Gram–Schmidt.
    static func orthonormalized(_ vectors: [[Float]]) -> [[Float]] {
        var out: [[Float]] = []
        for v in vectors {
            var w = v
            for u in out { w = vDSP.subtract(w, vDSP.multiply(vDSP.dot(w, u), u)) }
            let length = vDSP.sumOfSquares(w).squareRoot()
            if length < 1e-9 {
                // Degenerate: any direction not yet used.
                w = (0..<v.count).map { $0 == out.count ? 1 : 0 }
                for u in out { w = vDSP.subtract(w, vDSP.multiply(vDSP.dot(w, u), u)) }
                out.append(vDSP.divide(w, vDSP.sumOfSquares(w).squareRoot()))
            } else {
                out.append(vDSP.divide(w, length))
            }
        }
        return out
    }
}

/// The Sound Map's model: a node for every note a voice starts, placed by
/// its timbre. Each node's MFCCs are reduced to 3D by `TimbrePCA`, so nearby
/// nodes sound alike; each links to the earlier nodes it sounds most like,
/// and to the voice's previous node, making a path through the map.
///
/// Fed once per display frame with the frames heard since the last call;
/// the timbre is read 35 ms after a note starts, once most of the FFT
/// window holds the new note.
nonisolated final class SoundMap {
    struct Node {
        let id: Int
        let voice: Int
        /// When it appeared, on the caller's clock (seconds).
        let born: Double
        let amplitude: Float
        let centroid: Float
        let spread: Float
        /// Seconds into the tune.
        let time: Float
        /// The voice's previous node, if it's still on the map.
        let previous: Int?
    }

    static let capacity = 1200
    static let linksPerNode = 4
    /// Seconds from a note start to reading its timbre.
    static let settle = 0.035
    /// Seconds between nodes of one voice, at least.
    static let minimumGap = 0.06
    static let refitInterval = 2.0
    /// Nodes before the first fit; until then the axes are c1–c3.
    static let warmUp = 12

    private(set) var nodes: [Node] = []
    /// Pairs of node ids, older first.
    private(set) var links: [(Int, Int)] = []
    /// Each node's c1…c39, `TimbrePCA.dims` per node, in `nodes` order.
    private var features: [Float] = []
    private(set) var pca = TimbrePCA()

    /// The axes and scale positions are drawn with, easing toward the PCA's.
    private var axes: [[Float]] = TimbrePCA().axes
    private var center = [Float](repeating: 0, count: TimbrePCA.dims)
    private var scales: SIMD3<Float> = [1, 1, 1]
    private var easedOnce = false

    private let extractor = MFCCExtractor()
    private var nextID = 0
    private var lastIndex: UInt64?
    private var lastRefit = -Double.infinity
    private var voices = [VoiceState](repeating: VoiceState(), count: 3)

    private struct VoiceState {
        var gate = false
        var midi: Double = 0
        var pending: (at: Double, time: Float)?
        var lastEmit = -Double.infinity
        var last: Int?
    }

    func reset() {
        nodes = []
        links = []
        features = []
        pca = TimbrePCA()
        axes = pca.axes
        center = [Float](repeating: 0, count: TimbrePCA.dims)
        scales = [1, 1, 1]
        easedOnce = false
        lastIndex = nil
        lastRefit = -.infinity
        voices = [VoiceState](repeating: VoiceState(), count: 3)
    }

    func node(_ id: Int) -> Node? {
        guard let first = nodes.first, id >= first.id, id - first.id < nodes.count else { return nil }
        return nodes[id - first.id]
    }

    /// Takes the frames heard since the last call (oldest first; earlier
    /// ones are skipped) and adds the nodes that are due. `scope` is only
    /// called when one is.
    func update(frames: [VizSidFrame], scope: () -> VizScope, now: Double) {
        // The newest frame earlier than the last one seen means a new tune
        // or subtune. Callers pass a window of recent frames, so the older
        // ones in it are expected and skipped.
        if let lastIndex, let newest = frames.last?.index, newest < lastIndex { reset() }
        for frame in frames {
            if let lastIndex, frame.index <= lastIndex { continue }
            lastIndex = frame.index
            let time = Float(Double(frame.index) / (frame.isPal ? 50.125 : 59.826))
            guard let chip = frame.chips.first else { continue }
            for (v, voice) in chip.voices.prefix(3).enumerated() {
                var state = voices[v]
                let started = voice.gate && (!state.gate || abs(voice.midi - state.midi) > 0.5)
                if started, state.pending == nil, now - state.lastEmit >= Self.minimumGap {
                    state.pending = (now, time)
                }
                state.gate = voice.gate
                state.midi = voice.midi
                voices[v] = state
            }
        }

        guard voices.contains(where: { $0.pending.map { now - $0.at >= Self.settle } ?? false }) else { return }
        let samples = scope()
        for v in 0..<3 {
            guard let pending = voices[v].pending, now - pending.at >= Self.settle else { continue }
            voices[v].pending = nil
            guard v < samples.voices.count,
                  let timbre = extractor.timbre(of: samples.voices[v], sampleRate: samples.sampleRate)
            else { continue }
            add(timbre, voice: v, time: pending.time, now: now)
        }
    }

    /// Adds a node for `timbre`, and refits the PCA when it's due.
    func add(_ timbre: Timbre, voice: Int, time: Float, now: Double) {
        let id = nextID
        nextID += 1
        let x = timbre.mfcc[1...]

        // Link to the nodes that sound most like it: nearest in MFCC space,
        // within a fraction of the typical distance between two moments.
        if pca.weight >= Float(Self.warmUp) {
            let radius = 0.45 * (2 * pca.totalVariance).squareRoot()
            let d = TimbrePCA.dims
            var nearest: [(id: Int, distance: Float)] = []
            let xs = Array(x)
            features.withUnsafeBufferPointer { f in
                for i in 0..<nodes.count {
                    var squared: Float = 0
                    vDSP_distancesq(xs, 1, f.baseAddress! + i * d, 1, &squared, vDSP_Length(d))
                    let distance = squared.squareRoot()
                    if distance < radius { nearest.append((nodes[i].id, distance)) }
                }
            }
            nearest.sort { $0.distance < $1.distance }
            links += nearest.prefix(Self.linksPerNode).map { ($0.id, id) }
        }

        let previous = voices[voice].last.flatMap { node($0) != nil ? $0 : nil }
        nodes.append(Node(id: id, voice: voice, born: now, amplitude: timbre.amplitude,
                          centroid: timbre.centroid, spread: timbre.spread, time: time, previous: previous))
        features += x
        pca.add(x)
        voices[voice].last = id
        voices[voice].lastEmit = now

        if nodes.count >= Self.warmUp {
            if now - lastRefit >= Self.refitInterval {
                pca.refit()
                lastRefit = now
            }
        } else {
            pca.measure()
        }

        if nodes.count > Self.capacity {
            let dropped = nodes.removeFirst().id
            features.removeFirst(TimbrePCA.dims)
            links.removeAll { $0.0 <= dropped }
        }
    }

    /// Eases the drawn axes toward the PCA's (most of the way in about a
    /// second), so a refit glides rather than jumps.
    func ease(dt: Double) {
        let k = easedOnce ? Float(1 - exp(-dt / 0.6)) : 1
        easedOnce = true
        let target = pca.axes
        axes = TimbrePCA.orthonormalized((0..<3).map { a in
            vDSP.add(axes[a], vDSP.multiply(k, vDSP.subtract(target[a], axes[a])))
        })
        center = vDSP.add(center, vDSP.multiply(k, vDSP.subtract(pca.mean, center)))
        // About ±2 standard deviations to ±1.
        let wanted = SIMD3(pca.variances.map { 1 / (2 * $0.squareRoot()) })
        scales += (wanted - scales) * k
    }

    /// Every node's place on the map, in `nodes` order: about −1…1 per axis.
    func positions() -> [SIMD3<Float>] {
        let d = TimbrePCA.dims, n = nodes.count
        guard n > 0 else { return [] }
        // Axes as a d × 3 matrix, row-major.
        var basis = [Float](repeating: 0, count: d * 3)
        for a in 0..<3 { for k in 0..<d { basis[k * 3 + a] = axes[a][k] } }
        var projected = [Float](repeating: 0, count: n * 3)
        vDSP_mmul(features, 1, basis, 1, &projected, 1, vDSP_Length(n), 3, vDSP_Length(d))
        var offset = [Float](repeating: 0, count: 3)
        vDSP_mmul(center, 1, basis, 1, &offset, 1, 1, 3, vDSP_Length(d))
        let o = SIMD3(offset[0], offset[1], offset[2])
        return (0..<n).map { i in
            (SIMD3(projected[i * 3], projected[i * 3 + 1], projected[i * 3 + 2]) - o) * scales
        }
    }
}
