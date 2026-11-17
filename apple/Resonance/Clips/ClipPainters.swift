import AppKit
import MetalKit
import PhosphorCore
import SceneKit
import SwiftUI
import ResonanceVisuals


/// What a clip's frame is drawn from: the clip's feed at one point in the
/// tune.
struct ClipMoment {
    let feed: VisualizerFeed
    /// Seconds into the subtune: the end of the frame's audio.
    let tuneTime: Double
    /// The clock the visualizers move their cameras and drifts by: the
    /// tune's own time, so a clip of the tune's start shows each tour from
    /// its start (Silicon's descent into the chip), and the same part of a
    /// tune always gets the same shots. It doesn't follow the window, whose
    /// tours run on the Mac's clock.
    let clock: Double
    /// Seconds since the last frame drawn.
    let dt: Double
}

/// Draws one visualizer into a texture the clip's size, frame by frame.
/// Each frame's GPU work is done when `paint` returns.
@MainActor
protocol ClipPainter: AnyObject {
    /// The picture, premultiplied over transparency (the compositor adds the
    /// background), or nil when there's nothing to show yet.
    func paint(_ moment: ClipMoment) async -> MTLTexture?
    /// The picture comes out upside down (Core Animation's origin is the
    /// bottom left).
    var isFlipped: Bool { get }
}

extension ClipPainter {
    var isFlipped: Bool { false }
}

extension MTLCommandBuffer {
    /// Commits, and waits for the GPU without holding the main thread, so
    /// the window's own visualizer keeps drawing while a clip or the
    /// sheet's still does.
    func commitAndWait() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            addCompletedHandler { _ in done.resume() }
            commit()
        }
    }
}

/// Points to pixels: a clip is drawn as a view 540 points tall at 2×.
let clipBackingScale: CGFloat = 2

@MainActor
enum ClipPainters {
    /// A painter for `visual` at `size` pixels, ready to draw; nil for one
    /// that can't make clips.
    static func make(_ visual: NowPlayingVisual, size: CGSize, theme: VoiceTheme, store: PlayerStore,
                     track: TrackDetails) async -> (any ClipPainter)? {
        let colors = theme.voices.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
        switch visual {
        case .ink: return MetalPainter(size: size) { InkClip(style: .ink, colors: colors) }
        case .liquidLight: return MetalPainter(size: size) { InkClip(style: .liquidLight, colors: colors) }
        case .ferrofluid: return MetalPainter(size: size) { FerroClip(colors: colors) }
        case .nimbus: return MetalPainter(size: size) { NimbusClip(colors: colors) }
        case .terrain: return MetalPainter(size: size) { TerrainClip(colors: colors) }
        case .soundMap: return MetalPainter(size: size) { SoundMapClip(colors: colors) }
        case .particles: return MetalPainter(size: size) { ParticlesClip(colors: theme.voices.map { SIMD4(Float($0.red), Float($0.green), Float($0.blue), 1) }) }
        case .notes:
            let song = await notes(store: store, track: track)
            return MetalPainter(size: size) { NotesClip(colors: colors, track: song) }
        case .silicon:
            let die: SiliconDie = track.sidModel == 2 ? .mos8580 : .mos6581
            return await SiliconClipPainter(die: die, size: size, colors: colors)
        case .halo: return HaloClipPainter(size: size, theme: theme)
        case .radial: return LayerClipPainter(size: size) { feed in
            let view = RadialNSView()
            view.apply(feed: feed, theme: theme, isAnimating: false)
            return (view, { view.clipFrame(at: $0) })
        }
        case .spectrum: return LayerClipPainter(size: size) { feed in
            let view = SpectrumNSView()
            view.apply(feed: feed, theme: theme, isAnimating: false)
            view.scaleChanged(to: clipBackingScale)
            return (view, { view.clipFrame(at: $0) })
        }
        case .chip, .rasters: return nil
        }
    }

    /// The last tune's notes: working them out takes about 2 s for a long
    /// tune (measured, `ClipBench.stills`), and the sheet asks again on
    /// every change.
    private static var lastNotes: (path: String, subtune: UInt16, notes: NoteTrack?)?

    private static func notes(store: PlayerStore, track: TrackDetails) async -> NoteTrack? {
        if let last = lastNotes, last.path == track.path, last.subtune == track.currentSong { return last.notes }
        let secs = min((store.duration ?? 300) + 2, 900)
        let song = try? await store.core.trackerSong(path: track.path, subtune: track.currentSong, secs: secs, chip: 0)
        let notes = song.map(NoteTrack.init)
        lastNotes = (track.path, track.currentSong, notes)
        return notes
    }

