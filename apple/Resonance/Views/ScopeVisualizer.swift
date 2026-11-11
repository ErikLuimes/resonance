import SwiftUI
import PhosphorCore

/// An oscilloscope per voice, with the note and waveform each voice is
/// playing, redrawn every display frame while music plays.
///
/// Each trace is the voice's output (waveform × envelope) from the
/// visualizer feed, in step with the audio, so a note grows and fades with
/// its envelope. Multi-SID tunes show their first chip. Made of Core
/// Animation layers in an AppKit view, not a `Canvas`: see
/// `FrameLinkedNSView` for why.
struct ScopeVisualizer: View {
    /// False pauses it, e.g. while another page or Now Playing covers it.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    var body: some View {
        ScopeLayerView(feed: store.visualizer, theme: theme, isAnimating: store.isPlaying && isActive)
            .accessibilityElement()
            .accessibilityLabel("Voice oscilloscopes")
    }

    /// The samples across `rect`, −1 at the bottom and 1 at the top, at
    /// most two points per pixel. The menu bar player draws with it too.
    static func trace(_ samples: ArraySlice<Float>, in rect: CGRect) -> Path {
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

private struct ScopeLayerView: NSViewRepresentable {
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let isAnimating: Bool

    func makeNSView(context: Context) -> ScopeNSView {
        let view = ScopeNSView()
        view.apply(feed: feed, theme: theme, isAnimating: isAnimating)
        return view
    }

    func updateNSView(_ view: ScopeNSView, context: Context) {
        view.apply(feed: feed, theme: theme, isAnimating: isAnimating)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScopeNSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 300, height: 180))
    }
}

/// The scope in layers: the three lanes, drawn when the size or theme
/// changes; a glow and a line per voice, whose paths change every frame;
/// and two labels per voice, whose text changes with the notes.
private final class ScopeNSView: FrameLinkedNSView {
    private static let gap: CGFloat = 6
    private static let gray = CGColor(srgbRed: 0.557, green: 0.557, blue: 0.576, alpha: 1)
    private static let noteFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
    private static let waveformFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    /// A new note replaces the old one at once: a text layer would fade
    /// between them otherwise, and the old one would show through.
    private static let noActions: [String: any CAAction] = [
        "contents": NSNull(), "string": NSNull(), "foregroundColor": NSNull(), "path": NSNull(), "strokeColor": NSNull(),
    ]

    private var feed: VisualizerFeed?
    private var theme = VoiceTheme.resonance

    private let lanes = CALayer()
    private let lanePainter = LanePainter()
    private let glows = (0..<3).map { _ in CAShapeLayer() }
    private let lines = (0..<3).map { _ in CAShapeLayer() }
    private let notes = (0..<3).map { _ in CATextLayer() }
    private let waveforms = (0..<3).map { _ in CATextLayer() }

    init() {
        super.init(framesPerSecond: VisualizerFeed.framesPerSecond)
        lanes.delegate = lanePainter
        lanes.needsDisplayOnBoundsChange = true
        layer?.addSublayer(lanes)
        for (shapes, width) in [(glows, 5.0), (lines, 1.6)] {
            for shape in shapes {
                shape.fillColor = nil
                shape.lineWidth = width
                shape.lineJoin = .round
                shape.actions = Self.noActions
                layer?.addSublayer(shape)
            }
        }
        for (labels, font) in [(notes, Self.noteFont), (waveforms, Self.waveformFont)] {
            for label in labels {
                label.font = font
                label.fontSize = font.pointSize
                label.alignmentMode = .center
                label.foregroundColor = Self.gray
                label.actions = Self.noActions
                layer?.addSublayer(label)
            }
        }
    }

    func apply(feed: VisualizerFeed, theme: VoiceTheme, isAnimating: Bool) {
        self.feed = feed
        if theme != self.theme || lanePainter.colors.isEmpty {
            self.theme = theme
            lanePainter.colors = (0..<3).map { color($0, 0.08) }
            lanes.setNeedsDisplay()
            for i in 0..<3 {
                glows[i].strokeColor = color(i, 0.25)
                lines[i].strokeColor = color(i, 1)
            }
        }
        self.isAnimating = isAnimating
        update()
    }

