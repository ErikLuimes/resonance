import AppKit
import simd
import MetalKit
import MetalPerformanceShaders

/// The copper bars of the Rasters visualizer: for each voice, a bar at
/// the line its note belongs on (low notes low, high notes high), as tall
/// as the voice is loud, and behind it the bars of its last few notes,
/// fading, so a melody leaves its shape on the screen. A drum (noise)
/// flashes the border, as demos did.
nonisolated struct RasterShow {
    struct Bar: Equatable {
        /// The line its middle is on, 0–272 from the top.
        var line: Float
        /// Half its height, in lines.
        var half: Float
        var brightness: Float
        var voice: Int
    }

    /// The lines the notes span, and the notes that reach their ends.
    static let lines: ClosedRange<Float> = 30...176
    static let notes: ClosedRange<Float> = 24...96
    /// Bars remembered behind each voice's own.
    static let echoes = 5
    /// Seconds an echo takes to fade, and a bar to slide to a new note.
    static let fade = 1.6
    static let slide = 0.05

    private struct Echo {
        var line: Float
        var age: Double
    }

    private var current: [Float?] = [nil, nil, nil]
    private var levels = [Float](repeating: 0, count: 3)
    private var echoes: [[Echo]] = [[], [], []]
    private var lastMidi: [Float?] = [nil, nil, nil]
    private var wasSounding = [false, false, false]
    /// The border's flash, 0–1.
    private(set) var flash: Float = 0

    static func line(of midi: Float) -> Float {
        let t = (min(max(midi, notes.lowerBound), notes.upperBound) - notes.lowerBound) / (notes.upperBound - notes.lowerBound)
        return lines.upperBound - t * (lines.upperBound - lines.lowerBound)
    }

    /// Advance by `dt` seconds with what the voices are playing.
    mutating func update(voices: [InkJets.Voice], dt: Double) {
        flash *= Float(exp(-dt / 0.06))
        for v in 0..<3 {
            let voice = v < voices.count ? voices[v] : InkJets.Voice(level: 0, midi: 0)
            let sounding = voice.level > 0.04
            let moved = lastMidi[v].map { abs($0 - voice.midi) > 0.5 } ?? true
            let started = sounding && (!wasSounding[v] || (moved && !voice.isNoise))
            wasSounding[v] = sounding
            for i in echoes[v].indices { echoes[v][i].age += dt }
            echoes[v].removeAll { $0.age > Self.fade }
            levels[v] += (voice.level - levels[v]) * Float(1 - exp(-dt / (voice.level > levels[v] ? 0.015 : 0.12)))
            guard sounding else { continue }
            lastMidi[v] = voice.midi
            if voice.isNoise {
                // A drum has no line of its own: it flashes the border.
                if started { flash = 1 }
                continue
            }
            let target = Self.line(of: voice.midi)
            if started, let line = current[v], abs(line - target) > 1 {
                echoes[v].append(Echo(line: line, age: 0))
                if echoes[v].count > Self.echoes { echoes[v].removeFirst() }
            }
            let k = current[v] == nil ? 1 : Float(1 - exp(-dt / Self.slide))
            current[v] = (current[v] ?? target) + (target - (current[v] ?? target)) * k
        }
    }

    /// The bars to draw, back to front: every voice's echoes, then the
    /// voices' own bars.
    var bars: [Bar] {
        var bars: [Bar] = []
        for v in 0..<3 {
            for echo in echoes[v] {
                let left = Float(1 - echo.age / Self.fade)
                bars.append(Bar(line: echo.line, half: 2 + 3 * left, brightness: 0.55 * left * left, voice: v))
            }
        }
        for v in 0..<3 {
            guard let line = current[v], levels[v] > 0.01 else { continue }
            bars.append(Bar(line: line, half: 3 + 9 * levels[v], brightness: min(1, 0.35 + levels[v]), voice: v))
        }
        return bars
    }
}

/// Draws the Rasters visualizer (`RasterView`) into an MTKView's drawable
/// or any texture: a C64 demo screen with copper bars for the voices, a
/// starfield and a sine scroller carrying the tune's name
/// (Shaders/Rasters.metal). The bloom is the Notes visualizer's.
final class RasterRenderer {
    let device: MTLDevice?
    /// Voices 1–3, from the theme.
    var voiceColors: [SIMD3<Float>] = Array(repeating: SIMD3(1, 1, 1), count: 3)

