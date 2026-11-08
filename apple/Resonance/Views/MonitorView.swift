import MetalKit
import SwiftUI

/// A Commodore 1084S in About Resonance, switched off, until you press its
/// power button: then it warms up, a C64 boots and runs the player, live,
/// answering the app's own keys while About is in front. The case is a photo;
/// the glass is Shaders/Monitor.metal over it, and the picture on it is
/// MonitorScreen.swift's. Measurements and reasons in design/crt-monitor/README.md.
/// The monitor at any size: the photo, the glass over it, the LED and the
/// power button. `live` draws the tube with Metal; otherwise the glass is a
/// plain dark shape, for previews without a device.
struct MonitorCase: View {
    let store: PlayerStore
    var live: Bool
    var onPower: (() -> Void)?

    /// The photo's geometry, in its own pixels (design/crt-monitor/README.md).
    /// The glass is drawn 12% larger than the photo's, out into the dark
    /// recess around it, so the picture gets the room the small case allows.
    static let photo = CGSize(width: 1200, height: 900)
    static var aspect: CGFloat { photo.height / photo.width }
    static let glass = CGRect(x: 240, y: 145, width: 655, height: 487)
    static let margin: CGFloat = 28
    static let led = CGRect(x: 870, y: 705, width: 8, height: 8)
    static let powerZone = CGRect(x: 843, y: 688, width: 64, height: 76)
    /// The sticker on the bezel, top left, a corner over the glass.
    static let sticker = CGRect(x: 190, y: 98, width: 100, height: 100)

    private var model: MonitorModel { MonitorModel.shared }

    var body: some View {
        GeometryReader { geometry in
            let k = geometry.size.width / Self.photo.width
            let quad = Self.glass.insetBy(dx: -Self.margin, dy: -Self.margin)
            ZStack(alignment: .topLeading) {
                Image(.monitor1084S)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                if live {
                    MonitorScreenView(store: store)
                        .frame(width: quad.width * k, height: quad.height * k)
                        .offset(x: quad.minX * k, y: quad.minY * k)
                } else {
                    RoundedRectangle(cornerRadius: 30 * k, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.26)], startPoint: .top, endPoint: .bottom))
                        .frame(width: Self.glass.width * k, height: Self.glass.height * k)
                        .offset(x: Self.glass.minX * k, y: Self.glass.minY * k)
                }
                IconSticker(size: Self.sticker.width * k)
                    .offset(x: Self.sticker.minX * k, y: Self.sticker.minY * k)
                    .allowsHitTesting(false)
                Circle()
                    .fill(model.isOn ? Color(red: 0.36, green: 1, blue: 0.5) : Color(red: 0.3, green: 0.42, blue: 0.37))
                    .shadow(color: model.isOn ? Color(red: 0.36, green: 1, blue: 0.5).opacity(0.9) : .clear, radius: 3 * k)
                    .frame(width: Self.led.width * k, height: Self.led.height * k)
                    .offset(x: Self.led.minX * k, y: Self.led.minY * k)
                    .allowsHitTesting(false)
                Button {
                    if let onPower { onPower() } else { model.pressPower(store: store) }
                } label: {
                    Color.clear
                        .frame(width: Self.powerZone.width * k, height: Self.powerZone.height * k)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: Self.powerZone.minX * k, y: Self.powerZone.minY * k)
                .help("Power")
                .accessibilityLabel("Power")
            }
        }
        .aspectRatio(Self.photo.width / Self.photo.height, contentMode: .fit)
    }
}

/// The app's icon as a sticker that has been on the bezel for years: a
/// yellowed die-cut edge, sun-faded colors, a crease across it, scratches
/// and scuffs, a corner lifting, and only a trace of its gloss left. Stuck
/// on a little crooked, with its shadow on the bezel. Everything is drawn;
/// the wear is the same every time (a seeded generator).
private struct IconSticker: View {
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        ZStack {
            shape.fill(Color(red: 0.92, green: 0.90, blue: 0.84))
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .saturation(0.68)
                .contrast(0.92)
                .brightness(-0.03)
                // The icon image carries its own margin; grown so the paper
                // edge around the print is thin.
                .scaleEffect(1.14)
            // Sun and years: a warm cast over everything.
            Color(red: 0.96, green: 0.84, blue: 0.58).opacity(0.14).blendMode(.multiply)
            Canvas { context, canvasSize in
                Self.drawWear(in: &context, size: canvasSize)
            }
            // What's left of the gloss.
            LinearGradient(stops: [
                .init(color: .white.opacity(0.28), location: 0),
                .init(color: .white.opacity(0.06), location: 0.4),
                .init(color: .clear, location: 0.48),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.42), radius: size * 0.045, x: 0, y: size * 0.025)
        .rotationEffect(.degrees(-5))
    }

