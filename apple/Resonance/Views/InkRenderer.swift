import simd
import MetalKit

/// What one voice pours into the Ink visualizer's fluid in a frame.
nonisolated struct InkPour: Equatable {
    /// Where, across and down the view, 0–1.
    var position: SIMD2<Float>
    /// Which way it pushes: a unit vector, y down.
    var direction: SIMD2<Float>
    var color: SIMD3<Float>
    /// How hard it's pouring, 0–1: the voice's level.
    var flow: Float
    /// 1 on the frame a note starts, for a puff; else 0.
    var burst: Float
}

/// Where the three voices pour from and which way, worked out from what
/// they're playing. They stand on a ring around the middle, a third of a
/// turn apart, drifting slowly round it, and aim across it: the note
/// within its octave steers the jet from side to side, so a melody sweeps
/// its stream about, and each voice's level is how hard it pours.
nonisolated struct InkJets {
    struct Voice {
        var level: Float
        var midi: Float
        /// Noise has no pitch: its jet wavers instead of steering.
        var isNoise = false
    }

    /// The ring's middle and radius, in view heights (x from the middle).
    static let center = SIMD2<Float>(0.5, 0.46)
    static let radius: Float = 0.33
    /// A full turn of the ring takes about two minutes.
    static let drift = 0.05
    /// The widest a jet steers off the middle, in radians.
    static let steer: Float = 0.75

    private var lastMidi: [Float?] = [nil, nil, nil]
    private var wasSounding = [false, false, false]

    /// The pours for this frame. `aspect` is the view's width over its
    /// height; `clock` is any steady clock, in seconds.
    mutating func pours(voices: [Voice], colors: [SIMD3<Float>], aspect: Float, clock: Double) -> [InkPour] {
        (0..<3).compactMap { v -> InkPour? in
            guard v < voices.count, v < colors.count else { return nil }
            let voice = voices[v]
            let sounding = voice.level > 0.04
            // A note starts when the voice comes in, or moves by more than
            // half a semitone while sounding.
            let moved = lastMidi[v].map { abs($0 - voice.midi) > 0.5 } ?? true
            let started = sounding && (!wasSounding[v] || (moved && !voice.isNoise))
            wasSounding[v] = sounding
            if sounding { lastMidi[v] = voice.midi }
            guard sounding else { return nil }

            let angle = Float(clock * Self.drift) + Float(v) * 2 * .pi / 3
            let out = SIMD2(cos(angle), sin(angle))
            let within = voice.midi / 12 - (voice.midi / 12).rounded(.down)
            let turn = voice.isNoise ? Float(sin(clock * 23 + Double(v))) * Self.steer : (within - 0.5) * 2 * Self.steer
            let aim = SIMD2(-out.x * cos(turn) + out.y * sin(turn), -out.x * sin(turn) - out.y * cos(turn))
            let place = Self.center + SIMD2(out.x * Self.radius / max(aspect, 0.3), out.y * Self.radius)
            return InkPour(position: place, direction: aim, color: colors[v], flow: min(1, voice.level),
                           burst: started ? 1 : 0)
        }
    }
}

/// Draws the Ink and Liquid Light visualizers (`InkView`) into an
/// MTKView's drawable or any texture: three streams of dye, one per voice
/// in its color, pouring into a fluid that swirls and mixes them. The fluid is a stable-fluids
/// solver run on the GPU each frame (Shaders/Ink.metal): a coarse grid of
/// velocities carries a finer one of dye, which is lit like the surface
/// of a liquid.
final class InkRenderer {
    let device: MTLDevice?

    /// Which visualizer this is: the same fluid, poured and shown two ways.
    let style: Style

    struct Style {
        /// How much dye a voice at full level pours a second, and the
        /// blot a note's start adds.
        var pour: Float
        var burstDye: Float
        /// A stream's width, in view heights.
        var nozzle: Float
        /// How fast the dye fades, per second.
        var dyeFade: Float
        /// How strongly whirls are kept up.
        var swirl: Float
        var exposure: Float
        var shine: Float
        /// The fragment function that shows the dye.
        var display: String

        /// Wisps of dye in dark water: thin streams that curl and are
        /// gone in a few seconds (the dye halves in about three).
        static let ink = Style(pour: 1.5, burstDye: 0.4, nozzle: 0.018, dyeFade: 0.24, swirl: 14,
                               exposure: 1.3, shine: 0.1, display: "inkDisplayFragment")
        /// Thick oil that stays: it halves in about eight seconds, so
        /// the glass fills and marbles.
        static let liquidLight = Style(pour: 2.6, burstDye: 0.55, nozzle: 0.024, dyeFade: 0.085, swirl: 22,
                                       exposure: 1.5, shine: 0.85, display: "inkLiquidLightFragment")
    }

