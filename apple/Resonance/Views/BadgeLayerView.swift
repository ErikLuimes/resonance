import AppKit
import SwiftUI

/// The moving badge, drawn by an AppKit view. A display link redraws one
/// layer with Core Graphics, so a frame is one Core Animation commit and
/// SwiftUI never hears about it. A `TimelineView` in the same place made
/// the window run its layout and constraints passes on every frame, which
/// cost about ten times as much.
struct BadgeLayerView: NSViewRepresentable {
    let theme: VoiceTheme
    let isAnimating: Bool

    func makeNSView(context: Context) -> BadgeNSView {
        let view = BadgeNSView()
        view.apply(theme: theme, isAnimating: isAnimating)
        return view
    }

    func updateNSView(_ view: BadgeNSView, context: Context) {
        view.apply(theme: theme, isAnimating: isAnimating)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BadgeNSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 200, height: 20))
    }
}

final class BadgeNSView: NSView {
    private let badge = CALayer()
    private let painter = BadgePainter()
    private var link: CADisplayLink?
    private var isAnimating = false
    /// The last cursor state drawn, for the screen badge.
    private var lastBlink = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        badge.delegate = painter
        badge.needsDisplayOnBoundsChange = true
        // The colors are sRGB: 8 bits a channel is enough, and half the
        // work of the 16 a wide-gamut display would get.
        badge.contentsFormat = .RGBA8Uint
        layer?.addSublayer(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(theme: VoiceTheme, isAnimating: Bool) {
        if painter.theme != theme || painter.isAnimating != isAnimating {
            painter.theme = theme
            painter.isAnimating = isAnimating
            badge.setNeedsDisplay()
        }
        self.isAnimating = isAnimating
        updateLink()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            badge.contentsScale = window.backingScaleFactor
        }
        updateLink()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        badge.contentsScale = window?.backingScaleFactor ?? 2
        badge.setNeedsDisplay()
    }

    override func layout() {
        super.layout()
        badge.frame = bounds
    }

    @objc private func occlusionChanged() {
        updateLink()
    }

    /// Runs only while the badge should move and its window can be seen.
    private func updateLink() {
        if isAnimating, let window, window.occlusionState.contains(.visible) {
            guard link == nil else { return }
            let link = displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if painter.theme.badge == .screen {
            // Only the cursor moves: 20 jiffies on, 20 off.
            let blink = Int(Date.timeIntervalSinceReferenceDate * 3)
            guard blink != lastBlink else { return }
            lastBlink = blink
        }
        badge.setNeedsDisplay()
    }
}

/// Draws the badge layer's contents.
private final class BadgePainter: NSObject, CALayerDelegate {
    var theme = VoiceTheme.resonance
    var isAnimating = true

    func draw(_ layer: CALayer, in ctx: CGContext) {
        // A still screen badge shows its cursor.
        let time = theme.badge == .screen && !isAnimating ? 0 : Date.timeIntervalSinceReferenceDate
        let size = layer.bounds.size
        // Top-left origin, as the drawing expects.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        BadgeDrawing.draw(theme, time: time, in: ctx, size: size)
    }

