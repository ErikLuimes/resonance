import SwiftUI
import PhosphorCore

/// One of Phosphor's published playlists: what it is, a way to play it, and
/// its tunes in a table like the rest of the library.
struct CuratedPlaylistView: View {
    let playlist: HvscPlaylist

    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    /// The list's own filter.
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // Again whenever the tunes are gone: the library drops its caches
        // when the collection changes, which would otherwise leave this
        // loading for good.
        .task(id: TaskKey(file: playlist.file, loaded: library.playlistTunes[playlist.file] != nil)) {
            await library.loadPlaylist(playlist)
        }
    }

    private struct TaskKey: Equatable {
        let file: String
        let loaded: Bool
    }

    @ViewBuilder
    private var content: some View {
        switch library.playlistTunes[playlist.file] {
        case nil:
            // The first load in a category builds (or reads) its index.
            ProgressView(store.hvscIndexing.isEmpty ? String(localized: "Loading the playlist…") : String(localized: "Indexing the collection…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .some(nil), .some([]):
            ContentUnavailableView {
                Label("No Tunes", systemImage: "music.note.list")
            } description: {
                Text("None of this playlist's tunes are in the collection folder.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .some(let rows?):
            LibraryTable(rows: filtered(rows.numbered()), source: .curated(playlist), actions: AnyView(listActions), numbered: true)
                .overlay {
                    if !query.isEmpty && filtered(rows).isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            PlaylistArtwork(name: playlist.name, size: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text("Curated Playlist")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Text(playlist.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                if let description = playlist.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// What the list does, in the row with Sound.
    private var listActions: some View {
        Group {
            ListFilterField(text: $filter)
            ListPlayButton(title: isPlaying ? String(localized: "Play Again") : String(localized: "Play"), isDisabled: rows.isEmpty) {
                library.play(rows, from: .curated(playlist))
            }
        }
    }

    /// "210 tunes · 11 hr 4 min", the length once the rows are in (tunes
    /// the Songlengths database doesn't know count as nothing).
    private var summary: String {
        let count = rows.isEmpty ? Int(playlist.tracks) : rows.count
        var text = count == 1 ? String(localized: "1 tune") : String(localized: "\(count.formatted()) tunes")
        let seconds = rows.compactMap(\.item.durationSecs).reduce(0) { $0 + Int($1) }
        if seconds > 0 {
            text += " · " + Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        }
        if isPlaying { text += String(localized: " · playing") }
        return text
    }

    // MARK: Rows and actions

    private var rows: [LibraryRow] { (library.playlistTunes[playlist.file] ?? nil) ?? [] }

    private var query: String { filter.trimmingCharacters(in: .whitespaces) }

    private func filtered(_ rows: [LibraryRow]) -> [LibraryRow] {
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.title.localizedStandardContains(query)
                || $0.author.localizedStandardContains(query)
                || $0.released.localizedStandardContains(query)
        }
    }

    private var isPlaying: Bool { store.source == .curated(playlist) }
}

/// A sidebar row for a published playlist; a speaker shows while it plays.
struct CuratedPlaylistRow: View {
    let playlist: HvscPlaylist
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(playlist.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if store.source == .curated(playlist) {
                    Image(systemName: store.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Playing")
                }
            }
        } icon: {
            Image(systemName: "music.note.list")
        }
        .help(playlist.description ?? playlist.name)
    }
}

/// A playlist's artwork: the published playlists have no images, so a
/// gradient in two of the voice colors, picked from the name so each
/// playlist keeps its own, behind a note.
struct PlaylistArtwork: View {
    let name: String
    var size: CGFloat

    var body: some View {
        let (from, to) = colors
        Image(systemName: "music.note.list")
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [from, to], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: .rect(cornerRadius: size * 0.22)
            )
    }

    /// Stable across launches (unlike `hashValue`).
    private var colors: (Color, Color) {
        let palette: [Color] = [
            Color(red: 1.0, green: 79 / 255, blue: 139 / 255),       // pink
            Color(red: 155 / 255, green: 107 / 255, blue: 1.0),      // purple
            Color(red: 63 / 255, green: 208 / 255, blue: 232 / 255), // teal
            Color(red: 1.0, green: 154 / 255, blue: 60 / 255),       // orange
        ]
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let first = seed % palette.count
        let second = (first + 1 + (seed / palette.count) % (palette.count - 1)) % palette.count
        return (palette[first], palette[second])
    }
}

#Preview {
    CuratedPlaylistView(
        playlist: HvscPlaylist(name: "Epic C64 SID Collection", file: "epic.m3u", description: String(localized: "Big tunes."), tracks: 210)
    )
    .environment(PlayerStore.preview)
    .environment(LibraryStore(player: .preview))
    .environment(FingerprintStore(player: .preview))
    .frame(width: 800, height: 500)
}
