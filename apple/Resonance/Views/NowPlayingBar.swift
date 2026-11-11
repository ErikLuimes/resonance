import AppKit
import SwiftUI
import PhosphorCore
import STILKit

/// Transport, progress, subtunes and volume in a floating glass bar.
///
/// The bar adapts to the width it's given, never the other way around: its
/// minimum width is pinned to zero so the playlist column's minimum can't
/// depend on what the bar shows. (When the subtune stepper appeared while the
/// inspector was open, the bar's rigid minimum exceeded the column and the
/// split view re-ran layout until AppKit aborted.) Lower-priority controls
/// drop out as the bar narrows instead.
struct NowPlayingBar: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @State private var width: CGFloat = 0
    /// The volume slider is slid open next to its speaker button.
    @State private var showsVolume = false
    @State private var volumeClosing: Task<Void, Never>?
    /// Bumped as the pointer reaches the Now Playing button, to bounce it.
    @State private var nowPlayingHovers = 0

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 16) {
                transport
                trackInfo
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if store.hasSubtunes {
                    subtunes
                }
                volume
                if width >= 420 {
                    underTheHood
                }
                nowPlaying
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
                ShuffleButton()
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
            // Bold and bright, so they read on the glass.
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .disabled(store.rows.isEmpty && !store.queueActive)
            if width >= 480 {
                RepeatButton()
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    /// Beside Now Playing, until the bar gets narrow; View › Under the Hood stays.
    private var underTheHood: some View {
        Button("Under the Hood", systemImage: "memorychip") { store.toggleUnderTheHood() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title3.weight(.semibold))
            .foregroundStyle(store.isShowingUnderTheHood ? Color.accentColor : Color.primary)
            .help("Show the tracker, registers, sweeps and pitch trail")
    }

    /// At the bar's far end, where players keep their full-screen button.
    /// Never drops out as the bar narrows: it's one of the ways into Now
    /// Playing, along with the track title and View › Now Playing.
    private var nowPlaying: some View {
        Button("Now Playing", systemImage: "rectangle.expand.diagonal") { store.toggleNowPlaying() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .symbolEffect(.bounce, value: nowPlayingHovers)
            .onHover { if $0 { nowPlayingHovers += 1 } }
            .help("Show Now Playing")
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
                Text("Not Playing")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProgressRow()
        }
    }

    /// One pill: step with the chevrons, or pick any song from the menu
    /// behind the number, named from STIL where it can.
    private var subtunes: some View {
        let song = Int(store.nowPlaying?.currentSong ?? 1)
        let songs = Int(store.nowPlaying?.songs ?? 1)
        let stil = store.nowPlaying.flatMap { library.stil[$0.path] ?? nil }
        return HStack(spacing: 0) {
            Button("Previous Song", systemImage: "chevron.left") { store.previousSubtune() }
                .disabled(song <= 1)
            Menu {
                ForEach(1...max(songs, 1), id: \.self) { n in
                    Toggle(Self.songTitle(stil, song: n), isOn: Binding(
                        get: { n == song },
                        set: { if $0 { store.setSubtune(n) } }
                    ))
                }
            } label: {
                Text("\(song)/\(songs)")
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            // AppKit draws the menu's title itself, so its width follows the
            // text; fixed to the longest number, stepping never moves the
            // chevrons.
            .frame(width: Self.songNumberWidth(songs))
            .help("Choose a song")
            .accessibilityLabel("Song \(song) of \(songs)")
            Button("Next Song", systemImage: "chevron.right") { store.nextSubtune() }
                .disabled(song >= songs)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.fill.tertiary, in: .capsule)
    }

    /// Room for "19/19", the longest number a tune with `songs` songs
    /// shows, in the bar's semibold system font.
    private static func songNumberWidth(_ songs: Int) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return ("\(songs)/\(songs)" as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 12
    }

    /// A song as the menu names it: "Song 1: Tea for the Seasick", from
    /// STIL's NAME, else the piece it covers, else "Medley"; just "Song 3"
    /// when STIL has nothing to call it.
    nonisolated static func songTitle(_ entry: STILEntry?, song: Int) -> String {
        let section = entry?.sections.first { $0.subtune == song }
        let name = section?.names.first
            ?? (section?.isMedley == true ? String(localized: "Medley") : section?.covers.compactMap(\.title).first)
        return name.map { String(localized: "Song \(song): \($0)") } ?? String(localized: "Song \(song)")
    }

    /// A speaker button that shows the level, like Music's; a click slides
    /// the slider out to its left, floating over the controls there rather
    /// than pushing them aside. It closes again shortly after you've set
    /// the volume or moved away, or with another click.
    private var volume: some View {
        @Bindable var store = store
        return Button {
            volumeClosing?.cancel()
            withAnimation(.snappy(duration: 0.25)) { showsVolume.toggle() }
        } label: {
            Image(systemName: store.volume > 0 ? "speaker.wave.3.fill" : "speaker.slash.fill", variableValue: store.volume)
                .frame(width: 26)
                // Waves follow the level; muting swaps the symbol; opening
                // and closing the slider bounces it.
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: showsVolume)
        }
        .buttonStyle(.borderless)
        // Bold and bright like the transport, so it reads on the glass.
        .font(.title3.weight(.semibold))
        .foregroundStyle(showsVolume ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .help(showsVolume ? "Hide Volume" : "Volume")
        .accessibilityLabel("Volume")
        .accessibilityValue(Text(store.volume, format: .percent.precision(.fractionLength(0))))
        .onHover { hoveringVolume($0) }
        .overlay(alignment: .trailing) {
            if showsVolume {
                Slider(value: $store.volume, in: 0...1) { editing in
                    if editing { volumeClosing?.cancel() } else { closeVolume(after: 1.2) }
                }
                .frame(width: 110)
                .controlSize(.small)
                .accessibilityLabel("Volume")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: .capsule)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .fixedSize()
                .offset(x: -30)
                .onHover { hoveringVolume($0) }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    /// The pointer on the button or the slider keeps it open; leaving both
    /// closes it.
    private func hoveringVolume(_ inside: Bool) {
        if inside { volumeClosing?.cancel() } else if showsVolume { closeVolume(after: 0.8) }
    }

    private func closeVolume(after seconds: Double) {
        volumeClosing?.cancel()
        volumeClosing = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.25)) { showsVolume = false }
        }
    }
}

/// Marks Surprise Me's radio, so it's clear why Next plays a random tune.
/// Just the dice when the bar is narrow. A solid pill: the bar is glass, so
/// whatever scrolls under it shows through anything lighter.
/// The transport's shuffle switch, in the bar and the menu bar player.
/// Both modes read the same way: bright like the other buttons when on
/// (the accent color didn't read on the glass), dimmed when off.
struct ShuffleButton: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Button("Shuffle", systemImage: "shuffle") { store.shuffle.toggle() }
            .foregroundStyle(store.shuffle ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .fontWeight(.semibold)
            .accessibilityValue(store.shuffle ? "On" : "Off")
            .help(store.shuffle ? "Shuffle: On" : "Shuffle: Off")
    }
}

