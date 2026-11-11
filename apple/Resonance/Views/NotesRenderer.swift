import simd
import MetalKit
import MetalPerformanceShaders

/// Draws the Notes visualizer (`NotesView`) into an MTKView's drawable or
/// any texture: three staves lying flat and running into the distance, the
/// tune's notes on them as dark beads with a stem as long as they last,
/// and a ball per voice hopping from note to note, landing on each as it
/// starts and lighting it in the voice's color. Played notes slide toward
/// the camera and out of focus.
///
/// The CPU places and projects everything from a `NoteTrack` and a time;
/// Shaders/Notes.metal draws the shapes, with bloom.
final class NotesRenderer {
    let device: MTLDevice?
    /// Voices 1–3, from the theme.
    var voiceColors: [SIMD3<Float>] = Array(repeating: SIMD3(1, 1, 1), count: 3)
    var track: NoteTrack?

    // The look.
    static let bloom: Float = 0.55
    static let backdrop: Float = 0.2
    /// Staff widths a second: how fast the notes come.
    static let speed: Float = 1.5
    /// Seconds of the tune drawn ahead of the balls and behind them.
    static let ahead = 9.0
    static let behind = 4.0
    /// Each voice's staff is 1 wide, with this much between two.
    static let laneGap: Float = 0.5
    static let headRadius: Float = 0.075
    static let ballRadius: Float = 0.068
    /// Seconds of each ball's path drawn behind it.
    static let trailSeconds = 0.75

