import SwiftUI
import PhosphorCore

/// Each voice's ADSR envelope as a shape built from its attack, decay,
/// sustain and release settings, with a dot riding along it as the real
/// envelope plays: up the attack, down the decay, along the sustain, down
/// the release. The settings sit above it, the current phase lit.
///
/// Multi-SID tunes show their first chip. Drawn into one Canvas (see
/// VisualizerView).
struct EnvelopeVisualizer: View {
    /// False pauses it, e.g. while another page or Now Playing covers it.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme
    @State private var releases = ReleaseTracker()

    var body: some View {
        TimelineView(.animation(minimumInterval: VisualizerFeed.frameInterval, paused: !store.isPlaying || !isActive)) { _ in
            let voices = store.visualizer.latest()?.chips.first?.voices ?? []
            let _ = releases.update(voices)
            Canvas { gc, size in
                draw(voices: voices, in: gc, size: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Voice envelopes")
    }

    private static let gap: CGFloat = 6
    private static let unlit = Color(red: 0x5E / 255, green: 0x5F / 255, blue: 0x66 / 255)
    private static let settingsSize: CGFloat = 11
    private static let minSettingsSize: CGFloat = 8
    private static let settingsGap: CGFloat = 5
    private static let minSettingsGap: CGFloat = 3

    private func draw(voices: [VizVoice], in gc: GraphicsContext, size: CGSize) {
        let width = (size.width - Self.gap * 2) / 3
        let laneHeight = size.height - VoiceLabels.height

        for i in 0..<3 {
            let color = theme.voice(i)
            let lane = CGRect(x: CGFloat(i) * (width + Self.gap), y: 0, width: width, height: laneHeight)
            gc.fill(Path(roundedRect: lane, cornerRadius: 6), with: .color(color.opacity(0.08)))

            let voice = i < voices.count ? voices[i] : nil
            if let voice {
                // Below the settings line, clear of the lane's edges.
                let area = CGRect(x: lane.minX + 6, y: lane.minY + 26, width: lane.width - 12, height: lane.height - 34)
                let shape = EnvelopeShape(voice, in: area)
                gc.fill(shape.path(closed: true), with: .color(color.opacity(0.15)))
                gc.stroke(shape.path(closed: false), with: .color(color.opacity(0.55)), lineWidth: 1.4)
                if let point = shape.dot(for: voice, releasedFrom: releases.from[i]) {
                    let dot = Path(ellipseIn: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
                    gc.fill(dot, with: .color(.white))
                    gc.stroke(dot, with: .color(color), lineWidth: 2.5)
                }
                drawSettings(voice, color: color, at: CGPoint(x: lane.minX + 6, y: lane.minY + 13),
                             width: lane.width - 12, in: gc)
            }
            VoiceLabels.draw(voice, color: color, centeredAt: lane.midX, top: laneHeight, in: gc)
        }
    }

    /// "A0 D9 SA R0", one hex digit per setting as the SID stores them, with
    /// the phase the voice is in lit in its colour. Fits `width`: in a
    /// narrow inspector the gaps close up first, then the text shrinks.
    private func drawSettings(_ voice: VizVoice, color: Color, at origin: CGPoint, width: CGFloat,
                              in gc: GraphicsContext) {
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
        func resolve(size: CGFloat) -> [GraphicsContext.ResolvedText] {
            settings.enumerated().map { k, setting in
                gc.resolve(Text(setting)
                    .font(.system(size: size, design: .monospaced))
                    .foregroundStyle(k == lit ? color : Self.unlit))
            }
        }
        func textWidth(_ texts: [GraphicsContext.ResolvedText]) -> CGFloat {
            texts.reduce(0) { $0 + $1.measure(in: CGSize(width: 100, height: 20)).width }
        }

        var texts = resolve(size: Self.settingsSize)
        var used = textWidth(texts)
        let minGaps = 3 * Self.minSettingsGap
        if used + minGaps > width {
            let size = max(Self.settingsSize * (width - minGaps) / used, Self.minSettingsSize)
            texts = resolve(size: size)
            used = textWidth(texts)
        }
        let gap = min(max((width - used) / 3, Self.minSettingsGap), Self.settingsGap)
        var x = origin.x
        for text in texts {
            gc.draw(text, at: CGPoint(x: x, y: origin.y), anchor: .leading)
            x += text.measure(in: CGSize(width: 100, height: 20)).width + gap
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