    /// No crossfade between frames.
    func action(for layer: CALayer, forKey event: String) -> (any CAAction)? {
        NSNull()
    }
}

/// The badges, in Core Graphics. `ctx` has its origin at the top left.
nonisolated enum BadgeDrawing {
    /// The Commodore badge's five bars, top to bottom.
    static let rainbow: [Color] = [0xE2231A, 0xF28C00, 0xFFCC00, 0x3FA535, 0x1F6FC5].map { RGB(integerLiteral: $0).color }

    /// What the custom theme's scroller says, round and round.
    private static let scrollText = Array("RESONANCE  •  MUSIC FROM THE HIGH VOLTAGE SID COLLECTION  •  GREETINGS TO EVERY SID COMPOSER, EVERY CODER AND EVERY SCENER STILL AT IT  •  ")

    static func draw(_ theme: VoiceTheme, time: Double, in ctx: CGContext, size: CGSize) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let environment = EnvironmentValues()
        func cg(_ color: Color) -> CGColor { color.resolve(in: environment).cgColor }
        func cg(_ i: Int, alpha: Double = 1) -> CGColor {
            let c = theme.voices[i % 3]
            return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: alpha)
        }
        func gray(_ white: Double) -> CGColor { CGColor(srgbRed: white, green: white, blue: white, alpha: 1) }
        func fill(_ rect: CGRect, _ color: CGColor) {
            ctx.setFillColor(color)
            ctx.fill(rect)
        }
        func fill(_ path: Path, _ color: CGColor) {
            ctx.addPath(path.cgPath)
            ctx.setFillColor(color)
            ctx.fillPath()
        }
        let v = (0..<3).map(theme.voice)
        let t = time.truncatingRemainder(dividingBy: 3600)

        switch theme.badge {
        case .rainbow:
            // Raster bars in the badge's colors wrapped around a cylinder
            // turning about a horizontal axis. Each raster line looks up
            // which bar is on the cylinder's front there (and, dimmed, its
            // back), so bars flatten toward the edges, fatten facing you
            // and pass behind each other the way the real effect does.
            let radius = h / 2
            let segment = 2 * Double.pi / Double(rainbow.count)
            let fillPart = 0.72
            let line: CGFloat = 0.5
            func shade(_ theta: Double) -> Color? {
                var around = (theta + t * 1.6).truncatingRemainder(dividingBy: 2 * .pi)
                if around < 0 { around += 2 * .pi }
                let index = Int(around / segment) % rainbow.count
                let across = (around - Double(index) * segment) / segment / fillPart
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
                    fill(CGRect(x: 0, y: y, width: w, height: line), cg(color))
                }
            }

        case .scanner:
            // The scanner on the nose of a certain black car: eight lamps
            // behind a red lens, lit one after the other, side to side and
            // back. They're incandescent, so a lamp the light has left
            // takes a moment to go dark, and that's the trail.
            let lamps = 8
            let mid = h / 2
            let housing = CGRect(x: 0, y: mid - h * 0.3, width: w, height: h * 0.6)
            fill(Path(roundedRect: housing, cornerRadius: h * 0.12), gray(0.06))
            // A little light off the housing's top edge.
            fill(CGRect(x: h * 0.12, y: housing.minY, width: w - h * 0.24, height: 0.5), gray(0.2))

            let inset = h * 0.1
            let gap = h * 0.08
            let lampWidth = (w - 2 * inset - gap * CGFloat(lamps - 1)) / CGFloat(lamps)
            let lampHeight = h * 0.36
            // One pass takes 1.1 s. `head` runs 0...1 and back.
            let pass = 1.1
            let phase = (t / pass).truncatingRemainder(dividingBy: 2)
            let head = phase < 1 ? phase : 2 - phase
            let fade = 0.16
            let red = theme.voices[0]

            var lit: [(rect: CGRect, level: Double)] = []
            for k in 0..<lamps {
                let rect = CGRect(x: inset + CGFloat(k) * (lampWidth + gap), y: mid - lampHeight / 2, width: lampWidth, height: lampHeight)
                let center = (Double(k) + 0.5) / Double(lamps)
                // Lit while the light is on it, then cooling since it last
                // passed, on the way out or the way back.
                let away = abs(head - center) * Double(lamps)
                let since = min((phase - center + 2).truncatingRemainder(dividingBy: 2),
                                (phase - (2 - center) + 2).truncatingRemainder(dividingBy: 2)) * pass
                let level = max(exp(-away * away * 1.4), exp(-since / fade))
                lit.append((rect, level))
            }
            // The glow first, so the lamps sit on top of it.
            for lamp in lit where lamp.level > 0.04 {
                capsuleGlow(ctx, rect: lamp.rect.insetBy(dx: 0, dy: lampHeight * 0.15), sigma: h * 0.3,
                            rgb: (red.red, red.green, red.blue), alpha: 0.85 * lamp.level)
            }
            for lamp in lit {
                // The lens: nearly black unlit, the theme's red lit.
                let shade = 0.12 + 0.88 * lamp.level
                fill(Path(roundedRect: lamp.rect, cornerRadius: h * 0.05),
                     CGColor(srgbRed: red.red * shade, green: red.green * shade, blue: red.blue * shade, alpha: 1))
                // The filament behind it, white-hot only at full power.
                let hot = lamp.level * lamp.level
                guard hot > 0.02 else { continue }
                capsuleGlow(ctx, rect: lamp.rect.insetBy(dx: lampWidth * 0.2, dy: lampHeight * 0.38), sigma: h * 0.07,
                            rgb: (1, 0.6 + 0.3 * hot, 0.55 + 0.3 * hot), alpha: hot)
            }

