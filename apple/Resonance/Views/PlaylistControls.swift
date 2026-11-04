import SwiftUI
import PhosphorCore

/// "Playing from Rob Hubbard": where the playing tune comes from, the
/// name a link that opens it (its sidebar section, or the tune in the
/// library). Nothing while nothing plays.
struct PlayingFrom: View {
    /// Shows what kind of list it is ("Composer: Rob Hubbard") instead of
    /// "Playing from".
    var showsKind = false

    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let source = store.source {
            Label {
                HStack(spacing: 4) {
                    Text(showsKind ? "\(source.kind):" : "Playing from")
                        .foregroundStyle(.secondary)
                    AccentLink(showsKind ? source.shortName : source.name) {
                        library.open(source, playing: store.nowPlaying?.path)
                    }
                        .lineLimit(1)
                        .help(source.section == nil ? "Show the tune in the library" : "Show \(source.name)")
                }
            } icon: {
                Image(systemName: source.symbol)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A heart that makes the tune a favourite, or not.
struct FavouriteButton: View {
    let path: String

    @Environment(PlaylistsStore.self) private var playlists

    var body: some View {
        let on = playlists.isFavourite(path)
        Button {
            Task { await playlists.setFavourite(path, !on) }
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .foregroundStyle(on ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(on ? "Remove from Favourites" : "Add to Favourites")
        .accessibilityLabel(on ? "Remove from Favourites" : "Add to Favourites")
    }
}

/// Add to…: a popover to add tunes to My Playlist, Favourites or one of
/// your playlists, found by typing; a name nobody has yet makes a new one.
struct AddToButton: View {
    let files: [String]
    var label = "Add to…"

    @State private var showing = false

    var body: some View {
        Button(label, systemImage: "plus") { showing = true }
            .help("Add to a playlist")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AddToPopover(files: files) { showing = false }
            }
    }
}

private struct AddToPopover: View {
    let files: [String]
    let done: () -> Void

    @Environment(PlaylistsStore.self) private var playlists
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Find a playlist", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .padding(.bottom, 6)
            if matches("My Playlist") {
                row("My Playlist", symbol: "music.note.list") { add(.myPlaylist) }
            }
            if matches("Favourites") {
                row("Favourites", symbol: "heart") { add(.favourites) }
            }
            let shown = playlists.recentlyUsed.filter { matches($0.name) }
            if !shown.isEmpty {
                Text("Your playlists")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.horizontal, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { playlist in
                            row(playlist.name, symbol: "music.note.list") { add(.playlist(playlist.id)) }
                        }
                    }
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
                .padding(.vertical, 4)
            row(newTitle, symbol: "plus") { makeNew() }
        }
        .padding(10)
        .frame(width: 260)
        .onAppear { focused = true }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var newTitle: String { trimmed.isEmpty ? "New Playlist" : "New Playlist “\(trimmed)”" }

    private func matches(_ name: String) -> Bool {
        trimmed.isEmpty || name.localizedCaseInsensitiveContains(trimmed)
    }

    private func row(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(.rect)
        }
        .buttonStyle(AddToRowStyle())
    }

    /// Return: the only match, else a new playlist by the typed name.
    private func submit() {
        let named = playlists.playlists.filter { matches($0.name) }
        if !trimmed.isEmpty, named.count == 1, let only = named.first {
            add(.playlist(only.id))
        } else if !trimmed.isEmpty {
            makeNew()
        }
    }

    private func add(_ target: AddTarget) {
        done()
        Task { await playlists.add(files, to: target) }
    }

    private func makeNew() {
        done()
        let name = trimmed.isEmpty ? nil : trimmed
        Task { await playlists.addToNew(files, named: name) }
    }
}

/// A menu row's hover highlight in the Add to popover.
private struct AddToRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}

/// The Add to submenu for context menus, which can't hold a search field:
/// My Playlist, Favourites, your playlists (latest first), New Playlist.
struct AddToMenu: View {
    let files: [String]

    @Environment(PlaylistsStore.self) private var playlists

    var body: some View {
        Menu("Add to") {
            Button("My Playlist") { add(.myPlaylist) }
            Button("Favourites") { add(.favourites) }
            if !playlists.playlists.isEmpty {
                Divider()
                ForEach(playlists.recentlyUsed.prefix(12)) { playlist in
                    Button(playlist.name) { add(.playlist(playlist.id)) }
                }
            }
            Divider()
            Button("New Playlist") { Task { await playlists.addToNew(files) } }
        }
    }

    private func add(_ target: AddTarget) {
        Task { await playlists.add(files, to: target) }
    }
}
