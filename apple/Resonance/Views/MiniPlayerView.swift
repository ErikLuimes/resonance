import SwiftUI
import PhosphorCore

/// The menu bar player, in three parts: the tune (its voices, title,
/// composer and heart, progress, and the play bar's transport), the list
/// it plays from with what comes next, and the actions: Surprise Me, and
/// a link that shows the tune in Resonance. Adding to playlists and
/// sharing stay in the main window. Works with the main window closed; Settings →
/// Appearance hides it. No accent colour: the panel's glass takes on the
/// desktop's colours, and the accent didn't read on it.
struct MiniPlayerView: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    /// Opens Resonance's window.
    let openApp: () -> Void

    /// How many tunes the list shows.
    private static let upNextCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let track = store.nowPlaying {
                header(track)
                progress
                    .padding(.top, 14)
                transport
                    .padding(.vertical, 10)
            } else {
                nothingPlaying
                    .padding(.bottom, 12)
            }
            upNext
            Divider()
                .padding(.top, 10)
            actions
                .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 340)
        .tint(.primary)
        // A thick backing, so the secondary text keeps its grey instead of
        // taking on the desktop's colour through the panel's glass.
        .background(.thickMaterial)
    }

    // MARK: The tune

    private func header(_ track: TrackDetails) -> some View {
        HStack(spacing: 12) {
            MiniScope()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                Text([track.author, NowPlayingInspector.releasedParts(track.released).year]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            FavouriteButton(path: track.path)
                .font(.title3)
        }
    }

    /// The time under the pointer while scrubbing.
    @State private var preview: TimeInterval?

    /// The bar (scrubbing like the player bar's), then the time played and
    /// the time left.
    private var progress: some View {
        let shown = preview ?? store.seekPosition ?? store.elapsed
        return VStack(spacing: 4) {
            ScrubBar(
                elapsed: store.elapsed,
                duration: store.duration,
                canSeek: store.canSeek,
                seeking: store.seeking,
                seekPosition: store.seekPosition,
                preview: $preview,
                seek: { store.seek(to: $0) }
            )
            .frame(height: 12)
            HStack {
                Text(Self.time(shown))
                Spacer()
                Text(store.duration.map { "−" + Self.time(max($0 - shown, 0)) } ?? "--:--")
            }
            .opacity(store.seeking && preview == nil ? 0.55 : 1)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    /// As in the play bar: shuffle · previous · play/pause · next · repeat,
    /// the middle three a size up.
    private var transport: some View {
        HStack(spacing: 22) {
            ShuffleButton()
            HStack(spacing: 18) {
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
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .disabled(store.rows.isEmpty && !store.queueActive)
            RepeatButton()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
    }

    private var nothingPlaying: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing playing")
                .font(.headline)
            Text("Pick a tune in Resonance, or let Surprise Me choose one.")
                .foregroundStyle(.secondary)
                // Wraps: the panel's width is fixed.
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The list

    /// The list playing and what comes next in it; for Surprise Me and
    /// Shuffle Collection, how the next tune is chosen instead.
    @ViewBuilder
    private var upNext: some View {
        if store.surpriseActive {
            listNote(store.beforeSurpriseSource.map {
                "Next: a random tune from all of HVSC. Turn off Surprise Me to go back to \($0.name)."
            } ?? "Next: a random tune from all of HVSC.")
        } else if store.shuffleCollectionActive {
            listNote("Next: a random tune. Shuffle Collection plays all of HVSC in a random order.")
        } else if let source = store.source, !playingList.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Divider()
                    .padding(.bottom, 8)
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 4) {
                        Text("From")
                            .foregroundStyle(.secondary)
                        Button(source.name) { library.open(source, playing: store.nowPlaying?.path) }
                            .buttonStyle(.plain)
                            .underline(color: .secondary.opacity(0.5))
                            .pointerStyle(.link)
                            .lineLimit(1)
                            .help(source.section == nil ? "Show the tune in the library" : "Show \(source.name)")
                    }
                    Spacer(minLength: 8)
                    Text(store.shuffle ? "Shuffled · \(playingList.count.formatted())" : playingList.count.formatted())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                ForEach(Array(next.enumerated()), id: \.element.id) { offset, tune in
                    Button {
                        play(tune)
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(offset + 1)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .frame(width: 14, alignment: .trailing)
                            Text(tune.title)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(tune.author)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(UpNextRowStyle())
                }
            }
        }
    }

    private func listNote(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.bottom, 10)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The tunes after the one playing, in the list it plays from.
    private var next: [QueuedTune] {
        let list = playingList
        let at = list.firstIndex { $0.path == store.nowPlaying?.path } ?? -1
        return Array(list.dropFirst(at + 1).prefix(Self.upNextCount))
    }

    /// The list playing: the library queue, or the playlist.
    private var playingList: [QueuedTune] {
        if store.queueActive { return store.queue }
        guard store.currentIndex != nil else { return [] }
        return store.rows.map { QueuedTune(path: $0.id, title: $0.title, author: $0.author) }
    }

    private func play(_ tune: QueuedTune) {
        if store.queueActive {
            store.playQueue(store.queue.map { URL(filePath: $0.path) }, startAt: URL(filePath: tune.path),
                            from: store.queueSource ?? .myPlaylist, tunes: store.queue)
        } else if let row = store.rows.first(where: { $0.id == tune.path }) {
            store.play(index: row.index)
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            ChipToggle(isOn: store.surpriseActive) {
                if store.surpriseActive {
                    store.endSurprise()
                } else {
                    Task { await library.surpriseMe() }
                }
            } label: {
                Text("Surprise Me")
            }
            .disabled(!store.hasCollection)
            .help(store.surpriseActive ? "Back to the list that played before" : "Random tunes from all of HVSC")
            Spacer(minLength: 8)
            // Underlined like the list's "From" link: the panel has no
            // accent colour to mark links with.
            Group {
                if let path = store.nowPlaying?.path {
                    AccentLink("Show in Resonance") { show(path) }
                        .help("Open Resonance with this tune selected")
                } else {
                    AccentLink("Open Resonance", action: openApp)
                }
            }
            .underline(color: .secondary.opacity(0.5))
            .pointerStyle(.link)
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .font(.callout)
    }

    /// Open Resonance's window with the playing tune selected: in the list
    /// it plays from, or (a composer, a search, Surprise Me) in its place
    /// in the library.
    private func show(_ path: String) {
        openApp()
        if let source = store.source {
            library.open(source, playing: path)
        } else {
            library.reveal(tunePath: path)
        }
    }

    private static func time(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(seconds, 0)).formatted(.time(pattern: .minuteSecond))
    }
}

/// The tune's three voices, traced over one another in the theme's
/// colours: the player's artwork.
private struct MiniScope: View {
    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    var body: some View {
        TimelineView(.animation(minimumInterval: VisualizerFeed.frameInterval, paused: !store.isPlaying)) { _ in
            let feed = store.visualizer
            let voices = feed.latest()?.chips.first?.voices ?? []
            let scope = voices.isEmpty ? nil : feed.scope(chip: 0, count: 1024)
            Canvas { gc, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 9)
                guard let scope else { return }
                for i in 0..<min(3, voices.count, scope.voices.count) {
                    let window = ScopeTrigger.window(
                        scope.voices[i], hz: voices[i].hz, sampleRate: scope.sampleRate,
                        pitched: voices[i].waveform & 0x7 != 0
                    )
                    gc.stroke(ScopeVisualizer.trace(window, in: rect), with: .color(theme.voice(i)),
                              style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                }
            }
        }
        .background(theme.background.color, in: .rect(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

/// A capsule that's filled while on, plain while off. Filled with the text
/// colour (the tint), its label in the background colour.
private struct ChipToggle<Label: View>: View {
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        if isOn {
            Button(action: action) { label.foregroundStyle(Color(nsColor: .windowBackgroundColor)) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
        }
    }
}

/// A row of the list: plain, lit on hover like a menu item.
private struct UpNextRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0),
                        in: .rect(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
}
