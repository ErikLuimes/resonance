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
}

struct ContentView: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @State private var sidebarSelection: SidebarItem? = .playlist
    @State private var showInspector = true
    @State private var isDropTargeted = false
    @AppStorage("sidebar.curatedExpanded") private var curatedExpanded = true
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
        // No collection yet: the Home (its empty state) is the welcome pane.
        .task(id: store.hasCollection) {
            if !store.hasCollection {
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
                Label("Playlist", systemImage: "music.note.list")
                    .badge(store.rows.count)
                    .tag(SidebarItem.playlist)
                Label("Recently Played", systemImage: "clock")
                    .tag(SidebarItem.recent)
            }
            Section("HVSC") {
                HvscCollectionRow()
                if store.hasCollection {
                    ForEach(HvscCategory.allCases, id: \.self) { category in
                        Label(category.displayName, systemImage: category.symbolName)
                            .tag(SidebarItem.hvsc(category))
                    }
                }
            }
            if store.hasCollection, let playlists = store.hvscInfo?.playlists, !playlists.isEmpty {
                Section("Curated Playlists", isExpanded: $curatedExpanded) {
                    ForEach(playlists, id: \.file) { playlist in
                        CuratedPlaylistRow(playlist: playlist)
                            .tag(SidebarItem.curated(playlist.file))
                    }
                }
            }
        }
    }

    private var section: SidebarItem { sidebarSelection ?? .playlist }

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
            // The column's minimum width must not follow its content
            // (see NowPlayingBar): pin it, and let content adapt.
            .frame(minWidth: 0, maxWidth: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NowPlayingBar()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .overlay(alignment: .top) {
                // The Home view is the download's status surface; other
                // panes get the pill instead.
                StatusBanner(showsSync: section != .hvscHome)
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
/// holds a tree, shows its percentage and a slim bar while one runs, and
/// becomes the collection's header (name, release badge) afterwards.
/// Selecting it shows the HVSC Home.
private struct HvscCollectionRow: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        let sync = store.hvscSync
        let running = sync?.running == true
        let version = store.hasCollection ? store.hvscInfo?.version : nil

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

            Text(store.hasCollection ? "High Voltage SID Collection" : "Collection")
                .lineLimit(1)

            if let version {
                Text("v\(version)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.18), in: .capsule)
                    .foregroundStyle(.tint)
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
            }
        }
        .tag(SidebarItem.hvscHome)
        .overlay(alignment: .bottom) {
            if running, let fraction = sync?.fraction {
                ProgressView(value: fraction)
                    .tint(.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
            }
        }
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
                    Text(sync.current)
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
        .frame(width: 1100, height: 680)
}

