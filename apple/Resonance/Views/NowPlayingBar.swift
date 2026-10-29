import SwiftUI
import PhosphorCore

/// Transport, progress, subtunes and volume in a floating glass bar.
///
/// The bar adapts to the width it's given, never the other way round: its
/// minimum width is pinned to zero so the playlist column's minimum can't
/// depend on what the bar shows. (When the subtune stepper appeared while the
/// inspector was open, the bar's rigid minimum exceeded the column and the
/// split view re-ran layout until AppKit aborted.) Lower-priority controls
/// drop out as the bar narrows instead.
struct NowPlayingBar: View {
    @Environment(PlayerStore.self) private var store
    @State private var width: CGFloat = 0

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 16) {
                transport
                trackInfo
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if store.hasSubtunes {
                    subtunes
                }
                if width >= 560 {
                    modes
                }
                if width >= 700 {
                    volume
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var transport: some View {
        HStack(spacing: 6) {
            Button("Previous", systemImage: "backward.fill") { store.previous() }
            Button(store.isPlaying ? "Pause" : "Play", systemImage: store.isPlaying ? "pause.fill" : "play.fill") {
                store.playPause()
            }
            .font(.title2)
            .contentTransition(.symbolEffect(.replace))
            Button("Next", systemImage: "forward.fill") { store.next() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(store.rows.isEmpty)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let track = store.nowPlaying {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(track.title).font(.headline)
                    Text(track.author).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            } else {
                Text("Not Playing").foregroundStyle(.secondary)
            }
            ProgressRow(elapsed: store.elapsed, duration: store.duration, progress: store.progress)
        }
    }

    private var subtunes: some View {
        HStack(spacing: 2) {
            Button("Previous Subtune", systemImage: "chevron.left") { store.previousSubtune() }
            Text("Song \(store.nowPlaying?.currentSong ?? 1)/\(store.nowPlaying?.songs ?? 1)")
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 84)
            Button("Next Subtune", systemImage: "chevron.right") { store.nextSubtune() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Subtune")
    }

    private var modes: some View {
        @Bindable var store = store
        return HStack(spacing: 6) {
            Toggle("Shuffle", systemImage: "shuffle", isOn: $store.shuffle)
            Button("Repeat: \(store.repeatMode.displayName)", systemImage: store.repeatMode.symbolName) {
                store.cycleRepeat()
            }
            .foregroundStyle(store.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .buttonStyle(.borderless)
    }

    private var volume: some View {
        @Bindable var store = store
        return HStack(spacing: 6) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: $store.volume, in: 0...1)
                .frame(width: 90)
                .controlSize(.small)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Volume")
    }
}

/// Elapsed / length with a read-only bar (SID tunes can't be seeked).
private struct ProgressRow: View {
    let elapsed: TimeInterval
    let duration: TimeInterval?
    let progress: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(format(elapsed))
            ProgressView(value: progress ?? 0)
                .progressViewStyle(.linear)
                .opacity(progress == nil ? 0.3 : 1)
            Text(duration.map(format) ?? "--:--")
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private func format(_ t: TimeInterval) -> String {
        Duration.seconds(t).formatted(.time(pattern: .minuteSecond))
    }
}

#Preview {
    NowPlayingBar()
        .environment(PlayerStore.preview)
        .padding()
        .frame(width: 900)
}
