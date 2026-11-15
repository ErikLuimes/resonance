import AppKit
import PhosphorCore
import SwiftUI

// The playback bar's title, slid with two fingers as Resonance Remote's mini
// player slides with one: the tune before, this one and the next side by
// side, following the trackpad; on lifting far enough the next or previous
// tune plays, with a small tap from the trackpad. The core says which tunes
// those are (`PlayerStore.previousUp` and `nextUp`).

/// The bar's title and composer, as they slide.
struct BarTitles: Equatable {
    let title: String
    let author: String
}

/// Three titles side by side, `drag` moving them, the edges faded only
/// while they move.
struct BarTitleStrip: View {
    let previous: BarTitles?
    let current: BarTitles
    let next: BarTitles?
    let drag: CGFloat
    @Binding var width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            if let previous { line(previous).offset(x: drag - width).accessibilityHidden(true) }
            line(current).offset(x: drag)
            if let next { line(next).offset(x: drag + width).accessibilityHidden(true) }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .mask {
            let edge: Color = drag == 0 ? .black : .clear
            LinearGradient(stops: [
                .init(color: edge, location: 0),
                .init(color: .black, location: 0.05),
                .init(color: .black, location: 0.92),
                .init(color: edge, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            .animation(.easeOut(duration: 0.2), value: drag == 0)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
    }

    private func line(_ titles: BarTitles) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(titles.title).font(.headline)
            Text(titles.author).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// Two-finger horizontal swipes over the view it sits behind. A local event
/// monitor reads the trackpad's scroll phases; only gestures that start
/// over this view and go sideways more than up or down are taken, so the
/// lists keep their vertical scrolling. Momentum after lifting is ignored.
struct TwoFingerSwipe: NSViewRepresentable {
    enum Swipe {
        /// Sideways, in points from where it started (right is positive).
        case moved(CGFloat)
        /// Lifted.
        case ended(CGFloat)
    }

    let swiped: (Swipe) -> Void

    func makeNSView(context: Context) -> Catcher {
        let catcher = Catcher()
        catcher.swiped = swiped
        return catcher
    }

    func updateNSView(_ catcher: Catcher, context: Context) {
        catcher.swiped = swiped
    }

    final class Catcher: NSView {
        var swiped: ((Swipe) -> Void)?
        private var monitor: Any?
        /// The gesture this view took, and how far it has gone.
        private var tracking = false
        private var deciding = false
        private var total: CGFloat = 0
        private var vertical: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        /// True when the event is this view's.
        private func handle(_ event: NSEvent) -> Bool {
            // Only the trackpad's own gesture, not momentum or a mouse wheel.
            guard event.window === window, event.momentumPhase == [], event.hasPreciseScrollingDeltas else {
                return tracking && event.momentumPhase != []
            }
            if event.phase.contains(.began) {
                let point = convert(event.locationInWindow, from: nil)
                guard bounds.contains(point) else { return false }
                deciding = true
                tracking = false
                total = 0
                vertical = 0
            }
            if deciding {
                total += event.scrollingDeltaX
                vertical += event.scrollingDeltaY
                // Decided after a few points: sideways takes it, else it's
                // the page's.
                if abs(total) + abs(vertical) > 6 {
                    deciding = false
                    tracking = abs(total) > abs(vertical)
                    if !tracking { return false }
                } else {
                    return false
                }
                swiped?(.moved(total))
                return true
            }
            guard tracking else { return false }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                tracking = false
                swiped?(.ended(total))
                return true
            }
            total += event.scrollingDeltaX
            swiped?(.moved(total))
            return true
        }
    }
}

extension PlaylistItem {
    var barTitles: BarTitles {
        BarTitles(title: title, author: author.isEmpty ? String(localized: "Unknown Composer") : author)
    }
}
