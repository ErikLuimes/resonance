import SwiftUI
import PhosphorCore

/// The Radial spectrum: a ring of bars per voice, each bar one band of that
/// voice's spectrum (`VoiceSpectrum`), mirrored left and right so the low
/// bands meet at the top and the highs at the bottom. The rings turn
/// slowly, neighbors opposite ways.
///
/// Shows the first chip, like the Halo.
///
/// Made of Core Animation layers moved by a display link, not a `Canvas` in
/// a `TimelineView`: see `FrameLinkedNSView` for why.
struct RadialView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    var body: some View {
        RadialLayerView(feed: store.visualizer, theme: theme, isAnimating: isActive)
            .accessibilityElement()
            .accessibilityLabel("Radial spectrum visualizer")
    }

    /// Ring radii and bar length, in units of half the view's shorter side
    /// (the mockup's 112, 164 and 216 px, and 40 px, at 640 px high).
    static let radii: [CGFloat] = [0.35, 0.51, 0.67]
    static let barLength: CGFloat = 0.125
}

private struct RadialLayerView: NSViewRepresentable {
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let isAnimating: Bool

    func makeNSView(context: Context) -> RadialNSView {
        let view = RadialNSView()
        view.apply(feed: feed, theme: theme, isAnimating: isAnimating)
        return view
    }

    func updateNSView(_ view: RadialNSView, context: Context) {
        view.apply(feed: feed, theme: theme, isAnimating: isAnimating)
    }
}

/// Per voice: a faint base ring, and a glowing group of four bar layers,
/// one per brightness step, whose paths change every frame. The group's
/// shadow is the glow.
final class RadialNSView: FrameLinkedNSView {
    private static let steps = 4
    private static let noActions: [String: any CAAction] = [
        "path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "shadowColor": NSNull(),
        "bounds": NSNull(), "position": NSNull(),
    ]

    private var feed: VisualizerFeed?
    private var theme: VoiceTheme?
    private let spectrum = VoiceSpectrum()
    private let rings = (0..<3).map { _ in CAShapeLayer() }
    private let glows = (0..<3).map { _ in CALayer() }
    private let bars = (0..<3).map { _ in (0..<RadialNSView.steps).map { _ in CAShapeLayer() } }

    init() {
        super.init(framesPerSecond: VisualizerFeed.framesPerSecond)
        for v in 0..<3 {
            let ring = rings[v]
            ring.fillColor = nil
            ring.lineWidth = 1
            ring.actions = Self.noActions
            layer?.addSublayer(ring)

            let glow = glows[v]
            glow.shadowOpacity = 1
            glow.shadowRadius = 6
            glow.shadowOffset = .zero
            glow.actions = Self.noActions
            layer?.addSublayer(glow)
            for bar in bars[v] {
                bar.fillColor = nil
                bar.lineCap = .round
                bar.actions = Self.noActions
                glow.addSublayer(bar)
            }
        }
    }

    func apply(feed: VisualizerFeed, theme: VoiceTheme, isAnimating: Bool) {
        self.feed = feed
        if theme != self.theme {
            self.theme = theme
            for v in 0..<3 {
                rings[v].strokeColor = color(v, 0.12)
                glows[v].shadowColor = color(v, 0.7)
                for (step, bar) in bars[v].enumerated() {
                    bar.strokeColor = color(v, 0.35 + (Double(step) + 0.5) / Double(Self.steps) * 0.65)
                }
            }
        }
        self.isAnimating = isAnimating
        update(at: .now)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let unit = min(bounds.width, bounds.height) / 2
        for v in 0..<3 {
            rings[v].frame = bounds
            glows[v].frame = bounds
            for bar in bars[v] { bar.frame = bounds }
            let r0 = RadialView.radii[v] * unit
            rings[v].path = CGPath(ellipseIn: CGRect(x: center.x - r0, y: center.y - r0, width: 2 * r0, height: 2 * r0),
                                   transform: nil)
        }
        draw(at: .now)
        CATransaction.commit()
    }

    override func frame(_ link: CADisplayLink) {
        update(at: .now)
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
        let scope = feed.scope(chip: 0, count: VoiceSpectrum.size)
        spectrum.update(voices: scope.voices, sampleRate: scope.sampleRate, at: date)
        draw(at: date)
    }

    /// The bars for the spectrum's levels, the rings turned to `date`.
    private func draw(at date: Date) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let levels = spectrum.levels
        let n = VoiceSpectrum.bands
        guard levels.count >= 3 * n else { return }
        // The layers' origin is the bottom left; the drawing is worked
        // out from the top left, so y runs the other way.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let unit = min(bounds.width, bounds.height) / 2
        let time = date.timeIntervalSinceReferenceDate
        for v in 0..<3 {
            let r0 = RadialView.radii[v] * unit
            let rotation = time.truncatingRemainder(dividingBy: 2 * .pi / 0.05) * 0.05 * (v % 2 == 0 ? 1 : -1)
            let width: CGFloat = (v == 2 ? 3 : 3.5) * max(1, unit / 320)
            let paths = (0..<Self.steps).map { _ in CGMutablePath() }
            for side in [-1.0, 1.0] {
                for j in 0..<n {
                    let level = CGFloat(levels[v * n + j])
                    let theta = -Double.pi / 2 + rotation + side * (Double(j) + 0.5) / Double(n) * .pi
                    let dx = CGFloat(cos(theta)), dy = -CGFloat(sin(theta))
                    let inner = r0 + 3
                    let outer = inner + (2 / 320 + level * RadialView.barLength) * unit
                    let step = min(Self.steps - 1, max(0, Int(level * 4)))
                    paths[step].move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
                    paths[step].addLine(to: CGPoint(x: center.x + dx * outer, y: center.y + dy * outer))
                }
            }
            for (step, bar) in bars[v].enumerated() {
                bar.path = paths[step]
                if bar.lineWidth != width { bar.lineWidth = width }
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
