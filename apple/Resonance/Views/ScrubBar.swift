import PhosphorCore
import SwiftUI

/// The progress bar through a tune. On the engines that can seek (reSIDfp
/// and SIDLite direct) a drag or click goes there, the fill following the
/// pointer; on the others it's read-only, and a click opens a note that
/// names the engine and offers the Playback settings. `preview` is the time
/// under the pointer while dragging, or the point just asked for until the
/// player reports it, so the parent's elapsed label can show it.
///
/// While the engine runs to the target, the fill there turns grey (where
/// you'll land) and a solid fill races up to it from where the run started:
/// the emulation's real position (`seekPosition`), like a tape winding.
struct ScrubBar: View {
    let elapsed: TimeInterval
    let duration: TimeInterval?
    let canSeek: Bool
    /// The engine playing, for the note when it can't seek.
    let engine: Engine
    /// The tune has more than one song: the note mentions stepping between them.
    var hasSubtunes = false
    /// The player is running to the point asked for; the fill dims.
    let seeking: Bool
    /// How far it has got, while seeking.
    var seekPosition: TimeInterval?
    /// White on Now Playing's dark background instead of the accent.
    var onDark = false
    @Binding var preview: TimeInterval?
    let seek: (TimeInterval) -> Void

    @Environment(\.openSettings) private var openSettings
    /// The note that this engine can't scrub.
    @State private var explaining = false
    /// While dragging: where the pointer is, 0...1.
    @State private var dragFraction: Double?
    /// Asked for; shown until the player's elapsed time reaches it.
    @State private var pending: TimeInterval?
    @State private var pendingTimeout: Task<Void, Never>?

    private func clamped(_ t: TimeInterval) -> Double? {
        guard let duration, duration > 0 else { return nil }
        return min(max(t / duration, 0), 1)
    }

    /// Where you're going, 0...1: under the pointer, just asked for, or
    /// where the engine is heading. Nil while simply playing.
    private var target: Double? {
        if let dragFraction { return dragFraction }
        if let pending { return clamped(pending) }
        if seeking { return clamped(elapsed) }
        return nil
    }

    /// The accent fill, 0...1: what plays now, or while seeking how far the
    /// engine has got, never past the target.
    private var played: Double? {
        guard let target else { return clamped(elapsed) }
        let at = seeking && dragFraction == nil && pending == nil ? (seekPosition ?? elapsed) : elapsed
        return clamped(at).map { min($0, target) }
    }

    private var fillColor: Color {
        onDark ? Color.white.opacity(0.85) : Color.accentColor
    }

    /// The target: grey, a step up from the track.
    private var targetColor: Color {
        onDark ? Color.white.opacity(0.4) : Color.primary.opacity(0.3)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(onDark ? Color.white.opacity(0.15) : Color.primary.opacity(0.12))
                if let target {
                    Capsule()
                        .fill(targetColor)
                        .frame(width: width * target)
                }
                if let played {
                    Capsule()
                        .fill(fillColor)
                        .frame(width: width * played)
                        // Between the store's polls, so the run looks continuous.
                        .animation(seeking ? .linear(duration: 0.06) : nil, value: played)
                }
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity, alignment: .center)
            .opacity(duration == nil ? 0.4 : 1)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canSeek, let duration, duration > 0 else { return }
                        let f = Self.clamp(value.location.x / max(width, 1))
                        dragFraction = f
                        preview = f * duration
                    }
                    .onEnded { value in
                        dragFraction = nil
                        guard canSeek, let duration, duration > 0 else {
                            preview = nil
                            explaining = !canSeek
                            return
                        }
                        let target = Self.clamp(value.location.x / max(width, 1)) * duration
                        pending = target
                        preview = target
                        seek(target)
                        pendingTimeout?.cancel()
                        pendingTimeout = Task {
                            // The player didn't take it (or is slow to say so).
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            pending = nil
                            preview = nil
                        }
                    }
            )
        }
        .popover(isPresented: $explaining, arrowEdge: .bottom) { explanation }
        .onChange(of: elapsed) { _, now in
            if let pending, abs(now - pending) < 1 {
                self.pending = nil
                preview = nil
                pendingTimeout?.cancel()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((played ?? 0) * 100)) percent")
        .accessibilityHint(canSeek ? "Drag to a point in the tune." : "")
    }

    private static func clamp(_ f: Double) -> Double {
        min(max(f, 0), 1)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scrubbing Needs reSIDfp or SIDLite Direct")
                .font(.headline)
            Text("The \(engine.displayName) engine plays a tune in real time only, so there's nothing to jump to. The reSIDfp and SIDLite direct engines run the tune to the point you choose.")
            if hasSubtunes {
                Text("Use \(Image(systemName: "chevron.left")) \(Image(systemName: "chevron.right")) to jump between the songs in this tune.")
            }
            Button("Choose Engine…") {
                explaining = false
                UserDefaults.standard.set(SettingsTab.playback.rawValue, forKey: Pref.settingsTab)
                openSettings()
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .font(.callout)
        .frame(width: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
    }
}
