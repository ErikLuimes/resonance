import SwiftUI
import PhosphorCore

/// The nine traits a fingerprint's glyphs draw, in `TuneFingerprint.traits`
/// order, each with its color: rhythm and pitch movement in cyan, the
/// filter in violet, the chip's harsher tricks in orange, samples in red,
/// pulse-width sweeps in green.
nonisolated enum SoundTrait: Int, CaseIterable {
    case notes, arpeggios, vibrato, filter, ring, sync, digi, noise, pulseWidth

    var name: String {
        switch self {
        case .notes: String(localized: "Notes")
        case .arpeggios: String(localized: "Arpeggios")
        case .vibrato: String(localized: "Vibrato")
        case .filter: String(localized: "Filter")
        case .ring: String(localized: "Ring mod")
        case .sync: String(localized: "Sync")
        case .digi: String(localized: "Digi")
        case .noise: String(localized: "Noise")
        case .pulseWidth: String(localized: "Pulse width")
        }
    }

    var color: Color {
        switch self {
        case .notes: .primary
        case .arpeggios, .vibrato: Color(red: 0.35, green: 0.78, blue: 0.91)
        case .filter: Color(red: 0.64, green: 0.49, blue: 0.96)
        case .ring, .sync, .noise: Color(red: 0.95, green: 0.63, blue: 0.33)
        case .digi: Color(red: 0.94, green: 0.44, blue: 0.44)
        case .pulseWidth: Color(red: 0.50, green: 0.86, blue: 0.64)
        }
    }
}

/// The waveform colors of the mix bar and the sphere.
nonisolated enum WaveformColor {
    static let triangle = Color(red: 0.50, green: 0.86, blue: 0.64)
    static let saw = Color(red: 0.64, green: 0.49, blue: 0.96)
    static let pulse = Color(red: 0.35, green: 0.78, blue: 0.91)
    static let noise = Color(red: 0.95, green: 0.63, blue: 0.33)

    static func of(_ wave: MixWave) -> Color {
        switch wave {
        case .triangle: triangle
        case .saw: saw
        case .pulse: pulse
        case .noise: noise
        }
    }
}

/// A list row's fingerprint: one bar per trait, always in the same place,
/// so tunes that sound alike look alike down a column.
struct SoundBarcode: View {
    let traits: [Float]

    static let size = CGSize(width: 62, height: 16)

    var body: some View {
        Canvas { context, size in
            let count = SoundTrait.allCases.count
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            for trait in SoundTrait.allCases {
                let x = CGFloat(trait.rawValue) * (width + gap)
                let track = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: track, cornerRadius: 1), with: .color(.secondary.opacity(0.18)))
                let value = CGFloat(traits.indices.contains(trait.rawValue) ? traits[trait.rawValue] : 0)
                let height = max(1.5, value * size.height)
                let bar = CGRect(x: x, y: size.height - height, width: width, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 1),
                             with: .color(trait.color.opacity(0.35 + 0.65 * value)))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityLabel(Self.description(traits))
    }

    /// The traits that stand out, for VoiceOver.
    nonisolated static func description(_ traits: [Float]) -> String {
        let strong = SoundTrait.allCases.filter { traits.indices.contains($0.rawValue) && traits[$0.rawValue] >= 0.5 }
        return strong.isEmpty ? String(localized: "Sound fingerprint") : String(localized: "Sound fingerprint: ") + strong.map(\.name).formatted(.list(type: .and))
    }
}

/// A slowly turning sphere of particles that bulges toward each of a
/// tune's traits, colored by its waveform mix: the tune's look, for the
/// hover card and "Sounds like". Traits always point the same way, so
/// similar tunes have similar shapes.
struct MorphSphere: View {
    let fingerprint: TuneFingerprint
    var animated = true
    /// Above 1 fills more of the frame, clipping what turns past it.
    var zoom = 1.0
    /// False holds it still while it's covered, e.g. by Now Playing.
    var isActive = true

    @Environment(\.voiceTheme) private var theme

    var body: some View {
        let points = MorphSphereShape(fingerprint)
        Group {
            if animated {
                // Decoration, not something to follow: 30 fps is plenty.
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive)) { timeline in
                    canvas(points, angle: timeline.date.timeIntervalSinceReferenceDate * 0.45)
                }
            } else {
                canvas(points, angle: 0.6)
            }
        }
        // On the visualizers' backdrop, dark in either appearance.
        .padding(4)
        .background(theme.background.color, in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func canvas(_ shape: MorphSphereShape, angle: Double) -> some View {
        Canvas { context, size in
            shape.draw(in: &context, size: size, angle: angle, zoom: zoom)
        }
        .accessibilityLabel(SoundBarcode.description(fingerprint.traits))
    }
}

