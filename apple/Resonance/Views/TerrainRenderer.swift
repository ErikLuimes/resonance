import simd
import MetalKit
import MetalPerformanceShaders

/// Draws the Terrain visualizer (`TerrainView`) into an MTKView's drawable
/// or any texture: the last few seconds of the spectrum as a landscape of
/// ridge lines, the newest at the front. It keeps those seconds in a
/// texture, one row per moment, and Shaders/Terrain.metal builds and
/// lights the mesh from it; the bloom is the Notes visualizer's.
final class TerrainRenderer {
    let device: MTLDevice?
    /// Voices 1–3 and the background, from the theme.
    var voiceColors: [SIMD3<Float>] = Array(repeating: SIMD3(1, 1, 1), count: 3)
    var background = SIMD3<Float>(14, 14, 16) / 255

    /// Bands across (`FineSpectrum`'s) and moments deep.
    static let columns = 128
    static let rows = 120
    /// How fast the land slides away: this many rows a second, so the
    /// back row is 4 seconds old.
    static let rowsPerSecond = 30.0
    static let bloom: Float = 0.45
    /// The land's size, in its own units.
    static let width: Float = 4.4
    static let depth: Float = 5.2
    static let height: Float = 0.85

    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let compositePipeline: MTLRenderPipelineState?
    private let depthState: MTLDepthStencilState?
    private let downscale: MPSImageBilinearScale?
    private let blur: MPSImageGaussianBlur?
    private let history: MTLTexture?
    private var scene: MTLTexture?
    private var depthTexture: MTLTexture?
    private var small: MTLTexture?
    private var blurred: MTLTexture?
    /// The texture row holding the spectrum now, and when it became that.
    private var newest = 0
    private var rowStarted: Double?
    private var row = [Float](repeating: 0, count: TerrainRenderer.columns * 4)