        case .waves:
            // Neighbors drift opposite ways, each swelling and settling.
            ctx.setLineWidth(max(h * 0.06, 1))
            for i in 0..<3 {
                let phase = t * (0.9 + 0.35 * Double(i)) * (i == 1 ? -1 : 1)
                let swell = h * 0.3 * CGFloat(0.65 + 0.35 * sin(t * 0.8 + Double(i) * 2))
                for x in stride(from: 0, through: w, by: 2) {
                    let y = h / 2 + CGFloat(sin(Double(x / (h * (0.8 + 0.26 * CGFloat(i)))) + Double(i) * 2 + phase)) * swell
                    if x == 0 { ctx.move(to: CGPoint(x: x, y: y)) } else { ctx.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.setStrokeColor(cg(i, alpha: 0.9))
                ctx.strokePath()
            }

        case .flame:
            // Each tongue flickers around its own height; sparks rise off the top.
            let step = h * 0.3
            for k in 0..<Int(w / step) {
                let base = abs(sin(Double(k) * 1.7) * cos(Double(k) * 0.6))
                let flicker = abs(sin(Double(k) * 1.7 + t * (3 + sin(Double(k)))) * cos(Double(k) * 0.6 - t * 1.9))
                let level = 0.55 * base + 0.45 * flicker
                let height = h * (0.25 + 0.75 * level)
                fill(Path(roundedRect: CGRect(x: CGFloat(k) * step, y: h - height, width: step * 0.6, height: height),
                          cornerRadius: step * 0.3), cg(level > 0.7 ? 2 : level > 0.38 ? 1 : 0))
            }
            for k in 0..<Int(w / (h * 2.2)) {
                let seed = Double(k) * 0.618_034
                let rise = (t * (0.5 + 0.3 * sin(seed * 7)) + seed).truncatingRemainder(dividingBy: 1)
                let x = (CGFloat(k) + 0.5) * h * 2.2 + CGFloat(sin(t * 2 + seed * 17)) * h * 0.3
                let r = h * 0.06
                ctx.setFillColor(cg(2, alpha: 1 - rise))
                ctx.fillEllipse(in: CGRect(x: x - r, y: h * CGFloat(0.9 - 0.9 * rise) - r, width: 2 * r, height: 2 * r))
            }

        case .plasma:
            if let image = plasma(theme, time: time, size: size) {
                // Images draw bottom-up: turn the context back for this one.
                ctx.saveGState()
                ctx.translateBy(x: 0, y: h)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(origin: .zero, size: size))
                ctx.restoreGState()
            }

        case .screen:
            for y in stride(from: 1, to: h, by: 3) {
                fill(CGRect(x: 0, y: y, width: w, height: 1), cg(1, alpha: 0.25))
            }
            let text = line("READY.", font: NSFont.monospacedSystemFont(ofSize: h * 0.48, weight: .regular))
            let origin = CGPoint(x: h * 0.3, y: (h - text.height) / 2)
            ctx.setFillColor(cg(0))
            draw(text, in: ctx, topLeft: origin)
            if Int(time * 3).isMultiple(of: 2) {
                fill(CGRect(x: origin.x + text.width + h * 0.08, y: h * 0.25, width: h * 0.3, height: h * 0.52), cg(0))
            }

        case .starfield:
            // A camera flying through a fixed cube of stars that wraps around
            // it, while it turns, nods and banks, like the demoscene
            // starfields (Triton's Crystal Dream): the stars sweep across on
            // curved paths. Crisp points, white near to graphite far.
            let yaw = t * 0.12 + sin(t * 0.21) * 0.9
            let pitch = sin(t * 0.15) * 0.35
            let roll = sin(t * 0.09) * 0.5
            let (cy, sy) = (cos(yaw), sin(yaw))
            let (cp, sp) = (cos(pitch), sin(pitch))
            let (cr, sr) = (cos(roll), sin(roll))
            let camera = SIMD3(sin(t * 0.05) * 3, sin(t * 0.07) * 2, t * 0.3)
            // Wide and short: the strip sees about 90° across and 30° up.
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
                let side: CGFloat = near > 0.75 ? 2 : 1
                fill(CGRect(x: px.rounded(.down), y: py.rounded(.down), width: side, height: side),
                     cg(near > 0.6 ? 0 : near > 0.3 ? 1 : 2, alpha: min(1, 0.35 + near)))
            }