/// The sphere's points, built once per fingerprint.
nonisolated struct MorphSphereShape {
    struct Point {
        var x, y, z: Double
        var color: Int
    }

    let points: [Point]
    /// The farthest point from the center, which the drawing fits.
    let extent: Double
    static let palette = [WaveformColor.triangle, WaveformColor.saw, WaveformColor.pulse, WaveformColor.noise]

    init(_ fp: TuneFingerprint, count: Int = 700) {
        let traits = fp.traits.map(Double.init)
        let directions = Self.directions(traits.count)
        let mix = [fp.mix.triangle, fp.mix.saw, fp.mix.pulse, fp.mix.noise].map(Double.init)
        points = (0..<count).map { i in
            let y = 1 - 2 * (Double(i) + 0.5) / Double(count)
            let r = (1 - y * y).squareRoot()
            let a = Double(i) * 2.39996
            let p = (x: r * cos(a), y: y, z: r * sin(a))
            var radius = 0.36
            for (k, d) in directions.enumerated() {
                let c = max(0, p.x * d.x + p.y * d.y + p.z * d.z)
                radius += traits[k] * 0.58 * pow(c, 8)
            }
            return Point(x: p.x * radius, y: p.y * radius, z: p.z * radius,
                         color: Self.pick(mix, Self.hash(Double(i), 3)))
        }
        extent = points.map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() }.max() ?? 1
    }

    /// `count` directions spread evenly over the sphere (a Fibonacci
    /// lattice), the same for every tune.
    static func directions(_ count: Int) -> [(x: Double, y: Double, z: Double)] {
        (0..<count).map { i in
            let y = 1 - 2 * (Double(i) + 0.5) / Double(count)
            let r = (1 - y * y).squareRoot()
            let a = Double(i) * 2.39996
            return (r * cos(a), y, r * sin(a))
        }
    }

    static func hash(_ a: Double, _ b: Double) -> Double {
        let x = sin(a * 127.1 + b * 311.7) * 43758.5453
        return x - x.rounded(.down)
    }

    /// The waveform a point at `u` (0–1) takes, in proportion to the mix.
    static func pick(_ mix: [Double], _ u: Double) -> Int {
        let total = mix.reduce(0, +)
        guard total > 0 else { return 2 }
        var sum = 0.0
        for (i, m) in mix.enumerated() {
            sum += m / total
            if u <= sum { return i }
        }
        return 2
    }

    func draw(in context: inout GraphicsContext, size: CGSize, angle: Double, zoom: Double = 1) {
        let (cy, sy) = (cos(angle), sin(angle))
        let tilt = 0.3
        let (cx, sx) = (cos(tilt), sin(tilt))
        // Fit the shape: its farthest point fills the frame when it's side
        // on, and stays about inside it when it turns toward you.
        let camera = 3.2
        let scale = min(size.width, size.height) * 0.44 * zoom * (camera - extent / 2) / max(extent, 0.1)
        var projected: [(z: Double, x: Double, y: Double, color: Int)] = points.map { p in
            let x = p.x * cy + p.z * sy
            let z0 = -p.x * sy + p.z * cy
            let y = p.y * cx - z0 * sx
            let z = p.y * sx + z0 * cx
            let perspective = 1 / (camera - z)
            return (z, size.width / 2 + x * scale * perspective, size.height / 2 - y * scale * perspective, p.color)
        }
        projected.sort { $0.z < $1.z }
        let small = size.width < 40
        for p in projected {
            let depth = (p.z + 1) / 2
            let dot = small ? 0.9 : 0.7 + 1.3 * depth
            let rect = CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)
            context.fill(Path(rect), with: .color(Self.palette[p.color].opacity(small ? 0.95 : 0.25 + 0.7 * depth)))
        }
    }
}

/// The waveform mix as one bar with its shares named underneath.
struct WaveformMixBar: View {
    let fingerprint: TuneFingerprint

    var body: some View {
        let waves = fingerprint.waveforms
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(waves, id: \.name) { wave in
                        WaveformColor.of(wave.kind)
                            .frame(width: max(2, (geo.size.width - CGFloat(waves.count - 1) * 2) * wave.share))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(.capsule)
            HStack(spacing: 10) {
                ForEach(waves, id: \.name) { wave in
                    Text("\(wave.name) \(Int((wave.share * 100).rounded()))%")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
