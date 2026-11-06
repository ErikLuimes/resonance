import SwiftUI
import UniformTypeIdentifiers
import PhosphorCore

/// What the sidebar can show. Favorites and Recent slot in here later.
enum SidebarItem: Hashable {
    /// Search's own place: everything in HVSC that matches.
    case search
    case playlist
    /// The play history.
    case recent
    /// The HVSC Home: the collection's header row in the sidebar.
    case hvscHome
    case hvsc(HvscCategory)
#if CSDB
    /// The C64 scene, from CSDb.
    case scene
    /// The tunes downloaded from CSDb.
    case csdbDownloads
#endif
    /// One of Phosphor's published playlists, by its file name.
    case curated(String)
    case favourites
    /// Making a playlist from a recipe.
    case smartPlaylist
    /// One of your playlists, by its file name.
    case userPlaylist(String)
}

/// What Resonance opens on (Settings → Appearance).
enum StartPage: String, CaseIterable, Identifiable {
    case myPlaylist, favourites, recentlyPlayed, hvscHome, musicians
#if CSDB
    case scenePulse
#endif

    var id: Self { self }

    var title: String {
        switch self {
        case .myPlaylist: "My Playlist"
        case .favourites: "Favourites"
        case .recentlyPlayed: "Recently Played"
        case .hvscHome: "HVSC Home"
        case .musicians: "Musicians"
#if CSDB
        case .scenePulse: "Scene Pulse"
#endif
        }
    }

    /// Where it is in the sidebar. Scene Pulse isn't there with CSDb off.
    func item(csdbEnabled: Bool) -> SidebarItem {
        switch self {
        case .myPlaylist: .playlist
        case .favourites: .favourites
        case .recentlyPlayed: .recent
        case .hvscHome: .hvscHome
        case .musicians: .hvsc(.musicians)
#if CSDB
        case .scenePulse: csdbEnabled ? .scene : .hvscHome
#endif
        }
    }

    /// Where the window opens, as things are set now.
    static var opening: SidebarItem {
#if CSDB
        let enabled = UserDefaults.standard.object(forKey: Pref.csdbEnabled) as? Bool ?? false
        return saved().item(csdbEnabled: enabled)
#else
        return saved().item(csdbEnabled: false)
#endif
    }

    static func saved(in defaults: UserDefaults = .standard) -> StartPage {
        defaults.string(forKey: Pref.startPage).flatMap(StartPage.init) ?? .myPlaylist
    }
}

extension EnvironmentValues {
    /// Search is over this section: it's kept, but mustn't animate, fetch or
    /// react to a pointer it can't be seen under. Clicks are already stopped,
    /// but hovers aren't, nor do timers know.
    @Entry var sectionIsCovered = false
}

struct ContentView: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistsStore.self) private var playlists
#if CSDB
    @Environment(CSDbStore.self) private var csdb
#endif
    @Environment(\.openWindow) private var openWindow
    @State private var sidebarSelection: SidebarItem? = StartPage.opening
    @State private var showInspector = true
    @State private var isDropTargeted = false
    @State private var isSidebarDropTargeted = false
    @AppStorage("sidebar.curatedExpanded") private var curatedExpanded = true
#if CSDB
    @AppStorage(Pref.csdbEnabled) private var csdbEnabled = false
