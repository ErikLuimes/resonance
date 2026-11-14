import SwiftUI
import PhosphorCore
import ResonanceVisuals

/// The Halo: a glowing ring per voice that swells with its envelope and
/// wobbles with its waveform's harmonics. `HaloShape` works out the rings on
/// the CPU each display frame; a Metal shader (Shaders/Halo.metal) draws
/// them on the GPU, so it stays cheap at full-screen sizes.
///
/// Shows the first chip, like the inspector's visualizers.
struct HaloView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme
    @State private var shape = HaloShape()

    var body: some View {
        TimelineView(.animation(minimumInterval: VisualizerFeed.frameInterval, paused: !isActive)) { context in
            let frame = store.visualizer.latest()
            let _ = shape.update(voices: (frame?.chips.first?.voices ?? []).map(HaloVoice.init), frame: frame?.index,
                                 at: context.date)
            // Copied out as values: an effect that only captured `shape`
            // (the same object every frame) looked unchanged to SwiftUI and
            // was never redrawn.
            let radii = shape.radii
            let levels = shape.levels
            let colors = (0..<3).map(theme.voice)
            Rectangle()
                .visualEffect { content, proxy in
                    content.colorEffect(HaloShape.shaders.halo(
                        .float2(proxy.size),
                        .floatArray(radii),
                        .floatArray(levels),
                        .color(colors[0]),
                        .color(colors[1]),
                        .color(colors[2])
                    ))
                }
        }
        .accessibilityElement()
        .accessibilityLabel("Halo visualizer")
    }
}

nonisolated extension HaloVoice {
    /// What the Halo needs from a voice of the feed.
    init(_ voice: VizVoice) {
        self.init(envLevel: voice.envLevel, midi: voice.midi, waveform: voice.waveform, pulseWidth: voice.pulseWidth)
    }
}

#Preview {
    HaloView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
}
