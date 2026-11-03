import SwiftUI
import UniformTypeIdentifiers
import PhosphorCore

/// What the sidebar can show. Favorites and Recent slot in here later.
enum SidebarItem: Hashable {
    case playlist
    /// The play history shared with Phosphor.
    case recent
    /// The HVSC Home: the collection's header row in the sidebar.
    case hvscHome
    case hvsc(HvscCategory)
    /// One of Phosphor's published playlists, by its file name.
    case curated(String)
    case favourites
    /// One of your playlists, by its file name.
    case userPlaylist(String)
}

struct ContentView: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistsStore.self) private var playlists
    @State private var sidebarSelection: SidebarItem? = .playlist
    @State private var showInspector = true
    @State private var isDropTargeted = false
    @AppStorage("sidebar.curatedExpanded") private var curatedExpanded = true
    /// The collection folder the Home was last opened for on its own.
    @AppStorage(Pref.homeShownForRoot) private var homeShownForRoot = ""
    /// Each sidebar section keeps its own search text.
    @State private var searches: [SidebarItem: String] = [:]

    var body: some View {
        // Now Playing slides up over the library: a sibling of it in a
        // ZStack with its own zIndex, so the removal transition draws on top
        // and completes. The title bar hides as a whole while it shows,
        // window buttons included: in that mode the window is only closed
        // back to the library, with Now Playing's own button. (Hiding the
        // toolbar whole is safe; changing its items per state is what
        // crashed the window, see searchable below.)
        ZStack(alignment: .bottom) {
            libraryMode
            if store.isShowingNowPlaying {
                // Paused as soon as it starts sliding away: its running
                // animation clock otherwise kept SwiftUI from ever finishing
                // the removal, and the view stayed parked below the window.
                NowPlayingView(isShowing: store.isShowingNowPlaying)
                    .ignoresSafeArea()
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .bottom)))
                    .zIndex(2)
            }
        }
        .toolbarVisibility(store.isShowingNowPlaying ? .hidden : .visible, for: .windowToolbar)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: store.isShowingNowPlaying)
        // A constant for the window, not a minimum inside the split view,
        // which made AppKit re-run layout until it aborted (see
        // NowPlayingBar). Only the inspector button changes it.
        .frame(minWidth: Self.minWidth(inspector: showInspector))
    }

    /// Narrowest the window gets: the sidebar, a bottom bar with room for
    /// its controls and some of the title, and the inspector when it shows.
    static func minWidth(inspector: Bool) -> CGFloat {
        160 + 520 + (inspector ? 260 : 0)
    }

    private var libraryMode: some View {
        @Bindable var store = store
        return NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Surprise Me", systemImage: "dice") {
                    Task { await library.surpriseMe() }
                }
                // Menu shortcut included. Only the symbol animates, so the
                // toolbar itself stays the same (see searchable below).
                .symbolEffect(.wiggle, value: library.surprises)
                .help("Play random tunes from all of HVSC")
                .disabled(!store.hasCollection)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Files", systemImage: "plus") { store.isImporting = true }
                    .help("Add SID files, folders or playlists")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                    .help(showInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
        .navigationTitle("Resonance")
        // Constant on purpose, like the rest of the toolbar (see below).
        .navigationSubtitle("powered by Phosphor")
        // One search field for the whole window, with a fixed prompt. Each
        // section used to bring its own (the HVSC one with scope buttons),
        // so the toolbar changed on every sidebar click — which made SwiftUI
        // re-run the window layout until AppKit aborted the app.
        .searchable(text: searchText, placement: .toolbar, prompt: "Search")
        .onSubmit(of: .search) { submitSearch() }
        .fileImporter(
            isPresented: $store.isImporting,
            allowedContentTypes: [.sidTune, .m3uPlaylist, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                store.add(urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        // The HVSC Home's metadata (and the sidebar's release badge): one
        // core walk of the tree per revision change.
        .task(id: store.hvscTreeRevision) { await store.loadHvscInfo() }
        // Once a launch, like Phosphor: is there a newer HVSC release, and
        // are the published playlists current?
        .task { await store.checkHvscUpdate() }
        .task { await store.syncPublishedPlaylists() }
        // The hearts, and Favourites' count.
        .task(id: store.hvscRoot) { await playlists.loadFavourites() }
        // No collection yet: the Home (its empty state) is the welcome pane.
        // A collection seen for the first time (downloaded, put in place by
        // hand, or another folder chosen) opens on its Home once.
        .task(id: "\(store.hasCollection) \(store.hvscRoot ?? "")") {
            if !store.hasCollection {
                sidebarSelection = .hvscHome
            } else if let root = store.hvscRoot, root != homeShownForRoot {
                homeShownForRoot = root
                sidebarSelection = .hvscHome
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // The inspector's author link (or a tune STIL links to): its
        // section, with no search, so the author list shows.
        .onChange(of: library.reveal) { _, reveal in
            guard let reveal else { return }
            searches[.hvsc(reveal.category)] = ""
            sidebarSelection = .hvsc(reveal.category)
        }
        // For a composer without a folder: the tune's section, with no
        // search, so the browser can list their tunes.
        // The inspector's playlist link, a Home playlist card.
        .onChange(of: library.shownSection) { _, section in
            guard let section else { return }
            searches[section] = ""
            sidebarSelection = section
            library.shownSection = nil
        }
        .onChange(of: library.credits) { _, credits in
            guard let credits else { return }
            searches[.hvsc(credits.category)] = ""
            sidebarSelection = .hvsc(credits.category)
        }
    }

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section("Library") {
                SidebarLabel("Recently Played", systemImage: "clock", playing: playing(.recent))
                    .tag(SidebarItem.recent)
            }
            Section {
                SidebarLabel("Favourites", systemImage: "heart", playing: playing(.favourites),
                             count: playlists.favourites?.count)
                    .tag(SidebarItem.favourites)
                SidebarLabel("My Playlist", systemImage: "music.note.list", playing: playing(.playlist),
                             count: store.rows.count)
                    .tag(SidebarItem.playlist)
                ForEach(playlists.playlists) { playlist in
                    UserPlaylistRow(playlist: playlist, playing: playing(.userPlaylist(playlist.id)),
                                    selection: $sidebarSelection)
                        .tag(SidebarItem.userPlaylist(playlist.id))
                }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button {
                        if let made = playlists.create() {
                            sidebarSelection = .userPlaylist(made.id)
                            playlists.renaming = made.id
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Playlist")
                    .accessibilityLabel("New Playlist")
                }
            }
            Section("HVSC") {
                HvscCollectionRow(isSelected: sidebarSelection == .hvscHome)
                if store.hasCollection {
                    ForEach(HvscCategory.allCases, id: \.self) { category in
                        Label(category.displayName, systemImage: category.symbolName)
                            .tag(SidebarItem.hvsc(category))
                    }
                }
            }
            if store.hasCollection, let curated = store.hvscInfo?.playlists, !curated.isEmpty {
                Section("Curated Playlists", isExpanded: $curatedExpanded) {
                    ForEach(curated, id: \.file) { playlist in
                        CuratedPlaylistRow(playlist: playlist)
                            .tag(SidebarItem.curated(playlist.file))
                    }
                }
            }
        }
    }

    private var section: SidebarItem { sidebarSelection ?? .playlist }

    /// The search typed in a list outside HVSC, which it can take to all of
    /// HVSC; nil in the HVSC sections, which search it themselves.
    private var searchAllQuery: String? {
        if case .hvsc = section { return nil }
        let query = searchText.wrappedValue.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || !store.hasCollection ? nil : query
    }

    /// Search all of HVSC for `query`, in Musicians' results.
    private func searchAllHvsc(_ query: String) {
        searches[section] = ""
        searches[.hvsc(.musicians)] = query
        library.searchesAllHvsc = true
        sidebarSelection = .hvsc(.musicians)
    }

    /// Return in the search field: in an HVSC section, open the composer
    /// it names first; elsewhere, search all of HVSC.
    private func submitSearch() {
        let query = searchText.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        if case .hvsc(let category) = section {
            if let first = library.composers(matching: query, in: category, limit: 1).first {
                library.showComposer(first.path, in: category)
            }
        } else if store.hasCollection {
            searchAllHvsc(query)
        }
    }

    /// Whether `item` is the list that's playing, for the sidebar's speaker.
    private func playing(_ item: SidebarItem) -> Bool {
        store.isPlaying && store.source?.section == item
    }

    private var searchText: Binding<String> {
        Binding(
            get: { searches[section, default: ""] },
            set: { searches[section] = $0 }
        )
    }

    /// The section's view, dressed for the window: the now-playing bar,
    /// the status banner and the inspector around it.
    @ViewBuilder
    private var detail: some View {
        detailContent
            // Outside HVSC the search only filters the list shown; this
            // takes it to all of HVSC.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let query = searchAllQuery {
                    Button {
                        searchAllHvsc(query)
                    } label: {
                        Label("Search all of HVSC for “\(query)”", systemImage: "magnifyingglass")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .help("Return does this too")
                }
            }
            // The column's minimum width must not follow its content
            // (see NowPlayingBar): pin it, and let content adapt.
            .frame(minWidth: 0, maxWidth: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NowPlayingBar()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .overlay(alignment: .top) {
                // The Home view is the first download's status surface;
                // other panes, and an update, get the pill instead.
                StatusBanner(showsSync: section != .hvscHome || store.hasCollection)
            }
            .inspector(isPresented: $showInspector) {
                NowPlayingInspector()
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 400)

            }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch section {
        case .playlist:
            PlaylistView(search: searchText.wrappedValue)
        case .recent:
            RecentlyPlayedView(search: searchText.wrappedValue)
        case .hvscHome:
            HVSCHomeView { category in
                searches[.hvsc(category)] = ""
                sidebarSelection = .hvsc(category)
            }
        case .hvsc(let category):
            // A fresh view (and selection) per category.
            HVSCBrowserView(category: category, search: searchText.wrappedValue)
                .id(category)
        case .favourites:
            UserPlaylistView(playlist: nil, search: searchText.wrappedValue)
        case .userPlaylist(let id):
            if let playlist = playlists.playlist(id) {
                UserPlaylistView(playlist: playlist, search: searchText.wrappedValue)
                    .id(id)
            } else {
                ContentUnavailableView("Playlist Not Found", systemImage: "music.note.list")
            }
        case .curated(let file):
            if let playlist = store.hvscInfo?.playlists.first(where: { $0.file == file }) {
                CuratedPlaylistView(playlist: playlist, search: searchText.wrappedValue)
                    .id(file)
            } else {
                ContentUnavailableView("Playlist Not Found", systemImage: "music.note.list")
            }
        }
    }
}

/// The sidebar's collection row: it offers the download before the folder
/// holds a tree, shows its percentage while one runs, and carries the
/// release badge (and an update, when there is one) afterwards.
/// Selecting it shows the HVSC Home.
private struct HvscCollectionRow: View {
    @Environment(PlayerStore.self) private var store
    /// On the selection highlight, where the tint would vanish. (The
    /// sidebar doesn't report it through `backgroundProminence`.)
    var isSelected = false

    var body: some View {
        let sync = store.hvscSync
        let running = sync?.running == true
        let version = store.hasCollection ? store.hvscInfo?.version : nil
        let showsUpdate = store.hvscUpdateAvailable && !running

        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 155 / 255, green: 107 / 255, blue: 1.0),
                            Color(red: 63 / 255, green: 208 / 255, blue: 232 / 255),
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ),
                    in: .rect(cornerRadius: 6)
                )

            // Short, so the release badge and what's on the right (Download,
            // Update, a download's percentage) always fit; the section is
            // already headed HVSC, and the Home has the full name.
            Text("Collection")
                .lineLimit(1)

            if let version {
                Text("v\(version)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    // White on the selection highlight, where the tint
                    // would vanish into it.
                    .background(isSelected ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(.tint.opacity(0.18)), in: .capsule)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            }

            Spacer(minLength: 4)

            if running, let fraction = sync?.fraction {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if !store.hasCollection && !running {
                Button("Download") { store.startHvscSync() }
                    .buttonStyle(.borderless)
                    .font(.callout)
            } else if showsUpdate, let latest = store.latestHvsc {
                Button("Update") { store.startHvscSync() }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .help("Update to HVSC \(latest)")
            }
        }
        .tag(SidebarItem.hvscHome)
        .animation(.default, value: store.hasCollection)
    }
}

