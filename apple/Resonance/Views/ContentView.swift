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

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
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
                .help("Play a random tune from HVSC")
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
        .onChange(of: sidebarSelection, initial: true) { _, selection in
            if case .hvsc(let category) = selection {
                library.activeCategory = category
            } else {
                library.activeCategory = nil
            }
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

    @ViewBuilder
    private var detail: some View {
        switch sidebarSelection ?? .playlist {
        case .playlist:
            PlaylistView()
        case .hvsc(let category):
            // A fresh view (and selection) per category.
            HVSCBrowserView(category: category)
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
                    Text(loading.trimmingCharacters(in: .whitespaces.union(["⏳"])))
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