    /// The lead-in for `visual`, in seconds: what runs before the clip's
    /// first frame, drawn and not kept, so the first frame looks as it
    /// would have live.
    static func leadIn(_ visual: NowPlayingVisual) -> Double {
        switch visual {
        case .notes, .silicon: 0
        case .terrain: TerrainClip.leadIn
        case .ferrofluid: FerroClip.leadIn
        // These build up; they start nearly fresh and grow through the
        // clip (Erik's call), with enough lead-in that the first frame,
        // which feeds show before playing, isn't empty.
        case .ink, .liquidLight, .nimbus, .soundMap: 2
        // Measured (`ClipBench.leadIns`): their first frame stops changing
        // after 0.5 s of lead-in.
        case .halo, .radial, .spectrum: 1
        // Never settles: its particles go wherever they were sent, so
        // its first frame depends on where the engine started. 2 s fills it.
        case .particles: 2
        case .chip, .rasters: 0
        }
    }

    /// The ones that can make clips: every one the chooser offers.
    static func canClip(_ visual: NowPlayingVisual) -> Bool {
        switch visual {
        case .chip, .rasters: false
        default: true
        }
    }
}

// MARK: Metal

/// One Metal visualizer's frame: what the view's display does each frame,
/// on the clip's clock.
@MainActor
protocol MetalClip: AnyObject {
    var queue: MTLCommandQueue? { get }
    func encode(into target: MTLTexture, commands: MTLCommandBuffer, moment: ClipMoment)
}

/// Draws a `MetalClip` into a texture of its own.
@MainActor
final class MetalPainter<Clip: MetalClip>: ClipPainter {
    private let clip: Clip
    private let target: MTLTexture?

    init(size: CGSize, make: () -> Clip) {
        clip = make()
        target = clip.queue.flatMap { clipTexture($0.device, size) }
    }

    func paint(_ moment: ClipMoment) async -> MTLTexture? {
        guard let target, let commands = clip.queue?.makeCommandBuffer() else { return nil }
        clip.encode(into: target, commands: commands, moment: moment)
        await commands.commitAndWait()
        return target
    }
}

/// A shared, readable bgra8 texture the clip's size.
func clipTexture(_ device: MTLDevice, _ size: CGSize) -> MTLTexture? {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width),
                                                     height: Int(size.height), mipmapped: false)
    d.usage = [.renderTarget, .shaderRead, .shaderWrite]
    d.storageMode = .shared
    return device.makeTexture(descriptor: d)
}

@MainActor
final class InkClip: MetalClip {
    private let renderer: InkRenderer
    private let colors: [SIMD3<Float>]
    private var jets = InkJets()
    var queue: MTLCommandQueue? { renderer.commandQueue }

    init(style: InkRenderer.Style, colors: [SIMD3<Float>]) {
        renderer = InkRenderer(style: style)
        self.colors = colors
    }

    func encode(into target: MTLTexture, commands: MTLCommandBuffer, moment: ClipMoment) {
        let pours = jets.pours(voices: moment.feed.latest()?.pouringVoices ?? [], colors: colors,
                               aspect: Float(target.width) / Float(max(target.height, 1)), clock: moment.clock)
        renderer.encode(into: target, commands: commands, pours: pours, dt: moment.dt, quality: .full)
    }
}

@MainActor
final class FerroClip: MetalClip {
    /// Its slowest smoothing is the pull sinking (`FerroField.sink`,
    /// 0.28 s); ln 510 ≈ 6.2 of those is 1.7 s.
    static let leadIn = 2.0
    private let renderer = FerroRenderer()
    private var field = FerroField()
    var queue: MTLCommandQueue? { renderer.commandQueue }

    init(colors: [SIMD3<Float>]) { renderer.voiceColors = colors }

    func encode(into target: MTLTexture, commands: MTLCommandBuffer, moment: ClipMoment) {
        field.update(voices: moment.feed.latest()?.pouringVoices ?? [], dt: moment.dt, clock: moment.clock)
        renderer.encode(into: target, commands: commands, magnets: field.magnets, clock: moment.clock,
                        scale: Float(clipBackingScale), quality: .full)
    }
}

@MainActor
final class NimbusClip: MetalClip {
    private let renderer = NimbusRenderer()
    private var voices = NimbusVoices()
    var queue: MTLCommandQueue? { renderer.commandQueue }

    init(colors: [SIMD3<Float>]) { renderer.voiceColors = colors }

    func encode(into target: MTLTexture, commands: MTLCommandBuffer, moment: ClipMoment) {
        voices.update(voices: moment.feed.latest()?.pouringVoices ?? [], dt: moment.dt)
        renderer.encode(into: target, commands: commands, voices: voices, clock: moment.clock,
                        scale: Float(clipBackingScale), quality: .full)
    }
}

