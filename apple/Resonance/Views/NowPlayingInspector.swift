import SwiftUI
import PhosphorCore

/// Visualizer and details of the playing tune: its title, the composer's
/// card, what STIL says about it, and its specs.
struct NowPlayingInspector: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library

    var body: some View {
        // The visualizer redraws every frame, so it stays above the
        // scrolling details rather than being laid out with them.
        VStack(spacing: 0) {
            VisualizerView()
                .frame(height: 204)
                .padding(12)
            details
        }
    }

    @ViewBuilder
    private var details: some View {
        if let track = store.nowPlaying {
            let composer = library.composer(of: track)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(track, showsAuthor: composer == nil)
                    if let composer {
                        ComposerCard(composer: composer, tunePath: track.path)
                    }
                    if let stil = library.stil[track.path] ?? nil {
                        StilNotesView(entry: stil, track: track)
                    }
                    InspectorSection("Details") {
                        specs(of: track)
                    }
                }
                .padding([.horizontal, .bottom], 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Pinned like the playlist column: content must not decide the
            // inspector column's width.
            .frame(minWidth: 0, maxWidth: .infinity)
            // The composer card matches composers against the MUSICIANS list.
            .task(id: store.hvscRoot) { await library.loadAuthors(.musicians) }
            .task(id: track.path) { await library.loadStil(path: track.path, sidAuthor: track.author) }
        } else {
            ContentUnavailableView {
                Label("Not Playing", systemImage: "waveform")
            } description: {
                Text("Double-click a tune to play it. Its details and STIL commentary appear here.")
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Where it's playing from (with a way to keep it), the title, who
    /// released it when, then how long it runs and which of several songs
    /// is on. The author too, when no composer card names them.
    private func header(_ track: TrackDetails, showsAuthor: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                source
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                playlistStatus(track)
            }
            .padding(.bottom, 2)
            Text(track.title)
                .font(.title2.weight(.semibold))
            if showsAuthor {
                Text(track.author)
            }
            if let released = Self.released(track.released) {
                Text(released)
                    .foregroundStyle(.secondary)
            }
            let duration = store.duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }
            if duration != nil || track.songs > 1 {
                // Each fact keeps to one line; there's room for both.
                HStack(spacing: 14) {
                    if let duration {
                        Label(duration, systemImage: "clock")
                            .fixedSize()
                            .help("Length")
                    }
                    if track.songs > 1 {
                        Label("Song \(track.currentSong) of \(track.songs)", systemImage: "list.number")
                            .fixedSize()
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 4)
    }

    /// The header's released field in words: "1985 Gremlin Graphics" →
    /// "Released 1985 by Gremlin Graphics". It holds a year, then the
    /// publisher, group or party that put the tune out; either may be
    /// missing, and "<?>" means nothing is known.
    nonisolated static func released(_ field: String) -> String? {
        switch releasedParts(field) {
        case let (year?, by?): return "Released \(year) by \(by)"
        case let (year?, nil): return "Released \(year)"
        case let (nil, by?): return "Released by \(by)"
        case (nil, nil): return nil
        }
    }

    /// The released field's year and who put the tune out, either nil when
    /// unknown.
    nonisolated static func releasedParts(_ field: String) -> (year: String?, by: String?) {
        let parts = field.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return (nil, nil) }
        // "1985", "198?", "1987-88"; "19??" and "????" say nothing.
        let isYear = first.allSatisfy { $0.isNumber || "?-/".contains($0) }
        let year = isYear && first.filter(\.isNumber).count >= 3 ? first : nil
        let by = (isYear ? parts.dropFirst().first : field.trimmingCharacters(in: .whitespaces))
            .flatMap { $0.isEmpty || $0 == "<?>" ? nil : $0 }
        return (year, by)
    }

    /// Which list Next and Previous walk.
    @ViewBuilder
    private var source: some View {
        if store.surpriseActive {
            Label("Surprise Me", systemImage: "dice.fill")
                .foregroundStyle(.tint)
                .help("Next plays another random tune from HVSC. Play anything else to stop.")
        } else if let playlist = store.queuePlaylist {
            // The published playlist it's playing from, which opens it.
            Label {
                AccentLink(playlist.name) {
                    library.shownSection = .curated(playlist.file)
                }
                .lineLimit(1)
                .help("Show the playlist")
            } icon: {
                Image(systemName: "music.note.list")
            }
        } else if store.queueActive {
            Label("From Queue", systemImage: "list.bullet")
                .help("A selection, search or folder from HVSC")
        } else {
            Label("From Playlist", systemImage: "music.note.list")
        }
    }

    /// Keep what's playing — a surprise, or any tune played from the
    /// library. Once it's kept, a label says so (a disabled button would
    /// show no tooltip); nothing at all when it's playing from the playlist.
    @ViewBuilder
    private func playlistStatus(_ track: TrackDetails) -> some View {
        if !store.rows.contains(where: { $0.id == track.path }) {
            Button("Add to Playlist", systemImage: "plus") {
                store.add([URL(filePath: track.path)])
            }
            .controlSize(.small)
            .help("Add this tune to your playlist")
        } else if store.queueActive || store.surpriseActive {
            Label("In Playlist", systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("This tune is already in your playlist")
        }
    }

    /// The tune's format, SID model, clock and chip count side by side,
    /// then its file.
    private func specs(of track: TrackDetails) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                spec("Format", track.isRsid ? "RSID" : "PSID")
                Divider()
                spec("SID", track.chipModel.short)
                    .help(track.chipModel.full)
                Divider()
                spec("Clock", track.isPal ? "PAL" : "NTSC")
                Divider()
                spec("Chips", "\(track.numSids)")
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: track.path)])
            }
            .controlSize(.small)
            .help("Show \(URL(filePath: track.path).lastPathComponent) in Finder")
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func spec(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

nonisolated extension TrackDetails {
    /// The SID chip the tune's header asks for: short for labels, in full
    /// for help text.
    var chipModel: (short: String, full: String) {
        switch sidModel {
        case 1: ("6581", "MOS 6581")
        case 2: ("8580", "MOS 8580")
        case 3: ("Either", "Plays on the 6581 or the 8580")
        default: ("—", "Not specified in the file")
        }
    }
}

/// A titled group of details on a rounded fill, like a grouped form's
/// section.
private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        }
    }
}

