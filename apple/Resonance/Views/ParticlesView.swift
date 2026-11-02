import MetalKit
import SwiftUI
import PhosphorCore

/// The Particle sphere: 24,000 points over a turning sphere, a third per
/// voice, rippling with each voice's envelope and sending a wave across from
/// the voice's pole on every new note
/// (design/visualizers/reference/Particles.dc.html). `ParticleSphere` keeps
/// the per-voice state on the CPU; Shaders/Particles.metal moves and draws
/// the points, so the CPU does the same small amount of work at any count.
/// Each point eases toward its place rather than jumping to it, so the
/// sphere moves smoothly whatever the music does.
///
/// Shows the first chip, like the Halo.
struct ParticlesView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store

    var body: some View {
        ParticleMetalView(feed: store.visualizer, isActive: isActive)
            // A faint glow behind the sphere, as in the mockup.
            .background {
                RadialGradient(colors: [Color(red: 0.47, green: 0.43, blue: 0.78).opacity(0.10), .clear],
                               center: .center, startRadius: 0, endRadius: 360)
            }
            .accessibilityElement()
            .accessibilityLabel("Particle sphere visualizer")
    }
}

private struct ParticleMetalView: NSViewRepresentable {
    let feed: VisualizerFeed
    let isActive: Bool

    func makeCoordinator() -> ParticleRenderer {
        ParticleRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = PassThroughMTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 120
        view.delegate = context.coordinator
        update(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        update(view, context.coordinator)
    }

    private func update(_ view: MTKView, _ renderer: ParticleRenderer) {
        renderer.feed = feed
        view.isPaused = !isActive
    }
}

/// Never takes the mouse: as an AppKit view it otherwise caught the clicks
/// meant for Now Playing's SwiftUI buttons drawn over it.
private final class PassThroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws the sphere into an MTKView, once per display frame.
final class ParticleRenderer: NSObject, MTKViewDelegate {
    static let count = 24_000

    let device = MTLCreateSystemDefaultDevice()
    var feed: VisualizerFeed?

    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let settle: MTLComputePipelineState?
    private let points: MTLBuffer?
    /// Each point's eased displacement, one float per point.
    private let offsets: MTLBuffer?
    private let sphere = ParticleSphere()
    private var lastTime: Double?

    override init() {
        queue = device?.makeCommandQueue()
        pipeline = device.flatMap(Self.makePipeline)
        settle = device.flatMap { device in
            device.makeDefaultLibrary()?.makeFunction(name: "particleSettle")
                .flatMap { try? device.makeComputePipelineState(function: $0) }
        }
        offsets = device?.makeBuffer(length: Self.count * MemoryLayout<Float>.stride, options: .storageModeShared)
        if let offsets { memset(offsets.contents(), 0, offsets.length) }
        points = device.flatMap { device in
            let data = Self.makePoints()
            return device.makeBuffer(bytes: data, length: data.count * MemoryLayout<SIMD4<Float>>.stride)
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let queue, let pipeline, let settle, let points, let offsets,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer()
        else { return }

        let history = feed?.history(8) ?? []
        sphere.update(history: history, at: .now)
        let dt = lastTime.map { sphere.time - $0 } ?? 0
        lastTime = sphere.time
        var uniforms = makeUniforms(view: view, frame: history.last?.index ?? 0,
                                    follow: Float(1 - exp(-dt / Self.easing)))
        var count = UInt32(Self.count)

        guard let compute = commands.makeComputeCommandEncoder() else { return }
        compute.setComputePipelineState(settle)
        compute.setBuffer(points, offset: 0, index: 0)
        compute.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        compute.setBuffer(offsets, offset: 0, index: 2)
        compute.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
        compute.dispatchThreads(MTLSize(width: Self.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: settle.threadExecutionWidth, height: 1, depth: 1))
        compute.endEncoding()

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(points, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setVertexBuffer(offsets, offset: 0, index: 2)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.count)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    // MARK: Data

    /// Matches `ParticleUniforms` in Particles.metal.
    private struct Uniforms {
        var size: SIMD2<Float>
        var time: Float
        var noiseFrame: Float
        var rotation: SIMD2<Float>
        var radius: Float
        var pointScale: Float
        var alphaScale: Float
        var follow: Float
        var state0: SIMD4<Float>, color0: SIMD4<Float>
        var state1: SIMD4<Float>, color1: SIMD4<Float>
        var state2: SIMD4<Float>, color2: SIMD4<Float>
    }

    /// How long a point takes to (mostly) reach a new place, in seconds.
    private static let easing = 0.08

    private func makeUniforms(view: MTKView, frame: UInt64, follow: Float) -> Uniforms {
        let size = view.drawableSize
        let backing = Float(view.window?.backingScaleFactor ?? 2)
        let t = sphere.time
        let states = (0..<3).map { v in
            SIMD4<Float>(sphere.levels[v], sphere.frequencies[v], Float(t - sphere.hits[v]),
                         sphere.waveforms[v] & 0x8 != 0 ? 1 : 0)
        }
        let colors = Self.colors
        return Uniforms(
            size: SIMD2(Float(size.width), Float(size.height)),
            time: Float(t),
            noiseFrame: Float(frame % 997),
            rotation: SIMD2(Float(t * 0.22), Float(0.38 + sin(t * 0.3) * 0.08)),
            // The mockup's 205 px sphere in a 640 px high view.
            radius: Float(min(size.width, size.height)) * 0.32,
            pointScale: backing * 1.5,
            // The mockup has 2,700 points; this many need to be fainter.
            alphaScale: 0.45,
            follow: follow,
            state0: states[0], color0: colors[0],
            state1: states[1], color1: colors[1],
            state2: states[2], color2: colors[2]
        )
    }

    private static let colors: [SIMD4<Float>] = VisualizerFeed.voiceColors.map { color in
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
    }

    /// A Fibonacci sphere: `count` evenly spread points, two SIMD4s each
    /// (see `ParticlePoint` in Particles.metal), dealt to the voices in turn.
    static func makePoints() -> [SIMD4<Float>] {
        let golden = Float.pi * (3 - Float(5).squareRoot())
        var data: [SIMD4<Float>] = []
        data.reserveCapacity(count * 2)
        for i in 0..<count {
            let y = 1 - Float(i) / Float(count - 1) * 2
            let r = (1 - y * y).squareRoot()
            let theta = golden * Float(i)
            let p = SIMD3(cos(theta) * r, y, sin(theta) * r)
            let voice = i % 3
            let fromPole = acos(max(-1, min(1, simd_dot(p, ParticleSphere.poles[voice]))))
            let seed = Float(HaloShape.Wave.random(UInt64(i + 1)))
            data.append(SIMD4(p, asin(y)))
            data.append(SIMD4(fromPole, seed, Float(voice), 0))
        }
        return data
    }

    private static func makePipeline(_ device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "particleVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "particleFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // Additive, like the mockup's "lighter".
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

#Preview {
    ParticlesView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
