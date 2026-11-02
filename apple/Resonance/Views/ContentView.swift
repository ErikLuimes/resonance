import SwiftUI
import UniformTypeIdentifiers
import PhosphorCore

/// What the sidebar can show. Favorites and Recent slot in here later.
enum SidebarItem: Hashable {
    case playlist
    case hvsc(HvscCategory)
}

struct ContentView: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @State private var sidebarSelection: SidebarItem? = .playlist
    @State private var showInspector = true
    @State private var isDropTargeted = false
    @State private var choosingHvscFolder = false
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
                // The column's minimum width must not follow its content
                // (see NowPlayingBar): pin it, and let content adapt.
                .frame(minWidth: 0, maxWidth: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    NowPlayingBar()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
                .overlay(alignment: .top) { StatusBanner() }
                .inspector(isPresented: $showInspector) {
                    NowPlayingInspector()
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
                }
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
                .disabled(!library.hasRoot)
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
            }
            Section("HVSC") {
                if library.hasRoot {
                    ForEach(HvscCategory.allCases, id: \.self) { category in
                        Label(category.displayName, systemImage: category.symbolName)
                            .tag(SidebarItem.hvsc(category))
                    }
                } else {
                    Button("Choose HVSC Folder…", systemImage: "folder.badge.plus") {
                        choosingHvscFolder = true
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .fileImporter(isPresented: $choosingHvscFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                store.hvscRoot = url.path
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

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .playlist:
            PlaylistView(search: searchText.wrappedValue)
        case .hvsc(let category):
            // A fresh view (and selection) per category.
            HVSCBrowserView(category: category, search: searchText.wrappedValue)
                .id(category)
        }
    }
}

/// Loading progress and errors, floating over the top of the playlist.
private struct StatusBanner: View {
    @Environment(PlayerStore.self) private var store
    @State private var dismissedError: String?

    var body: some View {
        VStack(spacing: 8) {
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
        .frame(width: 1100, height: 680)
}