    /// `library` is the app's own unless given, as a harness outside the
    /// app does.
    init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), library: MTLLibrary? = nil) {
        self.device = device
        queue = device?.makeCommandQueue()
        let library = library ?? device?.makeDefaultLibrary()
        pipeline = device.flatMap { device in
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library?.makeFunction(name: "terrainVertex")
            descriptor.fragmentFunction = library?.makeFunction(name: "terrainFragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .rgba16Float
            // Premultiplied: the land fades out at the back.
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            descriptor.depthAttachmentPixelFormat = .depth32Float
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        compositePipeline = device.flatMap { device in
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library?.makeFunction(name: "notesCompositeVertex")
            descriptor.fragmentFunction = library?.makeFunction(name: "notesCompositeFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        depthState = device.flatMap { device in
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = .less
            descriptor.isDepthWriteEnabled = true
            return device.makeDepthStencilState(descriptor: descriptor)
        }
        downscale = device.map { MPSImageBilinearScale(device: $0) }
        blur = device.map { MPSImageGaussianBlur(device: $0, sigma: 4) }
        history = device.flatMap { device in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: Self.columns,
                                                             height: Self.rows, mipmapped: false)
            d.usage = .shaderRead
            let texture = device.makeTexture(descriptor: d)
            let silence = [Float](repeating: 0, count: Self.columns * Self.rows * 4)
            texture?.replace(region: MTLRegionMake2D(0, 0, Self.columns, Self.rows), mipmapLevel: 0,
                             withBytes: silence, bytesPerRow: Self.columns * 4 * MemoryLayout<Float>.stride)
            return texture
        }
    }

    var commandQueue: MTLCommandQueue? { queue }

    /// Matches `TerrainUniforms` in Terrain.metal.
    private struct Uniforms {
        var viewProjection: simd_float4x4
        var color0: SIMD4<Float>
        var color1: SIMD4<Float>
        var color2: SIMD4<Float>
        var background: SIMD4<Float>
        var grid: SIMD4<Float>
        var shape: SIMD4<Float>
    }

    /// Renders into `target` (bgra8Unorm) with the spectrum now: `levels`
    /// is `columns` levels per voice, voice after voice (`FineSpectrum`).
    /// `clock` is any steady clock in seconds; it moves the land along and
    /// sways the camera.
    func encode(into target: MTLTexture, commands: MTLCommandBuffer, levels: [Float], clock: Double, scale: Float) {
        guard let pipeline, let compositePipeline, let depthState, let history else { return }
        prepareTextures(width: target.width, height: target.height)
        guard let scene, let depthTexture, let small, let blurred else { return }

        let phase = advance(to: clock)
        write(levels)

        let colors = (0..<3).map { SIMD4(voiceColors[$0 % voiceColors.count], 1) }
        var uniforms = Uniforms(
            viewProjection: Self.camera(aspect: Float(target.width) / Float(max(target.height, 1)), clock: clock),
            color0: colors[0], color1: colors[1], color2: colors[2],
            background: SIMD4(background, 1),
            grid: SIMD4(Float(Self.columns), Float(Self.rows), Float(newest), phase),
            shape: SIMD4(Self.width, Self.depth, Self.height, scale))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scene
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexTexture(history, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: (Self.columns - 1) * (Self.rows - 1) * 6)
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

    /// Moves on to new rows as their time comes, and returns how far
    /// through the current one `clock` is, 0–1.
    private func advance(to clock: Double) -> Float {
        let length = 1 / Self.rowsPerSecond
        guard let started = rowStarted, clock >= started, clock - started < Double(Self.rows) * length else {
            // The first frame, or back after a long pause: start over from here.
            rowStarted = clock
            return 0
        }
        let passed = Int((clock - started) / length)
        if passed > 0 {
            // The rows in between keep the spectrum they were last given.
            newest = (newest + passed) % Self.rows
            rowStarted = started + Double(passed) * length
        }
        return Float((clock - (rowStarted ?? clock)) / length)
    }

    /// Writes the spectrum now into the newest row.
    private func write(_ levels: [Float]) {
        guard let history else { return }
        let n = Self.columns
        guard levels.count >= 3 * n else { return }
        for column in 0..<n {
            // Rounded off a little across the bands, so a peak is a hill
            // rather than a spike.
            let left = max(column - 1, 0), right = min(column + 1, n - 1)
            for voice in 0..<3 {
                let at = voice * n
                row[column * 4 + voice] = 0.25 * levels[at + left] + 0.5 * levels[at + column] + 0.25 * levels[at + right]
            }
        }
        history.replace(region: MTLRegionMake2D(0, newest, n, 1), mipmapLevel: 0, withBytes: row,
                        bytesPerRow: n * 4 * MemoryLayout<Float>.stride)
    }

    private func prepareTextures(width: Int, height: Int) {
        guard let device, scene?.width != width || scene?.height != height else { return }
        func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(w, 1), height: max(h, 1),
                                                             mipmapped: false)
            d.usage = format == .depth32Float ? .renderTarget : [.renderTarget, .shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        scene = texture(width, height, .rgba16Float)
        depthTexture = texture(width, height, .depth32Float)
        small = texture(width / 4, height / 4, .rgba16Float)
        blurred = texture(width / 4, height / 4, .rgba16Float)
    }

    // MARK: Camera

    /// From in front of the land and above it, looking down its length,
    /// drifting a little from side to side. A narrow view stands farther
    /// back, so the land's whole width stays in it.
    static func camera(aspect: Float, clock: Double) -> simd_float4x4 {
        let turn = 0.2 * Float(sin(clock * 0.09))
        let lift = 0.08 * Float(sin(clock * 0.13 + 2))
        let back = max(1, 1.45 / max(aspect, 0.2))
        // The land runs away along −z, so its low bands are on the left.
        let target = SIMD3<Float>(0, 0.1, -depth * 0.4)
        let eye = target + SIMD3(sin(turn) * 5.5, 2.7 + lift, cos(turn) * 5.5) * back
        return perspective(fovY: 0.68, aspect: aspect, near: 0.1, far: 60) * look(from: eye, at: target)
    }

    private static func look(from eye: SIMD3<Float>, at target: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        return simd_float4x4(columns: (
            SIMD4(right.x, up.x, -forward.x, 0),
            SIMD4(right.y, up.y, -forward.y, 0),
            SIMD4(right.z, up.z, -forward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1)))
    }

    /// Metal's: depth runs 0–1.
    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY / 2)
        return simd_float4x4(columns: (
            SIMD4(y / aspect, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, far / (near - far), -1),
            SIMD4(0, 0, near * far / (near - far), 0)))
    }

    // MARK: Offscreen

    /// The land as it is after `levels` at `clock`, as an image over the
    /// background, for tests and checks.
    func image(width: Int, height: Int, levels: [Float], clock: Double, scale: Float = 2) -> CGImage? {
        render(width: width, height: height, levels: levels, clock: clock, scale: scale)
            .flatMap { VisualizerSnapshot.image(of: $0, background: background) }
    }

    /// Renders offscreen with `levels` at `clock` and waits for the GPU.
    func render(width: Int, height: Int, levels: [Float], clock: Double, scale: Float = 2) -> MTLTexture? {
        guard let device, let commands = queue?.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        encode(into: target, commands: commands, levels: levels, clock: clock, scale: scale)
        commands.commit()
        commands.waitUntilCompleted()
        return target
    }
}
