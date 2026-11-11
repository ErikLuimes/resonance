import simd
import MetalKit
import MetalPerformanceShaders

/// The three magnets under the Ferrofluid visualizer's pool, one per
/// voice: where each is and how hard it pulls, eased so the fluid moves
/// like something with weight. A voice's level is its pull, rising fast
/// and sinking slowly; a new note kicks it; and the note within its
/// octave slides the magnet in and out from the pool's middle.
nonisolated struct FerroField {
    struct Magnet: Equatable {
        /// On the pool's floor, from its middle.
        var position: SIMD2<Float>
        /// 0–1 and a little over on a note's start.
        var pull: Float
    }

    private(set) var magnets = [Magnet](repeating: Magnet(position: .zero, pull: 0), count: 3)

    /// How far from the middle a magnet goes, for the lowest and highest
    /// note of an octave, and how far its pull reaches.
    static let nearest: Float = 0.38
    static let farthest: Float = 1.0
    static let reach: Float = 0.32
    /// The magnets turn slowly round the middle, a turn in two minutes.
    static let drift = -0.05
    /// Seconds for the pull to (mostly) rise and to sink, and for a
    /// magnet to slide to a new note's place.
    static let rise = 0.03
    static let sink = 0.28
    static let slide = 0.12
    static let kick: Float = 0.3

    private var lastMidi: [Float?] = [nil, nil, nil]
    private var wasSounding = [false, false, false]
    private var started = false

    /// Advance by `dt` seconds with what the voices are playing.
    mutating func update(voices: [InkJets.Voice], dt: Double, clock: Double) {
        for v in 0..<3 {
            let voice = v < voices.count ? voices[v] : InkJets.Voice(level: 0, midi: 0)
            let sounding = voice.level > 0.04
            let moved = lastMidi[v].map { abs($0 - voice.midi) > 0.5 } ?? true
            let noteStarted = sounding && (!wasSounding[v] || (moved && !voice.isNoise))
            wasSounding[v] = sounding
            if sounding { lastMidi[v] = voice.midi }

            let midi = lastMidi[v] ?? 60
            let within = midi / 12 - (midi / 12).rounded(.down)
            let angle = Float(clock * Self.drift) + Float(v) * 2 * .pi / 3
            let distance = Self.nearest + (Self.farthest - Self.nearest) * within
            let place = SIMD2(cos(angle), sin(angle)) * distance
            let target = sounding ? min(1, voice.level) : 0
            let pullTime = target > magnets[v].pull ? Self.rise : Self.sink
            magnets[v].pull += (target - magnets[v].pull) * Float(1 - exp(-dt / pullTime))
            if noteStarted { magnets[v].pull = min(1.2, magnets[v].pull + Self.kick) }
            let k = started ? Float(1 - exp(-dt / Self.slide)) : 1
            magnets[v].position += (place - magnets[v].position) * k
        }
        started = true
    }
}

/// Draws the Ferrofluid visualizer (`FerroView`) into an MTKView's
/// drawable or any texture: a pool of black liquid standing in spikes
/// over three magnets, with each voice's colored light gleaming in it.
/// Shaders/Ferro.metal finds and lights the surface for every pixel; the
/// bloom is the Notes visualizer's. The camera circles the pool slowly,
/// rising, sinking and leaning in as it goes.
final class FerroRenderer {
    let device: MTLDevice?
    /// Voices 1–3, from the theme.
    var voiceColors: [SIMD3<Float>] = Array(repeating: SIMD3(1, 1, 1), count: 3)

