import SwiftUI
import PhosphorCore

/// Each voice's ADSR envelope as a shape built from its attack, decay,
/// sustain and release settings, with a dot riding along it as the real
/// envelope plays: up the attack, down the decay, along the sustain, down
/// the release. The settings sit above it, the current phase lit.
///
/// Multi-SID tunes show their first chip. Made of Core Animation layers in
/// an AppKit view, not a `Canvas`: see `FrameLinkedNSView` for why.
struct EnvelopeVisualizer: View {
    /// False pauses it, e.g. while another page or Now Playing covers it.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    var body: some View {
        EnvelopeLayerView(feed: store.visualizer, theme: theme, isAnimating: store.isPlaying && isActive)
            .accessibilityElement()
            .accessibilityLabel("Voice envelopes")
    }
}

private struct EnvelopeLayerView: NSViewRepresentable {
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let isAnimating: Bool

    func makeNSView(context: Context) -> EnvelopeNSView {
        let view = EnvelopeNSView()
        view.apply(feed: feed, theme: theme, isAnimating: isAnimating)
        return view
    }

    func updateNSView(_ view: EnvelopeNSView, context: Context) {
        view.apply(feed: feed, theme: theme, isAnimating: isAnimating)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EnvelopeNSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 300, height: 166))
    }
}

/// The envelopes in layers, a lane per voice: its panel, the shape's fill
/// and outline (new paths only when the settings change), the dot (moved
/// every frame), the four settings and the labels. The layers' origin is
/// the bottom left; everything is worked out from the top left, as the
/// shape is, and turned over.
private final class EnvelopeNSView: FrameLinkedNSView {
    private static let gap: CGFloat = 6
    private static let unlit = CGColor(srgbRed: 0x5E / 255, green: 0x5F / 255, blue: 0x66 / 255, alpha: 1)
    private static let settingsSize: CGFloat = 11
    private static let minSettingsSize: CGFloat = 8
    private static let settingsGap: CGFloat = 5
    private static let minSettingsGap: CGFloat = 3
    private static let dotSize: CGFloat = 9
    private static let dotStroke: CGFloat = 2.5

    /// What a lane's shape was drawn from.
    fileprivate struct ShapeKey: Equatable {
        let attack, decay, sustain, release: Int
        let area: CGRect
    }

    private final class Lane {
        let panel = CALayer()
        let fill = CAShapeLayer()
        let outline = CAShapeLayer()
        let dot = CAShapeLayer()
        let settings = (0..<4).map { _ in CATextLayer() }
        let labels: VoiceLabelLayers
        var shape: ShapeKey?

        init(in parent: CALayer) {
            // First: a class sets every stored property before it uses one.
            labels = VoiceLabelLayers(in: parent)
            for part in [panel, fill, outline, dot] as [CALayer] {
                part.actions = VoiceLabelLayers.noActions
                parent.addSublayer(part)
            }
            panel.cornerRadius = 6
            outline.fillColor = nil
            outline.lineWidth = 1.4
            outline.lineJoin = .miter
            let size = EnvelopeNSView.dotSize + EnvelopeNSView.dotStroke
            dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            dot.path = CGPath(ellipseIn: dot.bounds.insetBy(dx: EnvelopeNSView.dotStroke / 2, dy: EnvelopeNSView.dotStroke / 2),
                              transform: nil)
            dot.fillColor = CGColor(gray: 1, alpha: 1)
            dot.lineWidth = EnvelopeNSView.dotStroke
            dot.isHidden = true
            for text in settings {
                text.alignmentMode = .left
                text.foregroundColor = EnvelopeNSView.unlit
                text.actions = VoiceLabelLayers.noActions
                parent.addSublayer(text)
            }
        }
    }

    private var feed: VisualizerFeed?
    private var theme = VoiceTheme.resonance
    private let releases = ReleaseTracker()
    private var voices: [VizVoice] = []
    private var lanes: [Lane] = []

    init() {
        super.init(framesPerSecond: VisualizerFeed.framesPerSecond)
        if let layer { lanes = (0..<3).map { _ in Lane(in: layer) } }
        paint()
    }

