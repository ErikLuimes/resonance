import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The menu bar player: an item in the menu bar (the app icon's voices,
/// slashed while nothing plays) that opens `MiniPlayerView` in a panel
/// below it, from a click, ⌃⌥⌘P in any app, or Window → Mini Player.
/// Settings → Appearance turns it off.
///
/// AppKit rather than SwiftUI's MenuBarExtra: SwiftUI can't open its panel
/// from code (no API, and it ignores a click made in code), and the
/// shortcut has to.
@MainActor
final class MiniPlayer: NSObject, NSWindowDelegate {
    /// The one the app delegate makes, for the Window menu.
    private(set) static var shared: MiniPlayer?
    /// Opens the main window, closed or not; set by ContentView, which has
    /// SwiftUI's action for it.
    static var openMainWindow: (() -> Void)?

    static let key = KeyEquivalent("p")
    static let modifiers: SwiftUI.EventModifiers = [.control, .option, .command]

    private let store: PlayerStore
    private let library: LibraryStore
    private let playlists: PlaylistsStore
    private let defaults: UserDefaults
    private var item: NSStatusItem?
    private var panel: NSPanel?
    private var clickMonitor: Any?
    /// When the panel last closed: a click on the item that closed it (by
    /// taking its focus) mustn't open it again straight away.
    private var closedAt = Date.distantPast
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    init(store: PlayerStore, library: LibraryStore, playlists: PlaylistsStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.library = library
        self.playlists = playlists
        self.defaults = defaults
        super.init()
        Self.shared = self
        followSetting()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.followSetting() }
        }
    }

    var isEnabled: Bool { defaults.object(forKey: Pref.menuBarPlayer) as? Bool ?? true }

    /// Open the panel, or close it when it's open.
    func toggle() {
        if panel?.isVisible == true {
            close()
        } else if Date.now.timeIntervalSince(closedAt) > 0.25 {
            open()
        }
    }

    // MARK: The item

    private func followSetting() {
        if isEnabled {
            if item == nil { makeItem() }
            registerHotKey()
        } else {
            close()
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            unregisterHotKey()
        }
    }

    private func makeItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(itemClicked)
        item.button?.sendAction(on: .leftMouseDown)
        item.button?.setAccessibilityLabel("Resonance")
        self.item = item
        followPlayback()
    }

    @objc private func itemClicked() { toggle() }

    /// Slashed while nothing plays.
    private func followPlayback() {
        withObservationTracking {
            item?.button?.image = store.isPlaying ? MenuBarIcon.playing : MenuBarIcon.notPlaying
        } onChange: {
            Task { @MainActor [weak self] in self?.followPlayback() }
        }
    }

    // MARK: The panel

    private func open() {
        guard let anchor = itemFrame else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel, below: anchor)
        panel.makeKeyAndOrderFront(nil)
        item?.button?.highlight(true)
        // A click in another app closes it, as it does a menu.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        item?.button?.highlight(false)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        closedAt = .now
    }

    /// The item's button, in screen coordinates.
    private var itemFrame: NSRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func makePanel() -> NSPanel {
        let content = MiniPlayerView { [weak self] in
            self?.close()
            NSApp.activate()
            MiniPlayer.openMainWindow?()
        }
        .environment(store)
        .environment(library)
        .environment(playlists)
        .voiceThemed()
        .clipShape(.rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))

        let host = NSHostingController(rootView: content)
        // The panel follows the player's height (a list, a note, nothing).
        host.sizingOptions = .preferredContentSize
        let panel = MiniPlayerPanel(contentViewController: host)
        panel.delegate = self
        return panel
    }

    /// Under the item, its top a little below the menu bar, kept on screen.
    private func place(_ panel: NSPanel, below anchor: NSRect) {
        let size = panel.frame.size
        let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 6))
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    /// Grown or shrunk with its content: back under the item.
    func windowDidResize(_ notification: Notification) {
        guard let panel, let anchor = itemFrame else { return }
        place(panel, below: anchor)
    }

    // MARK: ⌃⌥⌘P

    /// A system-wide hot key (Carbon's, which needs no Accessibility
    /// permission), while the menu bar player is on.
    private func registerHotKey() {
        guard hotKey == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            Task { @MainActor in MiniPlayer.shared?.toggle() }
            return noErr
        }, 1, &type, nil, &hotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x5253_4E43), id: 1) // "RSNC"
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey | cmdKey), id,
                            GetEventDispatcherTarget(), 0, &hotKey)
    }

    private func unregisterHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKey = nil
        hotKeyHandler = nil
    }
}

/// A borderless panel that takes the keyboard without making Resonance the
/// active app, floating over the menu bar's apps like a menu.
private final class MiniPlayerPanel: NSPanel {
    init(contentViewController: NSViewController) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.contentViewController = contentViewController
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
}

/// Window → Mini Player, with its shortcut. The hot key handles the keys
/// themselves, in every app; this item is how people find it.
struct MiniPlayerCommands: Commands {
    @AppStorage(Pref.menuBarPlayer) private var showsMenuBarPlayer = true

    var body: some Commands {
        CommandGroup(before: .windowList) {
            // After the menu has closed, which would take the panel's focus.
            Button("Mini Player") { DispatchQueue.main.async { MiniPlayer.shared?.toggle() } }
                .keyboardShortcut(MiniPlayer.key, modifiers: MiniPlayer.modifiers)
                .disabled(!showsMenuBarPlayer)
            Divider()
        }
    }
}
