import SwiftUI
import PhosphorCore

/// Spectrum: an analyzer like a mixing desk's. Each voice's spectrum is a
/// filled curve in its color over a log frequency scale from 30 Hz to
/// 16 kHz, on a −60…0 dB grid, with a thin line above it holding its
/// recent peaks and a white line for the three together. Each sounding
/// voice's note is marked where its fundamental is: that comes from the
/// chip's frequency register, not from the spectrum, so it's exact.
///
/// `FineSpectrum` works it out. Shows the first chip, like the Halo.
struct SpectrumView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme
    @State private var spectrum = FineSpectrum(bands: SpectrumView.bands)

    static let bands = 160

    var body: some View {
        TimelineView(.animation(minimumInterval: VisualizerFeed.frameInterval, paused: !isActive)) { context in
            let scope = store.visualizer.scope(chip: 0, count: FineSpectrum.samples)
            let _ = spectrum.update(voices: scope.voices, sampleRate: scope.sampleRate, at: context.date)
            let plot = Plot(levels: spectrum.levels, peaks: spectrum.peaks, mix: spectrum.mix(),
                            notes: Self.notes(store.visualizer.latest()?.chips.first?.voices ?? []),
                            colors: (0..<3).map(theme.voice))
            Canvas { gc, size in
                plot.draw(in: &gc, size: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Spectrum visualizer")
    }

    /// Each voice's note and frequency while it sounds.
    private static func notes(_ voices: [VizVoice]) -> [Plot.Note?] {
        (0..<3).map { i in
            guard i < voices.count else { return nil }
            let voice = voices[i]
            // Noise has no pitch to mark.
            guard voice.gate || voice.envLevel > 0.05, voice.waveform & 0x7 != 0, voice.hz > 0 else { return nil }
            guard let name = voice.note else { return nil }
            return Plot.Note(name: name, hz: Float(voice.hz))
        }
    }

    /// One frame of the analyzer, as values, so the canvas redraws with them.
    struct Plot {
        struct Note {
            var name: String
            var hz: Float
        }

        var levels: [Float]
        var peaks: [Float]
        var mix: [Float]
        var notes: [Note?]
        var colors: [Color]

        /// The frequencies with a labeled line, and the fainter ones between.
        static let labeled: [(Float, String)] = [
            (50, "50"), (100, "100"), (200, "200"), (500, "500"), (1000, "1k"), (2000, "2k"), (5000, "5k"), (10_000, "10k"),
        ]
        static let unlabeled: [Float] = [30, 40, 60, 70, 80, 90, 300, 400, 600, 700, 800, 900,
                                          3000, 4000, 6000, 7000, 8000, 9000]
        static let decibels: [Float] = [-12, -24, -36, -48]

        func draw(in gc: inout GraphicsContext, size: CGSize) {
            let bands = mix.count
            guard bands > 1, levels.count >= 3 * bands, peaks.count >= 3 * bands else { return }
            // Above Now Playing's title and transport, which sit over the
            // lower part of the view; what's below the baseline is only a
            // reflection.
            let unit = max(1, min(size.width / 1100, size.height / 700))
            let left = 44.0, right = size.width - 44
            let top = max(96, size.height * 0.15)
            let base = max(top + 80, size.height * 0.6)
            let rise = base - top
            func x(_ position: Float) -> CGFloat { left + CGFloat(position) * (right - left) }
            func y(_ level: Float) -> CGFloat { base - CGFloat(level) * rise }
            func band(_ b: Int) -> CGFloat { x((Float(b) + 0.5) / Float(bands)) }

            drawGrid(in: &gc, x: x, y: y, top: top, base: base, left: left, right: right, unit: unit)

            /// A smooth line through `values`, one per band.
            func curve(_ values: ArraySlice<Float>, flip: CGFloat? = nil) -> Path {
                let points = values.enumerated().map { i, level -> CGPoint in
                    let py = y(level)
                    return CGPoint(x: band(i), y: flip.map { base + (base - py) * $0 } ?? py)
                }
                var path = Path()
                path.move(to: CGPoint(x: left, y: points[0].y))
                path.addLine(to: points[0])
                for i in 1..<points.count {
                    let middle = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
                    path.addQuadCurve(to: middle, control: points[i - 1])
                }
                path.addLine(to: points[points.count - 1])
                path.addLine(to: CGPoint(x: right, y: points[points.count - 1].y))
                return path
            }
            func closed(_ line: Path) -> Path {
                var area = line
                area.addLine(to: CGPoint(x: right, y: base))
                area.addLine(to: CGPoint(x: left, y: base))
                area.closeSubpath()
                return area
            }

            // Lines stop at the baseline: where a band is silent they'd all
            // run along it and add up to a bright bar.
            let above = Path(CGRect(x: 0, y: 0, width: size.width, height: base - 3))
            gc.drawLayer { layer in
                layer.clip(to: above)
                layer.stroke(curve(mix[...]), with: .color(.white.opacity(0.4)), lineWidth: 1)
            }
            gc.drawLayer { layer in
                layer.blendMode = .plusLighter
                for v in 0..<3 {
                    let color = colors[v]
                    let values = levels[v * bands..<(v + 1) * bands]
                    let line = curve(values)
                    // A faint reflection under the baseline.
                    layer.fill(closed(curve(values, flip: 0.3)),
                               with: .linearGradient(Gradient(colors: [color.opacity(0.16), color.opacity(0)]),
                                                     startPoint: CGPoint(x: 0, y: base), endPoint: CGPoint(x: 0, y: base + rise * 0.3)))
                    layer.fill(closed(line),
                               with: .linearGradient(Gradient(colors: [color.opacity(0.5), color.opacity(0.06)]),
                                                     startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: base)))
                    layer.drawLayer { glow in
                        glow.clip(to: above)
                        glow.addFilter(.shadow(color: color.opacity(0.8), radius: 5 * unit))
                        glow.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5 * unit, lineJoin: .round))
                    }
                    layer.drawLayer { held in
                        held.clip(to: above)
                        held.stroke(curve(peaks[v * bands..<(v + 1) * bands]), with: .color(color.opacity(0.45)), lineWidth: 1)
                    }
                }
            }
            gc.stroke(Path { $0.move(to: CGPoint(x: left, y: base)); $0.addLine(to: CGPoint(x: right, y: base)) },
                      with: .color(.white.opacity(0.28)), lineWidth: 1)

            // Each sounding voice's note, at its fundamental.
            for (v, note) in notes.enumerated().prefix(3) {
                guard let note else { continue }
                let position = FineSpectrum.position(of: note.hz)
                guard position > 0, position < 1 else { continue }
                let b = min(bands - 1, max(0, Int(position * Float(bands))))
                let at = CGPoint(x: x(position), y: y(levels[v * bands + b]))
                let color = colors[v]
                gc.stroke(Path { $0.move(to: at); $0.addLine(to: CGPoint(x: at.x, y: base)) },
                          with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                gc.fill(Path(ellipseIn: CGRect(x: at.x - 3 * unit, y: at.y - 3 * unit, width: 6 * unit, height: 6 * unit)),
                        with: .color(.white))
                gc.draw(Text(verbatim: note.name).font(.system(size: 13 * unit, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color), at: CGPoint(x: at.x, y: at.y - 8 * unit), anchor: .bottom)
            }
        }

        private func drawGrid(in gc: inout GraphicsContext, x: (Float) -> CGFloat, y: (Float) -> CGFloat,
                              top: CGFloat, base: CGFloat, left: CGFloat, right: CGFloat, unit: CGFloat) {
            let dim = Color.white.opacity(0.4)
            let font = Font.system(size: 10 * unit, design: .monospaced)
            var faint = Path(), plain = Path()
            for hz in Self.unlabeled {
                let at = x(FineSpectrum.position(of: hz))
                faint.move(to: CGPoint(x: at, y: top))
                faint.addLine(to: CGPoint(x: at, y: base))
            }
            for (hz, label) in Self.labeled {
                let at = x(FineSpectrum.position(of: hz))
                plain.move(to: CGPoint(x: at, y: top))
                plain.addLine(to: CGPoint(x: at, y: base))
                gc.draw(Text(verbatim: label).font(font).foregroundStyle(dim), at: CGPoint(x: at, y: top - 4), anchor: .bottom)
            }
            for db in Self.decibels {
                let at = y(1 - db / FineSpectrum.floorDB)
                plain.move(to: CGPoint(x: left, y: at))
                plain.addLine(to: CGPoint(x: right, y: at))
                gc.draw(Text(verbatim: "\(Int(db))").font(font).foregroundStyle(dim), at: CGPoint(x: left - 6, y: at), anchor: .trailing)
            }
            gc.draw(Text(verbatim: "dB").font(font).foregroundStyle(dim), at: CGPoint(x: left - 6, y: top), anchor: .trailing)
            gc.draw(Text(verbatim: "Hz").font(font).foregroundStyle(dim), at: CGPoint(x: right + 6, y: top - 4), anchor: .bottomLeading)
            gc.stroke(faint, with: .color(.white.opacity(0.045)), lineWidth: 1)
            gc.stroke(plain, with: .color(.white.opacity(0.1)), lineWidth: 1)
        }
    }
}

#Preview {
    SpectrumView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
