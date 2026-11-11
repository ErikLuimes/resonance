import MetalKit
import SwiftUI
import PhosphorCore

/// Terrain: the spectrum as a landscape. Frequency runs from the low notes
/// on the left to the highest overtones on the right, the newest moment is
/// the ridge at the front, and the last four seconds slide away behind it,
/// so a held note is a ridge running into the distance, a melody a row of
/// hills stepping sideways, and a drum a wall across. Each ridge takes the
/// color of the voices sounding there.
///
/// `FineSpectrum` works out the spectrum; `TerrainRenderer` draws it with
/// Metal (Shaders/Terrain.metal). Shows the first chip, like the Halo.
struct TerrainView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    var body: some View {
        TerrainMetalView(feed: store.visualizer, theme: theme, isActive: isActive)
            .accessibilityElement()
            .accessibilityLabel("Terrain visualizer")
    }
}

private struct TerrainMetalView: NSViewRepresentable {
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let isActive: Bool

    func makeCoordinator() -> TerrainDisplay {
        TerrainDisplay()
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

    private func update(_ view: MTKView, _ display: TerrainDisplay) {
        display.feed = feed
        display.renderer.voiceColors = theme.voices.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
        let background = theme.background
        display.renderer.background = SIMD3(Float(background.red), Float(background.green), Float(background.blue))
        view.isPaused = !isActive
    }
}

/// Reads the spectrum and draws the land once per display frame.
private final class TerrainDisplay: NSObject, MTKViewDelegate {
    let renderer = TerrainRenderer()
    var feed: VisualizerFeed?
    private let spectrum = FineSpectrum(bands: TerrainRenderer.columns)

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commands = renderer.commandQueue?.makeCommandBuffer() else { return }
        if let scope = feed?.scope(chip: 0, count: FineSpectrum.samples) {
            spectrum.update(voices: scope.voices, sampleRate: scope.sampleRate, at: .now)
        }
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        renderer.encode(into: drawable.texture, commands: commands, levels: spectrum.levels, clock: CACurrentMediaTime(), scale: scale)
        commands.present(drawable)
        commands.commit()
    }
}

#Preview {
    TerrainView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