    static let bloom: Float = 0.7
    static let poolRadius: Float = 1.7
    static let spacing: Float = 0.125
    /// How finely the surface is found at each quality level: points a
    /// sample, and steps along each line of sight. At full quality it's
    /// one sample a point, not a pixel: on a Retina display that's a
    /// quarter of the work, and it's a soft, glossy thing anyway. Each
    /// level down costs about a third of the one above.
    static func detail(_ quality: VisualizerQuality.Level) -> (pointsPerSample: Float, steps: Int) {
        switch quality {
        case .full: (1, 88)
        case .reduced: (1.5, 64)
        case .low: (2, 48)
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
        pipeline = make("ferroVertex", "ferroFragment", .rgba16Float)
        compositePipeline = make("notesCompositeVertex", "notesCompositeFragment", .bgra8Unorm)
        downscale = device.map { MPSImageBilinearScale(device: $0) }
        blur = device.map { MPSImageGaussianBlur(device: $0, sigma: 3) }
    }

    var commandQueue: MTLCommandQueue? { queue }

    /// Matches `FerroUniforms` in Ferro.metal.
    private struct Uniforms {
        var cameraPosition: SIMD4<Float>
        var cameraRight: SIMD4<Float>
        var cameraUp: SIMD4<Float>
        var cameraForward: SIMD4<Float>
        var view: SIMD4<Float>
        var magnets: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    /// Where the camera is at `clock`: circling the pool about once in
    /// two minutes, and now and then swinging wider, higher or closer,
    /// as several slow movements drift in and out of step.
    static func camera(clock: Double) -> (position: SIMD3<Float>, target: SIMD3<Float>) {
        let t = clock
        let around = Float(t * 0.055 + 0.5 * sin(t * 0.071) + 0.25 * sin(t * 0.19 + 1))
        let height = Float(1.55 + 0.38 * sin(t * 0.083 + 2) + 0.14 * sin(t * 0.23))
        let away = Float(3.5 + 0.5 * sin(t * 0.061 + 4) + 0.2 * sin(t * 0.17 + 3))
        let target = SIMD3<Float>(Float(0.12 * sin(t * 0.11)), 0.12, Float(0.12 * cos(t * 0.09)))
        return (SIMD3(sin(around) * away, height, cos(around) * away), target)
    }

    /// Renders the pool into `target` (bgra8Unorm) with the magnets as
    /// they are. `clock` moves the camera; `scale` is pixels per point.
    func encode(into target: MTLTexture, commands: MTLCommandBuffer, magnets: [FerroField.Magnet], clock: Double, scale: Float,
                quality: VisualizerQuality.Level = .full) {
        guard let pipeline, let compositePipeline, magnets.count >= 3 else { return }
        let detail = Self.detail(quality)
        let reduce = max(1, scale * detail.pointsPerSample)
        prepareTextures(width: max(Int(Float(target.width) / reduce), 1), height: max(Int(Float(target.height) / reduce), 1))
        guard let scene, let small, let blurred else { return }

        let size = SIMD2(Float(scene.width), Float(scene.height))
        let (eye, lookAt) = Self.camera(clock: clock)
        // A narrow view stands farther back, so the pool stays in it.
        let back = max(1, 1.5 / max(size.x / size.y, 0.2))
        let position = lookAt + (eye - lookAt) * back
        let forward = simd_normalize(lookAt - position)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        func magnet(_ i: Int) -> SIMD4<Float> {
            SIMD4(magnets[i].position.x, magnets[i].position.y, magnets[i].pull, FerroField.reach)
        }
        func color(_ i: Int) -> SIMD4<Float> { SIMD4(voiceColors[i % voiceColors.count], 1) }
        var uniforms = Uniforms(
            cameraPosition: SIMD4(position, Float(detail.steps)), cameraRight: SIMD4(right, 0), cameraUp: SIMD4(up, 0),
            cameraForward: SIMD4(forward, size.y * 1.3),
            view: SIMD4(size.x, size.y, Self.poolRadius, Self.spacing),
            magnets: (magnet(0), magnet(1), magnet(2)), colors: (color(0), color(1), color(2)))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scene
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
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

    /// Renders the pool offscreen and waits for the GPU.
    func render(width: Int, height: Int, magnets: [FerroField.Magnet], clock: Double, scale: Float = 2,
                quality: VisualizerQuality.Level = .full) -> MTLTexture? {
        guard let device, let commands = queue?.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        encode(into: target, commands: commands, magnets: magnets, clock: clock, scale: scale, quality: quality)
        commands.commit()
        commands.waitUntilCompleted()
        return target
    }

    /// The same as an image over `background`, for tests and checks.
    func image(width: Int, height: Int, magnets: [FerroField.Magnet], clock: Double, scale: Float = 2,
               quality: VisualizerQuality.Level = .full, background: SIMD3<Float> = SIMD3(14, 14, 16) / 255) -> CGImage? {
        render(width: width, height: height, magnets: magnets, clock: clock, scale: scale, quality: quality)
            .flatMap { VisualizerSnapshot.image(of: $0, background: background) }
    }
}
