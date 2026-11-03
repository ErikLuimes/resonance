import Accelerate
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import PhosphorCore
@testable import Resonance

private let rate: Float = 44_784

/// `count` samples of a sine (or, with `harmonics`, a band-limited saw).
private func tone(_ hz: Float, amplitude: Float = 0.5, harmonics: Int = 1, count: Int = 2048) -> [Float] {
    (0..<count).map { n in
        (1...harmonics).reduce(Float(0)) { sum, k in
            sum + amplitude / Float(k) * sin(2 * .pi * hz * Float(k) * Float(n) / rate)
        }
    }
}

private func frame(_ index: UInt64, gates: [Bool], midi: [Double] = [60, 64, 67]) -> VizSidFrame {
    let voices = (0..<3).map { i in
        VizVoice(freqReg: 0, hz: 440 * pow(2, (midi[i] - 69) / 12), midi: midi[i], note: "", gate: gates[i],
                 waveform: 0x2, test: false, ring: false, sync: false, pulseWidth: 0, attack: 0, decay: 0,
                 sustain: 15, release: 0, envLevel: gates[i] ? 1 : 0, envPhase: .sustain)
    }
    let chip = VizChip(voices: voices, registers: Data(count: 29), cutoff: 0, resonance: 0,
                       filterRouting: 0, filterMode: 0, volume: 15)
    return VizSidFrame(index: index, isPal: true, chips: [chip])
}

struct MFCCTests {
    @Test func aSineHasItsFrequencyAsCentroidAndItsRMSAsAmplitude() throws {
        let timbre = try #require(MFCCExtractor().timbre(of: tone(1000, amplitude: 0.5), sampleRate: rate))
        #expect(abs(timbre.centroid - 1000) < 60)
        #expect(abs(timbre.amplitude - 0.5 / Float(2).squareRoot()) < 0.01)
        #expect(timbre.mfcc.count == 40)
        #expect(timbre.mfcc.allSatisfy { $0.isFinite })
    }

    @Test func silenceHasNoTimbre() {
        #expect(MFCCExtractor().timbre(of: [Float](repeating: 0, count: 2048), sampleRate: rate) == nil)
    }

    @Test func harmonicsRaiseTheCentroidAndSpread() throws {
        let extractor = MFCCExtractor()
        let sine = try #require(extractor.timbre(of: tone(440), sampleRate: rate))
        let saw = try #require(extractor.timbre(of: tone(440, harmonics: 20), sampleRate: rate))
        #expect(saw.centroid > sine.centroid * 2)
        #expect(saw.spread > sine.spread * 2)
    }

    @Test func louderIsTheSameTimbreExceptC0() throws {
        let extractor = MFCCExtractor()
        let quiet = try #require(extractor.timbre(of: tone(440, amplitude: 0.1, harmonics: 8), sampleRate: rate))
        let loud = try #require(extractor.timbre(of: tone(440, amplitude: 0.8, harmonics: 8), sampleRate: rate))
        #expect(loud.mfcc[0] > quiet.mfcc[0])
        for k in 1..<40 { #expect(abs(loud.mfcc[k] - quiet.mfcc[k]) < 0.01) }
    }
}

struct TimbrePCATests {
    /// Points spread mostly along three known directions, plus a little noise.
    private func samples(_ count: Int, seed: UInt64) -> (points: [[Float]], directions: [[Float]]) {
        var generator = SeededGenerator(seed: seed)
        let d = TimbrePCA.dims
        let directions = TimbrePCA.orthonormalized((0..<3).map { _ in
            (0..<d).map { _ in Float.random(in: -1...1, using: &generator) }
        })
        let points = (0..<count).map { _ in
            var p = (0..<d).map { _ in Float.random(in: -0.05...0.05, using: &generator) }
            for (a, scale) in zip(directions, [9, 5, 3] as [Float]) {
                p = vDSP.add(p, vDSP.multiply(Float.random(in: -1...1, using: &generator) * scale, a))
            }
            return p
        }
        return (points, directions)
    }

