import AppKit
import Carbon.HIToolbox

/// The keys that aren't menu shortcuts: ? for the keyboard help panel, Space,
/// the Vim and Emacs sets, and the panel's own movement. One local monitor,
/// because no one view has the focus everywhere. Nothing here happens while
/// typing, so text fields keep every plain key, and macOS's own ⌃F and ⌃N.
@MainActor
enum AppKeys {
    /// SwiftUI's actions, handed over by the main window.
    static var openHelp: () -> Void = {}
    static var openSettings: () -> Void = {}

    private static var monitor: Any?
    private static var matcher = KeySequenceMatcher()
    private static var store: PlayerStore?
    private static var library: LibraryStore?

    static func start(store: PlayerStore, library: LibraryStore) {
        guard monitor == nil else { return }
        self.store = store
        self.library = library
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    /// True when the event has been dealt with.
    private static func handle(_ event: NSEvent) -> Bool {
        guard let store, let stroke = KeyStroke(event) else { return false }
        let responder = event.window?.firstResponder
        // Space works in every window of Resonance, as it did before the
        // panel. Everything else belongs to the main window, and not to a
        // sheet over it, which is a window of its own.
        guard isMainWindow(event.window) else {
            return stroke == KeyStroke(KeyStroke.space) && SpaceKey.handle(store: store, responder: responder)
        }
        if store.isShowingKeyHelp {
            return handleInPanel(event, stroke, store)
        }
        guard !(responder is NSText) else { return false }

        let match = matcher.feed(stroke, in: .current, at: event.timestamp)
        switch match {
        case .none: return false
        case .pending: return true
        case .action(let action):
            if action == .playPause { return SpaceKey.handle(store: store, responder: responder) }
            guard action.binding(in: .current).handler == .monitor else { return false }
            if event.isARepeat, !action.repeats { return true }
            return perform(action, store: store, window: event.window)
        }
    }

    private static func handleInPanel(_ event: NSEvent, _ stroke: KeyStroke, _ store: PlayerStore) -> Bool {
        let scheme = KeyScheme.current
        if stroke == KeyStroke(KeyStroke.tab) || stroke == KeyStroke(KeyStroke.backtab) {
            KeyScheme.current = scheme.cycled(by: stroke.key == KeyStroke.tab ? 1 : -1)
            return true
        }
        if let move = KeyHelpMove.from(stroke, in: scheme) {
            store.keyHelpSelection = move.applied(to: store.keyHelpSelection)
            return true
        }
        if stroke == KeyStroke(KeyStroke.enter) {
            if !event.isARepeat { activate(store.keyHelpSelection) }
            return true
        }
        // Esc always closes it, in Emacs's set too.
        if stroke == KeyStroke(KeyStroke.escape) {
            store.isShowingKeyHelp = false
            return true
        }
        // The menus' shortcuts work in every set: light the row, and the menu
        // runs it.
        if stroke.modifiers.contains(.command) {
            if let action = KeyAction.allCases.first(where: { $0.binding(in: .normal).sequence == [stroke] }) {
                store.keyHelpSelection = action
                if action.leavesPanel { store.isShowingKeyHelp = false }
            }
            return false
        }
        // Spaces and the like still act, so a key can be tried from here.
        switch matcher.feed(stroke, in: scheme, at: event.timestamp) {
        case .none:
            return true
        case .pending:
            return true
        case .action(let action):
            store.keyHelpSelection = action
            if action.actsOnList { return true }
            if event.isARepeat, !action.repeats { return true }
            activate(action)
            return true
        }
    }

    /// Return on a row of the panel, or a click on it: what its key does.
    static func activate(_ action: KeyAction) {
        guard let store, !action.actsOnList else { return }
        if action.leavesPanel { store.isShowingKeyHelp = false }
        _ = perform(action, store: store, window: nil)
    }

    private static func perform(_ action: KeyAction, store: PlayerStore, window: NSWindow?) -> Bool {
        switch action {
        case .playPause: store.playPause()
        case .stop: store.stop()
        case .nextTrack: store.next()
        case .previousTrack: store.previous()
        case .nextSubtune: store.nextSubtune()
        case .previousSubtune: store.previousSubtune()
        case .volumeUp: store.nudgeVolume(by: 0.1)
        case .volumeDown: store.nudgeVolume(by: -0.1)
        case .shuffle: store.shuffle.toggle()
        case .surpriseMe:
            if let library, library.hasRoot {
                Task { await library.surpriseMe() }
            }
        case .nowPlaying: store.toggleNowPlaying()
        case .underTheHood: store.toggleUnderTheHood()
        case .search: store.focusSearch()
        case .addFiles: store.isImporting = true
        case .settings: openSettings()
        case .help: openHelp()
        // After this key's handling is over: the panel takes the focus.
        case .menuBarPlayer: DispatchQueue.main.async { MiniPlayer.shared?.toggle() }
        case .shortcuts: store.toggleKeyHelp()
        case .close:
            if store.isShowingKeyHelp {
                store.isShowingKeyHelp = false
            } else if store.isShowingNowPlaying {
                store.isShowingNowPlaying = false
            } else if store.isShowingUnderTheHood {
                store.isShowingUnderTheHood = false
            } else {
                return false
            }
        case .moveDown, .moveUp, .top, .bottom, .playSelected, .remove:
            // Nothing to act on: the list is under Now Playing.
            guard let window, !store.isShowingNowPlaying,
                  let table = SongTableStyle.activeTable(in: window) else { return true }
            act(action, on: table, in: window)
        }
        return true
    }

    private static func act(_ action: KeyAction, on table: NSTableView, in window: NSWindow) {
        switch action {
        case .moveDown: send(kVK_DownArrow, NSDownArrowFunctionKey, to: window)
        case .moveUp: send(kVK_UpArrow, NSUpArrowFunctionKey, to: window)
        case .remove: send(kVK_Delete, 0x7F, to: window)
        case .top: select(row: 0, in: table)
        case .bottom: select(row: table.numberOfRows - 1, in: table)
        default: break
        }
    }

    /// Selection the table's own way, so it moves as the arrows move it, and
    /// SwiftUI's actions for Delete and Return run as usual.
    private static func send(_ keyCode: Int, _ character: Int, to window: NSWindow) {
        let characters = String(UnicodeScalar(UInt16(character)).map(Character.init) ?? " ")
        let isArrow = character >= NSUpArrowFunctionKey
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: isArrow ? [.numericPad, .function] : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(keyCode)
        ) else { return }
        window.sendEvent(event)
    }

    private static func select(row: Int, in table: NSTableView) {
        guard row >= 0, row < table.numberOfRows else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// As Window → Size for Recording finds it.
    private static func isMainWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue.hasPrefix("main") == true
    }
}

extension KeyStroke {
    /// Nil for what no binding uses: Shift on a named key, which extends a
    /// list's selection.
    init?(_ event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let named: String? = switch Int(event.keyCode) {
        case kVK_Space: Self.space
        case kVK_Return, kVK_ANSI_KeypadEnter: Self.enter
        case kVK_Escape: Self.escape
        case kVK_Delete: Self.delete
        case kVK_Home: Self.home
        case kVK_End: Self.end
        case kVK_Tab: flags.contains(.shift) ? Self.backtab : Self.tab
        case kVK_UpArrow: Self.up
        case kVK_DownArrow: Self.down
        case kVK_LeftArrow: Self.left
        case kVK_RightArrow: Self.right
        default: nil
        }
        if let named {
            if flags.contains(.shift), named != Self.backtab { return nil }
            self.init(named, modifiers)
        } else if let character = event.charactersIgnoringModifiers, !character.isEmpty {
            self.init(character, modifiers)
        } else {
            return nil
        }
    }
}