    /// The crease, the scratches and scuffs, the worn edge, the lifted corner.
    private static func drawWear(in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        var random = SeededRandom(seed: 0x1084)

        // The crease: a shadow with a highlight beside it, corner to corner-ish.
        var crease = Path()
        crease.move(to: CGPoint(x: w * 0.08, y: h * 0.86))
        crease.addQuadCurve(to: CGPoint(x: w * 0.66, y: h * 0.06), control: CGPoint(x: w * 0.30, y: h * 0.50))
        var shadowed = context
        shadowed.addFilter(.blur(radius: w * 0.012))
        shadowed.stroke(crease, with: .color(.black.opacity(0.26)), lineWidth: w * 0.035)
        context.stroke(crease.offsetBy(dx: w * 0.012, dy: w * 0.008), with: .color(.white.opacity(0.38)), lineWidth: w * 0.012)
        var faint = context
        faint.addFilter(.blur(radius: w * 0.03))
        faint.stroke(crease, with: .color(.black.opacity(0.10)), lineWidth: w * 0.10)

        // Scratches: short, mostly leaning one way, light and a few dark.
        for _ in 0..<22 {
            let start = CGPoint(x: w * random.next(), y: h * random.next())
            let length = w * (0.06 + 0.26 * random.next())
            let angle = (-0.35 + 0.7 * random.next()) + (random.next() < 0.25 ? 1.3 : 0)
            let end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            var line = Path()
            line.move(to: start)
            line.addLine(to: end)
            let dark = random.next() < 0.3
            context.stroke(line, with: .color(dark ? .black.opacity(0.10 + 0.12 * random.next()) : .white.opacity(0.14 + 0.3 * random.next())),
                           lineWidth: w * (0.005 + 0.008 * random.next()))
        }
        // Scuffs: soft pale patches, mostly near the edges.
        for _ in 0..<9 {
            let edge = random.next()
            let x = edge < 0.5 ? w * (random.next() < 0.5 ? 0.08 : 0.92) : w * random.next()
            let y = edge < 0.5 ? h * random.next() : h * (random.next() < 0.5 ? 0.08 : 0.92)
            let radius = w * (0.04 + 0.08 * random.next())
            var scuff = context
            scuff.addFilter(.blur(radius: radius * 0.6))
            scuff.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius * 0.6, width: radius * 2, height: radius * 1.2)),
                       with: .color(.white.opacity(0.10 + 0.16 * random.next())))
        }
        // The edge, worn pale and a little grubby.
        let inset = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: w * 0.012, dy: w * 0.012),
                         cornerRadius: w * 0.21, style: .continuous)
        context.stroke(inset, with: .color(.white.opacity(0.22)), lineWidth: w * 0.02)
        var grime = context
        grime.addFilter(.blur(radius: w * 0.02))
        grime.stroke(inset, with: .color(Color(red: 0.25, green: 0.2, blue: 0.1).opacity(0.18)), lineWidth: w * 0.03)

        // The corner lifting, bottom right: the paper back, and its shadow on the print.
        let lift = w * 0.22
        var corner = Path()
        corner.move(to: CGPoint(x: w, y: h - lift))
        corner.addLine(to: CGPoint(x: w, y: h))
        corner.addLine(to: CGPoint(x: w - lift, y: h))
        corner.closeSubpath()
        var liftShadow = context
        liftShadow.addFilter(.blur(radius: w * 0.02))
        liftShadow.fill(corner.offsetBy(dx: -w * 0.03, dy: -w * 0.03), with: .color(.black.opacity(0.35)))
        context.fill(corner, with: .linearGradient(
            Gradient(colors: [Color(red: 0.97, green: 0.96, blue: 0.92), Color(red: 0.80, green: 0.78, blue: 0.72)]),
            startPoint: CGPoint(x: w - lift * 0.3, y: h - lift * 0.3), endPoint: CGPoint(x: w, y: h)))
        var fold = Path()
        fold.move(to: CGPoint(x: w, y: h - lift))
        fold.addLine(to: CGPoint(x: w - lift, y: h))
        context.stroke(fold, with: .color(.black.opacity(0.25)), lineWidth: w * 0.008)
    }
}

