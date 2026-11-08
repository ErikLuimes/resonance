import SwiftUI
import PhosphorCore

/// Per-voice level bars with peak hold, plus the note and waveform each
/// voice is playing, redrawn every display frame while music plays. Shows
/// every chip's voices.
///
/// Levels are the voices' envelopes from the visualizer feed's reSID, in
/// step with the audio. Drawn into one Canvas (see VisualizerView).
struct BarsVisualizer: View {
    /// False pauses it, e.g. while another page or Now Playing covers it.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme
    @State private var meter = VoiceMeter()

    var body: some View {
        TimelineView(.animation(minimumInterval: VisualizerFeed.frameInterval, paused: !store.isPlaying || !isActive)) { context in
            let voices = store.visualizer.latest()?.chips.flatMap(\.voices) ?? []
            // Empty slots until the first frame sounds.
            let levels = voices.isEmpty
                ? Array(repeating: 0, count: 3 * Int(store.nowPlaying?.numSids ?? 1))
                : voices.map(\.envLevel)
            let _ = meter.update(levels: levels, at: context.date)
            Canvas { gc, size in
                draw(levels: meter.levels, peaks: meter.peaks, voices: voices, in: gc, size: size)
            }
        }
        .onChange(of: store.state) { _, state in
            if state == .stopped { meter.reset() }
        }
        .accessibilityElement()
        .accessibilityLabel("Voice levels")
    }

    private static let gap: CGFloat = 6

    private func draw(levels: [Double], peaks: [Double], voices: [VizVoice], in gc: GraphicsContext, size: CGSize) {
        Self.drawBars(levels: levels, peaks: peaks, theme: theme, in: gc, size: size) { i, x, top in
            VoiceLabels.draw(i < voices.count ? voices[i] : nil, color: theme.voice(i), centeredAt: x, top: top, in: gc)
        }
    }

    /// The bars themselves, also drawn by the welcome. `label` draws what's
    /// under voice `i`, given the voice's center and the labels' top.
    static func drawBars(
        levels: [Double],
        peaks: [Double],
        theme: VoiceTheme,
        in gc: GraphicsContext,
        size: CGSize,
        label: (_ voice: Int, _ centerX: CGFloat, _ top: CGFloat) -> Void
    ) {
        let count = levels.count
        guard count > 0 else { return }
        let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let barHeight = size.height - VoiceLabels.height

        for i in 0..<count {
            let x = CGFloat(i) * (width + gap)
            let color = theme.voice(i)

            // Faint slot so silent voices stay visible.
            gc.fill(Path(roundedRect: CGRect(x: x, y: 0, width: width, height: barHeight), cornerRadius: 4),
                    with: .color(color.opacity(0.12)))
            let h = max(barHeight * levels[i], 2)
            gc.fill(Path(roundedRect: CGRect(x: x, y: barHeight - h, width: width, height: h), cornerRadius: 4),
                    with: .linearGradient(Gradient(colors: [color.opacity(0.6), color]),
                                          startPoint: CGPoint(x: 0, y: barHeight),
                                          endPoint: CGPoint(x: 0, y: barHeight - h)))
            let peakY = barHeight - barHeight * peaks[i]
            gc.fill(Path(CGRect(x: x, y: max(peakY - 2, 0), width: width, height: 2)),
                    with: .color(.white.opacity(0.8)))

            label(i, x + width / 2, barHeight)
        }
    }
}

#Preview {
    BarsVisualizer()
        .environment(PlayerStore.preview)
        .frame(width: 300, height: 180)
        .padding()
}
