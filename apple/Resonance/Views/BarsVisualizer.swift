import SwiftUI
import PhosphorCore

/// Per-voice level bars with peak hold, plus the note and waveform each
/// voice is playing, redrawn every display frame while music plays. Shows
/// every chip's voices.
///
/// Levels are the voices' envelopes from the visualizer feed's reSID, in
/// step with the audio. Made of Core Animation layers in an AppKit view,
/// not a `Canvas`: see `FrameLinkedNSView` for why.
struct BarsVisualizer: View {
    /// False pauses it, e.g. while another page or Now Playing covers it.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    var body: some View {
        BarsLayerView(
            feed: store.visualizer,
            theme: theme,
            chips: Int(store.nowPlaying?.numSids ?? 1),
            isAnimating: store.isPlaying && isActive,
            isStopped: store.state == .stopped
        )
        .accessibilityElement()
        .accessibilityLabel("Voice levels")
    }

    fileprivate static let gap: CGFloat = 6

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
        let gap = BarsVisualizer.gap
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

private struct BarsLayerView: NSViewRepresentable {
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let chips: Int
    let isAnimating: Bool
    let isStopped: Bool

    func makeNSView(context: Context) -> BarsNSView {
        let view = BarsNSView()
        view.apply(feed: feed, theme: theme, chips: chips, isAnimating: isAnimating, isStopped: isStopped)
        return view
    }

    func updateNSView(_ view: BarsNSView, context: Context) {
        view.apply(feed: feed, theme: theme, chips: chips, isAnimating: isAnimating, isStopped: isStopped)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarsNSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 300, height: 180))
    }
}

/// The bars in layers, one column per voice: a faint slot, the level as a
/// gradient, the peak as a line, and the labels underneath. The layers'
/// origin is the bottom left; the bars are worked out from the top left,
/// as `drawBars` draws them, and turned over.
private final class BarsNSView: FrameLinkedNSView {
    private final class Column {
        let slot = CALayer()
        let level = CAGradientLayer()
        let peak = CALayer()
        let labels: VoiceLabelLayers

        init(in parent: CALayer) {
            // First: a class sets every stored property before it uses one.
            labels = VoiceLabelLayers(in: parent)
            for part in [slot, level, peak] as [CALayer] {
                part.actions = VoiceLabelLayers.noActions
                parent.addSublayer(part)
            }
            // Bottom to top: the layers' unit square starts at the bottom left.
            level.startPoint = CGPoint(x: 0.5, y: 0)
            level.endPoint = CGPoint(x: 0.5, y: 1)
            level.masksToBounds = true
            peak.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8)
        }

        func remove() {
            for part in [slot, level, peak] as [CALayer] { part.removeFromSuperlayer() }
            labels.removeFromSuperlayer()
        }
    }

    private var feed: VisualizerFeed?
    private var theme = VoiceTheme.resonance
    private var chips = 1
    private var isStopped = false
    private var scale: CGFloat = 2
    private let meter = VoiceMeter()
    private var voices: [VizVoice] = []
    private var columns: [Column] = []

    init() {
        super.init(framesPerSecond: VisualizerFeed.framesPerSecond)
    }

    func apply(feed: VisualizerFeed, theme: VoiceTheme, chips: Int, isAnimating: Bool, isStopped: Bool) {
        self.feed = feed
        let recolor = theme != self.theme
        self.theme = theme
        self.chips = max(chips, 1)
        let stopping = isStopped && !self.isStopped
        self.isStopped = isStopped
        self.isAnimating = isAnimating
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if recolor { paint(columns) }
        if stopping { meter.reset() }
        // Still: hold what shows, unless there's nothing yet or it stopped.
        if stopping || meter.levels.isEmpty || meter.levels.count != slots { advance() }
        render()
        CATransaction.commit()
    }

    override func scaleChanged(to scale: CGFloat) {
        self.scale = scale
        for column in columns {
            column.labels.setScale(scale)
            column.level.contentsScale = scale
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        render()
        CATransaction.commit()
    }

    override func frame(_ link: CADisplayLink) {
        advance()
        render()
    }

    /// How many bars an empty feed shows: three per chip.
    private var slots: Int { voices.isEmpty ? 3 * chips : voices.count }

    /// Reads what's being heard now into the meter.
    private func advance() {
        voices = feed?.latest()?.chips.flatMap(\.voices) ?? []
        // Empty slots until the first frame sounds.
        let levels: [Float] = voices.isEmpty ? Array(repeating: 0, count: 3 * chips) : voices.map(\.envLevel)
        meter.update(levels: levels, at: .now)
    }

    private func paint(_ columns: [Column]) {
        for (i, column) in columns.enumerated() {
            let rgb = theme.voices[i % 3]
            func tint(_ alpha: Double) -> CGColor {
                CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
            }
            column.slot.backgroundColor = tint(0.12)
            column.level.colors = [tint(0.6), tint(1)]
        }
    }

    private func render() {
        let levels = meter.levels
        let peaks = meter.peaks
        let count = levels.count
        let size = bounds.size
        guard count > 0, size.width > 0, size.height > 0 else { return }
        if columns.count != count, let layer {
            for column in columns { column.remove() }
            columns = (0..<count).map { _ in Column(in: layer) }
            for column in columns {
                column.labels.setScale(scale)
                column.level.contentsScale = scale
            }
            paint(columns)
        }

        let gap = BarsVisualizer.gap
        let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let barHeight = size.height - VoiceLabels.height
        func turned(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        }
        for (i, column) in columns.enumerated() {
            let x = CGFloat(i) * (width + gap)
            let slot = CGRect(x: x, y: 0, width: width, height: barHeight)
            VoiceLabelLayers.setFrame(column.slot, turned(slot))
            let slotRadius = min(4, width / 2, barHeight / 2)
            if column.slot.cornerRadius != slotRadius { column.slot.cornerRadius = slotRadius }

            let h = max(barHeight * levels[i], 2)
            VoiceLabelLayers.setFrame(column.level, turned(CGRect(x: x, y: barHeight - h, width: width, height: h)))
            let levelRadius = min(4, width / 2, h / 2)
            if column.level.cornerRadius != levelRadius { column.level.cornerRadius = levelRadius }

            let peakY = barHeight - barHeight * peaks[i]
            VoiceLabelLayers.setFrame(column.peak, turned(CGRect(x: x, y: max(peakY - 2, 0), width: width, height: 2)))

            column.labels.place(centeredAt: x + width / 2, top: barHeight, width: width + gap, in: size.height)
            let rgb = theme.voices[i % 3]
            column.labels.show(i < voices.count ? voices[i] : nil,
                               color: CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1))
        }
    }
}

#Preview {
    BarsVisualizer()
        .environment(PlayerStore.preview)
        .frame(width: 300, height: 180)
        .padding()
}
