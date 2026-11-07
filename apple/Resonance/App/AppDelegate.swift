import AppIntents
import AppKit

/// Owns the player for the app's lifetime, so files opened from Finder
/// before the window exists still reach it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: PlayerStore
    let library: LibraryStore
    let fingerprints: FingerprintStore
    let playlists: PlaylistsStore
#if CSDB
    let csdb = CSDbStore()
#endif
    let updater = Updater()
    private var nowPlaying: NowPlayingController?
    private var activity: PlaybackActivity?
    private var outputLatency: OutputLatencyMonitor?
    private var miniPlayer: MiniPlayer?
    private var jobs: JobWatcher?
    private var spotlight: SpotlightIndex?
    private var control: ControlServer?
    private var promptStatus: PromptStatus?

    override init() {
        // Under unit tests the app is only a host: no audio, no saved session.
        store = Self.isRunningTests
            ? PlayerStore(defaults: UserDefaults(suiteName: "tests")!, phosphorHvscRoot: { nil }, defaultHvscRoot: nil) { _ in PreviewCore.empty }
            : .live()
        library = LibraryStore(player: store)
        fingerprints = FingerprintStore(player: store)
        playlists = PlaylistsStore(player: store)
        super.init()
        // For the actions Siri and Shortcuts run (ResonanceIntents.swift).
        AppDependencyManager.shared.add(dependency: self.store)
        AppDependencyManager.shared.add(dependency: self.library)
        AppDependencyManager.shared.add(dependency: self.fingerprints)
        AppDependencyManager.shared.add(dependency: self.playlists)
        // Before the window's first frame, so the library never flashes first.
        if !Self.isRunningTests {
            store.welcomeSteps = OnboardingStep.pendingAtLaunch(store: store)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.startPolling()
        guard !Self.isRunningTests else { return }
        TuneDrag.install()
        SongTableStyle.install()
        AppKeys.start(store: store, library: library)
        ClickAwayFocus.start()
        miniPlayer = MiniPlayer(store: store, library: library, playlists: playlists)
        fingerprints.startPolling()
        nowPlaying = NowPlayingController(store: store, fingerprints: fingerprints)
        activity = PlaybackActivity(store: store)
        outputLatency = OutputLatencyMonitor { [store] latency in
            store.visualizer.setOutputLatency(latency)
        }
        jobs = JobWatcher(store: store, library: library, fingerprints: fingerprints)
        jobs?.start()
        // So Siri knows your playlists' names, as of this launch.
        ResonanceShortcuts.updateAppShortcutParameters()
        spotlight = SpotlightIndex(store: store)
        spotlight?.start()
        startControl()
    }

    /// The `resonance` command line tool's way in, and the shell prompt's.
    private func startControl() {
        let commands = ControlCommands(player: store, library: library, fingerprints: fingerprints, playlists: playlists)
        let server = ControlServer { line in await commands.handle(line) }
        do {
            try server.start()
            control = server
        } catch {
            // Quietly: only the command line tool misses it, and says so.
        }
        promptStatus = PromptStatus(store: store)
        promptStatus?.start()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockMenu.make(store: store, library: library, fingerprints: fingerprints)
    }

    /// Finder "Open With", double-clicked files, Dock drops, and shared
    /// tune links (resonance://tune/…, from the share page). A playlist
    /// file becomes a playlist of yours, shown and not played; anything
    /// else goes to My Playlist and plays.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        let tunes = files.filter { !PlaylistsStore.isPlaylistFile($0) }
        if !tunes.isEmpty {
            store.add(tunes, playFirst: true)
        }
        let lists = files.filter(PlaylistsStore.isPlaylistFile)
        if !lists.isEmpty {
            Task { await playlists.importAsNew(lists) }
            NSApp.activate()
            MiniPlayer.openMainWindow?()
        }
        if let link = urls.last(where: { !$0.isFileURL }), store.openShared(link) {
            NSApp.activate()
            MiniPlayer.openMainWindow?()
        }
    }

    /// A tune clicked in Spotlight: show it in the library and play it.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let path = SpotlightTunes.path(from: userActivity),
              FileManager.default.fileExists(atPath: path) else { return false }
        let tune = URL(filePath: path)
        store.isShowingNowPlaying = false
        store.playQueue([tune], startAt: tune, from: .files)
        library.reveal(tunePath: path)
        NSApp.activate()
        MiniPlayer.openMainWindow?()
        return true
    }

    /// Closing the window quits, unless the menu bar player is showing:
    /// then the music, and the player, carry on.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.object(forKey: Pref.menuBarPlayer) as? Bool == false
    }

    func applicationWillTerminate(_ notification: Notification) {
        control?.stop()
        promptStatus?.stop()
        store.shutdown()
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