/// Loading progress and errors, floating over the top of the pane below.
/// The collection download joins the queue wherever but the Home view,
/// which shows it in full.
private struct StatusBanner: View {
    @Environment(PlayerStore.self) private var store
    @State private var dismissedError: String?
    var showsSync: Bool = true

    /// "Downloading HVSC 85…", then "Extracting HVSC 85…" once the
    /// archive's files are counted.
    static func phase(of sync: HvscSyncStatus, release: UInt32?) -> String {
        let name = release.map { "HVSC \($0)" } ?? "HVSC"
        return sync.filesTotal > 0 ? "Extracting \(name)…" : "Downloading \(name)…"
    }

    var body: some View {
        VStack(spacing: 8) {
            if let sync = store.hvscSync, sync.running, showsSync {
                HStack(spacing: 10) {
                    if let fraction = sync.fraction {
                        ProgressView(value: fraction)
                            .frame(width: 110)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    // What's happening, not which file: Settings has those.
                    Text(Self.phase(of: sync, release: store.latestHvsc))
                        .lineLimit(1)
                    Button("Cancel") { store.cancelHvscSync() }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            } else if let sync = store.hvscSync, let error = sync.error, !sync.running, showsSync {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .lineLimit(1)
                    Button("Retry") { store.startHvscSync() }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
            if let loading = store.loading {
                Label {
                    Text(loading)
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
            if let error = store.error, error != dismissedError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .lineLimit(2)
                    Button("Dismiss", systemImage: "xmark") { dismissedError = error }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.top, 10)
        .animation(.default, value: store.loading)
        .animation(.default, value: store.error)
    }
}

#Preview {
    ContentView()
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .environment(FingerprintStore(player: .preview))
        .environment(PlaylistsStore(player: .preview))
        .frame(width: 1100, height: 680)
}


/// A sidebar row: its label, then a speaker while it's the list playing,
/// else its count.
private struct SidebarLabel: View {
    let title: String
    let systemImage: String
    let playing: Bool
    var count: Int? = nil

    init(_ title: String, systemImage: String, playing: Bool, count: Int? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.playing = playing
        self.count = count
    }

    var body: some View {
        Label {
            HStack {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if playing {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Playing")
                } else if let count, count > 0 {
                    Text(count.formatted())
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// One of your playlists in the sidebar: its name (edited in place right
/// after it's made, or on Rename), and a menu to play, rename, duplicate,
/// show or delete it.
private struct UserPlaylistRow: View {
    let playlist: UserPlaylist
    let playing: Bool
    @Binding var selection: SidebarItem?

    @Environment(PlaylistsStore.self) private var playlists
    @Environment(LibraryStore.self) private var library
    @State private var name = ""
    @State private var confirmingDelete = false
    @FocusState private var editing: Bool

    var body: some View {
        Group {
            if playlists.renaming == playlist.id {
                Label {
                    TextField("Name", text: $name)
                        .focused($editing)
                        .onSubmit(commit)
                        .onAppear {
                            name = playlist.name
                            editing = true
                        }
                        .onChange(of: editing) { if !editing { commit() } }
                } icon: {
                    Image(systemName: "music.note.list")
                }
            } else {
                SidebarLabel(playlist.name, systemImage: "music.note.list", playing: playing,
                             count: playlists.paths[playlist.id]?.count)
            }
        }
        .contextMenu {
            Button("Play") { play() }
            Divider()
            Button("Rename") { playlists.renaming = playlist.id }
            Button("Duplicate") {
                if let copy = playlists.duplicate(playlist) { selection = .userPlaylist(copy.id) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([playlist.url]) }
            Divider()
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if selection == .userPlaylist(playlist.id) { selection = .favourites }
                playlists.delete(playlist)
            }
        } message: {
            Text("The playlist moves to the Trash. Its tunes stay where they are.")
        }
        // The count, without reading every playlist's tunes.
        .task { _ = playlists.read(playlist) }
    }

    private func commit() {
        guard playlists.renaming == playlist.id else { return }
        if let renamed = playlists.rename(playlist, to: name), selection == .userPlaylist(playlist.id) {
            selection = .userPlaylist(renamed.id)
        }
        playlists.renaming = nil
    }

    private func play() {
        let urls = playlists.read(playlist).map { URL(filePath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = urls.first else { return }
        library.player.playQueue(urls, startAt: first, from: .playlist(id: playlist.id, name: playlist.name))
    }
}