/// The transport's repeat button (off, all, one), beside the shuffle.
struct RepeatButton: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Button("Repeat: \(store.repeatMode.displayName)", systemImage: store.repeatMode.symbolName) {
            store.cycleRepeat()
        }
        .foregroundStyle(store.repeatMode != .off ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .fontWeight(.semibold)
        .contentTransition(.symbolEffect(.replace))
        .help("Repeat: \(store.repeatMode.displayName)")
    }
}

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

/// Elapsed / length with the bar. It scrubs on the engines that can seek
/// (reSIDfp and SIDLite direct); on the other two the tune plays in real
/// time only, and a click on the bar explains.
///
/// It reads the store itself, so the clock's many updates a second stop here.
/// Handed down from the bar, they rebuilt the bar and its glass each time.
private struct ProgressRow: View {
    @Environment(PlayerStore.self) private var store
    @State private var preview: TimeInterval?

    private var elapsed: TimeInterval { store.elapsed }
    private var duration: TimeInterval? { store.duration }
    private var durationIsEstimate: Bool { store.durationIsEstimate }
    private var hasSubtunes: Bool { store.hasSubtunes }
    private var canSeek: Bool { store.canSeek }
    private var isPlaying: Bool { store.isPlaying }
    private var engine: Engine { store.engine }
    private var seeking: Bool { store.seeking }
    private var seekPosition: TimeInterval? { store.seekPosition }

    private static let how = String(localized: "Drag or click to a point in the tune. The sound pauses while the engine runs there, about a second per minute of tune.")

    var body: some View {
        HStack(spacing: 8) {
            // While seeking, the clock winds along with the engine.
            Text(format(preview ?? seekPosition ?? elapsed))
                .opacity(seeking && preview == nil ? 0.55 : 1)
            ScrubBar(
                elapsed: elapsed,
                duration: duration,
                canSeek: canSeek,
                isPlaying: isPlaying,
                engine: engine,
                hasSubtunes: hasSubtunes,
                seeking: seeking,
                seekPosition: seekPosition,
                preview: $preview,
                seek: { store.seek(to: $0) }
            )
            // The row's height, so the thin bar is easy to hit.
            .frame(height: 14)
            .help(canSeek ? Self.how : String(localized: "The \(engine.displayName) engine can't scrub. Click for why."))
            Text(duration.map { (durationIsEstimate ? "~" : "") + format($0) } ?? "--:--")
                .help(lengthHelp)
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var lengthHelp: String {
        if duration == nil { return String(localized: "This tune isn't in HVSC's song lengths, and Resonance hasn't figured out its length yet.") }
        return durationIsEstimate ? String(localized: "This tune isn't in HVSC's song lengths. Resonance figured out this length by running the tune, so it may be off.") : ""
    }

    private func format(_ t: TimeInterval) -> String {
        Duration.seconds(t).formatted(.time(pattern: .minuteSecond))
    }
}

#Preview {
    NowPlayingBar()
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .environment(FingerprintStore(player: .preview))
        .padding()
        .frame(width: 900)
}
