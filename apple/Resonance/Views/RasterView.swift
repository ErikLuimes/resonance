import MetalKit
import SwiftUI
import PhosphorCore

/// Rasters: a C64 demo's screen, in the C64's own 384 × 272 blocks with
/// its blue screen and light blue border. Each voice is a copper bar the
/// full width of the screen and border, on the line its note belongs on
/// and as tall as it's loud, with the bars of its last few notes fading
/// behind it; a drum flashes the border. Stars drift behind, the top line
/// says what each voice is playing, and a scroller riding a sine wave
/// carries the tune's name, composer and release.
///
/// `RasterShow` places the bars; `RasterRenderer` draws the screen
/// (Shaders/Rasters.metal). Shows the first chip, like the Halo.
struct RasterView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    /// What the scroller carries: the tune, its composer and its release.
    private var scroller: String {
        guard let track = store.nowPlaying else { return "Resonance" }
        return [track.title, track.author, track.released]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "<?>" }
            .joined(separator: "     ·     ")
    }

    var body: some View {
        RasterMetalView(feed: store.visualizer, theme: theme, scroller: scroller, isActive: isActive)
            .accessibilityElement()
            .accessibilityLabel("Rasters visualizer")
    }
}

private struct RasterMetalView: NSViewRepresentable {
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let scroller: String
    let isActive: Bool

    func makeCoordinator() -> RasterDisplay {
        RasterDisplay()
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

    private func update(_ view: MTKView, _ display: RasterDisplay) {
        display.feed = feed
        display.renderer.voiceColors = theme.voices.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
        display.renderer.setText(scroller)
        view.isPaused = !isActive
    }
}

/// Moves the bars with what the voices play and draws the screen, once
/// per display frame.
private final class RasterDisplay: NSObject, MTKViewDelegate {
    let renderer = RasterRenderer()
    var feed: VisualizerFeed?
    private var show = RasterShow()
    private var lastTime: Double?

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commands = renderer.commandQueue?.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let dt = min(lastTime.map { now - $0 } ?? 0, 0.1)
        lastTime = now
        let voices = feed?.latest()?.chips.first?.voices ?? []
        show.update(voices: voices.prefix(3).map(InkJets.Voice.init), dt: dt)
        renderer.setStatus(Self.status(voices))
        renderer.encode(into: drawable.texture, commands: commands, show: show, clock: now)
        commands.present(drawable)
        commands.commit()
    }

    /// The screen's top line: each voice's waveform and note, as
    /// "1:SAW A-4"; dashes while it's silent.
    static func status(_ voices: [VizVoice]) -> String {
        voices.prefix(3).enumerated().map { i, voice in
            let sounding = voice.gate || voice.envLevel > 0.02
            let waveform = voice.waveformName.split(separator: "+").first.map(String.init) ?? "---"
            let note = sounding ? (voice.note ?? "---") : "---"
            return "\(i + 1):\(waveform) \(note.padding(toLength: 3, withPad: " ", startingAt: 0))"
        }.joined(separator: "  ")
    }
}

#Preview {
    RasterView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