    override func scaleChanged(to scale: CGFloat) {
        for layer in [lanes] + notes + waveforms { layer.contentsScale = scale }
        lanes.setNeedsDisplay()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lanes.frame = bounds
        for shape in glows + lines { shape.frame = bounds }
        for i in 0..<3 {
            let lane = lane(i)
            // The layers' origin is the bottom left; the scope is laid out from the top.
            notes[i].frame = label(Self.noteFont, centeredAt: lane.height + 16, in: lane)
            waveforms[i].frame = label(Self.waveformFont, centeredAt: lane.height + 31, in: lane)
        }
        update()
        CATransaction.commit()
    }

    override func frame(_ link: CADisplayLink) {
        update()
    }

    private func color(_ i: Int, _ alpha: Double) -> CGColor {
        let rgb = theme.voices[i % 3]
        return CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    /// Voice `i`'s lane, measured from the top left.
    private func lane(_ i: Int) -> CGRect {
        let width = (bounds.width - Self.gap * 2) / 3
        return CGRect(x: CGFloat(i) * (width + Self.gap), y: 0, width: width, height: bounds.height - VoiceLabels.height)
    }

    /// Where a line of `font` goes to be centered `y` from the top, across `lane`.
    private func label(_ font: NSFont, centeredAt y: CGFloat, in lane: CGRect) -> CGRect {
        let height = (font.ascender - font.descender + font.leading).rounded(.up)
        return CGRect(x: lane.minX, y: bounds.height - y - height / 2, width: lane.width, height: height)
    }

    /// The traces and labels for what's being heard now.
    private func update() {
        guard let feed, bounds.width > 0, bounds.height > 0 else { return }
        let voices = feed.latest()?.chips.first?.voices ?? []
        let scope = voices.isEmpty ? nil : feed.scope(chip: 0, count: 2048)
        // Paths are worked out from the top left, as `trace` does, and turned over.
        var turnOver = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        for i in 0..<3 {
            let voice = i < voices.count ? voices[i] : nil
            var trace: CGPath?
            if let voice, let scope, i < scope.voices.count {
                let window = ScopeTrigger.window(
                    scope.voices[i], hz: voice.hz, sampleRate: scope.sampleRate,
                    pitched: voice.waveform & 0x7 != 0
                )
                trace = ScopeVisualizer.trace(window, in: lane(i).insetBy(dx: 4, dy: 6)).cgPath.copy(using: &turnOver)
            }
            glows[i].path = trace
            lines[i].path = trace

            // As VoiceLabels draws them: a released note still sounds, so
            // its name stays, dimmed; no voice shows placeholders.
            let sounding = voice.map { $0.gate || $0.envLevel > 0 } ?? false
            let waveform = voice?.waveformName ?? ""
            set(notes[i], (sounding ? voice?.note : nil) ?? "·", color: voice?.gate == true ? color(i, 1) : Self.gray)
            set(waveforms[i], waveform.isEmpty ? "—" : waveform, color: Self.gray)
        }
    }

    /// A text layer redraws when its string or color is set, even to the same thing.
    private func set(_ label: CATextLayer, _ string: String, color: CGColor) {
        if label.string as? String != string { label.string = string }
        if label.foregroundColor != color { label.foregroundColor = color }
    }
}

/// Draws the lanes: a tinted panel per voice with a line across its middle.
private final class LanePainter: NSObject, CALayerDelegate {
    var colors: [CGColor] = []

    func draw(_ layer: CALayer, in ctx: CGContext) {
        let size = layer.bounds.size
        let gap: CGFloat = 6
        let width = (size.width - gap * 2) / 3
        // Drawn from the bottom left: the labels' room is under the lanes.
        let bottom = VoiceLabels.height
        for (i, color) in colors.enumerated() {
            let lane = CGRect(x: CGFloat(i) * (width + gap), y: bottom, width: width, height: size.height - bottom)
            ctx.addPath(Path(roundedRect: lane, cornerRadius: 6).cgPath)
            ctx.setFillColor(color)
            ctx.fillPath()
            ctx.move(to: CGPoint(x: lane.minX, y: lane.midY))
            ctx.addLine(to: CGPoint(x: lane.maxX, y: lane.midY))
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08))
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
    }

    func action(for layer: CALayer, forKey event: String) -> (any CAAction)? {
        NSNull()
    }
}

#Preview {
    ScopeVisualizer()
        .environment(PlayerStore.preview)
        .frame(width: 300, height: 180)
        .padding()
}
