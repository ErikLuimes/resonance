import SwiftUI

/// The playlist as a sortable, searchable table. Sorting and filtering only
/// change the view (like the Iced app); dragging rows reorders the playlist
/// itself, so it's only offered in playlist order.
struct PlaylistView: View {
    @Environment(PlayerStore.self) private var store
    @State private var selection = Set<TrackRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\TrackRow.index)]
    @State private var search = ""

    var body: some View {
        Group {
            if store.rows.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search playlist")
    }

    private var table: some View {
        Table(of: TrackRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("#", value: \.index) { row in
                if row.index == store.currentIndex {
                    Image(systemName: store.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(.tint)
                } else {
                    Text("\(row.index + 1)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(36)

            TableColumn("Title", value: \.title) { row in
                Text(row.title)
                    .fontWeight(row.index == store.currentIndex ? .semibold : .regular)
            }
            TableColumn("Author", value: \.author)
            TableColumn("Released", value: \.released)
            TableColumn("Length", value: \.length) { row in
                Text(row.lengthText).monospacedDigit()
            }
            .width(60)
            TableColumn("Songs", value: \.songs) { row in
                Text(row.songsText).monospacedDigit()
            }
            .width(56)
            TableColumn("SIDs", value: \.chips) { row in
                Text("\(row.chips)")
            }
            .width(36)
            TableColumn("Type", value: \.format)
                .width(48)
        } rows: {
            ForEach(displayedRows) { row in
                TableRow(row)
                    .draggable(PlaylistRowDrag(path: row.id))
            }
            .dropDestination(for: PlaylistRowDrag.self) { offset, drags in
                reorder(drags, to: offset)
            }
        }
        .contextMenu(forSelectionType: TrackRow.ID.self) { ids in
            if !ids.isEmpty {
                Button("Play") { play(ids) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(rows(for: ids).map(\.url))
                }
                Divider()
                Button("Remove from Playlist", role: .destructive) { remove(ids) }
            }
        } primaryAction: { ids in
            play(ids)
        }
        .onDeleteCommand { remove(selection) }
        .onKeyPress(.space) {
            store.playPause(fallback: rows(for: selection).first?.index)
            return .handled
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Tunes", systemImage: "music.note")
        } description: {
            Text("Drop SID files, folders or M3U playlists here.")
        } actions: {
            Button("Add Files…") { store.isImporting = true }
                .buttonStyle(.glassProminent)
        }
    }

    // MARK: Rows

    private var displayedRows: [TrackRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty
            ? store.rows
            : store.rows.filter {
                $0.title.localizedStandardContains(query)
                    || $0.author.localizedStandardContains(query)
                    || $0.released.localizedStandardContains(query)
            }
        return filtered.sorted(using: sortOrder)
    }

    /// Reordering is only meaningful when the view shows playlist order.
    private var isInPlaylistOrder: Bool {
        search.isEmpty && sortOrder.first?.keyPath == \TrackRow.index && sortOrder.first?.order == .forward
    }

    private func rows(for ids: Set<TrackRow.ID>) -> [TrackRow] {
        store.rows.filter { ids.contains($0.id) }
    }

    // MARK: Actions

    private func play(_ ids: Set<TrackRow.ID>) {
        if let first = rows(for: ids).first {
            store.play(index: first.index)
        }
    }

    private func remove(_ ids: Set<TrackRow.ID>) {
        store.remove(indices: rows(for: ids).map(\.index))
        selection.subtract(ids)
    }

    private func reorder(_ drags: [PlaylistRowDrag], to offset: Int) {
        guard isInPlaylistOrder else { return }
        let paths = Set(drags.map(\.path))
        let moving = IndexSet(store.rows.filter { paths.contains($0.id) }.map(\.index))
        guard !moving.isEmpty else { return }
        store.move(fromOffsets: moving, toOffset: offset)
    }
}

#Preview {
    PlaylistView()
        .environment(PlayerStore.preview)
        .frame(width: 800, height: 400)
}
