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

    /// The tint would vanish on the selection.
    private var style: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint)
    }

    var body: some View {
        ZStack {
            if isHovered {
                button
            } else if isCurrent {
                VoiceBars(feed: feed, isActive: isPlaying)
                    .foregroundStyle(style)
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
            if isCurrent {
                PlayingRowMark()
            }
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
struct VoiceBars: View {
    let feed: VisualizerFeed
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var meter = RowVoiceMeter()

    var body: some View {
        // A small thing in a list: half the visualizers' rate looks the same.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive || reduceMotion)) { context in
            let frame = isActive && !reduceMotion ? feed.latest() : nil
            let reading = meter.update(levels: frame?.chips.first?.voices.map { Double($0.envLevel) }, at: context.date)
            Canvas { canvas, size in
                Self.draw(reading, in: &canvas, size: size)
            }
        }
        .frame(width: 14, height: 14)
    }

    /// Proportions from the mark (Assets: MenuBarIcon): bars 150 wide with
    /// gaps of 70, in 590, and the peak's line 34 tall in 622.
    private static func draw(_ reading: RowVoiceMeter.Reading, in canvas: inout GraphicsContext, size: CGSize) {
        let barWidth = size.width * 150 / 590
        let step = size.width * 220 / 590
        let peakHeight = max(size.height * 34 / 622, 1)
        let gap = size.height * 48 / 622
        let room = size.height - peakHeight - gap
        for voice in reading.bars.indices {
            let x = CGFloat(voice) * step
            let barHeight = max(room * reading.bars[voice], 1)
            let bar = CGRect(x: x, y: size.height - barHeight, width: barWidth, height: barHeight)
            canvas.fill(Path(roundedRect: bar, cornerRadius: min(barWidth * 0.24, barHeight / 2)), with: .foreground)
            let peakTop = room * (1 - reading.peaks[voice])
            let peak = CGRect(x: x, y: peakTop, width: barWidth, height: peakHeight)
            canvas.fill(Path(roundedRect: peak, cornerRadius: peakHeight / 2), with: .foreground)
        }
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