#endif
    /// The collection folder the Home was last opened for on its own.
    @AppStorage(Pref.homeShownForRoot) private var homeShownForRoot = ""
    /// The search field's text, the same from every section.
    @State private var searchQuery = ""
    /// The last section that isn't Search. It stays in the window under
    /// Search, so clearing the field finds it just as it was.
    @State private var browsedSection = StartPage.opening
    /// Typing opened Search, so clearing the field goes back. (Search opened
    /// from its sidebar row stays when the field empties.)
    @State private var returnsWhenCleared = false
    /// Goes up with each press of Return in the search field.
    @State private var submittedSearches = 0
    @FocusState private var isSearchFieldFocused: Bool
    /// Now Playing is in the window: while it shows, and while it slides away.
    @State private var isNowPlayingMounted = false
    @State private var isNowPlayingLeaving = false

    private static let nowPlayingSlide = Animation.spring(response: 0.45, dampingFraction: 0.85)

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
            if isNowPlayingMounted {
                // Paused as soon as it starts sliding away. The slide-out is
                // an offset rather than a removal transition: SwiftUI never
                // finished that one, and the view stayed parked below the
                // window, redrawing its visualizer on every resize. Once the
                // offset lands, it's removed outright.
                let leaving = isNowPlayingLeaving
                NowPlayingView(isShowing: store.isShowingNowPlaying)
                    .ignoresSafeArea()
                    .visualEffect { content, proxy in
                        content.offset(y: leaving ? proxy.size.height : 0)
                    }
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .identity))
                    .zIndex(2)
            }
        }
        // On the root, as the library has its own sheet. It waits for a shared
        // tune's: a window shows one sheet at a time.
        .sheet(isPresented: Binding(
            get: { !store.welcomeSteps.isEmpty && store.sharedTune == nil },
            set: { if !$0 { store.welcomeSteps = [] } }
        )) {
            OnboardingSheet()
        }
        .onChange(of: store.isShowingNowPlaying) { _, showing in
            if showing {
                withAnimation(Self.nowPlayingSlide) {
                    isNowPlayingMounted = true
                    isNowPlayingLeaving = false
                }
            } else {
                withAnimation(Self.nowPlayingSlide) {
                    isNowPlayingLeaving = true
                } completion: {
                    // Unless it was opened again meanwhile.
                    guard !store.isShowingNowPlaying else { return }
                    isNowPlayingMounted = false
                    isNowPlayingLeaving = false
                }
            }
        }
        .toolbarVisibility(store.isShowingNowPlaying ? .hidden : .visible, for: .windowToolbar)
        .animation(Self.nowPlayingSlide, value: store.isShowingNowPlaying)
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
        // The menu bar player's Open Resonance: SwiftUI's action reopens
        // this window after it's been closed, too.
        .onAppear { [openWindow] in MiniPlayer.openMainWindow = { openWindow(id: "main") } }
        // A shared tune link, opened from the share page.
        .sheet(item: Binding(get: { store.sharedTune }, set: { store.sharedTune = $0 })) { link in
            // A new identity per link, so a second link opened while the
            // sheet shows looks its own tune up.
            SharedTuneSheet(link: link)
                .id(link)
        }
        // Constant on purpose, like the rest of the toolbar (see below).
        .navigationSubtitle("The SID, played and seen")
        // One search field for the whole window, with a fixed prompt. Each
        // section used to bring its own (the HVSC one with scope buttons),
        // so the toolbar changed on every sidebar click — which made SwiftUI
        // re-run the window layout until AppKit aborted the app.
        .searchable(text: searchText, placement: .toolbar, prompt: "Search tunes, composers and games")
        .searchFocused($isSearchFieldFocused)
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
        // A playlist just imported. A task, not onChange: a file opened from
        // Finder at launch sets it before this view exists.
        .task(id: playlists.revealing) {
            guard let id = playlists.revealing else { return }
            sidebarSelection = .userPlaylist(id)
            playlists.revealing = nil
        }
        // Any other row closes the search, whether clicked or following a link.
        .onChange(of: sidebarSelection) { _, selection in
            if selection == .search {
                isSearchFieldFocused = true
            } else if let selection {
                browsedSection = selection
                returnsWhenCleared = false
                searchQuery = ""
            }
        }
        // The inspector's author link (or a tune STIL links to): its section.
        .onChange(of: library.reveal) { _, reveal in
            guard let reveal else { return }
            sidebarSelection = .hvsc(reveal.category)
        }
        // The inspector's playlist link, a Home playlist card.
        .onChange(of: library.shownSection) { _, section in
            guard let section else { return }
            sidebarSelection = section
            library.shownSection = nil
        }
#if CSDB
        // Scene switched off in Settings while it's showing.
        .onChange(of: csdbEnabled) { _, enabled in
            if !enabled, sidebarSelection == .scene { sidebarSelection = .hvscHome }
        }
#endif
        // For a composer without a folder: the tune's section, so the browser
        // can list their tunes.
        .onChange(of: library.credits) { _, credits in
            guard let credits else { return }
            sidebarSelection = .hvsc(credits.category)
        }
    }

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section {
                Label("Search", systemImage: "magnifyingglass")
                    .modifier(RefusesFiles())
                    .tag(SidebarItem.search)
            }
            Section("Library") {
                SidebarLabel("Recently Played", systemImage: "clock", playing: playing(.recent))
                    .modifier(RefusesFiles())
                    .tag(SidebarItem.recent)
            }
            Section {
                Label("Smart Playlist", systemImage: "wand.and.stars")
                    .modifier(RefusesFiles())
                    .tag(SidebarItem.smartPlaylist)
                SidebarLabel("Favourites", systemImage: "heart", playing: playing(.favourites),
                             count: playlists.favourites?.count)
                    .modifier(PlaylistDrop(target: .favourites))
                    .background(SidebarDropHighlightOff())
                    .contextMenu { ExportPlaylistButton(target: .favourites, name: "Favourites") }
                    .tag(SidebarItem.favourites)
                SidebarLabel("My Playlist", systemImage: "music.note.list", playing: playing(.playlist),
                             count: store.rows.count)
                    .modifier(PlaylistDrop(target: .myPlaylist))
                    .contextMenu { ExportPlaylistButton(target: .myPlaylist, name: "My Playlist") }
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
                    .modifier(RefusesFiles())
                if store.hasCollection {
                    ForEach(HvscCategory.allCases, id: \.self) { category in
                        Label(category.displayName, systemImage: category.symbolName)
                            .modifier(RefusesFiles())
                            .tag(SidebarItem.hvsc(category))
                    }
                }
            }
