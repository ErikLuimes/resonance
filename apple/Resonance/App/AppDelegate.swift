import AppKit

/// Owns the player for the app's lifetime, so files opened from Finder
/// before the window exists still reach it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: PlayerStore
    let library: LibraryStore
    let fingerprints: FingerprintStore
    let playlists: PlaylistsStore
    let updater = Updater()
    private var nowPlaying: NowPlayingController?
    private var activity: PlaybackActivity?
    private var outputLatency: OutputLatencyMonitor?
    private var miniPlayer: MiniPlayer?

    override init() {
        // Under unit tests the app is only a host: no audio, no saved session.
        store = Self.isRunningTests
            ? PlayerStore(defaults: UserDefaults(suiteName: "tests")!, phosphorHvscRoot: { nil }, defaultHvscRoot: nil) { _ in PreviewCore.empty }
            : .live()
        library = LibraryStore(player: store)
        fingerprints = FingerprintStore(player: store)
        playlists = PlaylistsStore(player: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.startPolling()
        guard !Self.isRunningTests else { return }
        TuneDrag.install()
        SpaceKey.start(store)
        miniPlayer = MiniPlayer(store: store, library: library, playlists: playlists)
        fingerprints.startPolling()
        nowPlaying = NowPlayingController(store: store)
        activity = PlaybackActivity(store: store)
        outputLatency = OutputLatencyMonitor { [store] latency in
            store.visualizer.setOutputLatency(latency)
        }
    }

    /// Finder "Open With", double-clicked .sid files, Dock drops.
    func application(_ application: NSApplication, open urls: [URL]) {
        store.add(urls, playFirst: true)
    }

    /// Closing the window quits, unless the menu bar player is showing:
    /// then the music, and the player, carry on.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.object(forKey: Pref.menuBarPlayer) as? Bool == false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown()
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
