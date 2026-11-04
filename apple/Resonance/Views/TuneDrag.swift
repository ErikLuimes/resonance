import AppKit
import SwiftUI
import Synchronization

/// The drag image for tunes dragged out of a list. SwiftUI's table rows
/// drag without one on macOS: `TableRow.draggable` takes no preview, and
/// the image AppKit makes from rows SwiftUI draws comes out empty. So this
/// fills it in where AppKit starts the drag: each row notes its tune as it
/// hands over its payload, and the table's drag start (NSTableView's
/// `draggingSession(_:willBeginAt:)`, swapped for ours at launch) shows a
/// card naming them.
nonisolated enum TuneDrag {
    struct Tune: Sendable {
        let path: String
        let title: String
        let author: String
    }

    /// The tunes whose payloads were asked for since the last drag began.
    private static let pending = Mutex<[Tune]>([])

    /// A row's payload, noting its tune for the drag image. Only with the
    /// mouse down: a payload asked for any other time isn't a drag.
    static func payload(path: String, title: String, author: String, from: String? = nil) -> PlaylistRowDrag {
        if NSEvent.pressedMouseButtons & 1 != 0 {
            pending.withLock { tunes in
                if !tunes.contains(where: { $0.path == path }) {
                    tunes.append(Tune(path: path, title: title, author: author))
                }
            }
        }
        return PlaylistRowDrag(path: path, from: from)
    }

    /// Swap NSTableView's drag start for one that dresses the drag. Once,
    /// at launch.
    @MainActor static func install() {
        guard let original = class_getInstanceMethod(
                  NSTableView.self, #selector(NSTableView.draggingSession(_:willBeginAt:))),
              let dressed = class_getInstanceMethod(
                  NSTableView.self, #selector(NSTableView.resonance_draggingSession(_:willBeginAt:)))
        else { return }
        method_exchangeImplementations(original, dressed)
    }

    /// Give a drag of tunes their card, at the pointer; the rows' own
    /// (empty) images go.
    @MainActor fileprivate static func dress(_ session: NSDraggingSession, from table: NSTableView, at screenPoint: NSPoint) {
        let tunes = pending.withLock { tunes in
            defer { tunes = [] }
            return tunes
        }
        guard !tunes.isEmpty, let window = table.window else { return }
        let renderer = ImageRenderer(content: TuneDragPreview(tunes: tunes))
        renderer.scale = window.backingScaleFactor
        guard let image = renderer.nsImage else { return }
        let pointer = table.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let frame = NSRect(x: pointer.x - 16, y: pointer.y - image.size.height / 2,
                           width: image.size.width, height: image.size.height)
        session.draggingFormation = .none
        var first = true
        session.enumerateDraggingItems(options: .clearNonenumeratedImages, for: table,
                                       classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            if first {
                item.setDraggingFrame(frame, contents: image)
                first = false
            } else {
                item.imageComponentsProvider = { [] }
            }
        }
    }
}

extension NSTableView {
    /// Swapped with `draggingSession(_:willBeginAt:)` at launch: calling
    /// this name runs AppKit's original.
    @objc fileprivate func resonance_draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        resonance_draggingSession(session, willBeginAt: screenPoint)
        TuneDrag.dress(session, from: self, at: screenPoint)
    }
}

/// The card: the title (and composer) of one tune, or how many.
private struct TuneDragPreview: View {
    let tunes: [TuneDrag.Tune]

    var body: some View {
        Label {
            if tunes.count == 1, let tune = tunes.first {
                Text(tune.title).fontWeight(.semibold) + Text("  \(tune.author)").foregroundStyle(.secondary)
            } else {
                Text("\(tunes.count) tunes").fontWeight(.semibold)
            }
        } icon: {
            Image(systemName: tunes.count == 1 ? "music.note" : "music.note.list")
                .foregroundStyle(.tint)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // ImageRenderer draws no materials: a plain background, outlined.
        .background(Color(nsColor: .windowBackgroundColor), in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .frame(maxWidth: 320)
        .padding(2)
    }
}

/// Turns off the sidebar's own drop highlight: AppKit's, in the outline
/// view under SwiftUI's list, which lit only parts of a row (and SwiftUI's
/// target another part, in another style). `PlaylistDrop` draws one over
/// the whole row instead. Sits in a sidebar row, to find the outline view.
struct SidebarDropHighlightOff: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) { probe.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            var view = superview
            while let candidate = view, !(candidate is NSTableView) { view = candidate.superview }
            (view as? NSTableView)?.draggingDestinationFeedbackStyle = .none
        }
    }
}