/// A fixed sequence of "random" numbers, so the sticker's wear never changes.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    /// 0 ..< 1.
    mutating func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat((state >> 11) & 0x1F_FFFF) / CGFloat(0x20_0000)
    }
}

private struct MonitorScreenView: NSViewRepresentable {
    let store: PlayerStore

    func makeCoordinator() -> MonitorRenderer {
        MonitorRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MonitorMTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        context.coordinator.store = store
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.store = store
    }
}

/// Never takes the mouse, so the power button over the bezel keeps its clicks.
private final class MonitorMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Matches `MonitorUniforms` in Shaders/Monitor.metal.
private struct MonitorUniforms {
    var quad: SIMD2<Float>
    var glassHalf: SIMD2<Float>
    var scale: SIMD2<Float>
    var px: Float
    var time: Float
    var bright: Float
    var focus: Float
    var wobble: Float
    var ambient: Float
    var seed: Float
    var collapse: Float
}

/// Draws the tube into an MTKView, once per display frame: the frame's
/// pixels go up as a mipmapped texture when they change, then one quad.
final class MonitorRenderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()
    nonisolated(unsafe) var store: PlayerStore?

    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let texture: MTLTexture?
    private var pixels = [UInt32](repeating: 0, count: C64Frame.width * C64Frame.height)
    private var uploaded: C64Frame?
    private var uploadedCursor: (x: Int, y: Int)?
    private var uploadedBlink = false
    private var frames: UInt32 = 0

    override init() {
        queue = device?.makeCommandQueue()
        pipeline = device.flatMap(Self.makePipeline)
        texture = device.flatMap { device in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: C64Frame.width, height: C64Frame.height, mipmapped: true)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .managed
            return device.makeTexture(descriptor: descriptor)
        }
        super.init()
    }

    private static func makePipeline(_ device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "monitorVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "monitorFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let queue, let pipeline, let texture,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer()
        else { return }

        let (picture, changed) = MainActor.assumeIsolated { () -> (MonitorPicture, Bool) in
            let model = MonitorModel.shared
            let picture = model.tick(store: store)
            // The BASIC cursor blinks at the C64's 3 Hz.
            let blink = Int(CACurrentMediaTime() * 3) % 2 == 0
            let cursor = model.cursor
            let same = uploaded == model.frame && uploadedBlink == blink
                && uploadedCursor?.x == cursor?.x && uploadedCursor?.y == cursor?.y
            if same { return (picture, false) }
            model.frame.render(into: &pixels, cursor: blink ? cursor : nil)
            uploaded = model.frame
            uploadedBlink = blink
            uploadedCursor = cursor
            return (picture, true)
        }
        if changed {
            pixels.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, C64Frame.width, C64Frame.height), mipmapLevel: 0,
                                withBytes: bytes.baseAddress!, bytesPerRow: C64Frame.width * 4)
            }
            if let blit = commands.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: texture)
                blit.endEncoding()
            }
        }

        frames &+= 1
        let size = view.drawableSize
        let quad = MonitorCase.glass.insetBy(dx: -MonitorCase.margin, dy: -MonitorCase.margin)
        var uniforms = MonitorUniforms(
            quad: SIMD2(Float(quad.width), Float(quad.height)),
            glassHalf: SIMD2(Float(MonitorCase.glass.width / 2), Float(MonitorCase.glass.height / 2)),
            scale: SIMD2(picture.scaleX, picture.scaleY),
            px: Float(size.width / quad.width),
            time: Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)),
            bright: picture.bright, focus: picture.focus, wobble: picture.wobble,
            ambient: picture.ambient, seed: Float(frames % 1000), collapse: picture.collapse)

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MonitorUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

#Preview("Off") {
    MonitorModel.shared.powerOff(animated: false)
    return MonitorCase(store: PlayerStore.preview, live: true)
        .frame(width: 900, height: 675)
        .background(.black)
}

#Preview("Player") {
    let store = PlayerStore.preview
    MonitorModel.shared.showPlayer(store: store)
    return MonitorCase(store: store, live: true)
        .frame(width: 900, height: 675)
        .background(.black)
}

#Preview("Sticker") {
    IconSticker(size: 320)
        .padding(60)
        .background(Color(red: 0.62, green: 0.60, blue: 0.57))
}
