import MetalKit
import SwiftUI
import PhosphorCore

/// Ink and Liquid Light: each voice pours a stream of dye in its color
/// into a fluid, from a ring around the middle. The voice's level is how
/// hard it pours, every new note is a puff, and the note it plays steers
/// the stream from side to side, so the three chase, fold into and marble
/// each other as the tune goes.
///
/// Ink is thin dye in dark water, gone in a few seconds. Liquid Light is
/// the same fluid as thick oil on a projector's glass, lit from behind
/// like a 1960s light show: the oil stays, fills the glass and shines.
///
/// `InkJets` aims the streams; `InkRenderer` runs the fluid on the GPU
/// (Shaders/Ink.metal). Shows the first chip, like the Halo.
struct InkView: View {
    var style = InkRenderer.Style.ink
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    var body: some View {
        InkMetalView(style: style, feed: store.visualizer, theme: theme, isActive: isActive)
            .accessibilityElement()
            .accessibilityLabel(style.display == InkRenderer.Style.ink.display ? Text("Ink visualizer") : Text("Liquid Light visualizer"))
    }
}

nonisolated extension InkJets.Voice {
    /// What a voice is doing in a frame of the feed.
    init(_ voice: VizVoice) {
        self.init(level: Float(voice.envLevel), midi: Float(voice.midi), isNoise: voice.waveform == 0x8)
    }
}

nonisolated extension VizSidFrame {
    /// The first chip's three voices, for the fluid visualizers.
    var pouringVoices: [InkJets.Voice] {
        (chips.first?.voices ?? []).prefix(3).map(InkJets.Voice.init)
    }
}

private struct InkMetalView: NSViewRepresentable {
    let style: InkRenderer.Style
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let isActive: Bool

    func makeCoordinator() -> InkDisplay {
        InkDisplay(style: style)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = PassThroughMetalView(frame: .zero, device: context.coordinator.renderer.device)
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

    private func update(_ view: MTKView, _ display: InkDisplay) {
        display.feed = feed
        display.colors = theme.voices.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
        view.isPaused = !isActive
    }
}

/// Pours what the voices play into the fluid and draws it, once per
/// display frame.
private final class InkDisplay: NSObject, MTKViewDelegate {
    let renderer: InkRenderer
    var feed: VisualizerFeed?
    var colors: [SIMD3<Float>] = []
    private var jets = InkJets()
    private var lastTime: Double?
    private let quality: VisualizerQuality

    init(style: InkRenderer.Style) {
        renderer = InkRenderer(style: style)
        quality = VisualizerQuality()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commands = renderer.commandQueue?.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let dt = lastTime.map { now - $0 } ?? 0
        lastTime = now
        let size = view.drawableSize
        let pours = jets.pours(voices: feed?.latest()?.pouringVoices ?? [], colors: colors,
                               aspect: Float(size.width / max(size.height, 1)), clock: now)
        // Fewer pressure rounds, and at the lowest level half the frames,
        // on a Mac that can't keep up.
        if view.preferredFramesPerSecond != quality.framesPerSecond { view.preferredFramesPerSecond = quality.framesPerSecond }
        renderer.encode(into: drawable.texture, commands: commands, pours: pours, dt: dt, quality: quality.level)
        quality.track(commands)
        commands.present(drawable)
        commands.commit()
    }
}

#Preview {
    InkView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
