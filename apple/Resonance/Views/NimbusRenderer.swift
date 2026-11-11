import simd
import MetalKit
import MetalPerformanceShaders

/// The Nimbus visualizer's cloud from moment to moment: how far each
/// voice's billow has swollen and risen, how brightly it glows from
/// inside, and how far the whole cloud has churned.
///
/// It's made to move with the music, plainly:
/// - A billow's size follows its voice's level closely, up in a tenth of
///   a second and down in under a second, and jumps on every new note.
/// - It rises and sinks with the voice's pitch.
/// - Its glow follows the level and flares on every new note.
/// - The cloud's churning runs on at a pace set by how loud all three
///   are: nearly still in a silence, fast in a loud passage.
nonisolated struct NimbusVoices {
    private(set) var swell = SIMD3<Float>(0, 0, 0)
    private(set) var glow = SIMD3<Float>(0, 0, 0)
    /// Each billow's height for its voice's pitch, −1…1.
    private(set) var lift = SIMD3<Float>(0, 0, 0)
    /// How far the cloud has churned, in seconds of its fastest pace.
    private(set) var churn = 0.0

    /// Seconds for a billow to (mostly) swell, and to sink back.
    static let swelling = 0.1
    static let sinking = 0.8
    /// What a new note adds to its billow's size, and how long that lasts.
    static let kick: Float = 0.3
    static let kickFades = 0.3
    /// The notes that put a billow at its lowest and highest, and the
    /// seconds it takes to get to a new note's height.
    static let notes: ClosedRange<Float> = 30...90
    static let lifting = 0.25
    /// The churn's pace in silence and at full level, in seconds a second.
    static let pace: ClosedRange<Double> = 0.5...3.4
    /// How far back along its way a ball's smoke trails, in churned seconds.
    static let trail = 1.6

    /// Where ball `i` (0–5; a voice's two are `i` and `i + 3`) is once the
    /// cloud has churned `churn` far: its place and how far it reaches.
    /// Each goes round the middle its own way, at its own pace and tilt,
    /// and in and out as it goes, so they part and meet; and a voice's
    /// pair rides higher the higher it plays.
    func ball(_ i: Int, churn: Double) -> SIMD4<Float> {
        let v = i % 3, k = Float(i), t = Float(churn)
        let turn = k * 1.047 + t * (0.16 + 0.045 * k) * (i % 2 == 0 ? 1 : -1)
        let out = 1.7 + 1.15 * sin(t * (0.21 + 0.03 * k) + k * 2.1)
        let tilt = 0.5 * sin(k * 1.7) + 0.25 * sin(t * 0.13 + k)
        let flat = SIMD3(cos(turn) * out, 0, sin(turn) * out * 0.9)
        let place = SIMD3(flat.x, flat.x * sin(tilt) + 0.6 * sin(t * 0.27 + k * 1.3) + 0.8 * lift[v], flat.z)
        let reach = ((i < 3 ? 0.7 : 0.55) + 0.85 * swell[v]) * 1.75
        return SIMD4(place, reach)
    }

    private var kicks = SIMD3<Float>(0, 0, 0)
    private var levels = SIMD3<Float>(0, 0, 0)
    private var lastMidi: [Float?] = [nil, nil, nil]
    private var wasSounding = [false, false, false]

    var level: Float { (glow.x + glow.y + glow.z) / 3 }

    /// Advance by `dt` seconds with what the voices are playing.
    mutating func update(voices: [InkJets.Voice], dt: Double) {
        var loud: Float = 0
        for v in 0..<3 {
            let voice = v < voices.count ? voices[v] : InkJets.Voice(level: 0, midi: 0)
            let sounding = voice.level > 0.04
            let moved = lastMidi[v].map { abs($0 - voice.midi) > 0.5 } ?? true
            let started = sounding && (!wasSounding[v] || (moved && !voice.isNoise))
            wasSounding[v] = sounding
            if sounding { lastMidi[v] = voice.midi }
            let level = min(1, voice.level)
            loud += level / 3
            levels[v] += (level - levels[v]) * Float(1 - exp(-dt / (level > levels[v] ? Self.swelling : Self.sinking)))
            kicks[v] *= Float(exp(-dt / Self.kickFades))
            if started { kicks[v] = 1 }
            swell[v] = levels[v] + Self.kick * kicks[v]
            glow[v] += (level - glow[v]) * Float(1 - exp(-dt / (level > glow[v] ? 0.03 : 0.3)))
            if started { glow[v] = min(1.4, glow[v] + 0.45) }
            if sounding, !voice.isNoise {
                let t = (min(max(voice.midi, Self.notes.lowerBound), Self.notes.upperBound) - Self.notes.lowerBound)
                    / (Self.notes.upperBound - Self.notes.lowerBound)
                lift[v] += (t * 2 - 1 - lift[v]) * Float(1 - exp(-dt / Self.lifting))
            }
        }
        churn += dt * (Self.pace.lowerBound + Double(loud) * (Self.pace.upperBound - Self.pace.lowerBound))
    }
}