/// The inspector's links, all alike: text in the accent colour (`.link`
/// would be system blue).
struct AccentLink: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .pointerStyle(.link)
    }
}

/// Who wrote what's playing: their name, a way to all their tunes, and
/// STIL's note on them when it has one, set like the tune's notes, the
/// tunes it names leading to the browser. On the same fill as the cards
/// around it; the monogram is where a photo would go.
private struct ComposerCard: View {
    let composer: Composer
    let tunePath: String

    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                monogram
                VStack(alignment: .leading, spacing: 1) {
                    Text(composer.name)
                        .font(.headline)
                    if let subtitle = composer.subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                    if let path = composer.authorPath {
                        AccentLink("Show All Tunes") {
                            library.reveal = LibraryReveal(authorPath: path, tunePath: tunePath)
                        }
                        .help("Show all tunes by \(composer.name)")
                    } else if library.player.hasCollection {
                        // No folder: the tunes whose header credits them.
                        AccentLink("Show All Tunes") {
                            library.credits = LibraryCredits(
                                name: composer.name,
                                category: library.category(of: tunePath) ?? .musicians
                            )
                        }
                        .help("Show all tunes credited to \(composer.name)")
                    }
                }
            }
            if let path = composer.authorPath, let note = library.stil[path] ?? nil {
                StilCommentsView(entry: note)
                    .foregroundStyle(.secondary)
                    .id(path)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        .task(id: composer.authorPath) {
            if let path = composer.authorPath {
                await library.loadStil(path: path)
            }
        }
    }

    private var monogram: some View {
        ZStack {
            Circle().fill(.background)
            if composer.initials.isEmpty {
                Image(systemName: "person.fill")
            } else {
                Text(composer.initials)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(.tint)
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

#Preview {
    NowPlayingInspector()
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .frame(width: 300, height: 700)
}