    @Test func findsTheThreeMainDirections() {
        let (points, directions) = samples(400, seed: 1)
        var pca = TimbrePCA()
        for p in points { pca.add(p[...]) }
        pca.refit()
        // Every true direction lies (almost) inside the found axes.
        for v in directions {
            let inside = pca.axes.reduce(Float(0)) { $0 + pow(vDSP.dot(v, $1), 2) }
            #expect(inside > 0.98)
        }
        #expect(pca.variances.allSatisfy { $0 > 1 })
    }

    @Test func refittingTheSameKindOfDataKeepsTheAxesWhereTheyWere() {
        let (first, _) = samples(400, seed: 2)
        var pca = TimbrePCA()
        for p in first { pca.add(p[...]) }
        pca.refit()
        let before = pca.axes
        let (more, _) = samples(200, seed: 2)
        for p in more.reversed() { pca.add(p[...]) }
        pca.refit()
        for (a, b) in zip(before, pca.axes) { #expect(vDSP.dot(a, b) > 0.99) }
    }
}

struct SoundMapTests {
    private func scope(_ hz: Float = 440) -> VizScope {
        VizScope(sampleRate: rate, voices: [tone(hz, harmonics: 6), tone(hz * 2, harmonics: 3), tone(hz / 2)])
    }

    @Test func aNoteStartBecomesANodeOnceItHasSettled() {
        let map = SoundMap()
        map.update(frames: [frame(1, gates: [false, false, false])], scope: { scope() }, now: 0)
        map.update(frames: [frame(2, gates: [true, false, false])], scope: { scope() }, now: 0.02)
        #expect(map.nodes.isEmpty)
        map.update(frames: [], scope: { scope() }, now: 0.02 + SoundMap.settle)
        #expect(map.nodes.count == 1)
        #expect(map.nodes[0].voice == 0)
        #expect(abs(map.nodes[0].time - 2 / 50.125) < 0.001)
    }

    @Test func aPitchChangeWhileGatedIsANewNote() {
        let map = SoundMap()
        var now = 0.0, index: UInt64 = 0
        for midi in [60.0, 64, 67, 72] {
            index += 3
            now += 0.1
            map.update(frames: [frame(index, gates: [true, false, false], midi: [midi, 0, 0])], scope: { scope() }, now: now)
            now += 0.05
            map.update(frames: [], scope: { scope() }, now: now)
        }
        #expect(map.nodes.count == 4)
        #expect(map.nodes.dropFirst().allSatisfy { $0.previous == $0.id - 1 })
    }

    /// As the renderer calls it: the last 16 frames every display frame,
    /// mostly ones already seen.
    @Test func overlappingWindowsOfHistoryKeepTheMap() {
        let map = SoundMap()
        var history: [VizSidFrame] = []
        var now = 0.0
        for index in UInt64(1)...200 {
            // A note on voice 1 every 10 frames, gate off in between.
            history.append(frame(index, gates: [index % 10 < 5, false, false]))
            history = Array(history.suffix(16))
            now += 0.02
            map.update(frames: history, scope: { scope() }, now: now)
        }
        #expect(map.nodes.count >= 18)
    }

    @Test func goingBackToAnEarlierFrameStartsAFreshMap() {
        let map = SoundMap()
        map.update(frames: [frame(500, gates: [true, true, true])], scope: { scope() }, now: 0)
        map.update(frames: [], scope: { scope() }, now: 0.1)
        #expect(map.nodes.count == 3)
        map.update(frames: [frame(2, gates: [false, false, false])], scope: { scope() }, now: 0.2)
        #expect(map.nodes.isEmpty)
    }

