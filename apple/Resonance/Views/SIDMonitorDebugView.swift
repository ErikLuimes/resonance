import SwiftUI
import PhosphorCore

/// A live readout of the visualizer feed, for checking it against what you
/// hear: each voice's note, gate, waveform, pulse width, ADSR and envelope,
/// the filter, and a scope strip. Debug builds only.
///
/// Each voice flashes when a note starts (its gate opens), so on a tune with
/// drums the drum voice's flash should land on the beat.
///
/// Everything that changes per frame is drawn into one Canvas, so changing
/// text can't resize anything (see VisualizerView).
struct SIDMonitorDebugView: View {
    static let windowID = "sid-monitor-debug"

    @Environment(PlayerStore.self) private var store
    @State private var selectedChip = 0
    @State private var offsetMs = 0.0

    private var chips: Int { max(Int(store.nowPlaying?.numSids ?? 1), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if chips > 1 {
                    Picker("Chip", selection: $selectedChip) {
                        ForEach(0..<chips, id: \.self) { Text("SID \($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                Text("Fine-tune")
                Slider(value: $offsetMs, in: -100...100, step: 5)
                    .frame(width: 180)
                Text("\(Int(offsetMs), format: .number.sign(strategy: .always())) ms")
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
            }
            TimelineView(.animation(paused: !store.isPlaying)) { _ in
                let feed = store.visualizer
                let chip = min(selectedChip, chips - 1)
                let history = feed.history(Self.flashFrames)
                let scope = feed.scope(chip: chip, count: 1024)
                let stats = feed.stats
                Canvas { gc, size in
                    draw(history: history, chip: chip, scope: scope, stats: stats, in: gc, size: size)
                }
            }
            .background(Self.background, in: .rect(cornerRadius: 10))
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 380)
        .onAppear { offsetMs = Double(store.visualizer.stats.offsetMs) }
        .onChange(of: offsetMs) { _, ms in store.visualizer.setOffset(milliseconds: Int(ms)) }
    }

    private static let background = Color(red: 0x0E / 255, green: 0x0E / 255, blue: 0x10 / 255)
    private static let dim = Color(red: 0x8D / 255, green: 0x8E / 255, blue: 0x96 / 255)
    private static let empty = Color(red: 0x33 / 255, green: 0x33 / 255, blue: 0x3A / 255)
    private static let font = Font.system(size: 12, design: .monospaced)
    private static let margin: CGFloat = 14
    private static let rowHeight: CGFloat = 24
    /// A note-start flash fades out over this long.
    private static let flashMs = 150.0
    /// Enough frames to cover a flash at 50 or 60 Hz.
    private static let flashFrames = 10

    private func draw(history: [VizSidFrame], chip: Int, scope: VizScope, stats: VizStats,
                      in gc: GraphicsContext, size: CGSize) {
        let charWidth = gc.resolve(Text("0").font(Self.font)).measure(in: size).width
        let frame = history.last
        var y: CGFloat = 20

        let header = frame.map { "Frame \($0.index)  \($0.isPal ? "PAL" : "NTSC")" } ?? "No frame"
        label(header + "  ·  shadow reSID \(Int(stats.shadowMicros)) µs/frame",
              at: CGPoint(x: Self.margin, y: y), color: Self.dim, in: gc)
        y += Self.rowHeight - 4
        let buffer = Int(stats.bufferMs.rounded())
        let total = buffer + Int(stats.outputLatencyMs) + Int(stats.offsetMs)
        label("Sound trails the emulation by \(total) ms: buffer \(buffer) + output \(stats.outputLatencyMs)"
              + " + fine-tune \(stats.offsetMs)",
              at: CGPoint(x: Self.margin, y: y), color: Self.dim, in: gc)
        y += Self.rowHeight + 6

        let state = frame.flatMap { $0.chips.indices.contains(chip) ? $0.chips[chip] : nil }
        for v in 0..<3 {
            let voice = state.map { $0.voices[v] }
            let color = VisualizerFeed.voiceColors[v]

            // Note-start flash.
            let flash = Self.flash(voice: v, chip: chip, in: history)
            let lamp = CGRect(x: Self.margin, y: y - 8, width: 16, height: 16)
            gc.fill(Path(roundedRect: lamp, cornerRadius: 4), with: .color(Self.empty))
            gc.fill(Path(roundedRect: lamp, cornerRadius: 4), with: .color(color.opacity(flash)))

            let labelX = lamp.maxX + 8
            label("V\(v + 1)", at: CGPoint(x: labelX, y: y), color: color, in: gc)
            let row = voice.map(Self.row) ?? "—"
            let rowX = labelX + charWidth * 4
            label(row, at: CGPoint(x: rowX, y: y), color: voice?.gate == true ? .white : Self.dim, in: gc)

            // Envelope bar after the widest row.
            let barX = rowX + charWidth * CGFloat(Self.rowWidth) + 8
            let bar = CGRect(x: barX, y: y - 5, width: 100, height: 10)
            gc.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(Self.empty))
            let env = CGFloat(voice?.envLevel ?? 0)
            gc.fill(Path(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: bar.width * env, height: bar.height),
                         cornerRadius: 2),
                    with: .color(color))
            label(String(format: "%.2f", env), at: CGPoint(x: bar.maxX + 8, y: y), color: Self.dim, in: gc)
            y += Self.rowHeight
        }

        y += 4
        label(state.map(Self.filterRow) ?? "Filter —", at: CGPoint(x: Self.margin, y: y), color: Self.dim, in: gc)
        y += Self.rowHeight

        drawScope(scope, in: CGRect(x: Self.margin, y: y, width: size.width - 2 * Self.margin,
                                    height: size.height - y - Self.margin), gc: gc)
    }

    private func drawScope(_ scope: VizScope, in rect: CGRect, gc: GraphicsContext) {
        guard rect.height > 30 else { return }
        let laneHeight = rect.height / 3
        for (v, samples) in scope.voices.prefix(3).enumerated() {
            let lane = CGRect(x: rect.minX, y: rect.minY + CGFloat(v) * laneHeight, width: rect.width, height: laneHeight)
            gc.stroke(Path { p in
                p.move(to: CGPoint(x: lane.minX, y: lane.midY))
                p.addLine(to: CGPoint(x: lane.maxX, y: lane.midY))
            }, with: .color(Self.empty), lineWidth: 1)
            guard samples.count > 1 else { continue }
            let step = lane.width / CGFloat(samples.count - 1)
            let path = Path { p in
                for (n, s) in samples.enumerated() {
                    let point = CGPoint(x: lane.minX + CGFloat(n) * step,
                                        y: lane.midY - CGFloat(s) * (lane.height / 2 - 3))
                    if n == 0 { p.move(to: point) } else { p.addLine(to: point) }
                }
            }
            gc.stroke(path, with: .color(VisualizerFeed.voiceColors[v]), lineWidth: 1.2)
        }
    }

    /// 1 when `voice`'s gate opened in the frame being heard, fading to 0
    /// over `flashMs`.
    private static func flash(voice: Int, chip: Int, in history: [VizSidFrame]) -> Double {
        let gates = history.map { $0.chips.indices.contains(chip) && $0.chips[chip].voices[voice].gate }
        guard let last = history.last,
              let opened = gates.indices.dropFirst().last(where: { gates[$0] && !gates[$0 - 1] })
        else { return 0 }
        let frameMs = last.isPal ? 19.95 : 16.7
        let age = Double(last.index - history[opened].index) * frameMs
        return max(0, 1 - age / flashMs)
    }

    private func label(_ string: String, at point: CGPoint, color: Color, in gc: GraphicsContext) {
        gc.draw(Text(string).font(Self.font).foregroundStyle(color), at: point, anchor: .leading)
    }

    // MARK: Rows

    /// Characters in a voice row, so the envelope bars line up.
    private static let rowWidth = 4 + 12 + 6 + 9 + 11 + 8 + 12

    private static func row(_ v: VizVoice) -> String {
        let flags = [(v.ring, "RING"), (v.sync, "SYNC"), (v.test, "TEST")].filter(\.0).map(\.1)
        return [
            (v.note ?? "—", 4),
            (v.hz > 0 ? String(format: "%8.1f Hz", v.hz) : "", 12),
            (v.gate ? "GATE" : "", 6),
            (v.waveformName.isEmpty ? "—" : v.waveformName, 9),
            (flags.joined(separator: " "), 11),
            (String(format: "PW %4d", v.pulseWidth), 8),
            ("A\(v.attack) D\(v.decay) S\(v.sustain) R\(v.release)", 12),
        ]
        .map { $0.0.padding(toLength: $0.1, withPad: " ", startingAt: 0) }
        .joined()
    }

    private static func filterRow(_ c: VizChip) -> String {
        let routes = ["1", "2", "3", "E"].enumerated().map { c.filterRouting & (1 << $0.offset) != 0 ? $0.element : "·" }
        let modes = ["LP", "BP", "HP", "3OFF"].enumerated().map { c.filterMode & (1 << $0.offset) != 0 ? $0.element : "·" }
        return "Filter  cutoff \(c.cutoff)  res \(c.resonance)  route \(routes.joined(separator: " "))"
            + "  mode \(modes.joined(separator: " "))  vol \(c.volume)"
    }
}

#Preview {
    SIDMonitorDebugView()
        .environment(PlayerStore.preview)
        .frame(width: 720, height: 400)
}