@MainActor
final class TerrainClip: MetalClip {
    /// Its ridges are the last 4 s of the spectrum.
    static let leadIn = 4.0
    private let renderer = TerrainRenderer()
    private let spectrum = FineSpectrum(bands: TerrainRenderer.columns)
    var queue: MTLCommandQueue? { renderer.commandQueue }

    init(colors: [SIMD3<Float>]) { renderer.voiceColors = colors }

    func encode(into target: MTLTexture, commands: MTLCommandBuffer, moment: ClipMoment) {
        let scope = moment.feed.scope(chip: 0, count: FineSpectrum.samples)
        spectrum.update(voices: scope.voices, sampleRate: scope.sampleRate,
                        at: Date(timeIntervalSinceReferenceDate: moment.clock))
        renderer.encode(into: target, commands: commands, levels: spectrum.levels, clock: moment.clock,
                        scale: Float(clipBackingScale))
    }
}

@MainActor
final class NotesClip: MetalClip {
    private let renderer = NotesRenderer()
    var queue: MTLCommandQueue? { renderer.commandQueue }

    init(colors: [SIMD3<Float>], track: NoteTrack?) {
        renderer.voiceColors = colors
        renderer.track = track
    }

    func encode(into target: MTLTexture, commands: MTLCommandBuffer, moment: ClipMoment) {
        // The clip's time is exact, so no smoothing of the heard time.
        renderer.encode(into: target, commands: commands, time: moment.tuneTime, clock: moment.clock,
                        scale: Float(clipBackingScale))
    }
}

@MainActor
final class SoundMapClip: MetalClip {
    private let renderer = SoundMapRenderer()
    let queue: MTLCommandQueue?

    init(colors: [SIMD3<Float>]) {
        renderer.voiceColors = colors
        queue = renderer.device?.makeCommandQueue()
    }

    func encode(into target: MTLTexture, commands: MTLCommandBuffer, moment: ClipMoment) {
        let feed = moment.feed
        renderer.map.update(frames: feed.history(16), scope: { feed.scope(chip: 0, count: MFCCExtractor.size) },
                            now: moment.clock)
        renderer.encode(into: target, commands: commands, now: moment.clock, scale: Float(clipBackingScale))
    }
}

@MainActor
final class ParticlesClip: MetalClip {
    private let renderer = ParticleRenderer()
    var queue: MTLCommandQueue? { renderer.commandQueue }

    init(colors: [SIMD4<Float>]) { renderer.colors = colors }

    func encode(into target: MTLTexture, commands: MTLCommandBuffer, moment: ClipMoment) {
        renderer.feed = moment.feed
        renderer.encode(into: target, commands: commands, backing: Float(clipBackingScale),
                        at: Date(timeIntervalSinceReferenceDate: moment.clock))
    }
}

// MARK: SceneKit

/// Silicon through SceneKit's own renderer, into the clip's texture.
@MainActor
final class SiliconClipPainter: ClipPainter {
    private let silicon: SiliconScene
    private let renderer: SCNRenderer
    private let queue: MTLCommandQueue?
    private let target: MTLTexture?
    private let depth: MTLTexture?
    private let chip = ChipModel()

    init?(die: SiliconDie, size: CGSize, colors: [SIMD3<Float>]) async {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        await SiliconAssets.warm(die)
        silicon = SiliconScene(die: die)
        silicon.voiceColors = colors
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = silicon.scene
        renderer.pointOfView = silicon.cameraNode
        queue = device.makeCommandQueue()
        target = clipTexture(device, size)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: Int(size.width),
                                                         height: Int(size.height), mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .private
        depth = device.makeTexture(descriptor: d)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            renderer.prepare([silicon.scene]) { _ in done.resume() }
        }
    }

    func paint(_ moment: ClipMoment) async -> MTLTexture? {
        guard let target, let depth, let commands = queue?.makeCommandBuffer() else { return nil }
        chip.update(feed: moment.feed, at: Date(timeIntervalSinceReferenceDate: moment.clock))
        // SceneKit commits node changes at the end of a run loop turn: without
        // this, each frame draws the last one's camera, and the first frame
        // the scene's starting one whatever the clip's start.
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        silicon.update(state: chip.state, clock: moment.clock)
        SCNTransaction.commit()
        SCNTransaction.flush()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        renderer.render(atTime: moment.clock, viewport: CGRect(x: 0, y: 0, width: target.width, height: target.height),
                        commandBuffer: commands, passDescriptor: pass)
        await commands.commitAndWait()
        return target
    }
}

// MARK: SwiftUI and Core Animation

/// The Halo's shader through `ImageRenderer`, as the view draws it.
@MainActor
final class HaloClipPainter: ClipPainter {
    private let shape = HaloShape()
    private let size: CGSize
    private let colors: [Color]
    private let upload: TextureUpload?

