import SwiftUI
import PhosphorCore

/// Favourites, or one of your playlists: a header with its name, count and
/// Play, then its tunes. Tunes can be taken out of a playlist (a favourite
/// is un-hearted instead).
struct UserPlaylistView: View {
    /// Nil for Favourites.
    let playlist: UserPlaylist?
    /// The window search field's text for this list.
    let search: String

    @Environment(PlaylistsStore.self) private var playlists
    @Environment(LibraryStore.self) private var library

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
                         ? "Heart a tune in the inspector or Now Playing. Phosphor shares your favourites."
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
                             })
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
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: playlist == nil ? "heart.fill" : "music.note.list")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 76, height: 76)
                .background(
                    LinearGradient(
                        colors: playlist == nil
                            ? [Color(red: 1, green: 0.42, blue: 0.55), Color(red: 0.78, green: 0.25, blue: 0.62)]
                            : [Color(red: 0.42, green: 0.48, blue: 1), Color(red: 155 / 255, green: 107 / 255, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: .rect(cornerRadius: 17)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                library.play(playlists.rows[id] ?? [], from: source)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled((playlists.rows[id] ?? []).isEmpty)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        let count = playlists.rows[id]?.count
        let tunes = count.map { $0 == 1 ? "1 tune" : "\($0.formatted()) tunes" } ?? "…"
        return playlist == nil ? "\(tunes), shared with Phosphor" : tunes
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

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private func filtered(_ rows: [LibraryRow]) -> [LibraryRow] {
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.item.title.localizedCaseInsensitiveContains(query)
                || $0.item.author.localizedCaseInsensitiveContains(query)
        }
    }
}
