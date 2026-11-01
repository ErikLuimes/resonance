import SwiftUI
import PhosphorCore

/// Per-voice level bars with peak hold, plus the note and waveform each
/// voice is playing, redrawn every display frame while music plays.
///
/// Levels are the voices' envelopes from the visualizer feed's reSID, in
/// step with the audio.
///
/// Everything, labels included, is drawn into one Canvas. A Canvas has no
/// content-derived size, so per-frame text changes can't alter the
/// inspector's size; with SwiftUI Text labels, every new note name changed
/// the column's ideal width mid-layout and AppKit aborted the app after
/// re-running layout too many times.
struct VisualizerView: View {
    @Environment(PlayerStore.self) private var store
    @State private var meter = VoiceMeter()

    var body: some View {
        TimelineView(.animation(paused: !store.isPlaying)) { context in
            let voices = store.visualizer.latest()?.chips.flatMap(\.voices) ?? []
            // Empty slots until the first frame sounds.
            let levels = voices.isEmpty
                ? Array(repeating: 0, count: 3 * Int(store.nowPlaying?.numSids ?? 1))
                : voices.map(\.envLevel)
            let _ = meter.update(levels: levels, at: context.date)
            Canvas { gc, size in
                draw(levels: meter.levels, peaks: meter.peaks, voices: voices, in: gc, size: size)
            }
            .padding(12)
        }
        .background(.black.opacity(0.85), in: .rect(cornerRadius: 10))
        .onChange(of: store.state) { _, state in
            if state == .stopped { meter.reset() }
        }
        .accessibilityElement()
        .accessibilityLabel("Voice levels")
    }

    private static let labelHeight: CGFloat = 32
    private static let gap: CGFloat = 6

    private func draw(levels: [Double], peaks: [Double], voices: [VizVoice], in gc: GraphicsContext, size: CGSize) {
        let count = levels.count
        guard count > 0 else { return }
        let width = (size.width - Self.gap * CGFloat(count - 1)) / CGFloat(count)
        let barHeight = size.height - Self.labelHeight

        for i in 0..<count {
            let x = CGFloat(i) * (width + Self.gap)
            let color = VisualizerFeed.voiceColors[i % 3]

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

            let voice = i < voices.count ? voices[i] : nil
            // A released note still sounds: keep its name, dimmed.
            let sounding = voice.map { $0.gate || $0.envLevel > 0 } ?? false
            let center = x + width / 2
            let note = Text((sounding ? voice?.note : nil) ?? "·")
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .foregroundStyle(voice?.gate == true ? color : .gray)
            gc.draw(note, at: CGPoint(x: center, y: barHeight + 11))
            let waveform = voice?.waveformName ?? ""
            let wave = Text(waveform.isEmpty ? "—" : waveform)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.gray)
            gc.draw(wave, at: CGPoint(x: center, y: barHeight + 26))
        }
    }
}

#Preview {
    VisualizerView()
        .environment(PlayerStore.preview)
        .frame(width: 300, height: 180)
        .padding()
}
