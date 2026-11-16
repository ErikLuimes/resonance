import AppIntents
import AppKit
import KSCrashRecording

/// Owns the player for the app's lifetime, so files opened from Finder
/// before the window exists still reach it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: PlayerStore
    let library: LibraryStore
    let fingerprints: FingerprintStore
    let playlists: PlaylistsStore
#if CSDB
    let csdb: CSDbStore
#endif
    let remote: RemoteServer
    let updater: Updater
    private var nowPlaying: NowPlayingController?
    private var activity: PlaybackActivity?
    private var outputLatency: OutputLatencyMonitor?
    private var miniPlayer: MiniPlayer?
    private var jobs: JobWatcher?
    private var spotlight: SpotlightIndex?
    private var control: ControlServer?
    private var promptStatus: PromptStatus?

    override init() {
        if !Self.isRunningTests {
            // KSCrash only writes reports locally. Nothing leaves the Mac until
            // the user explicitly copies or reports one from Settings.
            try? KSCrash.shared.install(with: KSCrashConfiguration())
        }
        // Before anything below reads a path: the folders and files chosen
        // outside the sandbox, open again.
        if !Self.isRunningTests {
            FileAccess.shared.restore()
        }
#if CSDB
        csdb = CSDbStore()
#endif
        updater = Updater()
        // Under unit tests the app is only a host: no audio, no saved session.
        store = Self.isRunningTests
            ? PlayerStore(defaults: UserDefaults(suiteName: "tests")!, defaultHvscRoot: nil) { _ in PreviewCore.empty }
            : .live()
        library = LibraryStore(player: store)
        fingerprints = FingerprintStore(player: store)
        playlists = PlaylistsStore(player: store)
        remote = RemoteServer(
            commands: ControlCommands(player: store, library: library, fingerprints: fingerprints, playlists: playlists),
            player: store
        )
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

    /// Before any window exists, so none opens in the wrong mode first.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        AppAppearance.saved().apply()
        Headless.start()
        if Headless.asked {
            // SwiftUI answers a link by opening a window, any window, and
            // putting the app back in the Dock, all before `application(_:open:)`
            // hears of it. Taking the link's Apple event first keeps SwiftUI out.
            NSAppleEventManager.shared().setEventHandler(
                self, andSelector: #selector(openLink(_:reply:)),
                forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
            )
            quitWithTheTerminalApp()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.startPolling()
        guard !Self.isRunningTests else { return }
        Log.app.notice("Launched \(Updater.appVersion(), privacy: .public)")
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
        // So Siri knows your playlists' names: now, and whenever one is
        // made, renamed or deleted.
        ResonanceShortcuts.updateAppShortcutParameters()
        playlists.namesChanged = { ResonanceShortcuts.updateAppShortcutParameters() }
        spotlight = SpotlightIndex(store: store)
        spotlight?.start()
        startControl()
        remote.start()
        #if DEBUG
        VisualizerPictures.openIfAsked(store: store)
        VisualizerStage.openIfAsked(store: store)
        // To measure the drawer's tabs without a click; choose the tab
        // with the launch argument `-underTheHoodTab sweeps`.
        if ProcessInfo.processInfo.environment["RESONANCE_UNDER_THE_HOOD"] != nil {
            store.isShowingUnderTheHood = true
        }
        #endif
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
            Log.control.error("The control socket didn't start: \(Log.kind(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
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
        Log.app.notice("Opening \(files.count, privacy: .public) files and \(urls.count - files.count, privacy: .public) links: \(urls.map(\.absoluteString), privacy: .private)")
        FileAccess.shared.keep(files)
        // SwiftUI shows the window for an opened file, so that ends headless.
        if !files.isEmpty { Headless.leave() }
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
        if let url = urls.last(where: { !$0.isFileURL }), let link = SharedTuneLink(url: url) {
            openShared(link)
        }
    }

    /// While headless the terminal app is all of Resonance: when it goes,
    /// so does the app, and the music with it. Quitting it says so at once
    /// (`terminal.closed`); this is for when its window was closed or it
    /// was killed, noticed by its questions stopping.
    private func quitWithTheTerminalApp() {
        Task {
            while Headless.isOn {
                try? await Task.sleep(for: .seconds(1))
                if Headless.isOn, TerminalLinks.shared.hasGone {
                    Log.app.notice("The terminal app has gone: quitting, as headless")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @objc private func openLink(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        application(NSApp, open: [url])
    }

    /// A shared tune link: asked about in the window, or in the terminal app
    /// while that's all there is of Resonance (Headless).
    private func openShared(_ link: SharedTuneLink) {
        guard Headless.isOn, TerminalLinks.shared.isWatched else { return showShared(link) }
        Headless.giveFocusBack()
        Task { [weak self, store] in
            await TerminalLinks.shared.offer(link, player: store) { link in
                // Still headless, the app is about to quit with the terminal app.
                if !Headless.isOn { self?.showShared(link) }
            }
        }
    }

    private func showShared(_ link: SharedTuneLink) {
        store.openShared(link)
        NSApp.activate()
        MiniPlayer.openMainWindow?()
    }

    /// Opened again, from Finder or Spotlight: a headless app gets its Dock
    /// icon back, and its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if Headless.isOn { MiniPlayer.openMainWindow?() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Headless.becameActive()
    }

    /// A shared link opened from anywhere, or a tune clicked in Spotlight:
    /// that one shows in the library and plays.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        if let link = SharedTuneLink(activity: userActivity) {
            Log.sharing.notice("Opening a shared tune link")
            openShared(link)
            return true
        }
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
    /// then the music, and the player, keep going.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.object(forKey: Pref.menuBarPlayer) as? Bool == false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.notice("Quitting")
        control?.stop()
        promptStatus?.stop()
        store.shutdown()
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
