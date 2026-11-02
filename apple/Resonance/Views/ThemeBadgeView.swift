import SwiftUI

/// The theme's badge: a small strip drawn in its colours, e.g. the C64's
/// rainbow bars or Noir's lightsaber. Draws nothing when badges are turned
/// off in Settings. Scales to whatever size it's given; designed at about
/// 10:1.
struct ThemeBadgeView: View {
    @Environment(\.voiceTheme) private var theme
    @AppStorage(Pref.themeBadge) private var showsBadge = true

    var body: some View {
        if showsBadge {
            switch theme.badge {
            case .screen:
                // Often enough for the C64's cursor: 20 jiffies on, 20 off.
                TimelineView(.periodic(from: .now, by: 20.0 / 60)) { context in
                    canvas(time: context.date.timeIntervalSinceReferenceDate)
                }
            default:
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    canvas(time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
    }

    private func canvas(time: Double) -> some View {
        let theme = theme
        return Canvas { gc, size in
            Self.draw(theme, time: time, in: gc, size: size)
        }
        .accessibilityHidden(true)
    }

    /// Abyss's demoscene plasma, worked out at one sample per 2 points and
    /// drawn smoothed as one image. Four sine fields (across, along,
    /// diagonal, and rings round a wandering centre) add up to a value that
    /// picks a colour from a slowly cycling loop through the three voices'
    /// colours; the troughs sink into the background, so it stays dark.
    private static func plasma(_ theme: VoiceTheme, time: Double, size: CGSize) -> Image? {
        let cols = max(Int(size.width / 2), 1), rows = max(Int(size.height / 2), 1)
        let t = time.truncatingRemainder(dividingBy: 3600)
        let unit = Double(rows)
        let centre = (x: Double(cols) / unit * (0.5 + 0.35 * sin(t * 0.23)), y: 0.5 + 0.8 * cos(t * 0.31))
        let loop = theme.voices + [theme.voices[0]]
        let bg = theme.background
        var bytes = [UInt8](repeating: 255, count: cols * rows * 4)
        for row in 0..<rows {
            let y = (Double(row) + 0.5) / unit
            for col in 0..<cols {
                let x = (Double(col) + 0.5) / unit
                let v = sin(x * 1.1 + t * 0.9) + sin(y * 3 - t * 0.7) + sin(x * 0.6 + y * 2 + t * 1.1)
                    + sin(hypot(x - centre.x, y - centre.y) * 2.4 - t * 1.5)
                var u = (v * 0.125 + 0.5 + t * 0.04).truncatingRemainder(dividingBy: 1)
                if u < 0 { u += 1 }
                u *= 3
                let i = min(Int(u), 2)
                let f = u - Double(i), s = f * f * (3 - 2 * f)
                let (a, b) = (loop[i], loop[i + 1])
                let light = 0.5 + 0.5 * sin(v * 1.6)
                let k = 0.25 + 0.75 * light * light
                let n = (row * cols + col) * 4
                for (c, (pa, pb, pg)) in [(a.red, b.red, bg.red), (a.green, b.green, bg.green), (a.blue, b.blue, bg.blue)].enumerated() {
                    let hue = pa + (pb - pa) * s
                    bytes[n + c] = UInt8(min(max(pg + (hue - pg) * k, 0), 1) * 255)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return Image(decorative: image, scale: 1).interpolation(.high)
    }

    /// The Commodore badge's five bars, top to bottom.
    static let rainbow: [Color] = [0xE2231A, 0xF28C00, 0xFFCC00, 0x3FA535, 0x1F6FC5].map { RGB(integerLiteral: $0).color }

    /// What the custom theme's scroller says, round and round.
    private static let scrollText = "RESONANCE  •  MUSIC FROM THE HIGH VOLTAGE SID COLLECTION  •  GREETINGS TO EVERY SID COMPOSER, EVERY CODER AND EVERY SCENER STILL AT IT  •  "

    private static func draw(_ theme: VoiceTheme, time: Double, in gc: GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let v = (0..<3).map(theme.voice)
        switch theme.badge {
        case .rainbow:
            // Raster bars in the badge's colours wrapped round a cylinder
            // turning about a horizontal axis. Each raster line looks up
            // which bar is on the cylinder's front there (and, dimmed, its
            // back), so bars flatten towards the edges, fatten facing you
            // and pass behind each other the way the real effect does.
            let t = time.truncatingRemainder(dividingBy: 3600)
            let radius = h / 2
            let segment = 2 * Double.pi / Double(rainbow.count)
            let fill = 0.72
            let line: CGFloat = 0.5
            func shade(_ theta: Double) -> Color? {
                var around = (theta + t * 1.6).truncatingRemainder(dividingBy: 2 * .pi)
                if around < 0 { around += 2 * .pi }
                let index = Int(around / segment) % rainbow.count
                let across = (around - Double(index) * segment) / segment / fill
                guard across < 1 else { return nil }
                let light = 1 - abs(2 * across - 1)
                var color = rainbow[index].mix(with: .black, by: 0.7 * (1 - light))
                if light > 0.75 { color = color.mix(with: .white, by: 0.5 * (light - 0.75) / 0.25) }
                // Lit from the front: lines turned away are darker.
                return color.mix(with: .black, by: 0.6 * (1 - abs(cos(theta))))
            }
            for y in stride(from: 0, to: h, by: line) {
                let s = Double(min(max((y + line / 2 - radius) / radius, -1), 1))
                let front = asin(s)
                let color = shade(front) ?? shade(.pi - front).map { $0.mix(with: .black, by: 0.7) }
                if let color {
                    gc.fill(Path(CGRect(x: 0, y: y, width: w, height: line)), with: .color(color))
                }
            }

        case .saber:
            let hilt = min(w * 0.14, h * 2.4)
            let mid = h / 2
            gc.fill(Path(roundedRect: CGRect(x: 0, y: mid - h * 0.2, width: hilt, height: h * 0.4), cornerRadius: h * 0.06),
                    with: .color(Color(white: 0.24)))
            for k in 1...3 {
                gc.fill(Path(CGRect(x: hilt * CGFloat(k) / 5, y: mid - h * 0.2, width: hilt * 0.06, height: h * 0.4)),
                        with: .color(Color(white: 0.1)))
            }
            gc.fill(Path(roundedRect: CGRect(x: hilt * 0.82, y: mid - h * 0.27, width: hilt * 0.18, height: h * 0.54),
                         cornerRadius: h * 0.06), with: .color(Color(white: 0.36)))
            // The blade: a blurred glow that breathes slowly with a faint
            // unsteady hum, then the edge and the white-hot core.
            let t = time.truncatingRemainder(dividingBy: 3600)
            let breath = 0.75 + 0.25 * sin(t * 1.2) + 0.06 * sin(t * 23) * sin(t * 7.1)
            func blade(_ height: CGFloat) -> Path {
                let t = h * height
                return Path(roundedRect: CGRect(x: hilt, y: mid - t / 2, width: w - hilt - h * 0.1, height: t),
                            cornerRadius: t / 2)
            }
            // Now and then it takes a hit: a white flare at a random point
            // on the blade, sparks flying off, the whole blade surging, all
            // fading out over 0.4 s. One hit per 6.5 s window, at a random
            // moment in it.
            func random(_ n: Double) -> Double { (sin(n * 12.989) * 43_758.545_3).truncatingRemainder(dividingBy: 1).magnitude }
            let window = (t / 6.5).rounded(.down)
            let age = t - (window + random(window) * 0.6) * 6.5
            let hit = age >= 0 && age < 0.4 ? pow(1 - age / 0.4, 2) : 0
            let at = hilt + (0.2 + 0.7 * CGFloat(random(window + 0.5))) * (w - hilt)
            let surge = breath + 0.6 * hit

            gc.drawLayer { glow in
                glow.addFilter(.blur(radius: h * 0.22 * CGFloat(surge)))
                glow.fill(blade(0.5), with: .color(v[0].opacity(min(0.55 + 0.35 * surge, 1))))
            }
            gc.fill(blade(0.26), with: .color(v[0].mix(with: .white, by: 0.35 * hit)))
            gc.fill(blade(0.11 + 0.06 * CGFloat(hit)), with: .color(Color(red: 1, green: 0.9, blue: 0.9)))
            if hit > 0 {
                gc.drawLayer { flare in
                    flare.addFilter(.blur(radius: h * 0.25))
                    let r = h * (0.3 + 0.35 * CGFloat(hit))
                    flare.fill(Path(ellipseIn: CGRect(x: at - r * 1.6, y: mid - r, width: r * 3.2, height: r * 2)),
                               with: .color(.white.opacity(hit)))
                }
                for k in 0..<7 {
                    let angle = random(window * 7 + Double(k)) * 2 * .pi
                    let reach = h * CGFloat(0.2 + age * 2.2) * CGFloat(0.6 + random(window + Double(k) * 0.3))
                    let end = CGPoint(x: at + cos(angle) * reach * 1.8, y: mid + sin(angle) * reach)
                    let start = CGPoint(x: at + cos(angle) * reach * 1.1, y: mid + sin(angle) * reach * 0.6)
                    gc.stroke(Path { p in
                        p.move(to: start)
                        p.addLine(to: end)
                    }, with: .color(Color(red: 1, green: 0.85, blue: 0.6).opacity(hit)), lineWidth: 1)
                }
            }

        case .waves:
            // Neighbours drift opposite ways, each swelling and settling.
            let t = time.truncatingRemainder(dividingBy: 3600)
            for i in 0..<3 {
                let phase = t * (0.9 + 0.35 * Double(i)) * (i == 1 ? -1 : 1)
                let swell = h * 0.3 * CGFloat(0.65 + 0.35 * sin(t * 0.8 + Double(i) * 2))
                var path = Path()
                for x in stride(from: 0, through: w, by: 2) {
                    let y = h / 2 + CGFloat(sin(Double(x / (h * (0.8 + 0.26 * CGFloat(i)))) + Double(i) * 2 + phase)) * swell
                    if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                gc.stroke(path, with: .color(v[i].opacity(0.9)), lineWidth: max(h * 0.06, 1))
            }

        case .flame:
            // Each tongue flickers around its own height; sparks rise off the top.
            let t = time.truncatingRemainder(dividingBy: 3600)
            let step = h * 0.3
            for k in 0..<Int(w / step) {
                let base = abs(sin(Double(k) * 1.7) * cos(Double(k) * 0.6))
                let flicker = abs(sin(Double(k) * 1.7 + t * (3 + sin(Double(k)))) * cos(Double(k) * 0.6 - t * 1.9))
                let level = 0.55 * base + 0.45 * flicker
                let height = h * (0.25 + 0.75 * level)
                let color = level > 0.7 ? v[2] : level > 0.38 ? v[1] : v[0]
                gc.fill(Path(roundedRect: CGRect(x: CGFloat(k) * step, y: h - height, width: step * 0.6, height: height),
                             cornerRadius: step * 0.3), with: .color(color))
            }
            for k in 0..<Int(w / (h * 2.2)) {
                let seed = Double(k) * 0.618_034
                let rise = (t * (0.5 + 0.3 * sin(seed * 7)) + seed).truncatingRemainder(dividingBy: 1)
                let x = (CGFloat(k) + 0.5) * h * 2.2 + CGFloat(sin(t * 2 + seed * 17)) * h * 0.3
                let r = h * 0.06
                gc.fill(Path(ellipseIn: CGRect(x: x - r, y: h * CGFloat(0.9 - 0.9 * rise) - r, width: 2 * r, height: 2 * r)),
                        with: .color(v[2].opacity(1 - rise)))
            }

        case .plasma:
            if let image = plasma(theme, time: time, size: size) {
                gc.draw(image, in: CGRect(origin: .zero, size: size))
            }

        case .screen:
            for y in stride(from: 1, to: h, by: 3) {
                gc.fill(Path(CGRect(x: 0, y: y, width: w, height: 1)), with: .color(v[1].opacity(0.25)))
            }
            let text = gc.resolve(Text("READY.").font(.system(size: h * 0.48, design: .monospaced)).foregroundStyle(v[0]))
            let textSize = text.measure(in: size)
            let origin = CGPoint(x: h * 0.3, y: (h - textSize.height) / 2)
            gc.draw(text, at: origin, anchor: .topLeading)
            if Int(time * 3).isMultiple(of: 2) {
                gc.fill(Path(CGRect(x: origin.x + textSize.width + h * 0.08, y: h * 0.25, width: h * 0.3, height: h * 0.52)),
                        with: .color(v[0]))
            }

        case .starfield:
            // A camera flying through a fixed cube of stars that wraps around
            // it, while it turns, nods and banks, like the demoscene
            // starfields (Triton's Crystal Dream): the stars sweep across on
            // curved paths. Crisp points, white near to graphite far.
            let t = time.truncatingRemainder(dividingBy: 3600)
            let yaw = t * 0.12 + sin(t * 0.21) * 0.9
            let pitch = sin(t * 0.15) * 0.35
            let roll = sin(t * 0.09) * 0.5
            let (cy, sy) = (cos(yaw), sin(yaw))
            let (cp, sp) = (cos(pitch), sin(pitch))
            let (cr, sr) = (cos(roll), sin(roll))
            let camera = SIMD3(sin(t * 0.05) * 3, sin(t * 0.07) * 2, t * 0.3)
            // Wide and short: the strip sees about 90Â° across and 30Â° up.
            let (fx, fy) = (Double(w) / 2, Double(h) * 1.8)
            func hash(_ n: Double) -> Double { (sin(n) * 43_758.545_3).truncatingRemainder(dividingBy: 1).magnitude }
            for k in 0..<500 {
                let n = Double(k)
                let star = SIMD3(hash(n * 12.989), hash(n * 78.233), hash(n * 37.719)) * 2
                var r = star - camera
                r = r - (r / 2).rounded(.down) * 2 - SIMD3(repeating: 1)
                // Into the camera's view: undo yaw, pitch, then roll.
                let x1 = r.x * cy - r.z * sy, z1 = r.x * sy + r.z * cy
                let y2 = r.y * cp - z1 * sp, z2 = r.y * sp + z1 * cp
                let x3 = x1 * cr - y2 * sr, y3 = x1 * sr + y2 * cr
                guard z2 > 0.03 else { continue }
                let px = Double(w) / 2 + x3 / z2 * fx
                let py = Double(h) / 2 + y3 / z2 * fy
                guard px >= 0, px < Double(w), py >= 0, py < Double(h) else { continue }
                let near = max(0, 1 - z2)
                let size: CGFloat = near > 0.75 ? 2 : 1
                let color = v[near > 0.6 ? 0 : near > 0.3 ? 1 : 2].opacity(min(1, 0.35 + near))
                gc.fill(Path(CGRect(x: px.rounded(.down), y: py.rounded(.down), width: size, height: size)), with: .color(color))
            }

        case .scroller:
            // A sine scroller: chunky letters running right to left, each
            // riding a sine wave and coloured by where it is on the strip,
            // through the three voices' colours, over a faint mirrored
            // reflection.
            let t = time.truncatingRemainder(dividingBy: 3600)
            let font = Font.system(size: h * 0.62, weight: .black, design: .monospaced)
            let advance = h * 0.42
            let text = Array(scrollText)
            let offset = CGFloat(t) * h * 2.2
            let first = Int((offset / advance).rounded(.down))
            for slot in first...(first + Int(w / advance) + 1) {
                let x = CGFloat(slot) * advance - offset
                let letter = text[((slot % text.count) + text.count) % text.count]
                guard letter != " " else { continue }
                let y = h * 0.42 + CGFloat(sin(Double(x / h) * 0.9 + t * 3)) * h * 0.2
                let along = max(0, min(x / w, 1)) * 2
                let i = min(Int(along), 1)
                let color = v[i].mix(with: v[i + 1], by: Double(along) - Double(i))
                gc.draw(Text(String(letter)).font(font).foregroundStyle(color), at: CGPoint(x: x, y: y))
            }
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        ForEach(VoiceTheme.presets + [VoiceTheme.defaultCustom]) { theme in
            ThemeBadgeView()
                .frame(width: 300, height: 20)
                .padding(8)
                .background(theme.background.color)
                .environment(\.voiceTheme, theme)
        }
    }
    .padding()
}
