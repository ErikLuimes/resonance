import Testing
@testable import ResonanceVisuals

/// The shaders come from the package's own bundle, for both apps: each
/// renderer builds its pipelines and draws something.
struct ShaderTests {
    @Test func inkDrawsFromThePackagesShaders() {
        let renderer = InkRenderer(style: .ink)
        var jets = InkJets()
        let pours = jets.pours(voices: [.init(level: 1, midi: 60, isNoise: false)], colors: [SIMD3(1, 0, 0)],
                               aspect: 1, clock: 0)
        #expect(renderer.image(width: 64, height: 64, pours: pours, dt: 1.0 / 60) != nil)
    }

    @Test func ferrofluidDrawsFromThePackagesShaders() {
        var field = FerroField()
        field.update(voices: [.init(level: 1, midi: 60, isNoise: false)], dt: 0.1, clock: 0)
        #expect(FerroRenderer().image(width: 64, height: 64, magnets: field.magnets, clock: 0) != nil)
    }

    @Test func nimbusDrawsFromThePackagesShaders() {
        var voices = NimbusVoices()
        voices.update(voices: [.init(level: 1, midi: 60, isNoise: false)], dt: 0.1)
        #expect(NimbusRenderer().image(width: 64, height: 64, voices: voices, clock: 0) != nil)
    }
}

/// Portrait framing: wide views are framed as before; a tall one sees the
/// same width a square view does.
struct FramingTests {
    @Test func aWideViewIsFramedAsBefore() {
        let lens = Framing.lens(size: SIMD2(1600, 1000), focal: 1.3, standBack: 1.5)
        #expect(lens.focal == 1300)
        #expect(lens.back == 1)
        let square = Framing.lens(size: SIMD2(1000, 1000), focal: 1.3, standBack: 1.5)
        #expect(square.back == 1.5)
    }

    @Test func aTallViewSeesTheWidthASquareOneDoes() {
        // Half-width at the pool, in units of the camera's usual distance.
        func seen(_ size: SIMD2<Float>) -> Float {
            let lens = Framing.lens(size: size, focal: 1.3, standBack: 1.5)
            return size.x / 2 / lens.focal * lens.back
        }
        #expect(abs(seen(SIMD2(460, 1000)) - seen(SIMD2(1000, 1000))) < 1e-4)
    }

    @Test func inksRingStaysOnATallScreen() {
        var jets = InkJets()
        let voices = (0..<3).map { _ in InkJets.Voice(level: 1, midi: 60) }
        for t in stride(from: 0.0, to: 120, by: 7) {
            for pour in jets.pours(voices: voices, colors: Array(repeating: SIMD3(1, 1, 1), count: 3), aspect: 0.46, clock: t) {
                #expect((0...1).contains(pour.position.x), "x \(pour.position.x)")
            }
        }
    }
}
