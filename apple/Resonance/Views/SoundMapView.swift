import CoreText
import simd
import MetalKit
import MetalPerformanceShaders
import SwiftUI
import PhosphorCore

/// The Sound Map: every note each voice plays becomes a square in 3D,
/// placed by its timbre (`SoundMap`: MFCCs reduced to 3D by PCA), so notes
/// that sound alike sit together and the music draws paths and clusters as
/// it repeats and changes. A new note flashes white with large labels
/// (amplitude above, spectral spread left, centroid right, time below),
/// settles into its centroid's color, stays lit for a few seconds, then
/// fades into a faint map of everything played so far. Each node links to
/// the earlier ones it sounds most like, and to its voice's previous note
/// in the voice's color. The camera drifts after the newest notes.
///
/// Drawn with Metal (Shaders/SoundMap.metal): lines, squares and labels
/// add up in a half-float scene with bloom. Shows the first chip.
struct SoundMapView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    var body: some View {
        SoundMapMetalView(feed: store.visualizer, theme: theme, isActive: isActive)
            .accessibilityElement()
            .accessibilityLabel("Sound map visualizer")
    }
}

private struct SoundMapMetalView: NSViewRepresentable {
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let isActive: Bool

    func makeCoordinator() -> SoundMapRenderer {
        SoundMapRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = SoundMapMTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = VisualizerFeed.framesPerSecond
        view.delegate = context.coordinator
        update(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        update(view, context.coordinator)
    }

    private func update(_ view: MTKView, _ renderer: SoundMapRenderer) {
        renderer.feed = feed
        renderer.voiceColors = theme.voices.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
        view.isPaused = !isActive
    }
}

/// Never takes the mouse, like the Particles view.
private final class SoundMapMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws the Sound Map into an MTKView once per display frame, or into any
/// texture (`render(map:…)`), which the tests use.
final class SoundMapRenderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()
    var feed: VisualizerFeed?
    /// Voices 1–3, from the theme.
    var voiceColors: [SIMD3<Float>] = Array(repeating: SIMD3(1, 1, 1), count: 3)
    let map = SoundMap()
    /// The share of nodes inside the view in the last frame, for tests.
    private(set) var onScreen: Float = 1

    // The look, from the mockup the user tuned.
    // Timings measured from the user's reference recording
    // (design/visualizers/IMPLEMENTATION_NOTES.md, Sound Map).
    static let bloom: Float = 0.35
    /// Seconds a new node stays white and fully lit.
    static let freshSeconds = 1.0
    /// After that, its light halves about every 0.7 s (time constant 1 s).
    static let fadeSeconds = 1.0
    /// Labels and lines are gone by then, leaving a faint dot.
    static let goneSeconds = 4.0

    private let queue: MTLCommandQueue?
    private let segmentPipeline: MTLRenderPipelineState?
    private let nodePipeline: MTLRenderPipelineState?
    private let glyphPipeline: MTLRenderPipelineState?
    private let compositePipeline: MTLRenderPipelineState?
    private let atlas: GlyphAtlas?
    private var scene: MTLTexture?
    private var small: MTLTexture?
    private var blurred: MTLTexture?
    private var camera = Camera()
    private var lastTime: Double?
    private var labels: [Int: [[UInt8]]] = [:]
    private let downscale: MPSImageBilinearScale?
    private let blur: MPSImageGaussianBlur?