#if CSDB
            // Downloads stay while CSDb is off: they play without it.
            if csdbEnabled || !csdb.downloadedIDs.isEmpty {
                Section("CSDb") {
                    if csdbEnabled {
                        SidebarLabel("Scene Pulse", systemImage: "antenna.radiowaves.left.and.right", playing: playing(.scene))
                            .modifier(RefusesFiles())
                            .tag(SidebarItem.scene)
                    }
                    SidebarLabel("Downloads", systemImage: "arrow.down.circle", playing: playing(.csdbDownloads),
                                 count: csdb.downloadedIDs.count)
                        .modifier(RefusesFiles())
                        .tag(SidebarItem.csdbDownloads)
                }
            }
#endif
            if store.hasCollection, let curated = store.hvscInfo?.playlists, !curated.isEmpty {
                Section("Curated Playlists", isExpanded: $curatedExpanded) {
                    ForEach(curated, id: \.file) { playlist in
                        CuratedPlaylistRow(playlist: playlist)
                            .modifier(RefusesFiles())
                            .tag(SidebarItem.curated(playlist.file))
                    }
                }
            }
        }
        // Files from Finder on the Playlists heading or an empty part of the
        // sidebar: rows that take them, or refuse them, answer for themselves.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await playlists.importAsNew(files) }
            return true
        } isTargeted: { isSidebarDropTargeted = $0 }
        .overlay {
            if isSidebarDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var section: SidebarItem { sidebarSelection ?? .playlist }

    private var trimmedQuery: String { searchQuery.trimmingCharacters(in: .whitespaces) }

    /// Return in the search field opens the top result.
    private func submitSearch() {
        if section == .search, !trimmedQuery.isEmpty { submittedSearches += 1 }
    }

    /// Whether `item` is the list that's playing, for the sidebar's speaker.
    private func playing(_ item: SidebarItem) -> Bool {
        store.isPlaying && store.source?.section == item
    }

    /// The first keystroke goes to Search, from anywhere; clearing the field
    /// comes back.
    private var searchText: Binding<String> {
        Binding(
            get: { searchQuery },
            set: { text in
                searchQuery = text
                let isEmpty = text.trimmingCharacters(in: .whitespaces).isEmpty
                if !isEmpty, section != .search {
                    returnsWhenCleared = true
                    sidebarSelection = .search
                } else if isEmpty, section == .search, returnsWhenCleared {
                    returnsWhenCleared = false
                    sidebarSelection = browsedSection
                }
            }
        )
    }

    /// The section's view, dressed for the window: the now-playing bar,
    /// the status banner and the inspector around it.
    @ViewBuilder
    private var detail: some View {
        detailContent
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
                StatusBanner(showsSync: section != .hvscHome || store.hvscInfo != nil)
            }
            .inspector(isPresented: $showInspector) {
                NowPlayingInspector()
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 400)

            }
    }

    /// The section, with Search over it while that's open. The section stays
    /// in place underneath, so its selection, scroll position and filter are
    /// all still there when the search closes; it only rests meanwhile (see
    /// `sectionIsCovered`). Any other section replaces it outright.
    private var detailContent: some View {
        let searching = section == .search
        return ZStack {
            sectionContent(searching ? browsedSection : section)
                .opacity(searching ? 0 : 1)
                .allowsHitTesting(!searching)
                .accessibilityHidden(searching)
                .environment(\.sectionIsCovered, searching)
            if searching {
                SearchView(query: trimmedQuery, submissions: submittedSearches)
            }
        }
    }

    @ViewBuilder
    private func sectionContent(_ item: SidebarItem) -> some View {
        switch item {
        case .search:
            EmptyView()
        case .playlist:
            PlaylistView()
        case .recent:
            RecentlyPlayedView()
        case .hvscHome:
            HVSCHomeView { category in
                sidebarSelection = .hvsc(category)
            }
        case .hvsc(let category):
            // A fresh view (and selection) per category.
            HVSCBrowserView(category: category)
                .id(category)
#if CSDB
        case .scene:
            SceneView()
        case .csdbDownloads:
            CSDbDownloadsView()
#endif
        case .smartPlaylist:
            SmartPlaylistView()
        case .favourites:
            UserPlaylistView(playlist: nil)
        case .userPlaylist(let id):
            if let playlist = playlists.playlist(id) {
                UserPlaylistView(playlist: playlist)
                    .id(id)
            } else {
                ContentUnavailableView("Playlist Not Found", systemImage: "music.note.list")
            }
        case .curated(let file):
            if let playlist = store.hvscInfo?.playlists.first(where: { $0.file == file }) {
                CuratedPlaylistView(playlist: playlist)
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
                // An icon: the word wrapped in a narrow sidebar.
                Button("Download", systemImage: "arrow.down.circle") { store.startHvscSync() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.body)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .help("Download the High Voltage SID Collection")
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
    @Environment(PlaylistsStore.self) private var playlists
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
            if let importing = playlists.importing {
                Label {
                    Text(importing)
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
            if let notice = playlists.importNotice {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(notice)
                        .lineLimit(2)
                    Button("Dismiss", systemImage: "xmark") { playlists.importNotice = nil }
                        .labelStyle(.iconOnly)
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
        .animation(.default, value: playlists.importing)
        .animation(.default, value: playlists.importNotice)
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
/// A sidebar list's Export… item: asks where, then saves an M3U there.
private struct ExportPlaylistButton: View {
    let target: AddTarget
    let name: String

    @Environment(PlaylistsStore.self) private var playlists

    var body: some View {
        Button("Export…") {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.m3uPlaylist]
            panel.nameFieldStringValue = name + ".m3u"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                playlists.export(target, to: url)
            }
        }
        .disabled(playlists.exportContents(of: target).files.isEmpty)
    }
}

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
        .modifier(PlaylistDrop(target: .playlist(playlist.id)))
        .contextMenu {
            Button("Play") { play() }
            Divider()
            Button("Rename") { playlists.renaming = playlist.id }
            Button("Duplicate") {
                if let copy = playlists.duplicate(playlist) { selection = .userPlaylist(copy.id) }
            }
            ExportPlaylistButton(target: .playlist(playlist.id), name: playlist.name)
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

/// A sidebar row that isn't a list of yours turns files from Finder away.
/// Without this they'd reach the sidebar's own drop, which makes a playlist.
private struct RefusesFiles: ViewModifier {
    private struct Refusal: DropDelegate {
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .forbidden) }
        func performDrop(info: DropInfo) -> Bool { false }
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect.inset(by: -6))
            .onDrop(of: [.fileURL], delegate: Refusal())
    }
}

/// Tunes dragged from a list onto a sidebar playlist (or Favourites, or My
/// Playlist) are added to it, under the system's drop highlight, and so is
/// what's behind files dropped from Finder. Holding ⌘
/// as they drop moves them instead, from one of your playlists to another,
/// as ⌘ moves in Finder; from any other list, and into Favourites or My
/// Playlist, they're always added. (A sidebar row only takes drops through
/// dropDestination, so the cursor's + can't change to show a move.)
private struct PlaylistDrop: ViewModifier {
    let target: AddTarget

    @Environment(PlaylistsStore.self) private var playlists
    @State private var targeted = false

    func body(content: Content) -> some View {
        Group {
            if targeted {
                content.foregroundStyle(.white)
            } else {
                content
            }
        }
        // The whole row is the target, so the highlight shows wherever
        // the tunes hover: over the label alone, the row's own drop
        // highlight showed in the gaps beside it, and in the margin
        // above and below the drop still landed but nothing lit up.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Lit like a selected row: the outline view's own highlight is
        // off (SidebarDropHighlightOff), as it lit only part of a row.
        .background {
            if targeted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.tint)
                    .padding(.horizontal, -8)
                    .padding(.vertical, -3)
            }
        }
        .contentShape(.rect.inset(by: -6))
        .dropDestination(for: SidebarDrop.self) { items, _ in
            let urls = items.compactMap { item -> URL? in
                if case .file(let url) = item, url.isFileURL { url } else { nil }
            }
            if !urls.isEmpty {
                Task { await playlists.addFiles(urls, to: target) }
                return true
            }
            let drags = items.compactMap { item -> PlaylistRowDrag? in
                if case .tunes(let drag) = item { drag } else { nil }
            }
            let files = drags.flatMap(\.paths)
            guard !files.isEmpty else { return false }
            if case .playlist(let id) = target, drags.allSatisfy({ $0.from == id }) { return false }
            let moving = NSEvent.modifierFlags.contains(.command)
            Task {
                await playlists.add(files, to: target)
                guard moving, case .playlist(let id) = target else { return }
                for drag in drags {
                    if let from = drag.from, from != id, let source = playlists.playlist(from) {
                        playlists.remove(Set(drag.paths), from: source)
                    }
                }
            }
            return true
        } isTargeted: { targeted = $0 }
    }
}