    @Test func linksGoToTheMostAlikeAndStayCapped() {
        let map = SoundMap()
        let extractor = MFCCExtractor()
        for i in 0..<300 {
            let hz = Float([220, 330, 440, 660][i % 4]) * (1 + Float(i % 7) * 0.01)
            let timbre = extractor.timbre(of: tone(hz, harmonics: 1 + (i % 5) * 3), sampleRate: rate)!
            map.add(timbre, voice: i % 3, time: Float(i) / 10, now: Double(i) / 10)
        }
        #expect(map.nodes.count == 300)
        #expect(!map.links.isEmpty)
        let perNode = Dictionary(grouping: map.links, by: \.1).mapValues(\.count)
        #expect(perNode.values.allSatisfy { $0 <= SoundMap.linksPerNode })
        #expect(map.pca.totalVariance > 0)
    }

    @Test func dropsTheOldestPastCapacity() {
        let map = SoundMap()
        let timbre = MFCCExtractor().timbre(of: tone(440, harmonics: 4), sampleRate: rate)!
        for i in 0..<(SoundMap.capacity + 10) { map.add(timbre, voice: 0, time: 0, now: Double(i)) }
        #expect(map.nodes.count == SoundMap.capacity)
        #expect(map.nodes.first?.id == 10)
        #expect(map.links.allSatisfy { $0.0 >= 10 })
        #expect(map.positions().count == SoundMap.capacity)
    }
}

@MainActor
struct SoundMapRenderTests {
    /// Renders a map of a few hundred notes offscreen, checks it drew
    /// something in the middle, and times building and encoding a frame.
    @Test func rendersOffscreen() throws {
        let renderer = SoundMapRenderer()
        try #require(renderer.device != nil)
        let extractor = MFCCExtractor()
        var generator = SeededGenerator(seed: 7)
        for i in 0..<600 {
            let hz = Float([110, 220, 330, 440, 880][Int.random(in: 0..<5, using: &generator)])
            let timbre = extractor.timbre(of: tone(hz * Float.random(in: 0.98...1.02, using: &generator),
                                                   amplitude: Float.random(in: 0.05...0.7, using: &generator),
                                                   harmonics: Int.random(in: 1...16, using: &generator)), sampleRate: rate)!
            renderer.map.add(timbre, voice: i % 3, time: Float(i) * 0.12, now: Double(i) * 0.12)
        }
        #expect(renderer.map.nodes.count == 600)
        let last = 599 * 0.12
        _ = renderer.render(width: 64, height: 64, now: last)
        // A second of full-screen frames at 60 Hz, the newest notes still lit.
        let start = Date()
        for k in 0..<60 { _ = renderer.render(width: 3024, height: 1964, now: last + Double(k) / 60) }
        let perFrame = Date().timeIntervalSince(start) / 60
        let picture = try #require(renderer.image(width: 1600, height: 1000, now: last + 1.1))
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "SoundMap.png")
        if let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(out, picture, nil)
            CGImageDestinationFinalize(out)
        }
        print("SoundMap render: \(url.path), \(String(format: "%.2f", perFrame * 1000)) ms per full-screen frame")
        let lit = try #require(picture.dataProvider?.data as Data?).enumerated()
            .filter { $0.offset % 4 != 3 && $0.element > 60 }.count
        #expect(lit > 2000)
    }
}

extension SoundMapRenderTests {
    /// A wide spread of sounds in a tall, narrow view: after a few seconds
    /// the camera has zoomed out so nearly every node is on screen.
    @Test func zoomsOutUntilTheMapFits() throws {
        let renderer = SoundMapRenderer()
        try #require(renderer.device != nil)
        let extractor = MFCCExtractor()
        var generator = SeededGenerator(seed: 11)
        for i in 0..<400 {
            let samples: [Float] = i % 4 == 0
                ? (0..<2048).map { _ in Float.random(in: -0.4...0.4, using: &generator) }
                : tone(Float.random(in: 60...3000, using: &generator), amplitude: 0.4,
                       harmonics: Int.random(in: 1...30, using: &generator))
            renderer.map.add(extractor.timbre(of: samples, sampleRate: rate)!, voice: i % 3, time: 0, now: 0)
        }
        for k in 0..<240 { _ = renderer.render(width: 120, height: 400, now: 100 + Double(k) / 30, scale: 1) }
        #expect(renderer.onScreen >= 0.97)
    }
}

/// A small deterministic generator (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