    override init() {
        let device = device
        let queue = device?.makeCommandQueue()
        self.queue = queue
        let library = device?.makeDefaultLibrary()
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blend: MTLBlendOperation?) -> MTLRenderPipelineState? {
            guard let device, let library else { return nil }
            return Self.makePipeline(device, library, vertex, fragment, format: format, blend: blend)
        }
        // Lines add up, so dense clusters glow. Squares and labels take the
        // brightest instead: a note repeated in the same place would
        // otherwise stack into a white blob.
        segmentPipeline = pipeline("mapSegmentVertex", "mapSegmentFragment", format: .rgba16Float, blend: .add)
        nodePipeline = pipeline("mapNodeVertex", "mapNodeFragment", format: .rgba16Float, blend: .max)
        glyphPipeline = pipeline("mapGlyphVertex", "mapGlyphFragment", format: .rgba16Float, blend: .max)
        compositePipeline = pipeline("mapCompositeVertex", "mapCompositeFragment", format: .bgra8Unorm, blend: nil)
        atlas = device.flatMap { device in queue.flatMap { GlyphAtlas(device: device, queue: $0) } }
        downscale = device.map { MPSImageBilinearScale(device: $0) }
        blur = device.map { MPSImageGaussianBlur(device: $0, sigma: 3) }
        super.init()
    }

    private static func makePipeline(_ device: MTLDevice, _ library: MTLLibrary, _ vertex: String, _ fragment: String,
                                     format: MTLPixelFormat, blend: MTLBlendOperation?) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
        if let blend {
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = blend
            attachment.alphaBlendOperation = blend
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commands = queue?.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        if let feed {
            map.update(frames: feed.history(16), scope: { feed.scope(chip: 0, count: MFCCExtractor.size) }, now: now)
        }
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        encode(into: drawable.texture, commands: commands, now: now, scale: scale)
        commands.present(drawable)
        commands.commit()
    }

    /// Renders the map as it is at `now` into `target` (bgra8Unorm).
    func encode(into target: MTLTexture, commands: MTLCommandBuffer, now: Double, scale: Float) {
        guard let device, let segmentPipeline, let nodePipeline, let glyphPipeline, let compositePipeline
        else { return }
        let dt = min(lastTime.map { now - $0 } ?? 0, 0.1)
        lastTime = now
        map.ease(dt: dt)
        prepareTextures(width: target.width, height: target.height)
        guard let scene, let small, let blurred else { return }

        let size = SIMD2(Float(target.width), Float(target.height))
        let frame = build(size: size, scale: scale, now: now, dt: dt)
        var uniforms = size

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scene
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        func draw(_ pipeline: MTLRenderPipelineState, _ instances: [SIMD4<Float>], stride: Int) {
            let count = instances.count / stride
            guard count > 0, let buffer = device.makeBuffer(bytes: instances, length: instances.count * 16) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        draw(segmentPipeline, frame.segments, stride: 3)
        draw(nodePipeline, frame.nodes, stride: 3)
        if let atlas {
            encoder.setFragmentTexture(atlas.texture, index: 0)
            draw(glyphPipeline, frame.glyphs, stride: 3)
        }
        encoder.endEncoding()

        // Bloom: a quarter-size copy, blurred.
        downscale?.encode(commandBuffer: commands, sourceTexture: scene, destinationTexture: small)
        blur?.encode(commandBuffer: commands, sourceTexture: small, destinationTexture: blurred)

        let out = MTLRenderPassDescriptor()
        out.colorAttachments[0].texture = target
        out.colorAttachments[0].loadAction = .clear
        out.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        out.colorAttachments[0].storeAction = .store
        guard let composite = commands.makeRenderCommandEncoder(descriptor: out) else { return }
        var strength = Self.bloom
        composite.setRenderPipelineState(compositePipeline)
        composite.setFragmentTexture(scene, index: 0)
        composite.setFragmentTexture(blurred, index: 1)
        composite.setFragmentBytes(&strength, length: MemoryLayout<Float>.stride, index: 0)
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
        small = texture(width / 4, height / 4)
        blurred = texture(width / 4, height / 4)
    }

    // MARK: Building the frame

    private struct Frame {
        var segments: [SIMD4<Float>] = []
        var nodes: [SIMD4<Float>] = []
        var glyphs: [SIMD4<Float>] = []
    }

    /// A node's look at a given age: white and fully lit for
    /// `freshSeconds`, then fading in its color, then faint for good.
    struct Life {
        var flash: Float
        var lit: Float
        var white: Float

        init(age: Double) {
            let fresh = SoundMapRenderer.freshSeconds
            flash = Float(max(0, 1 - age / 0.6))
            // Exponential, shifted to reach zero at `goneSeconds`, when only
            // the faint dot is left.
            let fading = exp(-(age - fresh) / SoundMapRenderer.fadeSeconds)
            let floor = exp(-(SoundMapRenderer.goneSeconds - fresh) / SoundMapRenderer.fadeSeconds)
            lit = Float(age < fresh ? 1 : max(0, (fading - floor) / (1 - floor)))
            white = Float(max(0, 1 - age / fresh))
        }

        var intensity: Float { max(0.13, lit) }
    }

    /// Orbits the middle of the whole map, keeping all of it in view, as
    /// in the reference recording: it doesn't chase the newest notes. It
    /// turns at about 0.65 rad/s while notes keep coming and slows to about
    /// 0.3 rad/s over a few seconds of quiet.
    private struct Camera {
        var focus = SIMD3<Float>(0, 0, 0)
        var radius: Float = 1
        var activity: Float = 0
        var azimuth: Float = 0
        var time: Float = 0
        var position = SIMD3<Float>(0, 0, 3)
        var forward = SIMD3<Float>(0, 0, -1)
        var right = SIMD3<Float>(1, 0, 0)
        var up = SIMD3<Float>(0, 1, 0)
        var distance: Float = 2.1
        /// Extra distance on top of the measured framing, so the map stays
        /// on screen whatever its shape or the view's (see `fit`).
        var zoom: Float = 1
        private var started = false

        mutating func frame(_ points: [SIMD3<Float>], notesPerSecond: Float, dt: Float) {
            time += dt
            if !points.isEmpty {
                // The middle, and the distance that holds 85% of the nodes.
                let center = points.reduce(.zero, +) / Float(points.count)
                var reach = points.map { simd_length($0 - center) }
                reach.sort()
                let extent = max(0.2, reach[min(reach.count - 1, Int(Float(reach.count) * 0.85))])
                let k = started ? 1 - exp(-dt / 2) : 1
                focus += (center - focus) * k
                radius += (extent - radius) * k
                started = true
            }
            // About six notes a second counts as busy; it calms with a 3 s time constant.
            activity = max(activity * exp(-dt / 3), min(1, notesPerSecond / 6))
            azimuth += (0.3 + 0.38 * activity) * dt
            // Framed so the cloud spreads about as far as in the recording.
            distance = radius * 1.9 * zoom * (1 + 0.08 * sin(time * 0.17))
            let elevation = 0.3 + 0.12 * sin(time * 0.11)
            let direction = SIMD3(cos(elevation) * sin(azimuth), sin(elevation), cos(elevation) * cos(azimuth))
            position = focus + direction * distance
            forward = -direction
            right = simd_normalize(SIMD3(forward.z, 0, -forward.x))
            up = simd_cross(right, forward)
        }

        /// Zooms out quickly while more than 2% of the nodes are off screen
        /// (or behind the camera), and back in slowly once nearly all of
        /// them sit well inside it. `edges` is each node's place as a
        /// fraction of the way from the center to the view's edge.
        mutating func fit(_ edges: [Float], dt: Float) {
            guard edges.count >= 8 else { return }
            let sorted = edges.sorted()
            let reach = sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.98))]
            if reach > 0.92 {
                zoom *= exp(dt * 1.5 * min(1, (reach - 0.92) * 4))
            } else if reach < 0.7, zoom > 1 {
                zoom = max(1, zoom * exp(-dt * 0.25))
            }
            zoom = min(zoom, 4)
        }

        /// Pixels, and how much nearer than the focus it is (1 at the
        /// focus, 2 at half the distance); nil when too near or behind.
        func project(_ p: SIMD3<Float>, size: SIMD2<Float>) -> SIMD3<Float>? {
            let v = p - position
            let z = simd_dot(v, forward)
            guard z > 0.3 else { return nil }
            let focal = size.y * 0.95
            return SIMD3(size.x / 2 + simd_dot(v, right) / z * focal,
                         size.y / 2 - simd_dot(v, up) / z * focal, distance / z)
        }
    }

    private func build(size: SIMD2<Float>, scale: Float, now: Double, dt: Double) -> Frame {
        let nodes = map.nodes
        let positions = map.positions()
        var frame = Frame()
        guard !nodes.isEmpty else { return frame }

        let arrived = nodes.reversed().prefix { now - $0.born < 1 }.count
        camera.frame(positions, notesPerSecond: Float(arrived), dt: Float(dt))

        // Sizes in points at 600 pt high, growing with the view; `unit`
        // turns them into pixels.
        let unit = scale * max(1, size.y / scale / 600)
        var projected = [SIMD3<Float>?](repeating: nil, count: nodes.count)
        var lives = [Life](repeating: Life(age: 1e9), count: nodes.count)
        var edges = [Float](repeating: 2, count: nodes.count)
        let halfSize = size / 2
        for i in nodes.indices {
            projected[i] = camera.project(positions[i], size: size)
            if let p = projected[i] { edges[i] = max(abs(p.x - halfSize.x) / halfSize.x, abs(p.y - halfSize.y) / halfSize.y) }
            lives[i] = Life(age: now - nodes[i].born)
        }
        camera.fit(edges, dt: Float(dt))
        onScreen = Float(edges.count { $0 <= 1 }) / Float(edges.count)
        let first = nodes[0].id
        func index(_ id: Int) -> Int? { id >= first && id - first < nodes.count ? id - first : nil }
        func segment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ color: SIMD3<Float>, _ alpha: Float, _ width: Float) {
            // Skip lines from nodes right in front of the camera: they'd
            // sweep across the whole view.
            guard a.z < 6, b.z < 6 else { return }
            frame.segments.append(SIMD4(a.x, a.y, b.x, b.y))
            frame.segments.append(SIMD4(color * alpha, alpha))
            frame.segments.append(SIMD4(width, 0, 0, 0))
        }
        frame.segments.reserveCapacity(map.links.count * 3 + nodes.count * 3)

        // Links between notes that sound alike, while either end is lit.
        for (a, b) in map.links {
            guard let i = index(a), let j = index(b) else { continue }
            let lit = max(lives[i].lit, lives[j].lit)
            guard lit > 0, let pa = projected[i], let pb = projected[j] else { continue }
            let white = max(lives[i].white, lives[j].white) * 0.7
            segment(pa, pb, mix(spectrum(nodes[j].centroid), SIMD3(1, 1, 1), t: white), lit * 0.45, 0.6 * unit)
        }
        // Each voice's path, white at first, then in the voice's color.
        for (j, node) in nodes.enumerated() {
            guard lives[j].lit > 0, let previous = node.previous, let i = index(previous),
                  let pa = projected[i], let pb = projected[j] else { continue }
            let white = lives[j].white
            segment(pa, pb, mix(voiceColors[node.voice % 3], SIMD3(1, 1, 1), t: white), lives[j].lit * 0.9,
                    (0.8 + 1.4 * white) * unit)
        }

        // Nodes, nearest last so their labels sit on top.
        let order = nodes.indices.filter { projected[$0] != nil }.sorted { projected[$0]!.z < projected[$1]!.z }
        frame.nodes.reserveCapacity(order.count * 3)
        for i in order {
            let p = projected[i]!, node = nodes[i], life = lives[i]
            let color = mix(spectrum(node.centroid), SIMD3(1, 1, 1), t: life.white)
            let near = min(p.z, 3)
            var half: Float = 0
            if life.lit < 0.02 {
                // Faint for good: a dot.
                frame.nodes.append(SIMD4(p.x, p.y, 0, 0))
                frame.nodes.append(SIMD4(color, 0.35))
                frame.nodes.append(SIMD4(0, 0, 0, 0.8 * unit))
            } else {
                half = (3 + node.amplitude * 10) * near * (1 + life.flash)
                let halo = life.flash > 0 ? (half * 4 + 30 * life.flash) * unit : 0
                frame.nodes.append(SIMD4(p.x, p.y, half * unit, halo))
                frame.nodes.append(SIMD4(color, life.intensity))
                frame.nodes.append(SIMD4(life.flash, (1 + life.white) * 0.75 * near * unit, 0.1, 1.2 * unit))
            }
            addLabels(for: node, at: p, half: half, life: life, unit: unit, into: &frame.glyphs)
        }
        if labels.count > nodes.count + 64 { labels = labels.filter { $0.key >= first } }
        return frame
    }

    /// Amplitude above, spread left, centroid right and time below, in
    /// points that grow with nearness: large on a new note, fading with it
    /// and gone by `goneSeconds`.
    private func addLabels(for node: SoundMap.Node, at p: SIMD3<Float>, half: Float, life: Life, unit: Float,
                           into glyphs: inout [SIMD4<Float>]) {
        guard let atlas else { return }
        guard life.lit > 0.01 else { return }
        let near = min(p.z, 3)
        let size = 11 * near * (1 + life.white * 0.8)
        // Too small to read.
        guard size >= 3 else { return }
        let alpha = life.lit * 0.92
        let text = labels[node.id] ?? {
            let made = [String(format: "%.4f", node.amplitude), String(format: "%.2fk", node.spread / 1000),
                        String(format: "%.2fk", node.centroid / 1000), String(format: "%.2f", node.time)]
                .map(GlyphAtlas.indices)
            labels[node.id] = made
            return made
        }()
        let large = size * unit, small = size * 0.65 * unit, h = half * unit, gap = 3 * unit
        let smallAlpha = alpha
        atlas.layout(text[0], at: SIMD2(p.x, p.y - h - gap), size: large, align: .center, alpha: alpha, into: &glyphs)
        atlas.layout(text[1], at: SIMD2(p.x - h - gap, p.y + small * 0.35), size: small, align: .right, alpha: smallAlpha, into: &glyphs)
        atlas.layout(text[2], at: SIMD2(p.x + h + gap, p.y + small * 0.35), size: small, align: .left, alpha: smallAlpha, into: &glyphs)
        atlas.layout(text[3], at: SIMD2(p.x, p.y + h + small + gap * 0.5), size: small, align: .center, alpha: smallAlpha, into: &glyphs)
    }

    /// The reference's 0–10 kHz scale: blue, purple, red, orange, yellow,
    /// green, white.
    static let stops: [(Float, SIMD3<Float>)] = [
        (0, SIMD3(32, 48, 255) / 255), (1500, SIMD3(138, 43, 226) / 255), (2500, SIMD3(255, 42, 42) / 255),
        (4000, SIMD3(255, 138, 0) / 255), (5500, SIMD3(245, 228, 0) / 255), (7500, SIMD3(125, 255, 160) / 255),
        (10_000, SIMD3(1, 1, 1)),
    ]

    func spectrum(_ hz: Float) -> SIMD3<Float> {
        let f = min(max(hz, 0), 10_000)
        for k in 1..<Self.stops.count where f <= Self.stops[k].0 {
            let (a, ca) = Self.stops[k - 1], (b, cb) = Self.stops[k]
            return mix(ca, cb, t: (f - a) / (b - a))
        }
        return SIMD3(1, 1, 1)
    }

    // MARK: Offscreen

    /// Renders the map at `now` offscreen and waits for the GPU.
    func render(width: Int, height: Int, now: Double, scale: Float = 2) -> MTLTexture? {
        guard let device, let commands = queue?.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        encode(into: target, commands: commands, now: now, scale: scale)
        commands.commit()
        commands.waitUntilCompleted()
        return target
    }

    /// The map rendered at `now` as an image, over the visualizer
    /// background, for tests and checks.
    func image(width: Int, height: Int, now: Double, scale: Float = 2) -> CGImage? {
        guard let target = render(width: width, height: height, now: now, scale: scale) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // Over the visualizer background, as in the app.
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Float(bytes[i + 3]) / 255
            for (c, bg) in zip(0..<3, [16, 14, 14] as [Float]) {
                bytes[i + c] = UInt8(min(255, Float(bytes[i + c]) + bg * (1 - a)))
            }
            bytes[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// SF Mono's digits, point and "k" in a texture, so labels are glyph quads.
struct GlyphAtlas {
    static let characters = Array("0123456789.k")
    private static let fontSize: CGFloat = 64
    private static let padding = 4

    let texture: MTLTexture
    private let cellWidth: Int
    private let cellHeight: Int
    private let ascent: CGFloat

    enum Align { case left, center, right }

    static func indices(_ text: String) -> [UInt8] {
        text.compactMap { c in characters.firstIndex(of: c).map(UInt8.init) }
    }

    init?(device: MTLDevice, queue: MTLCommandQueue) {
        let font = NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        cellWidth = Int(advance.rounded(.up)) + 2 * Self.padding
        ascent = font.ascender
        cellHeight = Int((font.ascender - font.descender).rounded(.up)) + 2 * Self.padding
        let width = cellWidth * Self.characters.count, height = cellHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        for (i, c) in Self.characters.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(c), attributes: attributes))
            context.textPosition = CGPoint(x: CGFloat(i * cellWidth + Self.padding), y: CGFloat(Self.padding) - font.descender)
            CTLineDraw(line, context)
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: true)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d), let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width)
        if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
        }
        self.texture = texture
    }

    /// Adds `text`'s glyphs, `size` pixels high (the font size), with its
    /// baseline at `point.y`.
    func layout(_ text: [UInt8], at point: SIMD2<Float>, size: Float, align: Align, alpha: Float,
                into glyphs: inout [SIMD4<Float>]) {
        let k = size / Float(Self.fontSize)
        let w = Float(cellWidth) * k, h = Float(cellHeight) * k
        let advance = w - Float(2 * Self.padding) * k
        let total = advance * Float(text.count)
        var x = point.x - (align == .left ? 0 : align == .center ? total / 2 : total) - Float(Self.padding) * k
        let top = point.y - (Float(ascent) + Float(Self.padding)) * k
        let du = 1 / Float(Self.characters.count)
        for g in text {
            let u = Float(g) * du
            glyphs.append(SIMD4(x, top, w, h))
            glyphs.append(SIMD4(u, 0, u + du, 1))
            glyphs.append(SIMD4(1, 1, 1, alpha))
            x += advance
        }
    }
}

#Preview {
    SoundMapView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
