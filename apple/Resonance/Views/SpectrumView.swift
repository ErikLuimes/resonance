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
///
/// Made of Core Animation layers moved by a display link, not a `Canvas` in
/// a `TimelineView`: see `FrameLinkedNSView` for why. The grid and its
/// labels are laid out once per size; a frame only gives the curves new
/// paths and moves the note marks.
struct SpectrumView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    static let bands = 160

    var body: some View {
        SpectrumLayerView(feed: store.visualizer, theme: theme, isAnimating: isActive)
            .accessibilityElement()
            .accessibilityLabel("Spectrum visualizer")
    }

    /// Each voice's note and frequency while it sounds.
    fileprivate static func notes(_ voices: [VizVoice]) -> [Plot.Note?] {
        (0..<3).map { i in
            guard i < voices.count else { return nil }
            let voice = voices[i]
            // Noise has no pitch to mark.
            guard voice.gate || voice.envLevel > 0.05, voice.waveform & 0x7 != 0, voice.hz > 0 else { return nil }
            guard let name = voice.note else { return nil }
            return Plot.Note(name: name, hz: Float(voice.hz))
        }
    }

    /// One frame of the analyzer drawn into a canvas: a still of what the
    /// layers show, which the tests take a picture of.
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

private struct SpectrumLayerView: NSViewRepresentable {
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let isAnimating: Bool

    func makeNSView(context: Context) -> SpectrumNSView {
        let view = SpectrumNSView()
        view.apply(feed: feed, theme: theme, isAnimating: isAnimating)
        return view
    }

    func updateNSView(_ view: SpectrumNSView, context: Context) {
        view.apply(feed: feed, theme: theme, isAnimating: isAnimating)
    }
}

/// From the back: the grid and its labels, the white line of the mix, then
/// per voice its reflection, its filled curve, its glowing line and its
/// held peaks, then the baseline and the note marks. A voice's layers add
/// their light to what's behind them, as the canvas's `plusLighter` did.
///
/// A layer's origin is its bottom left, so heights here run up from the
/// bottom, where `SpectrumView.Plot` counts down from the top.
final class SpectrumNSView: FrameLinkedNSView {
    /// Where the plot is in a view of one size, as `Plot.draw` has it.
    private struct Metrics {
        var size: CGSize
        var unit: CGFloat
        var left: CGFloat
        var right: CGFloat
        /// The 0 dB line and the baseline, up from the bottom.
        var top: CGFloat
        var base: CGFloat
        var rise: CGFloat { top - base }

        init(_ size: CGSize) {
            self.size = size
            unit = max(1, min(size.width / 1100, size.height / 700))
            left = 44
            right = size.width - 44
            // Above Now Playing's title and transport, which sit over the
            // lower part of the view; what's below the baseline is only a
            // reflection.
            let fromTop = max(96, size.height * 0.15)
            top = size.height - fromTop
            base = size.height - max(fromTop + 80, size.height * 0.6)
        }

        func x(_ position: Float) -> CGFloat { left + CGFloat(position) * (right - left) }
        func y(_ level: Float) -> CGFloat { base + CGFloat(level) * rise }
    }

    /// One voice's layers.
    private final class Voice {
        let reflection = CAGradientLayer()
        let reflectionShape = CAShapeLayer()
        let fill = CAGradientLayer()
        let fillShape = CAShapeLayer()
        /// Holds the line and the peaks above the baseline.
        let clip = CALayer()
        /// Its shadow is the line's glow.
        let glow = CALayer()
        let line = CAShapeLayer()
        let peaks = CAShapeLayer()
        let stem = CAShapeLayer()
        let dot = CAShapeLayer()
        let note = CATextLayer()
    }

