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

/// A heart that makes the tune a favorite, or not.
struct FavoriteButton: View {
    let path: String

    @Environment(PlaylistsStore.self) private var playlists

    var body: some View {
        let on = playlists.isFavorite(path)
        Button {
            Task { await playlists.setFavorite(path, !on) }
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .foregroundStyle(on ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(on ? "Remove from Favorites" : "Add to Favorites")
        .accessibilityLabel(on ? "Remove from Favorites" : "Add to Favorites")
    }
}

/// Add to…: a popover to add tunes to My Playlist, Favorites or one of
/// your playlists, found by typing; a name nobody has yet makes a new one.
struct AddToButton: View {
    let files: [String]
    var label = String(localized: "Add to…")

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
            if matches(String(localized: "My Playlist")) {
                row(String(localized: "My Playlist"), symbol: "music.note.list") { add(.myPlaylist) }
            }
            if matches(String(localized: "Favorites")) {
                row(String(localized: "Favorites"), symbol: "heart") { add(.favorites) }
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

    private var newTitle: String { trimmed.isEmpty ? String(localized: "New Playlist") : String(localized: "New Playlist “\(trimmed)”") }

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
/// My Playlist, Favorites, your playlists (latest first), New Playlist.
struct AddToMenu: View {
    let files: [String]

    @Environment(PlaylistsStore.self) private var playlists

    var body: some View {
        Menu("Add to") {
            Button("My Playlist") { add(.myPlaylist) }
            Button("Favorites") { add(.favorites) }
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

/// The row under a list's header: the Sound menu on the left, what the list does
/// on the right. It's the same on every list. In a narrow pane the actions keep
/// just their icons, all but Play, and it never asks for more width than the
/// pane has: that would push the panes beside it out of line.
struct ListBar<Actions: View, Extra: View>: View {
    @Binding var sound: Set<SoundTag>
    /// Whether any tune here has a fingerprint to filter by.
    var showsSound = true
    /// How many are shown and in all, while Sound narrows them.
    var shown = 0
    var total = 0
    @ViewBuilder var actions: Actions
    /// A line under it, such as what the list is sorted by.
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    soundControls
                    Spacer(minLength: 8)
                    actions
                }
                HStack(spacing: 8) {
                    soundControls
                    Spacer(minLength: 0)
                    actions
                        .labelStyle(BarIconLabelStyle())
                }
                HStack(spacing: 6) {
                    soundControls
                        .labelStyle(BarIconLabelStyle())
                    Spacer(minLength: 0)
                    actions
                        .labelStyle(BarIconLabelStyle())
                }
            }
            extra
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(.bar)
    }

    @ViewBuilder
    private var soundControls: some View {
        if showsSound { SoundMenu(selection: $sound) }
        if !sound.isEmpty {
            Text("\(shown.formatted()) of \(total.formatted()) tunes")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            AccentLink(String(localized: "Clear")) { sound = [] }
                .fixedSize()
        }
    }
}

/// Just the icon, as tall as the same button with words: `.iconOnly` is shorter,
/// which stood out beside the others. The hidden title holds the height.
private struct BarIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            configuration.title
                .lineLimit(1)
                .fixedSize()
                .frame(width: 0)
                .hidden()
            configuration.icon
        }
    }
}

extension ListBar where Extra == EmptyView {
    init(sound: Binding<Set<SoundTag>>, showsSound: Bool = true, shown: Int = 0, total: Int = 0,
         @ViewBuilder actions: () -> Actions) {
        self.init(sound: sound, showsSound: showsSound, shown: shown, total: total, actions: actions, extra: { EmptyView() })
    }
}

/// A list's sounds to narrow it by, any number of them; a tune must have them
/// all. A pill that names what's on.
struct SoundMenu: View {
    @Binding var selection: Set<SoundTag>

    private var title: String {
        switch selection.count {
        case 0: String(localized: "Sound")
        case 1: selection.first?.name ?? String(localized: "Sound")
        default: String(localized: "Sound: \(selection.count)")
        }
    }

    var body: some View {
        let menu = Menu {
            ForEach(SoundTag.filters, id: \.self) { tag in
                Toggle(tag.name, isOn: Binding(
                    get: { selection.contains(tag) },
                    set: { on in
                        if on { selection.insert(tag) } else { selection.remove(tag) }
                    }
                ))
            }
            if !selection.isEmpty {
                Divider()
                Button("Clear") { selection = [] }
            }
        } label: {
            Label(title, systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.button)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .help("Show only tunes with these sounds")
        if selection.isEmpty {
            menu.buttonStyle(.bordered)
        } else {
            menu.buttonStyle(.borderedProminent)
        }
    }
}

/// A list's Play: small, and the same everywhere.
struct ListPlayButton: View {
    var title = String(localized: "Play")
    var isDisabled = false
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            Label(title, systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isDisabled)
        .fixedSize()
    }
}

/// What a composer's or section's list does, in the row with Sound: add all of
/// its tunes, narrow it, or play them all, whatever the filter shows. Play is
/// last, as on every list, and the player bar says whether it's shuffled.
struct TuneListActions: View {
    @Binding var filter: String
    let rows: [LibraryRow]
    let source: PlaybackSource

    @Environment(LibraryStore.self) private var library

    var body: some View {
        AddToButton(files: rows.map(\.id))
            .disabled(rows.isEmpty)
            .fixedSize()
        ListFilterField(text: $filter)
        ListPlayButton(isDisabled: rows.isEmpty) { library.play(rows, from: source) }
    }
}

extension [LibraryRow] {
    /// The tunes a list's filter leaves.
    func matching(filter: String) -> [LibraryRow] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return self }
        return self.filter {
            $0.title.localizedStandardContains(query)
                || $0.author.localizedStandardContains(query)
                || $0.released.localizedStandardContains(query)
        }
    }
}

/// The small field that narrows the list it sits on, and nothing else. The
/// window's search field is for finding things anywhere.
struct ListFilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter this list", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
                .accessibilityLabel("Clear the filter")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: 60, maxWidth: 170)
        .background(.fill.tertiary, in: .rect(cornerRadius: 7))
    }
}
