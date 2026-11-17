import AppKit
import PhosphorCore
import SwiftUI
import UniformTypeIdentifiers


/// Share Clip…: a short video of Now Playing's visualizer with its sound,
/// to post or send. Choose the
/// shape, the length and the part, make it, then save or share it.
struct ClipSheet: View {
    let visual: NowPlayingVisual

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.clipShape) private var shape = ClipMaker.Shape.square
    @AppStorage(Pref.clipLength) private var length = ClipMaker.defaultLength
    @State private var maker = ClipMaker()
    @State private var start: Double = 0
    @State private var context: Context?
    @State private var still: CGImage?
    /// What `still` shows; it dims when that's not the clip as set.
    @State private var stillShows: StillKey?
    /// While the strip is dragged, the still waits.
    @State private var dragging = false
    @State private var saved: URL?
    @State private var moreAnchor: NSView?

    /// What's fixed while the sheet is open: the tune, where it was when
    /// the sheet opened, and its link.
    private struct Context {
        let track: TrackDetails
        /// Seconds into the subtune being heard when the sheet opened.
        let heard: Double
        let duration: Double
        let link: URL?
        let hvscPath: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share a Clip").font(.headline)
                if let context {
                    Text(verbatim: "\(visual.title) · \(plan(context).title) — \(plan(context).composer)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            preview
            switch maker.phase {
            case .idle: options
            case .rendering(let done): rendering(done)
            case .finished(let url, let bytes): finished(url, bytes: bytes)
            case .failed(let message): failed(message)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await open() }
        .task(id: stillKey) { await makeStill() }
        .onDisappear { maker.cancel() }
    }

    // MARK: Parts

    private var preview: some View {
        ZStack {
            Color.black.opacity(0.25)
            if let still {
                Image(decorative: still, scale: 1)
                    .resizable()
                    .aspectRatio(shape.size, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 4))
                    .opacity(stillShows == settledKey ? 1 : 0.5)
                    .animation(.easeOut(duration: 0.15), value: stillShows == settledKey)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 300)
        .clipShape(.rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Shape").gridColumnAlignment(.trailing)
                HStack(spacing: 8) {
                    Picker("Shape", selection: $shape) {
                        ForEach(ClipMaker.Shape.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Text(verbatim: "\(Int(shape.size.width)) × \(Int(shape.size.height))")
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Length")
                Picker("Length", selection: $length) {
                    ForEach(ClipMaker.lengths, id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            GridRow(alignment: .top) {
                Text("Which part").padding(.top, 4)
                if let context {
                    ClipRangeStrip(start: $start, dragging: $dragging, length: Double(length),
                                   duration: context.duration, heard: context.heard)
                }
            }
        }
        .onChange(of: length) { old, new in
            guard let context else { return }
            // Still the part just heard, if it was; else the same start.
            start = abs(start - lastHeardStart(context, length: old)) < 0.5
                ? lastHeardStart(context, length: new) : min(start, max(0, context.duration - Double(new)))
        }
        HStack {
            Text("The clip renders on its own; what you're hearing keeps playing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Make Clip") { make() }
                .keyboardShortcut(.defaultAction)
                .disabled(context == nil)
        }
    }

    private func rendering(_ done: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rendering… \(Int(done * Double(length))) of \(length) s")
            ProgressView(value: done)
            HStack {
                Spacer()
                Button("Cancel") { maker.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func finished(_ url: URL, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "\(Int(shape.size.width)) × \(Int(shape.size.height)) · \(length) s · "
                         + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            HStack(spacing: 8) {
                Button("Save…") { save(url) }
                Button("Messages") { share(url, .composeMessage) }
                Button("Mail") { share(url, .composeEmail) }
                Button("AirDrop") { share(url, .sendViaAirDrop) }
                Button("More…") { showMore(url) }
                    .background(ViewAnchor(view: $moreAnchor))
                Spacer()
                // Back to the options, with what was chosen, to make it
                // again differently; this clip is thrown away.
                Button("Back") {
                    saved = nil
                    maker.cancel()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if let saved {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Saved to \(saved.deletingLastPathComponent().lastPathComponent).")
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                            .buttonStyle(.link)
                    }
                    if context?.link != nil {
                        Text("The tune's link is copied, to paste as the caption where you post it.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { make() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Doing

    private func open() async {
        guard let track = store.nowPlaying else { return }
        let heard = store.visualizer.heardSecs ?? store.elapsed
        let duration = max(store.duration ?? heard + 30, heard)
        let link = await store.prepareShare(path: track.path, subtune: Int(track.currentSong))?.url
        let context = Context(track: track, heard: heard, duration: duration, link: link,
                              hvscPath: ClipMaker.Plan.hvscPath(of: track.path, root: store.hvscRoot))
        start = lastHeardStart(context, length: length)
        self.context = context
    }

    /// The part that ends where the tune was when the sheet opened.
    private func lastHeardStart(_ context: Context, length: Int) -> Double {
        // The tune's start if there's less than that before it.
        min(max(0, context.heard - Double(length)), max(0, context.duration - Double(length)))
    }

    private func plan(_ context: Context) -> ClipMaker.Plan {
        ClipMaker.Plan(visual: visual, shape: shape, length: length, start: start, track: context.track,
                       engine: store.engine, forceStereo2sid: store.options.forceStereo2sid, theme: theme,
                       link: context.link, heard: context.heard, hvscPath: context.hvscPath)
    }

    private struct StillKey: Equatable {
        let shape: ClipMaker.Shape
        let start: Double
        let ready: Bool
    }

    /// The clip as set.
    private var settledKey: StillKey {
        StillKey(shape: shape, start: (start * 10).rounded() / 10, ready: context != nil)
    }

    /// What the still should show: nil while the strip is dragged, so
    /// nothing renders until it's let go.
    private var stillKey: StillKey? { dragging ? nil : settledKey }

    private func makeStill() async {
        guard let context, let key = stillKey, key != stillShows else { return }
        // Waits for the options to settle (a length or shape clicked twice).
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        if let image = try? await ClipMaker.still(plan(context), store: store), !Task.isCancelled {
            still = image
            stillShows = key
        }
    }

    private func make() {
        guard let context else { return }
        saved = nil
        maker.start(plan(context), store: store)
    }

    private var subject: String {
        guard let context else { return "" }
        let plan = plan(context)
        return String(localized: "\(plan.title) by \(plan.composer)")
    }

    /// The message beside the clip: the subject, and the link where text
    /// is clickable.
    private var message: String {
        [subject, context?.link?.absoluteString].compactMap(\.self).joined(separator: "\n")
    }

    private func share(_ url: URL, _ name: NSSharingService.Name) {
        guard let service = NSSharingService(named: name) else { return }
        service.subject = subject
        var items: [Any] = [url]
        if name != .sendViaAirDrop {
            items.insert(message, at: 0)
        }
        service.perform(withItems: items)
    }

    /// The system's share menu, given the text and the clip as separate
    /// items: services that take text (Notes, WhatsApp) keep the link,
    /// where `ShareLink`'s message was dropped by most of them.
    private func showMore(_ url: URL) {
        guard let anchor = moreAnchor else { return }
        let picker = NSSharingServicePicker(items: [message as NSString, url])
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func save(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            if let link = context?.link {
                // An upload strips the file's tags, so the link is ready to
                // paste beside it; Finder's Get Info shows it as Where from.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
                Self.setWhereFrom(link, on: destination)
            }
            saved = destination
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

extension ClipSheet {
    /// Finder's "Where from" (`kMDItemWhereFroms`), as Safari sets it on a
    /// download: a binary plist of URLs in an extended attribute.
    nonisolated static func setWhereFrom(_ link: URL, on file: URL) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: [link.absoluteString],
                                                             format: .binary, options: 0) else { return }
        _ = data.withUnsafeBytes { bytes in
            setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, bytes.count, 0, 0)
        }
    }
}

/// An `NSView` behind a SwiftUI view, for AppKit pickers to show from.
private struct ViewAnchor: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.view = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Which part of the tune: the whole length as a strip, the clip as a
/// window on it, dragged to place. A mark shows where the tune was when the
/// sheet opened, and the window snaps to end there.
private struct ClipRangeStrip: View {
    @Binding var start: Double
    @Binding var dragging: Bool
    let length: Double
    let duration: Double
    let heard: Double

    @State private var dragFrom: Double?

    private var lastHeard: Double { max(0, min(heard - length, duration - length)) }
    /// Points either side of the window that still take hold of it.
    private static let grab: CGFloat = 6
    /// Points from "now" within which the window's end snaps to it.
    private static let snap: CGFloat = 8
    private var latest: Double { max(0, duration - length) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let scale = width / max(duration, length)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.35))
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .frame(width: max(8, length * scale))
                        .offset(x: start * scale)
                    Rectangle()
                        .fill(.primary.opacity(0.6))
                        .frame(width: 2)
                        .padding(.vertical, -3)
                        .offset(x: min(heard, duration) * scale - 1)
                }
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragFrom == nil {
                            dragging = true
                            // A press on the window, or near it (a 6 s
                            // window can be a few points wide), takes
                            // hold of it; one elsewhere centers it there.
                            let x = value.startLocation.x
                            let left = start * scale, right = max(left + 8, (start + length) * scale)
                            dragFrom = x >= left - Self.grab && x <= right + Self.grab ? start : x / scale - length / 2
                        }
                        var proposed = (dragFrom ?? start) + value.translation.width / scale
                        // Snaps in points, not seconds: a second is a
                        // point or two of a long tune's strip.
                        if abs(proposed - lastHeard) * scale < Self.snap { proposed = lastHeard }
                        start = min(max(0, proposed), latest)
                    }
                    .onEnded { _ in
                        dragFrom = nil
                        dragging = false
                    })
            }
            .frame(height: 26)
            HStack {
                Text(rangeText)
                Spacer()
                Text(clock(duration))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("Which part")
        .accessibilityValue(rangeText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: start = min(start + 1, latest)
            case .decrement: start = max(start - 1, 0)
            @unknown default: break
            }
        }
    }

    private var rangeText: String {
        let range = "\(clock(start)) – \(clock(start + length))"
        return abs(start - lastHeard) < 0.5 && heard >= length
            ? String(localized: "\(range), the \(Int(length)) seconds you just heard") : range
    }

    private func clock(_ t: Double) -> String {
        Duration.seconds(max(0, t)).formatted(.time(pattern: .minuteSecond))
    }
}
