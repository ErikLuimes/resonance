import MetalKit
import SwiftUI
import PhosphorCore

/// Ferrofluid: a pool of black, glossy liquid with a magnet under it for
/// each voice. Where a voice sounds, the liquid stands up in spikes, as
/// ferrofluid does over a magnet: taller the louder it is, jumping on
/// every new note, and sliding in and out from the middle with the note
/// it plays. Each voice's light hangs over its magnet and gleams in the
/// spikes in its color. The camera circles slowly.
///
/// `FerroField` moves the magnets; `FerroRenderer` draws the pool
/// (Shaders/Ferro.metal). Shows the first chip, like the Halo.
struct FerroView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    var body: some View {
        FerroMetalView(feed: store.visualizer, theme: theme, isActive: isActive)
            .accessibilityElement()
            .accessibilityLabel("Ferrofluid visualizer")
    }
}

private struct FerroMetalView: NSViewRepresentable {
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let isActive: Bool

    func makeCoordinator() -> FerroDisplay {
        FerroDisplay()
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

    private func update(_ view: MTKView, _ display: FerroDisplay) {
        display.feed = feed
        display.renderer.voiceColors = theme.voices.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
        view.isPaused = !isActive
    }
}

/// Moves the magnets with what the voices play and draws the pool, once
/// per display frame.
private final class FerroDisplay: NSObject, MTKViewDelegate {
    let renderer = FerroRenderer()
    var feed: VisualizerFeed?
    private var field = FerroField()
    private var lastTime: Double?
    private let quality = VisualizerQuality()

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commands = renderer.commandQueue?.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let dt = min(lastTime.map { now - $0 } ?? 0, 0.1)
        lastTime = now
        field.update(voices: feed?.latest()?.pouringVoices ?? [], dt: dt, clock: now)
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        // Coarser, and at the lowest level half as often, on a Mac that
        // can't keep up.
        if view.preferredFramesPerSecond != quality.framesPerSecond { view.preferredFramesPerSecond = quality.framesPerSecond }
        renderer.encode(into: drawable.texture, commands: commands, magnets: field.magnets, clock: now, scale: scale,
                        quality: quality.level)
        quality.track(commands)
        commands.present(drawable)
        commands.commit()
    }
}

#Preview {
    FerroView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
