import MetalKit
import SwiftUI
import PhosphorCore

/// Nimbus: metaballs of smoke in a pale morning sky. Six soft balls, two
/// a voice, roam round each other, parting and meeting, each trailing
/// smoke; where two meet they run together and stir each other up. A voice's pair swells with its level and jumps on every new
/// note, rides higher the higher it plays, and glows from inside in the
/// voice's color; and they all drift and churn faster the louder the
/// music is. The low sun lights them from one side, and the camera
/// circles.
///
/// `NimbusVoices` follows the voices; `NimbusRenderer` walks each pixel's
/// line of sight through the cloud (Shaders/Nimbus.metal). Shows the
/// first chip, like the Halo.
struct NimbusView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    var body: some View {
        NimbusMetalView(feed: store.visualizer, theme: theme, isActive: isActive)
            .accessibilityElement()
            .accessibilityLabel("Nimbus visualizer")
    }
}

private struct NimbusMetalView: NSViewRepresentable {
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let isActive: Bool

    func makeCoordinator() -> NimbusDisplay {
        NimbusDisplay()
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

    private func update(_ view: MTKView, _ display: NimbusDisplay) {
        display.feed = feed
        display.renderer.voiceColors = theme.voices.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
        view.isPaused = !isActive
    }
}

/// Follows the voices and draws the cloud, once per display frame.
private final class NimbusDisplay: NSObject, MTKViewDelegate {
    let renderer = NimbusRenderer()
    var feed: VisualizerFeed?
    private var voices = NimbusVoices()
    private var lastTime: Double?
    private let quality = VisualizerQuality()

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commands = renderer.commandQueue?.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let dt = min(lastTime.map { now - $0 } ?? 0, 0.1)
        lastTime = now
        voices.update(voices: feed?.latest()?.pouringVoices ?? [], dt: dt)
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        // Coarser, and at the lowest level half as often, on a Mac that
        // can't keep up.
        if view.preferredFramesPerSecond != quality.framesPerSecond { view.preferredFramesPerSecond = quality.framesPerSecond }
        renderer.encode(into: drawable.texture, commands: commands, voices: voices, clock: now, scale: scale, quality: quality.level)
        quality.track(commands)
        commands.present(drawable)
        commands.commit()
    }
}

#Preview {
    NimbusView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
