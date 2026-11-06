import AppKit
import SwiftUI

/// The selection in song tables: the accent colour while the table is active,
/// and the sidebar's quiet gray when it isn't. SwiftUI's `Table` has no setting
/// for it, so this takes over where the row view draws it
/// (`NSTableRowView.drawSelection(in:)`, swapped at launch). Other lists keep
/// the system's. The row playing gets a faint wash of the accent, drawn the
/// same way: a cell can't colour its whole row.
///
/// It also makes a click on a row activate the table. A row's cells take the
/// click themselves: the row gets selected, but the table only became active
/// from a click beside the rows, so a selection often stayed inactive.
///
/// And a song table doesn't bounce sideways. SwiftUI's `Table` has no setting
/// for that either, so it's set on the table's scroll view as it appears.
enum SongTableStyle {
    /// Once, at launch.
    static func install() {
        guard let original = class_getInstanceMethod(
                  NSTableRowView.self, #selector(NSTableRowView.drawSelection(in:))),
              let ours = class_getInstanceMethod(
                  NSTableRowView.self, #selector(NSTableRowView.resonance_drawSelection(in:)))
        else { return }
        method_exchangeImplementations(original, ours)
        swap(NSTableRowView.self, #selector(NSTableRowView.draw(_:)), #selector(NSTableRowView.resonance_draw(_:)))
        swapInherited(NSTableView.self, #selector(NSTableView.viewDidMoveToWindow), #selector(NSTableView.resonance_viewDidMoveToWindow))
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            activateTable(under: event)
            return event
        }
    }

    private static func swap(_ type: AnyClass, _ original: Selector, _ ours: Selector) {
        guard let first = class_getInstanceMethod(type, original), let second = class_getInstanceMethod(type, ours) else { return }
        method_exchangeImplementations(first, second)
    }

    /// For a method `type` gets from its superclass. It gets its own copy first,
    /// or the swap would change the superclass, and every view with it.
    private static func swapInherited(_ type: AnyClass, _ original: Selector, _ ours: Selector) {
        guard let inherited = class_getInstanceMethod(type, original) else { return }
        class_addMethod(type, original, method_getImplementation(inherited), method_getTypeEncoding(inherited))
        swap(type, original, ours)
    }

    private static func activateTable(under event: NSEvent) {
        guard let window = event.window, let content = window.contentView,
              let frame = content.superview,
              let hit = content.hitTest(frame.convert(event.locationInWindow, from: nil))
        else { return }
        var view: NSView? = hit
        while let candidate = view, !(candidate is NSTableView) { view = candidate.superview }
        if let table = view as? NSTableView, table.isSongTable, window.firstResponder !== table {
            window.makeFirstResponder(table)
        }
    }

    /// As the system insets its own selection in an inset table.
    fileprivate static let inset: CGFloat = 10
    fileprivate static let radius: CGFloat = 6
    /// As the sidebar's selected row looks: a wash of the text colour.
    fileprivate static let inactiveOpacity: CGFloat = 0.15
    fileprivate static let playingOpacity: CGFloat = 0.16
}

extension NSTableView {
    /// SwiftUI's class for a `Table`, not a `List`. Should it get another name
    /// in a later macOS, these tables simply go back to the system's ways.
    fileprivate var isSongTable: Bool { String(describing: type(of: self)) == "SwiftUIOutlineTableView" }

    /// Swapped with `viewDidMoveToWindow()` at launch: calling this name runs
    /// AppKit's original.
    @objc fileprivate func resonance_viewDidMoveToWindow() {
        resonance_viewDidMoveToWindow()
        if isSongTable { enclosingScrollView?.horizontalScrollElasticity = .none }
    }
}

extension NSTableRowView {
    private var isInSongTable: Bool {
        var view = superview
        while let candidate = view, !(candidate is NSTableView) { view = candidate.superview }
        return (view as? NSTableView)?.isSongTable ?? false
    }

    /// Swapped with `draw(_:)` at launch: calling this name runs AppKit's
    /// original. What's drawn here is under the row's cells.
    @objc fileprivate func resonance_draw(_ dirtyRect: NSRect) {
        resonance_draw(dirtyRect)
        guard !isSelected, isInSongTable, holdsCurrentMark else { return }
        NSColor.controlAccentColor.withAlphaComponent(SongTableStyle.playingOpacity).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: SongTableStyle.inset, dy: 0),
                     xRadius: SongTableStyle.radius, yRadius: SongTableStyle.radius).fill()
    }

    /// Whether this is the row that's playing.
    var holdsCurrentMark: Bool { containsCurrentMark(self) }

    private func containsCurrentMark(_ view: NSView) -> Bool {
        (view as? PlayingRowMark.Mark)?.isCurrent == true || view.subviews.contains(where: containsCurrentMark)
    }

    /// Swapped with `drawSelection(in:)` at launch: calling this name runs
    /// AppKit's original.
    @objc fileprivate func resonance_drawSelection(in dirtyRect: NSRect) {
        guard isInSongTable else {
            resonance_drawSelection(in: dirtyRect)
            return
        }
        (isEmphasized ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(SongTableStyle.inactiveOpacity)).setFill()
        // Selected neighbours join up: the rounded end goes past the row,
        // where the clip cuts it off.
        var shape = bounds.insetBy(dx: SongTableStyle.inset, dy: 0)
        let reach = SongTableStyle.radius
        let lowEnd = isFlipped ? isPreviousRowSelected : isNextRowSelected
        let highEnd = isFlipped ? isNextRowSelected : isPreviousRowSelected
        if lowEnd {
            shape.origin.y -= reach
            shape.size.height += reach
        }
        if highEnd {
            shape.size.height += reach
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        NSBezierPath(roundedRect: shape, xRadius: reach, yRadius: reach).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Goes in a row's cell, and tells the row whether to draw its wash. The row
/// looks for it as it draws, so a row reused while scrolling can't keep a wash
/// from before. It's in every row, and only its value changes: when it came and
/// went, the row could redraw while SwiftUI was still removing it, find it, and
/// keep the wash until something else redrew the row.
struct PlayingRowMark: NSViewRepresentable {
    let isCurrent: Bool

    func makeNSView(context: Context) -> Mark { Mark() }
    func updateNSView(_ mark: Mark, context: Context) { mark.isCurrent = isCurrent }

    final class Mark: NSView {
        var isCurrent = false {
            didSet {
                if isCurrent != oldValue { redrawRow() }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { redrawRow() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            redrawRow()
        }

        /// Soon: when it's leaving, it's still in the row just now, and a value
        /// arrives in the middle of SwiftUI's update.
        private func redrawRow() {
            guard let row else { return }
            Task { @MainActor in row.needsDisplay = true }
        }

        private var row: NSView? {
            var view = superview
            while let candidate = view, !(candidate is NSTableRowView) { view = candidate.superview }
            return view
        }
    }
}

/// A song table's Author cell: HVSC's "<?>" for a composer no one knows, in
/// words and muted.
struct AuthorCell: View {
    let author: String

    var body: some View {
        if author == "<?>" {
            Text("Unknown")
                .foregroundStyle(.secondary)
        } else {
            Text(author)
        }
    }
}
