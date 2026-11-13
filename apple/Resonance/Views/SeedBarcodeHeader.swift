import AppKit
import SwiftUI

/// Sounds Like's header: while a list is sorted by how alike its tunes sound
/// to one, the Fingerprint column's header is that tune's barcode, so each
/// row's barcode sits right under the one it's compared with, as in the
/// terminal app. A `Table` header only takes text, so the column's title goes
/// clear meanwhile (in `HVSCBrowserView`), and this goes beside the table,
/// finds the column by title and lays the barcode on the header over it,
/// where the rows' barcodes start. It follows the column as it's resized,
/// moved or hidden.
struct SeedBarcodeHeader: NSViewRepresentable {
    /// The seed's traits; nil for the title.
    let traits: [Float]?
    /// The column's title, as the table has it.
    let title: String

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.title = title
        probe.traits = traits
    }

    /// Once, at launch (from `SongTableStyle.install()`).
    static func install() {
        SongTableStyle.swapInherited(NSTableHeaderView.self, #selector(NSView.layout), #selector(NSTableHeaderView.resonance_layout))
    }

    static func dismantleNSView(_ probe: Probe, coordinator: ()) {
        probe.traits = nil
    }

    final class Probe: NSView {
        var title = ""
        var traits: [Float]? {
            didSet { if traits != oldValue { apply() } }
        }

        private weak var table: NSTableView?
        private var barcode: NSHostingView<SoundBarcode>?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// Soon: the Match column comes in the same update as the seed, and
        /// the table only lays out its columns after this.
        private func apply() {
            Task { @MainActor [weak self] in self?.applyNow() }
        }

        private func applyNow() {
            guard let traits, window != nil else { return clear() }
            guard let table = table ?? nearestSongTable(), let header = table.headerView else { return }
            if self.table !== table { observe(table) }
            header.seedProbe = self
            self.table = table
            if barcode == nil {
                let view = PassThroughHostingView(rootView: SoundBarcode(traits: traits))
                header.addSubview(view)
                barcode = view
            }
            barcode?.rootView = SoundBarcode(traits: traits)
            place()
        }

        /// Over the column, where its cells start.
        func place() {
            guard let table, let header = table.headerView, let barcode,
                  let index = table.tableColumns.firstIndex(where: { $0.title == title })
            else { return }
            barcode.isHidden = table.tableColumns[index].isHidden
            let rect = header.headerRect(ofColumn: index)
            let size = SoundBarcode.size
            barcode.frame = NSRect(x: rect.minX + cellInset(table, index), y: (rect.midY - size.height / 2).rounded(),
                                   width: size.width, height: size.height)
            // Above the header's own column views, which it may add after.
            if header.subviews.last !== barcode {
                header.addSubview(barcode, positioned: .above, relativeTo: nil)
            }
        }

        /// How far the column's cells start from its edge: a row's cell, or
        /// where AppKit puts one.
        private func cellInset(_ table: NSTableView, _ index: Int) -> CGFloat {
            let column = table.rect(ofColumn: index)
            let row = table.rows(in: table.visibleRect).location
            if row < table.numberOfRows, let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) {
                return table.convert(cell.bounds, from: cell).minX - column.minX
            }
            return table.frameOfCell(atColumn: index, row: 0).minX - column.minX
        }

        private func observe(_ table: NSTableView) {
            stopObserving()
            let center = NotificationCenter.default
            for name in [NSTableView.columnDidResizeNotification, NSTableView.columnDidMoveNotification] {
                observers.append(center.addObserver(forName: name, object: table, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            if let header = table.headerView {
                header.postsFrameChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: header, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
        }

        private func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        /// The barcode gone; the title comes back with the column's own update.
        private func clear() {
            if table?.headerView?.seedProbe === self { table?.headerView?.seedProbe = nil }
            barcode?.removeFromSuperview()
            barcode = nil
            table = nil
            stopObserving()
        }

        /// The table beside it: the closest one up the view tree.
        private func nearestSongTable() -> NSTableView? {
            var ancestor = superview
            while let view = ancestor {
                if let table = Self.songTable(under: view) { return table }
                ancestor = view.superview
            }
            return nil
        }

        private static func songTable(under view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.isSongTable { return table }
            for subview in view.subviews {
                if let table = songTable(under: subview) { return table }
            }
            return nil
        }
    }

    /// Clicks and drags go to the header under it: sorting, moving and
    /// resizing columns work as before.
    private final class PassThroughHostingView: NSHostingView<SoundBarcode> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension NSTableHeaderView {
    /// The Sounds Like header on it, if any.
    fileprivate var seedProbe: SeedBarcodeHeader.Probe? {
        get { (objc_getAssociatedObject(self, &seedProbeKey) as? WeakProbe)?.probe }
        set { objc_setAssociatedObject(self, &seedProbeKey, newValue.map(WeakProbe.init), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Swapped with `layout()` at launch: calling this name runs AppKit's
    /// original. The header may rebuild its column views as it lays out, so
    /// the barcode goes back on top after.
    @objc fileprivate func resonance_layout() {
        resonance_layout()
        seedProbe?.place()
    }
}

private nonisolated(unsafe) var seedProbeKey: UInt8 = 0

private final class WeakProbe: NSObject {
    weak var probe: SeedBarcodeHeader.Probe?
    init(_ probe: SeedBarcodeHeader.Probe) { self.probe = probe }
}
