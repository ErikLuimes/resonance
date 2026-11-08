import AppKit
import SwiftUI

/// Describe's field, with room around it, and the theme's voice colors
/// walking around its edge.
struct SmartMagicField<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    let submit: () -> Void
    /// Inside the field on the right.
    @ViewBuilder let trailing: Trailing
    /// The field's height, which Refresh beside it shares.
    static var height: CGFloat { 40 }
    @FocusState private var isFocused: Bool
    @Environment(\.voiceTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sectionIsCovered) private var isCovered
    @Environment(\.appearsActive) private var appearsActive
    @Environment(PlayerStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFocused ? AnyShapeStyle(theme.voice(0)) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isFocused)
                .onSubmit(submit)
                .focusEffectDisabled()
            trailing
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: .capsule)
        .background {
            // Reaches past the field for the glow, which is why it's a
            // background: the field's own size doesn't change.
            // Color and movement only while it's being typed in.
            if isFocused {
                SmartWalkingBorder(
                    colors: (0..<3).map { NSColor(theme.voice($0)) },
                    isMoving: !reduceMotion && !isCovered && appearsActive && !store.isShowingNowPlaying
                )
                .padding(-SmartWalkingBorder.reach)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }
        .overlay {
            if !isFocused {
                Capsule()
                    .strokeBorder(.separator)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isFocused)
        .contentShape(.capsule)
        .onTapGesture { isFocused = true }
    }
}

/// The colors walking around a capsule, a sharp line and a soft glow
/// that breathes. Only there while the field has focus. Core Animation
/// moves them, so nothing here redraws: a blurred view redrawn by the app took so
/// much CPU that the visualizers' badge stalled.
///
/// A gradient that turns about the center, seen through the edge. Squashed to
/// the field's shape, so the colors travel evenly along its long sides.
struct SmartWalkingBorder: NSViewRepresentable {
    /// How far past the field it draws.
    static let reach: CGFloat = 28

    let colors: [NSColor]
    /// Whether anything's covering it, or motion is off.
    let isMoving: Bool

    func makeNSView(context: Context) -> WalkingBorderView { WalkingBorderView() }

    func updateNSView(_ view: WalkingBorderView, context: Context) {
        view.update(colors: colors, isMoving: isMoving)
    }
}

final class WalkingBorderView: NSView {
    private let line = EdgeGradient()
    private let halo = EdgeGradient()
    private var isRunning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(halo.holder)
        layer?.addSublayer(line.holder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(colors: [NSColor], isMoving: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.setColors(colors)
        halo.setColors(colors)
        // What it rests at: a breath moves from here and back.
        halo.holder.opacity = 0.55
        CATransaction.commit()
        self.isRunning = isMoving
        applyMotion()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        let edge = bounds.insetBy(dx: SmartWalkingBorder.reach, dy: SmartWalkingBorder.reach)
        // A capsule: never more than half the height, which CGPath refuses.
        let radius = max(min(edge.height, edge.width) / 2, 0)
        let outline = CGPath(roundedRect: edge, cornerWidth: radius, cornerHeight: radius, transform: nil)
        line.place(in: bounds, mask: {
            let mask = CAShapeLayer()
            mask.path = outline
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            mask.lineWidth = 1.5
            mask.contentsScale = scale
            return mask
        }())
        halo.place(in: bounds, mask: {
            // The shadow of the edge's line, which the shadow path keeps cheap.
            let mask = CALayer()
            mask.shadowPath = outline.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 1)
            mask.shadowColor = NSColor.black.cgColor
            mask.shadowOpacity = 1
            mask.shadowRadius = 11
            mask.shadowOffset = .zero
            return mask
        }())
        CATransaction.commit()
        applyMotion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMotion()
    }

    private func applyMotion() {
        let running = isRunning && window != nil
        line.setRunning(running)
        halo.setRunning(running)
        halo.setBreathing(running)
    }
}

/// A turning gradient, seen through `mask`.
private final class EdgeGradient {
    let holder = CALayer()
    private let squash = CALayer()
    private let gradient = CAGradientLayer()
    private static let key = "turn"

    init() {
        holder.addSublayer(squash)
        squash.addSublayer(gradient)
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
    }

    func setColors(_ colors: [NSColor]) {
        let cg = colors.map(\.cgColor)
        gradient.colors = cg + cg.prefix(1)
    }

    func place(in bounds: CGRect, mask: CALayer) {
        holder.frame = bounds
        mask.frame = holder.bounds
        // A new mask has no breath yet, so let it start again.
        holder.removeAnimation(forKey: "breath")
        holder.mask = mask
        squash.frame = holder.bounds
        // A square, wide enough to cover the height as it turns, stretched to
        // the width: the colors then take as long along each stretch of edge.
        let side = max(bounds.height, 1) * 1.5
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let stretch = max(bounds.width, 1) / max(bounds.height, 1)
        // Applied about the layer's center, which is the gradient's too.
        squash.sublayerTransform = CATransform3DMakeScale(stretch, 1, 1)
    }

    /// A slow glow outward: brighter and wider, about every 3.5 seconds.
    func setBreathing(_ breathing: Bool) {
        guard breathing else {
            holder.removeAnimation(forKey: "breath")
            holder.mask?.removeAnimation(forKey: "breath")
            return
        }
        guard holder.animation(forKey: "breath") == nil else { return }
        let brighter = CABasicAnimation(keyPath: "opacity")
        brighter.fromValue = 0.35
        brighter.toValue = 0.9
        let wider = CABasicAnimation(keyPath: "shadowRadius")
        wider.fromValue = 8
        wider.toValue = 15
        for (animation, layer) in [(brighter, holder), (wider, holder.mask)] as [(CABasicAnimation, CALayer?)] {
            animation.duration = 1.75
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(animation, forKey: "breath")
        }
    }

    func setRunning(_ running: Bool) {
        if running {
            guard gradient.animation(forKey: Self.key) == nil else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 6
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            gradient.add(turn, forKey: Self.key)
        } else {
            gradient.removeAnimation(forKey: Self.key)
        }
    }
}

/// What was understood, as plain text: it rises into place, and a band of the
/// theme's colors passes along it once. It's a new view for new words, so what
/// stays the same doesn't move again.
struct SmartRevealText: View {
    let text: String

    @State private var shown = false
    @State private var sweep: CGFloat = -0.6
    @Environment(\.voiceTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, theme.voice(0), theme.voice(1), theme.voice(2), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: proxy.size.width * sweep)
                }
                .mask(Text(text).font(.callout))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 4)
            .onAppear {
                if reduceMotion {
                    shown = true
                    return
                }
                withAnimation(.easeOut(duration: 0.3)) { shown = true }
                withAnimation(.easeInOut(duration: 1.1).delay(0.1)) { sweep = 1.05 }
            }
    }
}