    init(size: CGSize, theme: VoiceTheme) {
        self.size = size
        colors = (0..<3).map(theme.voice)
        upload = MTLCreateSystemDefaultDevice().flatMap { TextureUpload(device: $0, size: size) }
    }

    func paint(_ moment: ClipMoment) async -> MTLTexture? {
        let frame = moment.feed.latest()
        shape.update(voices: (frame?.chips.first?.voices ?? []).map(HaloVoice.init), frame: frame?.index,
                     at: Date(timeIntervalSinceReferenceDate: moment.clock))
        let radii = shape.radii, levels = shape.levels, colors = colors
        let points = CGSize(width: size.width / clipBackingScale, height: size.height / clipBackingScale)
        let picture = Rectangle()
            .visualEffect { content, proxy in
                content.colorEffect(HaloShape.shaders.halo(
                    .float2(proxy.size), .floatArray(radii), .floatArray(levels),
                    .color(colors[0]), .color(colors[1]), .color(colors[2])))
            }
            .frame(width: points.width, height: points.height)
        let renderer = ImageRenderer(content: picture)
        renderer.scale = clipBackingScale
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        return upload?.upload(image)
    }
}

/// A Core Animation visualizer (Radial, Spectrum): its view, offscreen,
/// drawn into a texture by `CARenderer`, which renders layers as the
/// window server does.
@MainActor
final class LayerClipPainter: ClipPainter {
    var isFlipped: Bool { true }
    private let view: NSView
    private let draw: (Date) -> Void
    private let root = CALayer()
    private let renderer: CARenderer?
    private let target: MTLTexture?
    private let queue: MTLCommandQueue?

    init(size: CGSize, make: (VisualizerFeed) -> (NSView, (Date) -> Void)) {
        // The feed is swapped in each frame through `paint`'s moment; the
        // view keeps the one it's given, so it's given a forwarding one.
        let source = ForwardingVizSource()
        let made = make(VisualizerFeed(core: source, frames: nil))
        view = made.0
        draw = made.1
        self.source = source
        let points = CGSize(width: size.width / clipBackingScale, height: size.height / clipBackingScale)
        view.frame = CGRect(origin: .zero, size: points)
        view.layoutSubtreeIfNeeded()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = .clear
        if let layer = view.layer {
            layer.removeFromSuperlayer()
            layer.anchorPoint = .zero
            layer.position = .zero
            layer.bounds = CGRect(origin: .zero, size: points)
            layer.setAffineTransform(CGAffineTransform(scaleX: clipBackingScale, y: clipBackingScale))
            root.addSublayer(layer)
        }
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        target = device.flatMap { clipTexture($0, size) }
        renderer = target.map { CARenderer(mtlTexture: $0, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]) }
        renderer?.layer = root
        renderer?.bounds = root.frame
    }

    private let source: ForwardingVizSource

    func paint(_ moment: ClipMoment) async -> MTLTexture? {
        guard let renderer, let target else { return nil }
        // CARenderer draws over what the texture holds: without clearing
        // it, every frame piles onto the last.
        clear(target)
        source.target = moment.feed.core
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layout()
        draw(Date(timeIntervalSinceReferenceDate: moment.clock))
        CATransaction.commit()
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        return target
    }

    private func clear(_ texture: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let commands = queue?.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
    }
}

/// A feed source that reads whichever source it's pointed at.
nonisolated final class ForwardingVizSource: VizSource, @unchecked Sendable {
    var target: (any VizSource)?

    func vizLatest() -> VizSidFrame? { target?.vizLatest() }
    func vizHeardSecs() -> Double? { target?.vizHeardSecs() }
    func vizHistory(count: UInt32) -> [VizSidFrame] { target?.vizHistory(count: count) ?? [] }
    func vizScope(chip: UInt32, count: UInt32) -> VizScopeSamples {
        target?.vizScope(chip: chip, count: count) ?? VizScopeSamples(sampleRate: 44_800, count: 0, samples: Data())
    }
    func vizStats() -> VizStats {
        target?.vizStats() ?? VizStats(frames: 0, shadowMicros: 0, bufferMs: 0, outputLatencyMs: 0, offsetMs: 0)
    }
    func setVizOutputLatencyMs(ms: UInt32) {}
    func setVizOffsetMs(ms: Int32) {}
}

/// Copies a `CGImage` into a texture, through a bitmap the texture's
/// layout.
final class TextureUpload {
    let texture: MTLTexture
    private let context: CGContext

    init?(device: MTLDevice, size: CGSize) {
        guard let texture = clipTexture(device, size),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        self.texture = texture
        self.context = context
    }

    func upload(_ image: CGImage) -> MTLTexture? {
        let rect = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        context.clear(rect)
        context.draw(image, in: rect)
        guard let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, context.width, context.height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: context.bytesPerRow)
        return texture
    }
}
