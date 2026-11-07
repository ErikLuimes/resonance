import AppKit

/// A progress bar across the Dock icon, while a long job runs. Redraws at
/// most once a percent: the Dock isn't drawn for free, and a bar this size
/// can't show less.
final class DockProgress {
    private var shown: Int?

    /// `fraction` is 0–1; nil puts the plain icon back.
    func show(_ fraction: Double?) {
        let percent = fraction.map { Int((min(max($0, 0), 1) * 100).rounded(.down)) }
        guard percent != shown else { return }
        shown = percent
        let tile = NSApp.dockTile
        if let percent {
            let view = tile.contentView as? DockProgressView
                ?? DockProgressView(frame: CGRect(origin: .zero, size: tile.size))
            view.fraction = Double(percent) / 100
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}

/// The app's icon with the bar over its lower part, inside the icon's edges.
final class DockProgressView: NSView {
    var fraction = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)

        let height = bounds.height * 0.09
        let track = CGRect(x: bounds.width * 0.17, y: bounds.height * 0.17,
                           width: bounds.width * 0.66, height: height)
        // Light, as the icon is dark.
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()

        // Never thinner than its own round ends.
        let inset = height * 0.14
        let inner = track.insetBy(dx: inset, dy: inset)
        let width = max(inner.height, inner.width * fraction)
        let fill = CGRect(origin: inner.origin, size: CGSize(width: width, height: inner.height))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}