    func apply(feed: VisualizerFeed, theme: VoiceTheme, isAnimating: Bool) {
        let first = self.feed == nil
        self.feed = feed
        let recolor = theme != self.theme
        self.theme = theme
        self.isAnimating = isAnimating
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if recolor { paint() }
        // Still: hold what shows.
        if first { advance() }
        render()
        CATransaction.commit()
    }

    override func scaleChanged(to scale: CGFloat) {
        for lane in lanes {
            lane.labels.setScale(scale)
            for text in lane.settings { text.contentsScale = scale }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeLanes()
        render()
        CATransaction.commit()
    }

    override func frame(_ link: CADisplayLink) {
        advance()
        render()
    }

    private func advance() {
        voices = feed?.latest()?.chips.first?.voices ?? []
        releases.update(voices)
    }

    private func color(_ i: Int, _ alpha: Double) -> CGColor {
        let rgb = theme.voices[i % 3]
        return CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    private func paint() {
        for (i, lane) in lanes.enumerated() {
            lane.panel.backgroundColor = color(i, 0.08)
            lane.fill.fillColor = color(i, 0.15)
            lane.outline.strokeColor = color(i, 0.55)
            lane.dot.strokeColor = color(i, 1)
        }
    }

    /// Voice `i`'s lane, measured from the top left.
    private func lane(_ i: Int) -> CGRect {
        let width = (bounds.width - Self.gap * 2) / 3
        return CGRect(x: CGFloat(i) * (width + Self.gap), y: 0, width: width, height: bounds.height - VoiceLabels.height)
    }

    private func turned(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Everything that only moves with the size: the panels, the settings'
    /// size and places, and the labels.
    private func placeLanes() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // "A0 D9 SA R0" fits the lane: in a narrow inspector the gaps close
        // up first, then the text shrinks. Every setting is two characters
        // of a monospaced font, so they're all as wide as one another.
        let width = lane(0).width - 12
        func settingWidth(_ font: NSFont) -> CGFloat {
            ("A0" as NSString).size(withAttributes: [.font: font]).width
        }
        var font = NSFont.monospacedSystemFont(ofSize: Self.settingsSize, weight: .regular)
        var used = 4 * settingWidth(font)
        let minGaps = 3 * Self.minSettingsGap
        if used + minGaps > width {
            let size = max(Self.settingsSize * (width - minGaps) / used, Self.minSettingsSize)
            font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            used = 4 * settingWidth(font)
        }
        let gap = min(max((width - used) / 3, Self.minSettingsGap), Self.settingsGap)
        let textWidth = settingWidth(font)
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)

        for (i, lane) in lanes.enumerated() {
            let rect = self.lane(i)
            VoiceLabelLayers.setFrame(lane.panel, turned(rect))
            VoiceLabelLayers.setFrame(lane.fill, bounds)
            VoiceLabelLayers.setFrame(lane.outline, bounds)
            var x = rect.minX + 6
            for text in lane.settings {
                if text.font as? NSFont != font {
                    text.font = font
                    text.fontSize = font.pointSize
                }
                // Centered on a line 13 from the lane's top, as drawn with a leading anchor.
                let frame = CGRect(x: x, y: rect.minY + 13 - lineHeight / 2, width: textWidth.rounded(.up) + 2, height: lineHeight)
                VoiceLabelLayers.setFrame(text, turned(frame))
                x += textWidth + gap
            }
            lane.labels.place(centeredAt: rect.midX, top: rect.height, width: rect.width, in: bounds.height)
        }
    }

    /// The shapes, dots, settings and labels for what's being heard now.
    private func render() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        var turnOver = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        for (i, lane) in lanes.enumerated() {
            let rect = self.lane(i)
            let voice = i < voices.count ? voices[i] : nil
            let shows = voice != nil
            let parts: [CALayer] = [lane.fill, lane.outline] + lane.settings.map { $0 as CALayer }
            for part in parts where part.isHidden == shows {
                part.isHidden = !shows
            }
            lane.labels.show(voice, color: color(i, 1))
            guard let voice else {
                if !lane.dot.isHidden { lane.dot.isHidden = true }
                continue
            }

            // Below the settings line, clear of the lane's edges.
            let area = CGRect(x: rect.minX + 6, y: rect.minY + 26, width: rect.width - 12, height: rect.height - 34)
            let shape = EnvelopeShape(voice, in: area)
            let key = ShapeKey(attack: Int(voice.attack), decay: Int(voice.decay), sustain: Int(voice.sustain),
                               release: Int(voice.release), area: area)
            if lane.shape != key {
                lane.shape = key
                lane.fill.path = shape.path(closed: true).cgPath.copy(using: &turnOver)
                lane.outline.path = shape.path(closed: false).cgPath.copy(using: &turnOver)
            }
            if let point = shape.dot(for: voice, releasedFrom: releases.from[i]) {
                let position = CGPoint(x: point.x, y: bounds.height - point.y)
                if lane.dot.position != position { lane.dot.position = position }
                if lane.dot.isHidden { lane.dot.isHidden = false }
            } else if !lane.dot.isHidden {
                lane.dot.isHidden = true
            }

            let lit: Int? = if voice.gate || voice.envLevel > 0 {
                switch voice.envPhase {
                case .attack: 0
                case .decay: 1
                case .sustain: 2
                case .release: 3
                }
            } else {
                nil
            }
            let settings = [("A", voice.attack), ("D", voice.decay), ("S", voice.sustain), ("R", voice.release)]
                .map { $0.0 + String($0.1, radix: 16, uppercase: true) }
            for (k, text) in lane.settings.enumerated() {
                VoiceLabelLayers.set(text, settings[k], color: k == lit ? color(i, 1) : Self.unlit)
            }
        }
    }
}