    static let bloom: Float = 0.35
    /// How bright the C64's own blue and light blue are: dimmed, so the
    /// screen sits in Now Playing's dark instead of lighting the room.
    static let dim: Float = 0.5
    /// C64 pixels a second the scroller moves.
    static let scrollSpeed = 70.0
    static let maxBars = 18

    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let compositePipeline: MTLRenderPipelineState?
    private let downscale: MPSImageBilinearScale?
    private let blur: MPSImageGaussianBlur?
    private var scene: MTLTexture?
    private var small: MTLTexture?
    private var blurred: MTLTexture?
    private var text: MTLTexture?
    private var shownText = ""
    private var status: MTLTexture?
    private var shownStatus: String?

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
        pipeline = make("rasterVertex", "rasterFragment", .rgba16Float)
        compositePipeline = make("notesCompositeVertex", "notesCompositeFragment", .bgra8Unorm)
        downscale = device.map { MPSImageBilinearScale(device: $0) }
        blur = device.map { MPSImageGaussianBlur(device: $0, sigma: 3) }
        setText("RESONANCE")
        setStatus("")
    }

    var commandQueue: MTLCommandQueue? { queue }

    /// What the scroller says, over and over. Drawn 16 C64 pixels tall
    /// with no smoothing, so its letters are made of blocks like the rest.
    func setText(_ string: String) {
        guard string != shownText else { return }
        shownText = string
        text = lettering(string.uppercased() + "     ·     ") ?? text
    }

    /// The line at the top of the screen: what each voice is playing.
    func setStatus(_ string: String) {
        guard string != shownStatus else { return }
        shownStatus = string
        status = lettering(string.isEmpty ? " " : string.uppercased()) ?? status
    }

    /// `line` as a texture, 16 C64 pixels tall, one byte a pixel.
    private func lettering(_ line: String) -> MTLTexture? {
        guard let device else { return nil }
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .heavy)
        let attributed = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.white])
        let typeset = CTLineCreateWithAttributedString(attributed)
        let width = min(max(Int(CTLineGetTypographicBounds(typeset, nil, nil, nil).rounded(.up)), 16), 8192), height = 16
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.setShouldAntialias(false)
        context.setShouldSmoothFonts(false)
        context.textPosition = CGPoint(x: 0, y: 3)
        CTLineDraw(typeset, context)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        // The context's first row is its top one, as the texture's is.
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width)
        return texture
    }

    /// Matches `RasterUniforms` in Rasters.metal.
    private struct Uniforms {
        var size: SIMD2<Float>
        var time: Float
        var flash: Float
        var scroll: Float
        var textWidth: Float
        var dim: Float
        var barCount: Float
        var status: SIMD4<Float>
        var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var bars: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                   SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                   SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    /// Renders the screen into `target` (bgra8Unorm). `clock` is any
    /// steady clock, in seconds: it moves the stars and the scroller.
    func encode(into target: MTLTexture, commands: MTLCommandBuffer, show: RasterShow, clock: Double) {
        guard let pipeline, let compositePipeline, let text, let status else { return }
        prepareTextures(width: target.width, height: target.height)
        guard let scene, let small, let blurred else { return }

        var packed = [SIMD4<Float>](repeating: .zero, count: Self.maxBars)
        let bars = show.bars.suffix(Self.maxBars)
        for (i, bar) in bars.enumerated() { packed[i] = SIMD4(bar.line, bar.half, bar.brightness, Float(bar.voice)) }
        func color(_ i: Int) -> SIMD4<Float> { SIMD4(voiceColors[i % voiceColors.count], 1) }
        // Kept small, so a float still holds it exactly after hours.
        let time = clock.truncatingRemainder(dividingBy: 3600)
        var uniforms = Uniforms(
            size: SIMD2(Float(target.width), Float(target.height)), time: Float(time), flash: show.flash,
            scroll: Float((time * Self.scrollSpeed).truncatingRemainder(dividingBy: Double(text.width))),
            textWidth: Float(text.width), dim: Self.dim, barCount: Float(bars.count),
            status: SIMD4(Float(status.width), 0, 0, 0),
            colors: (color(0), color(1), color(2)),
            bars: (packed[0], packed[1], packed[2], packed[3], packed[4], packed[5], packed[6], packed[7], packed[8],
                   packed[9], packed[10], packed[11], packed[12], packed[13], packed[14], packed[15], packed[16], packed[17]))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scene
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(text, index: 0)
        encoder.setFragmentTexture(status, index: 1)
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
        small = texture(width / 4, height / 4)
        blurred = texture(width / 4, height / 4)
    }

    // MARK: Offscreen

    /// Renders the screen offscreen and waits for the GPU.
    func render(width: Int, height: Int, show: RasterShow, clock: Double) -> MTLTexture? {
        guard let device, let commands = queue?.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        encode(into: target, commands: commands, show: show, clock: clock)
        commands.commit()
        commands.waitUntilCompleted()
        return target
    }

    /// The same as an image, for tests and checks.
    func image(width: Int, height: Int, show: RasterShow, clock: Double) -> CGImage? {
        render(width: width, height: height, show: show, clock: clock)
            .flatMap { VisualizerSnapshot.image(of: $0, background: .zero) }
    }
}