        case .scroller:
            // A sine scroller: chunky letters running right to left, each
            // riding a sine wave and colored by where it is on the strip,
            // through the three voices' colors.
            let font = NSFont.monospacedSystemFont(ofSize: h * 0.62, weight: .black)
            let advance = h * 0.42
            let offset = CGFloat(t) * h * 2.2
            let first = Int((offset / advance).rounded(.down))
            for slot in first...(first + Int(w / advance) + 1) {
                let x = CGFloat(slot) * advance - offset
                let letter = scrollText[((slot % scrollText.count) + scrollText.count) % scrollText.count]
                guard letter != " " else { continue }
                let y = h * 0.42 + CGFloat(sin(Double(x / h) * 0.9 + t * 3)) * h * 0.2
                let along = max(0, min(x / w, 1)) * 2
                let i = min(Int(along), 1)
                let glyph = line(String(letter), font: font)
                ctx.setFillColor(cg(v[i].mix(with: v[i + 1], by: Double(along) - Double(i))))
                draw(glyph, in: ctx, topLeft: CGPoint(x: x - glyph.width / 2, y: y - glyph.height / 2))
            }
        }
    }

    /// Abyss's demoscene plasma, worked out at one sample per 2 points and
    /// drawn smoothed as one image. Four sine fields (across, along,
    /// diagonal, and rings around a wandering center) add up to a value that
    /// picks a color from a slowly cycling loop through the three voices'
    /// colors; the troughs sink into the background, so it stays dark.
    private static func plasma(_ theme: VoiceTheme, time: Double, size: CGSize) -> CGImage? {
        let cols = max(Int(size.width / 2), 1), rows = max(Int(size.height / 2), 1)
        let t = time.truncatingRemainder(dividingBy: 3600)
        let unit = Double(rows)
        let center = (x: Double(cols) / unit * (0.5 + 0.35 * sin(t * 0.23)), y: 0.5 + 0.8 * cos(t * 0.31))
        let loop = (theme.voices + [theme.voices[0]]).map { (r: $0.red, g: $0.green, b: $0.blue) }
        let bg = (r: theme.background.red, g: theme.background.green, b: theme.background.blue)
        var bytes = [UInt8](repeating: 255, count: cols * rows * 4)
        for row in 0..<rows {
            let y = (Double(row) + 0.5) / unit
            for col in 0..<cols {
                let x = (Double(col) + 0.5) / unit
                let v = sin(x * 1.1 + t * 0.9) + sin(y * 3 - t * 0.7) + sin(x * 0.6 + y * 2 + t * 1.1)
                    + sin(hypot(x - center.x, y - center.y) * 2.4 - t * 1.5)
                var u = (v * 0.125 + 0.5 + t * 0.04).truncatingRemainder(dividingBy: 1)
                if u < 0 { u += 1 }
                u *= 3
                let i = min(Int(u), 2)
                let f = u - Double(i), s = f * f * (3 - 2 * f)
                let (a, b) = (loop[i], loop[i + 1])
                let light = 0.5 + 0.5 * sin(v * 1.6)
                let k = 0.25 + 0.75 * light * light
                let n = (row * cols + col) * 4
                func channel(_ pa: Double, _ pb: Double, _ pg: Double) -> UInt8 {
                    let hue = pa + (pb - pa) * s
                    return UInt8(min(max(pg + (hue - pg) * k, 0), 1) * 255)
                }
                bytes[n] = channel(a.r, b.r, bg.r)
                bytes[n + 1] = channel(a.g, b.g, bg.g)
                bytes[n + 2] = channel(a.b, b.b, bg.b)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The glow around a lit bar: what a Gaussian blur of `rect`, rounded
    /// to a capsule, would look like. Core Graphics has no blur, so it's
    /// three gradients that follow the blur's falloff: a band across the
    /// straight part and a half disc at each end.
    private static func capsuleGlow(_ ctx: CGContext, rect: CGRect, sigma: CGFloat, rgb: (Double, Double, Double), alpha: Double) {
        guard sigma > 0, alpha > 0, rect.width > rect.height else { return }
        let half = Double(rect.height / 2)
        let s = Double(sigma)
        func cdf(_ x: Double) -> Double { 0.5 * (1 + erf(x / 2.squareRoot())) }
        func blurred(_ p: Double) -> Double { cdf((half - p) / s) - cdf((-half - p) / s) }
        let outer = CGFloat(half + 2.6 * s)
        let stops = 16
        // From the center line (or an end's center) out to where it's gone.
        let outward = (0...stops).map { k -> CGColor in
            let p = Double(outer) * Double(k) / Double(stops)
            // Less what's left at the far end, so it fades to nothing there.
            return CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha * max(blurred(p) - blurred(Double(outer)), 0))
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let radial = CGGradient(colorsSpace: space, colors: outward as CFArray, locations: nil),
              let linear = CGGradient(colorsSpace: space, colors: (outward.reversed() + outward.dropFirst()) as CFArray, locations: nil)
        else { return }
        let (left, right) = (rect.minX + rect.height / 2, rect.maxX - rect.height / 2)

        ctx.saveGState()
        ctx.clip(to: CGRect(x: left, y: rect.midY - outer, width: right - left, height: 2 * outer))
        ctx.drawLinearGradient(linear, start: CGPoint(x: left, y: rect.midY - outer), end: CGPoint(x: left, y: rect.midY + outer), options: [])
        ctx.restoreGState()
        for (x, clip) in [(left, CGRect(x: left - outer, y: rect.midY - outer, width: outer, height: 2 * outer)),
                          (right, CGRect(x: right, y: rect.midY - outer, width: outer, height: 2 * outer))] {
            ctx.saveGState()
            ctx.clip(to: clip)
            ctx.drawRadialGradient(radial, startCenter: CGPoint(x: x, y: rect.midY), startRadius: 0,
                                   endCenter: CGPoint(x: x, y: rect.midY), endRadius: outer, options: [])
            ctx.restoreGState()
        }
    }

    private struct TextLine {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let height: CGFloat
    }

    /// A line of text that takes the context's fill color.
    private static func line(_ string: String, font: NSFont) -> TextLine {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return TextLine(line: line, width: width, ascent: ascent, height: ascent + descent + leading)
    }

    private static func draw(_ text: TextLine, in ctx: CGContext, topLeft: CGPoint) {
        // Text draws bottom-up: turn its glyphs back.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: topLeft.x, y: topLeft.y + text.ascent)
        CTLineDraw(text.line, ctx)
    }
}
