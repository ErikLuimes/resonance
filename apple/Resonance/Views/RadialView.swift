import SwiftUI
import PhosphorCore

/// The Radial spectrum: a ring of bars per voice, each bar one band of that
/// voice's spectrum (`VoiceSpectrum`), mirrored left and right so the low
/// bands meet at the top and the highs at the bottom
/// (design/visualizers/reference/RadialBars.dc.html). The rings turn
/// slowly, neighbours opposite ways.
///
/// Shows the first chip, like the Halo.
struct RadialView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @State private var spectrum = VoiceSpectrum()

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { context in
            let scope = store.visualizer.scope(chip: 0, count: VoiceSpectrum.size)
            let _ = spectrum.update(voices: scope.voices, sampleRate: scope.sampleRate, at: context.date)
            let levels = spectrum.levels
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                Self.draw(levels: levels, time: time, in: &gc, size: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Radial spectrum visualizer")
    }

    /// Ring radii and bar length, in units of half the view's shorter side
    /// (the mockup's 112, 164 and 216 px, and 40 px, at 640 px high).
    private static let radii: [CGFloat] = [0.35, 0.51, 0.67]
    private static let barLength: CGFloat = 0.125

    private static func draw(levels: [Float], time: Double, in gc: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let unit = min(size.width, size.height) / 2
        let n = VoiceSpectrum.bands
        gc.blendMode = .plusLighter

        for v in 0..<3 {
            let color = VisualizerFeed.voiceColors[v]
            let r0 = radii[v] * unit
            // Faint base ring.
            gc.stroke(Path(ellipseIn: CGRect(x: center.x - r0, y: center.y - r0, width: 2 * r0, height: 2 * r0)),
                      with: .color(color.opacity(0.12)), lineWidth: 1)

            let rotation = time.truncatingRemainder(dividingBy: 2 * .pi / 0.05) * 0.05 * (v % 2 == 0 ? 1 : -1)
            let width: CGFloat = (v == 2 ? 3 : 3.5) * max(1, unit / 320)
            // Bars in four brightness steps, so each step is one path.
            var paths = [Path](repeating: Path(), count: 4)
            for side in [-1.0, 1.0] {
                for j in 0..<n {
                    let level = CGFloat(levels[v * n + j])
                    let theta = -Double.pi / 2 + rotation + side * (Double(j) + 0.5) / Double(n) * .pi
                    let direction = CGPoint(x: cos(theta), y: sin(theta))
                    let inner = r0 + 3
                    let outer = inner + (2 / 320 + level * barLength) * unit
                    let step = min(3, Int(level * 4))
                    paths[step].move(to: CGPoint(x: center.x + direction.x * inner, y: center.y + direction.y * inner))
                    paths[step].addLine(to: CGPoint(x: center.x + direction.x * outer, y: center.y + direction.y * outer))
                }
            }
            gc.drawLayer { layer in
                layer.addFilter(.shadow(color: color.opacity(0.7), radius: 6))
                for (step, path) in paths.enumerated() {
                    let opacity = 0.35 + (Double(step) + 0.5) / 4 * 0.65
                    layer.stroke(path, with: .color(color.opacity(opacity)),
                                 style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
            }
        }
    }
}

#Preview {
    RadialView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
