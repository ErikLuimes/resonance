import SwiftUI
import PhosphorCore

/// Favourites, or one of your playlists: a header with its name and count, then
/// its tunes. Tunes can be taken out of a playlist (a favourite
/// is un-hearted instead).
struct UserPlaylistView: View {
    /// Nil for Favourites.
    let playlist: UserPlaylist?

    @Environment(PlaylistsStore.self) private var playlists
    @Environment(LibraryStore.self) private var library
    /// The list's own filter.
    @State private var filter = ""

    private var id: String { playlist?.id ?? PlaylistsStore.favouritesID }
    private var source: PlaybackSource {
        playlist.map { .playlist(id: $0.id, name: $0.name) } ?? .favourites
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: TaskKey(id: id, loaded: playlists.rows[id] != nil)) {
            if playlists.rows[id] == nil { await playlists.loadRows(id) }
        }
    }

    private struct TaskKey: Equatable {
        let id: String
        let loaded: Bool
    }

    @ViewBuilder
    private var content: some View {
        if let rows = playlists.rows[id] {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(playlist == nil ? "No Favourites Yet" : "Empty Playlist",
                          systemImage: playlist == nil ? "heart" : "music.note.list")
                } description: {
                    Text(playlist == nil
                         ? "Heart a tune in the inspector or Now Playing."
                         : "Add tunes with Add to, in the inspector, Now Playing or a list's context menu.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let shown = filtered(rows)
                LibraryTable(rows: shown, source: source, onRemove: remove,
                             removeTitle: playlist == nil ? "Remove from Favourites" : "Remove from Playlist",
                             // Favourites keep the order they were hearted in.
                             onPlace: playlist == nil || !query.isEmpty ? nil : { files, offset in
                                 place(files, at: offset, among: shown)
                             },
                             actions: AnyView(listActions(rows)))
                    .overlay {
                        if !query.isEmpty && shown.isEmpty {
                            ContentUnavailableView.search(text: query)
                        }
                    }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        PlaylistHeader(title: source.name, tunes: playlists.rows[id]?.count, isFavourites: playlist == nil)
    }

    private func listActions(_ rows: [LibraryRow]) -> some View {
        Group {
            ListFilterField(text: $filter)
            ListPlayButton { library.play(rows, from: source) }
        }
    }

    /// Dropped at `offset` of the rows shown: before that row's file, or
    /// at the end (rows skip files no longer on disk, so it goes by file).
    private func place(_ files: [String], at offset: Int, among rows: [LibraryRow]) {
        guard let playlist else { return }
        playlists.place(files, before: rows.indices.contains(offset) ? rows[offset].id : nil, in: playlist)
    }

    private func remove(_ ids: Set<LibraryRow.ID>) {
        if let playlist {
            playlists.remove(ids, from: playlist)
        } else {
            Task { for path in ids { await playlists.setFavourite(path, false) } }
        }
    }

    private var query: String { filter.trimmingCharacters(in: .whitespaces) }

    private func filtered(_ rows: [LibraryRow]) -> [LibraryRow] {
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.item.title.localizedCaseInsensitiveContains(query)
                || $0.item.author.localizedCaseInsensitiveContains(query)
        }
    }
}

/// The header of a list of your own: its picture, name and tune count. What
/// you can do with it is in the row below, with the others' (`ListBar`).
struct PlaylistHeader: View {
    let title: String
    /// Nil until the list has loaded.
    let tunes: Int?
    var isFavourites = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: isFavourites ? "heart.fill" : "music.note.list")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 76, height: 76)
                .background(
                    LinearGradient(
                        colors: isFavourites
                            ? [Color(red: 1, green: 0.42, blue: 0.55), Color(red: 0.78, green: 0.25, blue: 0.62)]
                            : [Color(red: 0.42, green: 0.48, blue: 1), Color(red: 155 / 255, green: 107 / 255, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: .rect(cornerRadius: 17)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(tunes.map { $0 == 1 ? "1 tune" : "\($0.formatted()) tunes" } ?? "…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
