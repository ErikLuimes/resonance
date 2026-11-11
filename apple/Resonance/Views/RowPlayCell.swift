import AppKit
import PhosphorCore
import SwiftUI

/// A song table's first cell: under the pointer a play button, or pause on the
/// row that's playing; otherwise the voices of what's playing, and the row's
/// number where the list has them.
///
/// Everything comes in as values and closures: table rows built while a list
/// scrolls don't reliably get the environment's stores (see `TuneTitleCell`).
struct RowPlayCell: View {
    let isCurrent: Bool
    let isPlaying: Bool
    let isSelected: Bool
    var number: Int?
    let feed: VisualizerFeed
    /// Plays this row.
    let play: () -> Void
    /// Pauses or resumes what's playing.
    let playPause: () -> Void

    @State private var isHovered = false
    @Environment(\.sectionIsCovered) private var isCovered

    /// The tint would vanish on the selection.
    private var style: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint)
    }

    var body: some View {
        ZStack {
            if isHovered, !isCovered {
                button
            } else if isCurrent {
                VoiceBars(feed: feed, isActive: isPlaying, color: isSelected ? .primary : .tint)
                    .accessibilityLabel(isPlaying ? "Playing" : "Paused")
            } else if let number {
                Text(number, format: .number.grouping(.never))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RowHoverReader(isHovered: $isHovered)
            PlayingRowMark(isCurrent: isCurrent)
        }
    }

    private var button: some View {
        let pauses = isCurrent && isPlaying
        return Button(pauses ? "Pause" : "Play", systemImage: pauses ? "pause.fill" : "play.fill") {
            if isCurrent {
                playPause()
            } else {
                play()
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(style)
        .help(pauses ? "Pause" : "Play")
    }
}

// MARK: - The voices

/// The app's mark, alive: the SID's three voices as bars, each with its peak
/// above it. Still while paused, or when the engine reports no voices.
///
/// Made of layers in an AppKit view, not a `Canvas` in a `TimelineView`
/// (see `FrameLinkedNSView`), so it can't take `foregroundStyle`: say
/// which color with `color`.
struct VoiceBars: View {
    /// What to draw it in.
    enum Tone {
        /// The accent color.
        case tint
        /// The text color, which is white on a selected row.
        case primary
        case white
    }

    let feed: VisualizerFeed
    let isActive: Bool
    var color = Tone.tint

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sectionIsCovered) private var isCovered

    var body: some View {
        VoiceBarsLayerView(feed: feed, isAnimating: isActive && !reduceMotion && !isCovered, tone: color)
            .frame(width: 14, height: 14)
    }
}

private struct VoiceBarsLayerView: NSViewRepresentable {
    let feed: VisualizerFeed
    let isAnimating: Bool
    let tone: VoiceBars.Tone

    func makeNSView(context: Context) -> VoiceBarsNSView {
        let view = VoiceBarsNSView()
        update(view, context)
        return view
    }

    func updateNSView(_ view: VoiceBarsNSView, context: Context) {
        update(view, context)
    }

    private func update(_ view: VoiceBarsNSView, _ context: Context) {
        let environment = context.environment
        let color: Color = switch tone {
        case .white: .white
        case .tint: .accentColor
        case .primary: environment.backgroundProminence == .increased ? .white : .primary
        }
        view.apply(feed: feed, isAnimating: isAnimating, color: color.resolve(in: environment).cgColor)
    }
}

/// A bar and a peak per voice, each a layer that's moved every frame.
private final class VoiceBarsNSView: FrameLinkedNSView {
    private var feed: VisualizerFeed?
    private let meter = RowVoiceMeter()
    private let bars = (0..<3).map { _ in CALayer() }
    private let peaks = (0..<3).map { _ in CALayer() }

    init() {
        // A small thing in a list: half the visualizers' rate looks the same.
        super.init(framesPerSecond: VisualizerFeed.framesPerSecond / 2)
        for part in bars + peaks { layer?.addSublayer(part) }
    }

    func apply(feed: VisualizerFeed, isAnimating: Bool, color: CGColor) {
        self.feed = feed
        for part in bars + peaks where part.backgroundColor != color { part.backgroundColor = color }
        self.isAnimating = isAnimating
        // Still, it's the mark as the icon has it.
        if !isAnimating { place(meter.update(levels: nil, at: .now)) }
    }

    override func layout() {
        super.layout()
        if !isAnimating { place(meter.update(levels: nil, at: .now)) }
    }

    override func frame(_ link: CADisplayLink) {
        let voices = feed?.latest()?.chips.first?.voices
        place(meter.update(levels: voices?.map { Double($0.envLevel) }, at: .now))
    }

    /// Proportions from the mark (Assets: MenuBarIcon): bars 150 wide with
    /// gaps of 70, in 590, and the peak's line 34 tall in 622. The layers'
    /// origin is the bottom left.
    private func place(_ reading: RowVoiceMeter.Reading) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let barWidth = size.width * 150 / 590
        let step = size.width * 220 / 590
        let peakHeight = max(size.height * 34 / 622, 1)
        let gap = size.height * 48 / 622
        let room = size.height - peakHeight - gap
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for voice in reading.bars.indices.prefix(3) {
            let x = CGFloat(voice) * step
            let barHeight = max(room * reading.bars[voice], 1)
            bars[voice].frame = CGRect(x: x, y: 0, width: barWidth, height: barHeight)
            bars[voice].cornerRadius = min(barWidth * 0.24, barHeight / 2)
            peaks[voice].frame = CGRect(x: x, y: room * reading.peaks[voice] + gap, width: barWidth, height: peakHeight)
            peaks[voice].cornerRadius = peakHeight / 2
        }
        CATransaction.commit()
    }
}

