import simd
import Metal

/// Draws what's lit on the Silicon visualizer's die into two textures the
/// scene lays over it, each the die's shape, every frame:
///
/// - `light`: the blocks at work and their bits. The die's material lets
///   it through along its own wiring, so a lit bit is that bit's real
///   circuitry glowing.
/// - `signals`: the beads of light running along each signal's way, and
///   the waveforms of the three voices and of the output. It floats just
///   above the die, as light of its own.
///
/// Both are drawn with the Notes visualizer's shapes (Shaders/Notes.metal).
final class SiliconOverlay {
    let light: MTLTexture?
    let signals: MTLTexture?
    /// Voices 1–3, from the theme; the chip's shared parts are near white.
    var voiceColors: [SIMD3<Float>] = Array(repeating: SIMD3(1, 1, 1), count: 3)

    static let shared = SIMD3<Float>(0.82, 0.9, 1)

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?

    /// The chip whose die this is drawn for.
    let die: SiliconDie

    init(die: SiliconDie, device: MTLDevice?, library: MTLLibrary? = nil) {
        self.die = die
        self.device = device
        queue = device?.makeCommandQueue()
        func texture(_ width: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                             height: Int(Float(width) * die.aspect), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            return device?.makeTexture(descriptor: d)
        }
        light = texture(1024)
        signals = texture(2048)
        pipeline = device.flatMap { device in
            let library = library ?? device.makeDefaultLibrary()
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library?.makeFunction(name: "noteShapeVertex")
            descriptor.fragmentFunction = library?.makeFunction(name: "noteShapeFragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .rgba16Float
            // Everything here is light: it adds up.
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
    }

    private func color(_ owner: Int) -> SIMD3<Float> {
        owner < 3 ? voiceColors[owner % voiceColors.count] : Self.shared
    }

    /// Redraws both textures for `state`. `clock` moves the beads.
    func draw(state: ChipState, clock: Double) {
        guard let light, let signals else { return }

        // Shapes for Notes.metal: ends, then radii, blur and kind, then color.
        var patches: [SIMD4<Float>] = []
        let lightSize = SIMD2(Float(light.width), Float(light.height))
        for cell in die.cells(state, clock: clock) {
            let from = SIMD2(cell.place.x, cell.place.y) * lightSize, to = SIMD2(cell.place.z, cell.place.w) * lightSize
            let wide = to.x - from.x, tall = to.y - from.y
            // A rectangle: a line along its longer side, half as thick as
            // its shorter, with square ends (kind 3).
            let half = min(wide, tall) / 2
            let middle = (from + to) / 2
            let a = wide >= tall ? SIMD2(from.x, middle.y) : SIMD2(middle.x, from.y)
            let b = wide >= tall ? SIMD2(to.x, middle.y) : SIMD2(middle.x, to.y)
            patches.append(SIMD4(a.x, a.y, b.x, b.y))
            patches.append(SIMD4(half, half, 1.2, 3))
            patches.append(SIMD4(color(cell.owner) * cell.level, 0))
        }

        var lines: [SIMD4<Float>] = []
        let size = SIMD2(Float(signals.width), Float(signals.height))
        func stroke(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ rgb: SIMD3<Float>, radius: Float, glow: Bool = false) {
            lines.append(SIMD4(a.x, a.y, b.x, b.y))
            lines.append(SIMD4(radius, radius, 0.8, glow ? 2 : 0))
            lines.append(SIMD4(rgb, 0))
        }
        // The signals' ways, faintly, and beads running along them.
        for flow in die.flows(state) where flow.level > 0.01 {
            let rgb = color(flow.owner)
            let points = flow.points.map { $0 * size }
            var lengths: [Float] = [0]
            for i in 1..<points.count {
                stroke(points[i - 1], points[i], rgb * (0.12 + 0.3 * flow.level), radius: 1.6)
                lengths.append(lengths[i - 1] + simd_length(points[i] - points[i - 1]))
            }
            let spacing: Float = 34
            var along = Float((clock * 150).truncatingRemainder(dividingBy: Double(spacing)))
            while along < lengths[lengths.count - 1] {
                let segment = max(1, lengths.firstIndex { $0 >= along } ?? points.count - 1)
                let t = (along - lengths[segment - 1]) / max(lengths[segment] - lengths[segment - 1], 1e-4)
                let p = points[segment - 1] + (points[segment] - points[segment - 1]) * t
                stroke(p, p, rgb * (0.5 + 0.9 * flow.level), radius: 9, glow: true)
                stroke(p, p, SIMD3(repeating: 0.6 + 0.6 * flow.level), radius: 2.6)
                along += spacing
            }
        }
        // Each voice's waveform across its envelope generator, and the
        // three together across the paddles' unused corner.
        func scope(_ samples: [Float], in place: SiliconDie.Place, _ rgb: SIMD3<Float>) {
            guard samples.count > 16 else { return }
            // Drawn to fill its place however quiet it is, down to a
            // twentieth of full scale: below that it's left small, so
            // silence is a flat line and not noise blown up.
            let peak = samples.suffix(840).reduce(Float(0)) { max($0, abs($1)) }
            let gain = 1 / max(peak, 0.05)
            let window = min(samples.count / 2, 420)
            var start = samples.count - window * 2
            // From a rising zero crossing, so a steady note stands still.
            for i in max(start, 1)..<(samples.count - window) where samples[i - 1] <= 0 && samples[i] > 0 {
                start = i
                break
            }
            let from = SIMD2(place.x, place.y) * size, to = SIMD2(place.z, place.w) * size
            var last: SIMD2<Float>?
            for i in stride(from: 0, to: window, by: 2) {
                let value = max(-1, min(1, samples[start + i] * gain))
                // The die's picture has voice 1 on its right; the trace
                // still runs left to right, as time does.
                let p = SIMD2(from.x + (to.x - from.x) * Float(i) / Float(window - 1),
                              (from.y + to.y) / 2 - value * (to.y - from.y) * 0.4)
                if let last {
                    stroke(last, p, rgb * 0.5, radius: 6, glow: true)
                    stroke(last, p, rgb * 1.3, radius: 1.5)
                }
                last = p
            }
        }
        var mix: [Float] = []
        let count = state.voices.map(\.samples.count).min() ?? 0
        if count > 0 {
            mix = [Float](repeating: 0, count: count)
            for v in 0..<3 where state.isHeard(v) {
                let samples = state.voices[v].samples
                for i in 0..<count { mix[i] += samples[samples.count - count + i] / 3 }
            }
            for i in 0..<count { mix[i] *= Float(state.volume) / 15 }
        }
        for v in 0..<3 {
            let place = die.envelope(v)
            // The middle third of the block's height.
            let third = (place.w - place.y) / 3
            scope(state.voices[v].samples, in: SIMD4(place.x + 0.01, place.y + third, place.z - 0.01, place.w - third), color(v))
        }
        scope(mix, in: die.outputScope, Self.shared)

        guard let commands = queue?.makeCommandBuffer() else { return }
        fill(light, with: patches, commands: commands)
        fill(signals, with: lines, commands: commands)
        commands.commit()
    }

    private func fill(_ target: MTLTexture, with shapes: [SIMD4<Float>], commands: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let pipeline, let device, !shapes.isEmpty,
           let buffer = device.makeBuffer(bytes: shapes, length: shapes.count * MemoryLayout<SIMD4<Float>>.stride) {
            var size = SIMD2(Float(target.width), Float(target.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: shapes.count / 3)
        }
        encoder.endEncoding()
    }
}