/// An ADSR envelope laid out across a rect: each slope widens with its
/// setting, the sustain level sets the plateau's height, and the plateau
/// takes the width that's left.
nonisolated struct EnvelopeShape {
    /// Start, peak, sustain start, sustain end, end.
    let points: [CGPoint]
    /// 0–1.
    let sustain: CGFloat

    init(_ voice: VizVoice, in rect: CGRect) {
        let attack = rect.width * (0.06 + 0.012 * CGFloat(voice.attack))
        let decay = rect.width * (0.10 + 0.012 * CGFloat(voice.decay))
        let release = rect.width * (0.10 + 0.012 * CGFloat(voice.release))
        sustain = CGFloat(voice.sustain) / 15
        let sustainY = rect.maxY - rect.height * sustain
        points = [
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX + attack, y: rect.minY),
            CGPoint(x: rect.minX + attack + decay, y: sustainY),
            CGPoint(x: rect.maxX - release, y: sustainY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }

    func path(closed: Bool) -> Path {
        Path { p in
            p.addLines(points)
            if closed { p.closeSubpath() }
        }
    }

    /// Where the dot sits for the voice's phase and level, on the shape.
    /// `releasedFrom` is the level the release started at; nil once silent.
    func dot(for voice: VizVoice, releasedFrom: Float) -> CGPoint? {
        let level = CGFloat(voice.envLevel)
        switch voice.envPhase {
        case .attack:
            return along(points[0], points[1], level)
        case .decay:
            return along(points[1], points[2], sustain < 1 ? (1 - level) / (1 - sustain) : 1)
        case .sustain:
            return along(points[2], points[3], 0.5)
        case .release:
            guard level > 0 else { return nil }
            return along(points[3], points[4], 1 - level / max(CGFloat(releasedFrom), level))
        }
    }

    private func along(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let t = min(max(t, 0), 1)
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// The level each voice's release started from, so the dot can run the
/// release slope from its start to silence whatever level the note had.
nonisolated final class ReleaseTracker {
    private(set) var from: [Float] = [1, 1, 1]
    private var last: [VizVoice?] = [nil, nil, nil]

    func update(_ voices: [VizVoice]) {
        for i in 0..<3 {
            let voice = i < voices.count ? voices[i] : nil
            if let voice, voice.envPhase == .release, let previous = last[i], previous.envPhase != .release {
                from[i] = max(previous.envLevel, voice.envLevel)
            }
            last[i] = voice
        }
    }
}

#Preview {
    EnvelopeVisualizer()
        .environment(PlayerStore.preview)
        .frame(width: 300, height: 166)
        .padding()
        .background(.black)
}