/// Bars that rise at once and fall smoothly, and peaks that hold, then fall.
nonisolated final class RowVoiceMeter {
    nonisolated struct Reading: Equatable {
        var bars: [Double]
        var peaks: [Double]
    }

    /// The mark as it's drawn in the icon, for when there's nothing to show.
    static let rest = Reading(bars: [380.0 / 540, 1, 300.0 / 540], peaks: [380.0 / 540, 1, 300.0 / 540])

    private static let floor = 0.08
    private static let barFallPerSecond = 2.4
    private static let peakFallPerSecond = 0.7
    private static let peakHold = 0.35

    private var reading: Reading?
    private var heldSince: [Date] = []
    private var last: Date?

    /// The reading at `date` for voice `levels`, 0–1; nil levels mean there's
    /// nothing playing to follow, and the mark rests.
    func update(levels: [Double]?, at date: Date) -> Reading {
        guard let levels, !levels.isEmpty else {
            reading = nil
            last = nil
            return Self.rest
        }
        let voices = (0..<3).map { $0 < levels.count ? max(Self.floor, min(levels[$0], 1)) : Self.floor }
        guard var now = reading, let last else {
            reading = Reading(bars: voices, peaks: voices)
            heldSince = Array(repeating: date, count: 3)
            self.last = date
            return reading!
        }
        let elapsed = max(date.timeIntervalSince(last), 0)
        for voice in 0..<3 {
            now.bars[voice] = max(voices[voice], now.bars[voice] - Self.barFallPerSecond * elapsed)
            if now.bars[voice] >= now.peaks[voice] {
                now.peaks[voice] = now.bars[voice]
                heldSince[voice] = date
            } else if date.timeIntervalSince(heldSince[voice]) > Self.peakHold {
                now.peaks[voice] = max(now.bars[voice], now.peaks[voice] - Self.peakFallPerSecond * elapsed)
            }
        }
        reading = now
        self.last = date
        return now
    }
}

// MARK: - Hover

/// Whether the pointer is over the whole row this cell is in, not just over
/// the cell.
struct RowHoverReader: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> Reader {
        let reader = Reader()
        reader.report = { inside in isHovered = inside }
        return reader
    }

    func updateNSView(_ reader: Reader, context: Context) {
        reader.report = { inside in isHovered = inside }
    }

    final class Reader: NSView {
        var report: ((Bool) -> Void)?
        private var inside = false
        private weak var row: NSTableRowView?
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let area { row?.removeTrackingArea(area) }
            area = nil
            NotificationCenter.default.removeObserver(self)
            var view = superview
            while let candidate = view, !(candidate is NSTableRowView) { view = candidate.superview }
            row = view as? NSTableRowView
            guard window != nil, let row else {
                set(false)
                return
            }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            row.addTrackingArea(area)
            self.area = area
            // Rows scroll under a pointer that stays still, and get reused.
            if let clip = row.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                                       name: NSView.boundsDidChangeNotification, object: clip)
            }
            recheck()
        }

        override func mouseEntered(with event: NSEvent) { set(true) }
        override func mouseExited(with event: NSEvent) { set(false) }

        @objc private func boundsChanged() { recheck() }

        /// Hit-tested, so a row scrolled under the header above doesn't count.
        private func recheck() {
            guard let row, let window, window.isKeyWindow, let content = window.contentView, let frame = content.superview else {
                set(false)
                return
            }
            let pointer = frame.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            set(content.hitTest(pointer)?.isDescendant(of: row) ?? false)
        }

        private func set(_ value: Bool) {
            guard value != inside else { return }
            inside = value
            // Not during the layout that may have brought it here.
            Task { @MainActor [report] in report?(value) }
        }
    }
}
