import AppKit
import SwiftUI

/// Calls `tick` every frame while `isActive`, from a display link, without
/// SwiftUI hearing about the frame. For a view whose look changes far less
/// often than every frame: `tick` works out what it would show and writes
/// state only when that changed, so SwiftUI updates the window only then.
/// A `TimelineView` in its place updates it every tick, changed or not
/// (see `FrameLinkedNSView`).
///
/// Put it in a `background`; it takes no room and draws nothing.
struct FrameTicker: NSViewRepresentable {
    var framesPerSecond: Int
    var isActive: Bool
    var tick: @MainActor () -> Void

    func makeNSView(context: Context) -> FrameTickerNSView {
        let view = FrameTickerNSView(framesPerSecond: framesPerSecond)
        view.onFrame = tick
        view.isAnimating = isActive
        return view
    }

    func updateNSView(_ view: FrameTickerNSView, context: Context) {
        view.onFrame = tick
        view.isAnimating = isActive
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FrameTickerNSView, context: Context) -> CGSize? {
        .zero
    }
}

final class FrameTickerNSView: FrameLinkedNSView {
    var onFrame: (@MainActor () -> Void)?

    override func frame(_ link: CADisplayLink) {
        onFrame?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