    /// Adds a layer's light to what's behind it.
    private static let additive = "plusL"
    private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let dim = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.4)

    private var feed: VisualizerFeed?
    private var theme: VoiceTheme?
    private let spectrum = FineSpectrum(bands: SpectrumView.bands)
    private var notes: [SpectrumView.Plot.Note?] = []
    private var metrics = Metrics(.zero)

    private let faintGrid = CAShapeLayer()
    private let plainGrid = CAShapeLayer()
    private let frequencyLabels = SpectrumView.Plot.labeled.map { _ in CATextLayer() }
    private let decibelLabels = SpectrumView.Plot.decibels.map { _ in CATextLayer() }
    private let decibelUnit = CATextLayer()
    private let frequencyUnit = CATextLayer()
    private let mixClip = CALayer()
    private let mixLine = CAShapeLayer()
    private let voices = (0..<3).map { _ in Voice() }
    private let baseline = CAShapeLayer()

    private var labels: [CATextLayer] { frequencyLabels + decibelLabels + [decibelUnit, frequencyUnit] }

    init() {
        super.init(framesPerSecond: VisualizerFeed.framesPerSecond)
        guard let layer else { return }

        for (grid, opacity) in [(faintGrid, 0.045), (plainGrid, 0.1)] {
            grid.fillColor = nil
            grid.lineWidth = 1
            grid.strokeColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: opacity)
            layer.addSublayer(grid)
        }
        for (label, text) in zip(frequencyLabels, SpectrumView.Plot.labeled.map(\.1)) { label.string = text }
        for (label, db) in zip(decibelLabels, SpectrumView.Plot.decibels) { label.string = "\(Int(db))" }
        decibelUnit.string = "dB"
        frequencyUnit.string = "Hz"
        for label in labels {
            label.foregroundColor = Self.dim
            layer.addSublayer(label)
        }

        mixClip.masksToBounds = true
        mixLine.fillColor = nil
        mixLine.lineWidth = 1
        mixLine.strokeColor = Self.dim
        mixClip.addSublayer(mixLine)
        layer.addSublayer(mixClip)

        for voice in voices {
            voice.reflectionShape.fillColor = Self.white
            voice.reflection.mask = voice.reflectionShape
            voice.reflection.compositingFilter = Self.additive
            layer.addSublayer(voice.reflection)

            voice.fillShape.fillColor = Self.white
            voice.fill.mask = voice.fillShape
            voice.fill.compositingFilter = Self.additive
            layer.addSublayer(voice.fill)

            voice.clip.masksToBounds = true
            voice.clip.compositingFilter = Self.additive
            voice.glow.shadowOpacity = 1
            voice.glow.shadowOffset = .zero
            voice.line.fillColor = nil
            voice.line.lineJoin = .round
            voice.glow.addSublayer(voice.line)
            voice.peaks.fillColor = nil
            voice.peaks.lineWidth = 1
            voice.clip.addSublayer(voice.glow)
            voice.clip.addSublayer(voice.peaks)
            layer.addSublayer(voice.clip)
        }

        baseline.fillColor = nil
        baseline.lineWidth = 1
        baseline.strokeColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28)
        layer.addSublayer(baseline)

        // The note marks are over everything, and not added to it.
        for voice in voices {
            voice.stem.fillColor = nil
            voice.stem.lineWidth = 1
            voice.stem.lineDashPattern = [2, 3]
            voice.dot.fillColor = Self.white
            voice.note.alignmentMode = .center
            for mark in [voice.stem, voice.dot, voice.note] {
                mark.isHidden = true
                layer.addSublayer(mark)
            }
        }
    }

    func apply(feed: VisualizerFeed, theme: VoiceTheme, isAnimating: Bool) {
        self.feed = feed
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if theme != self.theme {
            self.theme = theme
            for (v, voice) in voices.enumerated() {
                voice.reflection.colors = [color(v, 0.16), color(v, 0)]
                voice.fill.colors = [color(v, 0.5), color(v, 0.06)]
                voice.glow.shadowColor = color(v, 0.8)
                voice.line.strokeColor = color(v, 1)
                voice.peaks.strokeColor = color(v, 0.45)
                voice.stem.strokeColor = color(v, 0.5)
                voice.note.foregroundColor = color(v, 1)
            }
        }
        self.isAnimating = isAnimating
        update(at: .now)
        CATransaction.commit()
    }

    override func scaleChanged(to scale: CGFloat) {
        for label in labels { label.contentsScale = scale }
        for voice in voices { voice.note.contentsScale = scale }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let m = Metrics(bounds.size)
        metrics = m
        let height = bounds.height

        // The grid: drawn here, as it only changes with the size.
        let faint = CGMutablePath(), plain = CGMutablePath()
        for hz in SpectrumView.Plot.unlabeled {
            let at = m.x(FineSpectrum.position(of: hz))
            faint.move(to: CGPoint(x: at, y: m.top))
            faint.addLine(to: CGPoint(x: at, y: m.base))
        }
        let font = NSFont.monospacedSystemFont(ofSize: 10 * m.unit, weight: .regular)
        for label in labels {
            label.font = font
            label.fontSize = font.pointSize
        }
        for ((hz, _), label) in zip(SpectrumView.Plot.labeled, frequencyLabels) {
            let at = m.x(FineSpectrum.position(of: hz))
            plain.move(to: CGPoint(x: at, y: m.top))
            plain.addLine(to: CGPoint(x: at, y: m.base))
            let size = Self.size(of: label, in: font)
            label.frame = CGRect(x: (at - size.width / 2).rounded(), y: (m.top + 4).rounded(), width: size.width, height: size.height)
        }
        for (db, label) in zip(SpectrumView.Plot.decibels, decibelLabels) {
            let at = m.y(1 - db / FineSpectrum.floorDB)
            plain.move(to: CGPoint(x: m.left, y: at))
            plain.addLine(to: CGPoint(x: m.right, y: at))
            let size = Self.size(of: label, in: font)
            label.frame = CGRect(x: (m.left - 6 - size.width).rounded(), y: (at - size.height / 2).rounded(), width: size.width, height: size.height)
        }
        let decibelSize = Self.size(of: decibelUnit, in: font)
        decibelUnit.frame = CGRect(x: (m.left - 6 - decibelSize.width).rounded(), y: (m.top - decibelSize.height / 2).rounded(),
                                   width: decibelSize.width, height: decibelSize.height)
        let frequencySize = Self.size(of: frequencyUnit, in: font)
        frequencyUnit.frame = CGRect(x: (m.right + 6).rounded(), y: (m.top + 4).rounded(),
                                     width: frequencySize.width, height: frequencySize.height)
        faintGrid.frame = bounds
        faintGrid.path = faint
        plainGrid.frame = bounds
        plainGrid.path = plain

        let line = CGMutablePath()
        line.move(to: CGPoint(x: m.left, y: m.base))
        line.addLine(to: CGPoint(x: m.right, y: m.base))
        baseline.frame = bounds
        baseline.path = line

        // Lines stop short of the baseline: where a band is silent they'd
        // all run along it and add up to a bright bar. What's inside a
        // clipping layer is placed so that its points are the view's.
        let above = CGRect(x: 0, y: m.base + 3, width: bounds.width, height: max(0, height - m.base - 3))
        let inside = CGRect(x: 0, y: -above.minY, width: bounds.width, height: height)
        mixClip.frame = above
        mixLine.frame = inside
        let noteFont = NSFont.monospacedSystemFont(ofSize: 13 * m.unit, weight: .semibold)
        for voice in voices {
            for layer in [voice.reflection, voice.reflectionShape, voice.fill, voice.fillShape, voice.stem, voice.dot] {
                layer.frame = bounds
            }
            // A gradient's points are fractions of its layer, up from the bottom.
            if height > 0 {
                voice.reflection.startPoint = CGPoint(x: 0.5, y: m.base / height)
                voice.reflection.endPoint = CGPoint(x: 0.5, y: (m.base - m.rise * 0.3) / height)
                voice.fill.startPoint = CGPoint(x: 0.5, y: m.top / height)
                voice.fill.endPoint = CGPoint(x: 0.5, y: m.base / height)
            }
            voice.clip.frame = above
            for layer in [voice.glow, voice.line, voice.peaks] { layer.frame = inside }
            // `line` is inside `glow`, which is already placed.
            voice.line.frame = CGRect(origin: .zero, size: inside.size)
            voice.glow.shadowRadius = 5 * m.unit
            voice.line.lineWidth = 1.5 * m.unit
            voice.note.font = noteFont
            voice.note.fontSize = noteFont.pointSize
        }
        draw()
        CATransaction.commit()
    }

    override func frame(_ link: CADisplayLink) {
        update(at: .now)
    }

    private static func size(of label: CATextLayer, in font: NSFont) -> CGSize {
        let size = ((label.string as? String ?? "") as NSString).size(withAttributes: [.font: font])
        return CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    private func color(_ v: Int, _ alpha: Double) -> CGColor {
        let rgb = (theme ?? .resonance).voices[v % 3]
        return CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    /// A clip's frame (`LayerClipPainter`): reads the feed as it is at
    /// `date` and draws, without a display link.
    func clipFrame(at date: Date) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update(at: date)
        CATransaction.commit()
    }

    /// Reads the feed, then draws.
    private func update(at date: Date) {
        guard let feed else { return }
        let scope = feed.scope(chip: 0, count: FineSpectrum.samples)
        spectrum.update(voices: scope.voices, sampleRate: scope.sampleRate, at: date)
        notes = SpectrumView.notes(feed.latest()?.chips.first?.voices ?? [])
        draw()
    }

    /// The curves for the spectrum's levels, and the notes at their fundamentals.
    private func draw() {
        let m = metrics
        let levels = spectrum.levels, peaks = spectrum.peaks, mix = spectrum.mix()
        let bands = mix.count
        guard m.size.width > 0, m.size.height > 0, bands > 1,
              levels.count >= 3 * bands, peaks.count >= 3 * bands else { return }

        /// A smooth line through `values`, one per band; `scale` below zero
        /// hangs it under the baseline, as a reflection.
        func curve(_ values: ArraySlice<Float>, scale: CGFloat = 1) -> CGMutablePath {
            let points = values.enumerated().map { i, level in
                CGPoint(x: m.x((Float(i) + 0.5) / Float(bands)), y: m.base + CGFloat(level) * m.rise * scale)
            }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: m.left, y: points[0].y))
            path.addLine(to: points[0])
            for i in 1..<points.count {
                let middle = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
                path.addQuadCurve(to: middle, control: points[i - 1])
            }
            path.addLine(to: points[points.count - 1])
            path.addLine(to: CGPoint(x: m.right, y: points[points.count - 1].y))
            return path
        }
        func closed(_ line: CGPath) -> CGPath {
            let area = CGMutablePath()
            area.addPath(line)
            area.addLine(to: CGPoint(x: m.right, y: m.base))
            area.addLine(to: CGPoint(x: m.left, y: m.base))
            area.closeSubpath()
            return area
        }

        mixLine.path = curve(mix[...])
        for (v, voice) in voices.enumerated() {
            let values = levels[v * bands..<(v + 1) * bands]
            let line = curve(values)
            voice.reflectionShape.path = closed(curve(values, scale: -0.3))
            voice.fillShape.path = closed(line)
            voice.line.path = line
            voice.peaks.path = curve(peaks[v * bands..<(v + 1) * bands])
            mark(voice, at: v < notes.count ? notes[v] : nil, level: { levels[v * bands + $0] }, bands: bands)
        }
    }

    /// A voice's note where its fundamental is: a dashed stem down to the
    /// baseline, a dot on its curve and its name above. Hidden with no note.
    private func mark(_ voice: Voice, at note: SpectrumView.Plot.Note?, level: (Int) -> Float, bands: Int) {
        let m = metrics
        let position = note.map { FineSpectrum.position(of: $0.hz) } ?? 0
        let isShown = note != nil && position > 0 && position < 1
        for layer in [voice.stem, voice.dot, voice.note] where layer.isHidden == isShown {
            layer.isHidden = !isShown
        }
        guard let note, isShown else { return }
        let b = min(bands - 1, max(0, Int(position * Float(bands))))
        let at = CGPoint(x: m.x(position), y: m.y(level(b)))
        let stem = CGMutablePath()
        stem.move(to: at)
        stem.addLine(to: CGPoint(x: at.x, y: m.base))
        voice.stem.path = stem
        voice.dot.path = CGPath(ellipseIn: CGRect(x: at.x - 3 * m.unit, y: at.y - 3 * m.unit, width: 6 * m.unit, height: 6 * m.unit),
                                transform: nil)
        // A text layer redraws when its string is set, even to the same thing.
        if voice.note.string as? String != note.name { voice.note.string = note.name }
        let font = voice.note.font as? NSFont ?? .monospacedSystemFont(ofSize: 13 * m.unit, weight: .semibold)
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        let width = 80 * m.unit
        voice.note.frame = CGRect(x: at.x - width / 2, y: at.y + 8 * m.unit, width: width, height: lineHeight)
    }
}

#Preview {
    SpectrumView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