/// Draws the Nimbus visualizer (`NimbusView`) into an MTKView's drawable
/// or any texture: a cloud in the dusk sky, its billows swelling, rising
/// and glowing with the voices (Shaders/Nimbus.metal). The bloom is the
/// Notes visualizer's. The camera circles it, rising, sinking and coming
/// in as it goes.
final class NimbusRenderer {
    let device: MTLDevice?
    /// Voices 1–3, from the theme.
    var voiceColors: [SIMD3<Float>] = Array(repeating: SIMD3(1, 1, 1), count: 3)

    static let bloom: Float = 0.3

    /// How finely the scene is found at each quality level: points a
    /// sample, and steps through the cloud.
    static func detail(_ quality: VisualizerQuality.Level) -> (pointsPerSample: Float, steps: Int) {
        switch quality {
        case .full: (1, 56)
        case .reduced: (1.5, 44)
        case .low: (2, 32)
        }
    }

    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let compositePipeline: MTLRenderPipelineState?
    private let downscale: MPSImageBilinearScale?
    private let blur: MPSImageGaussianBlur?
    private var scene: MTLTexture?
    private var small: MTLTexture?
    private var blurred: MTLTexture?
    private let noise: MTLTexture?

    /// `library` is the app's own unless given, as a harness outside the
    /// app does.
    init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), library: MTLLibrary? = nil) {
        self.device = device
        queue = device?.makeCommandQueue()
        let library = library ?? device?.makeDefaultLibrary()
        func make(_ vertex: String, _ fragment: String, _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
            guard let device else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library?.makeFunction(name: vertex)
            descriptor.fragmentFunction = library?.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        pipeline = make("nimbusVertex", "nimbusFragment", .rgba16Float)
        compositePipeline = make("notesCompositeVertex", "notesCompositeFragment", .bgra8Unorm)
        downscale = device.map { MPSImageBilinearScale(device: $0) }
        blur = device.map { MPSImageGaussianBlur(device: $0, sigma: 4) }
        noise = Self.noise(device: device)
    }

    /// A block of random values, 64 a side, that repeats. Read between
    /// its points it's smooth noise, which is all the cloud's shape is.
    /// It's the same every time, and takes under a millisecond to fill.
    private static func noise(device: MTLDevice?) -> MTLTexture? {
        let side = 64
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .r8Unorm
        d.width = side
        d.height = side
        d.depth = side
        d.usage = .shaderRead
        guard let texture = device?.makeTexture(descriptor: d) else { return nil }
        var state: UInt64 = 0x9E3779B97F4A7C15
        let bytes = (0..<side * side * side).map { _ -> UInt8 in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        texture.replace(region: MTLRegionMake3D(0, 0, 0, side, side, side), mipmapLevel: 0, slice: 0, withBytes: bytes,
                        bytesPerRow: side, bytesPerImage: side * side)
        return texture
    }

    var commandQueue: MTLCommandQueue? { queue }

    /// Where the camera is at `clock`: circling the cloud about once in
    /// two minutes, now above it and now below, now and then coming in,
    /// as several slow movements drift in and out of step.
    static func camera(clock: Double) -> (position: SIMD3<Float>, target: SIMD3<Float>) {
        let t = clock
        let around = Float(t * 0.05 + 0.45 * sin(t * 0.063) + 2.4)
        let height = Float(0.3 + 1.3 * sin(t * 0.057 + 1) + 0.25 * sin(t * 0.21))
        let away = Float(10.5 + 1.5 * sin(t * 0.041 + 3) + 0.3 * sin(t * 0.15))
        return (SIMD3(sin(around) * away, height, cos(around) * away), SIMD3(0, Float(0.12 * sin(t * 0.09)), 0))
    }

    /// Renders the cloud into `target` (bgra8Unorm) as `voices` has it.
    /// `clock` moves the camera and the water; `scale` is pixels a point.
    func encode(into target: MTLTexture, commands: MTLCommandBuffer, voices: NimbusVoices, clock: Double, scale: Float,
                quality: VisualizerQuality.Level = .full) {
        guard let pipeline, let compositePipeline, let noise else { return }
        let detail = Self.detail(quality)
        let reduce = max(1, scale * detail.pointsPerSample)
        prepareTextures(width: max(Int(Float(target.width) / reduce), 1), height: max(Int(Float(target.height) / reduce), 1))
        guard let scene, let small, let blurred else { return }

        let size = SIMD2(Float(scene.width), Float(scene.height))
        let (eye, lookAt) = Self.camera(clock: clock)
        // A narrow view stands farther back, so the cloud stays in it.
        let back = max(1, 1.45 / max(size.x / size.y, 0.2))
        let position = lookAt + (eye - lookAt) * back
        let forward = simd_normalize(lookAt - position)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        func color(_ i: Int) -> SIMD4<Float> { SIMD4(voiceColors[i % voiceColors.count], voices.glow[i]) }
        let values: [SIMD4<Float>] = [
            SIMD4(position, 0), SIMD4(right, Float(clock.truncatingRemainder(dividingBy: 3600))), SIMD4(up, 0),
            SIMD4(forward, size.y * 1.35), SIMD4(size.x, size.y, Float(detail.steps), voices.level),
            color(0), color(1), color(2), SIMD4(voices.swell, Float(voices.churn.truncatingRemainder(dividingBy: 3600))),
            SIMD4(voices.lift, 0),
        ] + (0..<6).map { voices.ball($0, churn: voices.churn) }
          + (0..<6).map { voices.ball($0, churn: voices.churn - NimbusVoices.trail) }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scene
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(values, length: values.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(noise, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        downscale?.encode(commandBuffer: commands, sourceTexture: scene, destinationTexture: small)
        blur?.encode(commandBuffer: commands, sourceTexture: small, destinationTexture: blurred)

        let out = MTLRenderPassDescriptor()
        out.colorAttachments[0].texture = target
        out.colorAttachments[0].loadAction = .clear
        out.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        out.colorAttachments[0].storeAction = .store
        guard let composite = commands.makeRenderCommandEncoder(descriptor: out) else { return }
        // Bloom, and no backdrop light (see `NotesComposite`).
        var look = SIMD2(Self.bloom, 0)
        composite.setRenderPipelineState(compositePipeline)
        composite.setFragmentTexture(scene, index: 0)
        composite.setFragmentTexture(blurred, index: 1)
        composite.setFragmentBytes(&look, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        composite.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        composite.endEncoding()
    }

    private func prepareTextures(width: Int, height: Int) {
        guard let device, scene?.width != width || scene?.height != height else { return }
        func texture(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(w, 1),
                                                             height: max(h, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        scene = texture(width, height)
        small = texture(width / 2, height / 2)
        blurred = texture(width / 2, height / 2)
    }

    // MARK: Offscreen

    /// Renders the cloud offscreen and waits for the GPU.
    func render(width: Int, height: Int, voices: NimbusVoices, clock: Double, scale: Float = 2,
                quality: VisualizerQuality.Level = .full) -> MTLTexture? {
        guard let device, let commands = queue?.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        encode(into: target, commands: commands, voices: voices, clock: clock, scale: scale, quality: quality)
        commands.commit()
        commands.waitUntilCompleted()
        return target
    }

    /// The same as an image, for tests and checks.
    func image(width: Int, height: Int, voices: NimbusVoices, clock: Double, scale: Float = 2) -> CGImage? {
        render(width: width, height: height, voices: voices, clock: clock, scale: scale)
            .flatMap { VisualizerSnapshot.image(of: $0, background: .zero) }
    }
}
