import AppKit

/// A layer-backed view that gets a call every frame, for drawings that
/// move all the time and are made of Core Animation layers. SwiftUI never
/// hears about a frame. A `TimelineView` with a `Canvas` in the same place
/// makes the window run its layout pass and SwiftUI update its whole
/// hosting view every frame, which costs several times what the drawing
/// does; and drawing a frame with Core Graphics instead rasterizes it on
/// the main thread, which costs about as much again. Layers whose paths
/// and strings change are drawn by the window server.
///
/// Subclass it, add sublayers, override `frame(_:)` to move them, and
/// switch `isAnimating`. It stops by itself while its window is covered.
class FrameLinkedNSView: NSView {
    /// False holds the last frame.
    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            updateLink()
        }
    }

    private let framesPerSecond: Float
    private var link: CADisplayLink?

    init(framesPerSecond: Int) {
        self.framesPerSecond = Float(framesPerSecond)
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called on the main thread every frame while it's animating. Implicit
    /// animations are off: what's set shows in the next frame.
    func frame(_ link: CADisplayLink) {}

    /// The window's pixels per point changed, or it has a window now.
    func scaleChanged(to scale: CGFloat) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            scaleChanged(to: window.backingScaleFactor)
        }
        updateLink()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window { scaleChanged(to: window.backingScaleFactor) }
    }

    @objc private func occlusionChanged() {
        updateLink()
    }

    /// Runs only while it should move and its window can be seen.
    private func updateLink() {
        if isAnimating, let window, window.occlusionState.contains(.visible) {
            guard link == nil else { return }
            let link = displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: framesPerSecond, maximum: framesPerSecond,
                                                            preferred: framesPerSecond)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame(link)
        CATransaction.commit()
    }
}
