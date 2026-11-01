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
                nowPlaying
                trackInfo
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if store.hasSubtunes {
                    subtunes
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

    /// Laid out like Music: shuffle · previous · play/pause · next · repeat,
    /// the middle three a size up. Shuffle and repeat drop out first when
    /// the bar narrows.
    private var transport: some View {
        HStack(spacing: 10) {
            if width >= 480 {
                shuffle
            }
            HStack(spacing: 6) {
                Button("Previous", systemImage: "backward.fill") { store.previous() }
                    .font(.title3)
                Button(store.isPlaying ? "Pause" : "Play", systemImage: store.isPlaying ? "pause.fill" : "play.fill") {
                    store.playPause()
                }
                .font(.title)
                .contentTransition(.symbolEffect(.replace))
                Button("Next", systemImage: "forward.fill") { store.next() }
                    .font(.title3)
            }
            .disabled(store.rows.isEmpty && !store.queueActive)
            if width >= 480 {
                repeatMode
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    /// Never drops out as the bar narrows: it's one of the ways into Now
    /// Playing, along with the track title and View › Now Playing.
    private var nowPlaying: some View {
        Button("Now Playing", systemImage: "chevron.up") { store.toggleNowPlaying() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Show Now Playing")
    }

    private var shuffle: some View {
        Button("Shuffle", systemImage: "shuffle") { store.shuffle.toggle() }
            .foregroundStyle(modeStyle(on: store.shuffle))
            .accessibilityValue(store.shuffle ? "On" : "Off")
            .help(store.shuffle ? "Shuffle: On" : "Shuffle: Off")
    }

    private var repeatMode: some View {
        Button("Repeat: \(store.repeatMode.displayName)", systemImage: store.repeatMode.symbolName) {
            store.cycleRepeat()
        }
        .foregroundStyle(modeStyle(on: store.repeatMode != .off))
        .contentTransition(.symbolEffect(.replace))
        .help("Repeat: \(store.repeatMode.displayName)")
    }

    /// Both modes read the same way: accent colour when on, dimmed when off.
    private func modeStyle(on: Bool) -> AnyShapeStyle {
        on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let track = store.nowPlaying {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if store.surpriseActive {
                        SurpriseBadge(compact: width < 560)
                    }
                    // Like clicking the artwork in Music.
                    Button {
                        store.toggleNowPlaying()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(track.title).font(.headline)
                            Text(track.author).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Show Now Playing")
                }
                .lineLimit(1)
            } else {
                Text("Not Playing").foregroundStyle(.secondary)
            }
            ProgressRow(
                elapsed: store.elapsed,
                duration: store.duration,
                progress: store.progress,
                hasSubtunes: store.hasSubtunes
            )
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

/// Marks Surprise Me's radio, so it's clear why Next plays a random tune.
/// Just the dice when the bar is narrow. A solid pill: the bar is glass, so
/// whatever scrolls under it shows through anything lighter.
private struct SurpriseBadge: View {
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                Image(systemName: "dice.fill")
            } else {
                Label("Surprise Me", systemImage: "dice.fill")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.tint, in: .capsule)
        .fixedSize()
        .help("Surprise Me: Next plays another random tune from HVSC. Play anything else to stop.")
        .accessibilityLabel("Surprise Me")
    }
}

/// Elapsed / length with a read-only bar. SID tunes can't be seeked (the
/// engine runs each one as a C64 program, in real time), but people expect
/// to scrub: hovering explains, and so does a click or drag on the bar.
private struct ProgressRow: View {
    let elapsed: TimeInterval
    let duration: TimeInterval?
    let progress: Double?
    let hasSubtunes: Bool

    @State private var explaining = false

    private static let why = "SID tunes play in real time, so you can't skip within a tune."

    var body: some View {
        HStack(spacing: 8) {
            Text(format(elapsed))
            ProgressView(value: progress ?? 0)
                .progressViewStyle(.linear)
                .opacity(progress == nil ? 0.3 : 1)
                // The row's height, so the thin bar is easy to hit.
                .frame(height: 14)
                .contentShape(.rect)
                // A click is a drag that didn't move.
                .gesture(DragGesture(minimumDistance: 0).onEnded { _ in explaining = true })
                .help(Self.why)
                .accessibilityHint(Self.why)
                .popover(isPresented: $explaining, arrowEdge: .bottom) { explanation }
            Text(duration.map(format) ?? "--:--")
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Scrubbing in SID Tunes")
                .font(.headline)
            Text("A SID tune is a little C64 program that plays in real time, so there's no skipping ahead or back within it.")
            if hasSubtunes {
                Text("Use \(Image(systemName: "chevron.left")) \(Image(systemName: "chevron.right")) to jump between the songs in this tune.")
            }
        }
        .font(.callout)
        .frame(width: 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
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
