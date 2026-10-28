import SwiftUI
import UniformTypeIdentifiers

/// Library sources in the sidebar. Only the playlist exists in M1; HVSC,
/// Favorites and Recent slot in here later.
enum SidebarItem: Hashable {
    case playlist
}

struct ContentView: View {
    @Environment(PlayerStore.self) private var store
    @State private var sidebarSelection: SidebarItem? = .playlist
    @State private var showInspector = true
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Section("Library") {
                    Label("Playlist", systemImage: "music.note.list")
                        .badge(store.rows.count)
                        .tag(SidebarItem.playlist)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            PlaylistView()
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
                Button("Add Files", systemImage: "plus") { store.isImporting = true }
                    .help("Add SID files, folders or playlists")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                    .help(showInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
        .navigationTitle("Resonance")
        .navigationSubtitle(subtitle)
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
    }

    private var subtitle: String {
        let count = store.rows.count
        return count == 1 ? "1 tune" : "\(count) tunes"
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
        .frame(width: 1100, height: 680)
}