    // The fluid.
    /// Cells down the velocity grid; the dye has four times as many.
    static let cells = 176
    static let dyeScale = 4
    /// How hard a voice at full level pushes, in cells a second squared.
    static let push: Float = 5200
    /// The shove a note's start gives, in cells a second.
    static let burstPush: Float = 170
    static let velocityFade: Float = 0.35
    /// Rounds of working the pressure out at each quality level: most of
    /// the fluid's cost. Fewer leave it a little springier, not broken.
    static func pressureRounds(_ quality: VisualizerQuality.Level) -> Int {
        switch quality {
        case .full: 22
        case .reduced: 14
        case .low: 10
        }
    }

    private let queue: MTLCommandQueue?
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var velocity: Pair?
    private var pressure: Pair?
    private var dye: Pair?
    private var divergence: MTLTexture?
    private var curl: MTLTexture?
    private var gridSize = SIMD2<Int>(0, 0)

    /// Two textures to go back and forth between: a pass reads one and
    /// writes the other.
    private struct Pair {
        var read: MTLTexture
        var write: MTLTexture
        mutating func swap() { (read, write) = (write, read) }
    }

    /// `library` is the app's own unless given, as a harness outside the
    /// app does.
    init(style: Style = .ink, device: MTLDevice? = MTLCreateSystemDefaultDevice(), library: MTLLibrary? = nil) {
        self.style = style
        self.device = device
        queue = device?.makeCommandQueue()
        guard let device, let library = library ?? device.makeDefaultLibrary() else { return }
        func make(_ name: String, vertex: String = "inkVertex", fragment: String, format: MTLPixelFormat, adds: Bool = false) {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if adds {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            pipelines[name] = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        make("splatVelocity", vertex: "inkSplatVertex", fragment: "inkSplatFragment", format: .rg16Float, adds: true)
        make("splatDye", vertex: "inkSplatVertex", fragment: "inkSplatFragment", format: .rgba16Float, adds: true)
        make("curl", fragment: "inkCurlFragment", format: .r16Float)
        make("vorticity", fragment: "inkVorticityFragment", format: .rg16Float)
        make("divergence", fragment: "inkDivergenceFragment", format: .r16Float)
        make("scale", fragment: "inkScaleFragment", format: .r16Float)
        make("pressure", fragment: "inkPressureFragment", format: .r16Float)
        make("gradient", fragment: "inkGradientFragment", format: .rg16Float)
        make("advectVelocity", fragment: "inkAdvectFragment", format: .rg16Float)
        make("advectDye", fragment: "inkAdvectFragment", format: .rgba16Float)
        make("display", fragment: style.display, format: .bgra8Unorm)
    }

    var commandQueue: MTLCommandQueue? { queue }

    /// Matches `InkUniforms` in Ink.metal.
    private struct Uniforms {
        var texel: SIMD2<Float>
        var dt: Float
        var a: Float = 0
        var b: Float = 0
        var c: Float = 0
        var d: Float = 0
        var e: Float = 0
    }

    /// Moves the fluid on by `dt` seconds with what the voices pour in,
    /// and draws it into `target` (bgra8Unorm).
    func encode(into target: MTLTexture, commands: MTLCommandBuffer, pours: [InkPour], dt: Double,
                quality: VisualizerQuality.Level = .full) {
        prepare(width: target.width, height: target.height)
        guard pipelines.count == 11, var velocity, var pressure, var dye, let divergence, let curl else { return }
        // A long gap (a paused view coming back) is one ordinary step, or
        // two at the lowest quality's half rate.
        let dt = Float(min(max(dt, 0), 1.0 / 30))
        let cell = SIMD2(1 / Float(gridSize.x), 1 / Float(gridSize.y))
        let dyeCell = cell / Float(Self.dyeScale)
        let aspect = Float(gridSize.x) / Float(gridSize.y)

        func pass(_ name: String, to target: MTLTexture, _ textures: [MTLTexture], _ uniforms: Uniforms) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let pipeline = pipelines[name], let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            var uniforms = uniforms
            encoder.setRenderPipelineState(pipeline)
            for (index, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        /// Adds soft-edged blots to `target`: two SIMD4s each (`InkSplat`).
        func splat(_ name: String, onto target: MTLTexture, _ splats: [SIMD4<Float>]) {
            guard !splats.isEmpty, let device, let pipeline = pipelines[name],
                  let buffer = device.makeBuffer(bytes: splats, length: splats.count * MemoryLayout<SIMD4<Float>>.stride)
            else { return }
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .load
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splats.count / 2)
            encoder.endEncoding()
        }

        // What the voices pour in.
        var pushes: [SIMD4<Float>] = [], blots: [SIMD4<Float>] = []
        for pour in pours {
            let size = style.nozzle * (1 + pour.burst * 1.4)
            let place = SIMD4(pour.position.x, pour.position.y, size / aspect, size)
            let speed = Self.push * pour.flow * dt + Self.burstPush * pour.burst
            let amount = style.pour * pour.flow * dt + style.burstDye * pour.burst
            pushes.append(place)
            pushes.append(SIMD4(pour.direction.x * speed, pour.direction.y * speed, 0, 0))
            blots.append(place)
            blots.append(SIMD4(pour.color * amount, 0))
        }
        splat("splatVelocity", onto: velocity.read, pushes)
        splat("splatDye", onto: dye.read, blots)

        // Keep the whirls up.
        pass("curl", to: curl, [velocity.read], Uniforms(texel: cell, dt: dt))
        pass("vorticity", to: velocity.write, [velocity.read, curl], Uniforms(texel: cell, dt: dt, a: style.swirl))
        velocity.swap()

        // Take out the squeezing, so it flows like a liquid.
        pass("divergence", to: divergence, [velocity.read], Uniforms(texel: cell, dt: dt))
        pass("scale", to: pressure.write, [pressure.read], Uniforms(texel: cell, dt: dt, a: 0.8))
        pressure.swap()
        for _ in 0..<Self.pressureRounds(quality) {
            pass("pressure", to: pressure.write, [pressure.read, divergence], Uniforms(texel: cell, dt: dt))
            pressure.swap()
        }
        pass("gradient", to: velocity.write, [velocity.read, pressure.read], Uniforms(texel: cell, dt: dt))
        velocity.swap()

        // Carry the motion, then the dye, along the flow.
        pass("advectVelocity", to: velocity.write, [velocity.read, velocity.read],
             Uniforms(texel: cell, dt: dt, a: Self.velocityFade, b: cell.x, c: cell.y))
        velocity.swap()
        pass("advectDye", to: dye.write, [velocity.read, dye.read],
             Uniforms(texel: dyeCell, dt: dt, a: style.dyeFade, b: cell.x, c: cell.y))
        dye.swap()

        pass("display", to: target, [dye.read], Uniforms(texel: dyeCell, dt: dt, a: style.exposure, b: style.shine))

        self.velocity = velocity
        self.pressure = pressure
        self.dye = dye
    }

    /// The grids, sized to the view's shape: square cells, `cells` down.
    /// A new shape starts with still, clear fluid.
    private func prepare(width: Int, height: Int) {
        guard let device, width > 0, height > 0 else { return }
        let across = max(16, Int((Float(Self.cells) * Float(width) / Float(height)).rounded()))
        let size = SIMD2(min(across, Self.cells * 4), Self.cells)
        guard size != gridSize else { return }
        gridSize = size
        func texture(_ format: MTLPixelFormat, scale: Int = 1) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.x * scale, height: size.y * scale,
                                                             mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let made = device.makeTexture(descriptor: d) else { return nil }
            clear(made)
            return made
        }
        func pair(_ format: MTLPixelFormat, scale: Int = 1) -> Pair? {
            guard let a = texture(format, scale: scale), let b = texture(format, scale: scale) else { return nil }
            return Pair(read: a, write: b)
        }
        velocity = pair(.rg16Float)
        pressure = pair(.r16Float)
        dye = pair(.rgba16Float, scale: Self.dyeScale)
        divergence = texture(.r16Float)
        curl = texture(.r16Float)
    }

    private func clear(_ texture: MTLTexture) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.colorAttachments[0].storeAction = .store
        guard let commands = queue?.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.endEncoding()
        commands.commit()
    }

    // MARK: Offscreen

    /// Moves the fluid on a step and renders it offscreen, waiting for the GPU.
    func render(width: Int, height: Int, pours: [InkPour], dt: Double) -> MTLTexture? {
        guard let device, let commands = queue?.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        encode(into: target, commands: commands, pours: pours, dt: dt)
        commands.commit()
        commands.waitUntilCompleted()
        return target
    }

    /// The same as an image over `background`, for tests and checks.
    func image(width: Int, height: Int, pours: [InkPour], dt: Double,
               background: SIMD3<Float> = SIMD3(14, 14, 16) / 255) -> CGImage? {
        render(width: width, height: height, pours: pours, dt: dt)
            .flatMap { VisualizerSnapshot.image(of: $0, background: background) }
    }
}