    private let queue: MTLCommandQueue?
    private let shapePipeline: MTLRenderPipelineState?
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
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blends: Bool) -> MTLRenderPipelineState? {
            guard let device, let library else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if blends {
                // Premultiplied: a shape covers by its alpha and adds its color.
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        shapePipeline = pipeline("noteShapeVertex", "noteShapeFragment", format: .rgba16Float, blends: true)
        compositePipeline = pipeline("notesCompositeVertex", "notesCompositeFragment", format: .bgra8Unorm, blends: false)
        downscale = device.map { MPSImageBilinearScale(device: $0) }
        blur = device.map { MPSImageGaussianBlur(device: $0, sigma: 4) }
    }

    var commandQueue: MTLCommandQueue? { queue }

    /// Renders the tune at `time` seconds in into `target` (bgra8Unorm).
    /// `clock` only sways the camera.
    func encode(into target: MTLTexture, commands: MTLCommandBuffer, time: Double, clock: Double, scale: Float) {
        guard let device, let shapePipeline, let compositePipeline else { return }
        prepareTextures(width: target.width, height: target.height)
        guard let scene, let small, let blurred else { return }

        var size = SIMD2(Float(target.width), Float(target.height))
        let shapes = build(size: size, scale: scale, time: time, clock: clock)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scene
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let count = shapes.count / 3
        if count > 0, let buffer = device.makeBuffer(bytes: shapes, length: shapes.count * MemoryLayout<SIMD4<Float>>.stride) {
            encoder.setRenderPipelineState(shapePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
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
        var look = SIMD2(Self.bloom, Self.backdrop)
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

    // MARK: The scene

    /// The world: x runs with time (the balls are at `time × speed`), y is
    /// up from the staves, z goes across them toward the camera, voice 3's
    /// staff nearest.
    struct Camera {
        var position: SIMD3<Float>
        var forward: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var focal: Float
        var size: SIMD2<Float>
        /// How far away things are sharp, and how fast they blur off it.
        var focus: Float
        var aperture: Float

        /// Behind the balls and to voice 3's side, looking ahead and across
        /// the staves, so they run from the lower left into the distance at
        /// the upper right. It sways a little.
        init(at x: Float, size: SIMD2<Float>, clock: Double) {
            let sway = Float(sin(clock * 0.21)), bob = Float(sin(clock * 0.13 + 1))
            let width = NotesRenderer.lanesWidth
            // A wide view sees more of the road; a tall one is pulled back.
            let aspect = size.x / max(size.y, 1)
            let back = 1 + max(0, 1.5 - aspect) * 0.6
            position = SIMD3(x - (3.3 + 0.15 * sway) * back, (2.0 + 0.1 * bob) * back, width + (1.5 - 0.2 * sway) * back)
            let target = SIMD3(x + 1.1, 0, width * 0.5)
            forward = simd_normalize(target - position)
            right = simd_normalize(SIMD3(-forward.z, 0, forward.x))
            up = simd_cross(right, forward)
            focal = size.y * 1.1
            self.size = size
            focus = simd_dot(SIMD3(x, 0, width * 0.5) - position, forward)
            aperture = 0.03
        }

        static let near: Float = 0.35

        func depth(_ p: SIMD3<Float>) -> Float { simd_dot(p - position, forward) }

        /// Pixels and depth; nil when behind the camera or too near.
        func project(_ p: SIMD3<Float>) -> SIMD3<Float>? {
            let v = p - position
            let z = simd_dot(v, forward)
            guard z > Self.near else { return nil }
            return SIMD3(size.x / 2 + simd_dot(v, right) / z * focal,
                         size.y / 2 - simd_dot(v, up) / z * focal, z)
        }

        /// A length at `depth`, in pixels.
        func pixels(_ length: Float, depth: Float) -> Float { length * focal / depth }

        /// How blurred something at `depth` is, in pixels.
        func blur(depth: Float) -> Float { aperture * focal * abs(1 / depth - 1 / focus) }

        /// The part of a–b in front of the camera, if any.
        func clip(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>)? {
            let za = depth(a) - Self.near, zb = depth(b) - Self.near
            if za <= 0, zb <= 0 { return nil }
            if za > 0, zb > 0 { return (a, b) }
            let cut = a + (b - a) * (za / (za - zb) + (za < 0 ? 1e-3 : -1e-3))
            return za < 0 ? (cut, b) : (a, cut)
        }
    }

    static var lanesWidth: Float { 3 + 2 * laneGap }

    /// Where a place on `voice`'s staff (`NoteTrack.place`) is across the
    /// world: voice 1 farthest, the higher the note the farther.
    static func across(_ place: Float, voice: Int) -> Float {
        Float(voice) * (1 + laneGap) + 1 - place
    }

    private enum Kind: Float {
        case flat = 0, bead = 1, glow = 2
        /// Flat with square ends, so pieces of one line meet without overlapping.
        case piece = 3
    }

    private struct Shapes {
        var data: [SIMD4<Float>] = []
        let camera: Camera

        /// A capsule between two world points with a world radius, blurred
        /// by how far out of focus it is. `alpha` 0 only adds light.
        mutating func capsule(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float, color: SIMD3<Float>, alpha: Float,
                              kind: Kind = .flat, thinnest: Float = 0, focused: Bool = false) {
            guard let (ca, cb) = camera.clip(a, b), let pa = camera.project(ca), let pb = camera.project(cb) else { return }
            var ra = camera.pixels(radius, depth: pa.z), rb = camera.pixels(radius, depth: pb.z)
            var fade: Float = 1
            // Thinner than `thinnest` pixels, it's drawn that wide and fainter, so it doesn't shimmer.
            if thinnest > 0 {
                let thin = max(ra, rb)
                if thin < thinnest {
                    fade = thin / thinnest
                    ra = thinnest
                    rb = thinnest
                }
            }
            let blur = focused ? 0 : (camera.blur(depth: pa.z) + camera.blur(depth: pb.z)) / 2
            // Spread over a larger area, the same light is fainter.
            let r = max((ra + rb) / 2, 0.5)
            fade *= kind == .glow ? 1 : r / (r + blur * 0.6)
            data.append(SIMD4(pa.x, pa.y, pb.x, pb.y))
            data.append(SIMD4(ra, rb, blur, kind.rawValue))
            data.append(SIMD4(color * fade, alpha * fade))
        }

        mutating func disc(_ p: SIMD3<Float>, radius: Float, color: SIMD3<Float>, alpha: Float, kind: Kind = .flat,
                           focused: Bool = false) {
            capsule(p, p, radius: radius, color: color, alpha: alpha, kind: kind, focused: focused)
        }
    }

    private func build(size: SIMD2<Float>, scale: Float, time: Double, clock: Double) -> [SIMD4<Float>] {
        let now = Float(time) * Self.speed
        let camera = Camera(at: now, size: size, clock: clock)
        var shapes = Shapes(camera: camera)
        let from = time - Self.behind, to = time + Self.ahead
        func x(_ seconds: Double) -> Float { Float(seconds) * Self.speed }
        /// 1 near the balls, falling to 0 at the far end and at the near one.
        func presence(_ seconds: Double) -> Float {
            let t = seconds - time
            return Float(t > 0 ? min(1, (Self.ahead - t) / (Self.ahead * 0.45)) : min(1, (Self.behind + t) / 0.8))
        }

        // The staves: five lines each, in pieces so they fade with distance.
        let pieces = 28
        for voice in 0..<3 {
            for line in 0..<5 {
                let z = Self.across(Float(line) / 4, voice: voice)
                for piece in 0..<pieces {
                    let t0 = from + (to - from) * Double(piece) / Double(pieces)
                    let t1 = from + (to - from) * Double(piece + 1) / Double(pieces)
                    let alpha = 0.62 * max(0, presence((t0 + t1) / 2))
                    guard alpha > 0.01 else { continue }
                    shapes.capsule(SIMD3(x(t0), 0, z), SIMD3(x(t1), 0, z), radius: 0.006, color: .zero, alpha: alpha,
                                   kind: .piece, thinnest: 0.6 * scale)
                }
            }
        }
        guard let track else { return shapes.data }

        let window = max(from, 0)...max(to, 0)
        // Notes still to come: dark beads, the farthest first.
        for voice in 0..<3 {
            for note in track.notes(voice: voice, in: window).reversed() where note.start > time {
                let alpha = 0.92 * max(0, presence(note.start))
                guard alpha > 0.01 else { continue }
                let z = Self.across(track.place(note.midi, voice: voice), voice: voice)
                let head = SIMD3(x(note.start), 0, z)
                let dark = SIMD3<Float>(repeating: 0.012)
                shapes.capsule(head, SIMD3(stemEnd(note), 0, z), radius: Self.headRadius * 0.3, color: dark, alpha: alpha)
                shapes.disc(head + SIMD3(0, Self.headRadius * 0.6, 0), radius: Self.headRadius, color: dark, alpha: alpha, kind: .bead)
            }
        }
        // Played notes, lit in their voice's color: the oldest are nearest
        // the camera, so the newest go first.
        for voice in 0..<3 {
            let color = voiceColors[voice % voiceColors.count]
            for note in track.notes(voice: voice, in: window).reversed() where note.start <= time {
                let age = Float(time - note.start)
                let present = max(0, presence(note.start))
                guard present > 0.01 else { continue }
                let sounding = time < note.end
                // A flash as the ball lands, brighter while it sounds, then a steady glow.
                let flash = exp(-age / 0.18)
                let lit = (0.5 + (sounding ? 0.35 : 0) + 0.9 * flash) * present
                let z = Self.across(track.place(note.midi, voice: voice), voice: voice)
                let head = SIMD3(x(note.start), Self.headRadius * 0.6, z)
                let tail = SIMD3(stemEnd(note), Self.headRadius * 0.3, z)
                let white = SIMD3<Float>(repeating: 1)
                let core = mix(color, white, t: min(1, 0.25 + 0.6 * flash))
                shapes.capsule(SIMD3(head.x, tail.y, z), tail, radius: Self.headRadius * 0.95, color: color * 0.5 * lit, alpha: 0, kind: .glow)
                shapes.capsule(SIMD3(head.x, tail.y, z), tail, radius: Self.headRadius * 0.42, color: color * 0.55 * lit, alpha: 0.35 * present)
                shapes.capsule(SIMD3(head.x, tail.y, z), tail, radius: Self.headRadius * 0.13, color: core * 0.9 * lit, alpha: 0)
                shapes.disc(head, radius: Self.headRadius * (2.2 + 1.6 * flash), color: color * 0.55 * lit, alpha: 0, kind: .glow)
                shapes.disc(head, radius: Self.headRadius * (1 + 0.25 * flash), color: core * (0.95 + 0.6 * flash) * lit,
                            alpha: present)
            }
        }
        // The balls, with their paths behind them and their light on the staff below.
        for voice in 0..<3 {
            guard let ball = track.ball(voice: voice, at: time) else { continue }
            let color = voiceColors[voice % voiceColors.count]
            let steps = 22
            var previous: SIMD3<Float>?
            for step in 0...steps {
                let back = Self.trailSeconds * Double(steps - step) / Double(steps)
                guard let past = track.ball(voice: voice, at: time - back) else { continue }
                let point = place(past, voice: voice, at: time - back)
                if let previous {
                    let strength = Float(step) / Float(steps)
                    shapes.capsule(previous, point, radius: 0.008, color: mix(color, SIMD3(1, 1, 1), t: 0.6) * 0.5 * strength * strength,
                                   alpha: 0, kind: .piece, thinnest: 0.7 * scale, focused: true)
                }
                previous = point
            }
            let center = place(ball, voice: voice, at: time)
            let floor = SIMD3(center.x, 0, center.z)
            let closeness = 1 / (1 + ball.height * 3)
            shapes.disc(floor, radius: Self.ballRadius * (2.5 + ball.height), color: color * 0.3 * closeness, alpha: 0, kind: .glow, focused: true)
            let landing = ball.sinceLanding.map { Float(exp(-$0 / 0.15)) } ?? 0
            shapes.disc(center, radius: Self.ballRadius * (3 + landing), color: color * (0.5 + 0.4 * landing), alpha: 0, kind: .glow, focused: true)
            shapes.disc(center, radius: Self.ballRadius, color: mix(color, SIMD3(1, 1, 1), t: 0.82) * 1.5, alpha: 1, focused: true)
        }
        return shapes.data
    }

    /// Where a note's stem ends: as long as the note, short of the next one.
    private func stemEnd(_ note: NoteTrack.Note) -> Float {
        let length = max(Float(note.end - note.start) * Self.speed - Self.headRadius * 1.2, 0)
        return Float(note.start) * Self.speed + length
    }

    private func place(_ ball: NoteTrack.Ball, voice: Int, at time: Double) -> SIMD3<Float> {
        SIMD3(Float(time) * Self.speed, Self.ballRadius + Self.headRadius * 0.6 + ball.height, Self.across(ball.place, voice: voice))
    }

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> { a + (b - a) * t }

    // MARK: Offscreen

    /// Renders the tune at `time` offscreen and waits for the GPU.
    func render(width: Int, height: Int, time: Double, clock: Double = 0, scale: Float = 2) -> MTLTexture? {
        guard let device, let commands = queue?.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        encode(into: target, commands: commands, time: time, clock: clock, scale: scale)
        commands.commit()
        commands.waitUntilCompleted()
        return target
    }

    /// The tune at `time` as an image over `background`, for tests and checks.
    func image(width: Int, height: Int, time: Double, clock: Double = 0, scale: Float = 2,
               background: SIMD3<Float> = SIMD3(14, 14, 16) / 255) -> CGImage? {
        render(width: width, height: height, time: time, clock: clock, scale: scale)
            .flatMap { VisualizerSnapshot.image(of: $0, background: background) }
    }
}

/// A rendered visualizer frame as an image, for tests and checks.
nonisolated enum VisualizerSnapshot {
    /// `texture` (bgra8Unorm, premultiplied, shared storage) over `background`.
    static func image(of texture: MTLTexture, background: SIMD3<Float>) -> CGImage? {
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let under = [background.z, background.y, background.x].map { $0 * 255 }
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Float(bytes[i + 3]) / 255
            for c in 0..<3 {
                bytes[i + c] = UInt8(min(255, Float(bytes[i + c]) + under[c] * (1 - a)))
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
