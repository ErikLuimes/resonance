import SwiftUI
import PhosphorCore

/// An oscilloscope per voice, with the note and waveform each voice is
/// playing, redrawn every display frame while music plays.
///
/// Each trace is the voice's output (waveform × envelope) from the
/// visualizer feed, in step with the audio, so a note grows and fades with
/// its envelope. Multi-SID tunes show their first chip. Drawn into one
/// Canvas (see VisualizerView).
struct ScopeVisualizer: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        TimelineView(.animation(paused: !store.isPlaying)) { _ in
            let feed = store.visualizer
            let voices = feed.latest()?.chips.first?.voices ?? []
            let scope = voices.isEmpty ? nil : feed.scope(chip: 0, count: 2048)
            Canvas { gc, size in
                draw(voices: voices, scope: scope, in: gc, size: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Voice oscilloscopes")
    }

    private static let gap: CGFloat = 6

    private func draw(voices: [VizVoice], scope: VizScope?, in gc: GraphicsContext, size: CGSize) {
        let width = (size.width - Self.gap * 2) / 3
        let scopeHeight = size.height - VoiceLabels.height

        for i in 0..<3 {
            let color = VisualizerFeed.voiceColors[i]
            let lane = CGRect(x: CGFloat(i) * (width + Self.gap), y: 0, width: width, height: scopeHeight)
            gc.fill(Path(roundedRect: lane, cornerRadius: 6), with: .color(color.opacity(0.08)))
            gc.stroke(Path { p in
                p.move(to: CGPoint(x: lane.minX, y: lane.midY))
                p.addLine(to: CGPoint(x: lane.maxX, y: lane.midY))
            }, with: .color(.white.opacity(0.08)), lineWidth: 1)

            let voice = i < voices.count ? voices[i] : nil
            if let voice, let scope, i < scope.voices.count {
                let window = ScopeTrigger.window(
                    scope.voices[i], hz: voice.hz, sampleRate: scope.sampleRate,
                    pitched: voice.waveform & 0x7 != 0
                )
                let trace = Self.trace(window, in: lane.insetBy(dx: 4, dy: 6))
                gc.stroke(trace, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                gc.stroke(trace, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }

            VoiceLabels.draw(voice, color: color, centeredAt: lane.midX, top: scopeHeight, in: gc)
        }
    }

    /// The samples across `rect`, −1 at the bottom and 1 at the top, at
    /// most two points per pixel.
    private static func trace(_ samples: ArraySlice<Float>, in rect: CGRect) -> Path {
        let points = min(samples.count, max(Int(rect.width * 2), 2))
        guard points > 1 else { return Path() }
        let step = Double(samples.count - 1) / Double(points - 1)
        return Path { p in
            for k in 0..<points {
                let sample = samples[samples.startIndex + Int((Double(k) * step).rounded())]
                let point = CGPoint(
                    x: rect.minX + rect.width * CGFloat(k) / CGFloat(points - 1),
                    y: rect.midY - CGFloat(sample) * rect.height / 2
                )
                if k == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
        }
    }
}

#Preview {
    ScopeVisualizer()
        .environment(PlayerStore.preview)
        .frame(width: 300, height: 180)
        .padding()
}
