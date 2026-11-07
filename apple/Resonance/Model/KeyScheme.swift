import Foundation

/// The set of keys Resonance answers to, chosen in the keyboard help panel or
/// in Settings. Vim and Emacs add keys: the menus' shortcuts work in all three.
enum KeyScheme: String, CaseIterable, Identifiable {
    case normal, vim, emacs

    var id: Self { self }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .vim: "Vim"
        case .emacs: "Emacs"
        }
    }

    static var current: KeyScheme {
        get { KeyScheme(rawValue: UserDefaults.standard.string(forKey: Pref.keyScheme) ?? "") ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Pref.keyScheme) }
    }

    /// The next one along, for Tab in the panel.
    func cycled(by step: Int) -> KeyScheme {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + step + all.count) % all.count]
    }
}

/// One press of a key. A character key is what it types with Shift applied
/// ("G", "?"), so Shift isn't a modifier here; other keys have a name.
struct KeyStroke: Hashable {
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let command = Modifiers(rawValue: 4)
    }

    static let space = "space", enter = "return", escape = "escape", delete = "delete"
    static let home = "home", end = "end", tab = "tab", backtab = "backtab"
    static let up = "up", down = "down", left = "left", right = "right"

    let key: String
    let modifiers: Modifiers

    init(_ key: String, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// What a key is shown as, and what has to be pressed.
struct KeyBinding: Equatable {
    /// Who answers it.
    enum Handler {
        /// Resonance's key monitor.
        case monitor
        /// A menu's shortcut, or what the focused view does with it anyway.
        case system
    }

    let label: String
    let sequence: [KeyStroke]
    let handler: Handler

    /// A plain key or a chord for the key monitor.
    static func key(_ label: String, _ key: String, _ modifiers: KeyStroke.Modifiers = []) -> KeyBinding {
        KeyBinding(label: label, sequence: [KeyStroke(key, modifiers)], handler: .monitor)
    }

    /// The same key pressed twice in a row, as Vim's "gg" and "dd".
    static func twice(_ key: String) -> KeyBinding {
        KeyBinding(label: key + key, sequence: [KeyStroke(key), KeyStroke(key)], handler: .monitor)
    }

    static func system(_ label: String, _ key: String, _ modifiers: KeyStroke.Modifiers = []) -> KeyBinding {
        KeyBinding(label: label, sequence: [KeyStroke(key, modifiers)], handler: .system)
    }
}

/// Everything with a key. The panel and the Keyboard Shortcuts help page are
/// both drawn from this.
enum KeyAction: CaseIterable, Hashable {
    case playPause, stop, nextTrack, previousTrack, nextSubtune, previousSubtune, volumeUp, volumeDown
    case moveDown, moveUp, top, bottom, playSelected, remove, search, addFiles
    case shuffle, surpriseMe, nowPlaying, underTheHood, menuBarPlayer, settings, help, shortcuts, close

    /// The panel's columns, with their headings.
    static let columns: [(title: String, actions: [KeyAction])] = [
        ("Playback", [.playPause, .stop, .nextTrack, .previousTrack, .nextSubtune, .previousSubtune, .volumeUp, .volumeDown]),
        ("Lists", [.moveDown, .moveUp, .top, .bottom, .playSelected, .remove, .search, .addFiles]),
        ("Discovery and Windows", [.shuffle, .surpriseMe, .nowPlaying, .underTheHood, .menuBarPlayer, .settings, .help, .shortcuts, .close]),
    ]

    var title: String {
        switch self {
        case .playPause: "Play or Pause"
        case .stop: "Stop"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .nextSubtune: "Next Subtune"
        case .previousSubtune: "Previous Subtune"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .moveDown: "Move Down"
        case .moveUp: "Move Up"
        case .top: "Top of List"
        case .bottom: "End of List"
        case .playSelected: "Play Selected"
        case .remove: "Remove from Playlist"
        case .search: "Search"
        case .addFiles: "Add Files or Folders"
        case .shuffle: "Shuffle"
        case .surpriseMe: "Surprise Me"
        case .nowPlaying: "Now Playing"
        case .underTheHood: "Under the Hood"
        case .menuBarPlayer: "Menu Bar Player"
        case .settings: "Settings"
        case .help: "Resonance Help"
        case .shortcuts: "These Shortcuts"
        case .close: "Close"
        }
    }

    /// Its name on the help page, away from the panel.
    var helpPageTitle: String {
        switch self {
        case .playPause: "Play or Pause (not while typing)"
        case .shortcuts: "Show or Hide the Keyboard Shortcuts Panel"
        case .close: "Close the Panel, or What's Open"
        default: title
        }
    }

    /// One line on what it does, in the panel's fixed place for it.
    var summary: String {
        switch self {
        case .playPause: "Pauses the tune, or plays it again. Works everywhere except while you're typing."
        case .stop: "Stops the tune."
        case .nextTrack: "Plays the next tune in the list you're playing from."
        case .previousTrack: "Plays the previous tune in the list you're playing from."
        case .nextSubtune: "One SID file can hold several songs. This plays the next one in the file."
        case .previousSubtune: "One SID file can hold several songs. This plays the previous one in the file."
        case .volumeUp: "Turns the volume up by 10%."
        case .volumeDown: "Turns the volume down by 10%."
        case .moveDown: "Moves the selection down the song list."
        case .moveUp: "Moves the selection up the song list."
        case .top: "Jumps to the first tune in the list."
        case .bottom: "Jumps to the last tune in the list."
        case .playSelected: "Plays the selected tune."
        case .remove: "Removes the selected tunes from the playlist you're looking at."
        case .search: "Puts the cursor in the search field."
        case .addFiles: "Adds SID files, folders or M3U playlists to My Playlist."
        case .shuffle: "Turns shuffle on or off."
        case .surpriseMe: "Starts a radio of random tunes from all of HVSC."
        case .nowPlaying: "Slides the large player over the library, or away again."
        case .underTheHood: "Slides up the tracker, registers, sweeps and pitch trail, or away again."
        case .menuBarPlayer: "Opens the small player from the menu bar, from any app."
        case .settings: "Opens Resonance's settings."
        case .help: "Opens the full guide to Resonance."
        case .shortcuts: "Shows or hides this panel."
        case .close: "Closes this panel. Pressed again, it closes Now Playing or Under the Hood."
        }
    }

    /// Works on the list under the panel, so it's only described while the
    /// panel is open: removing tunes you can't see would be a nasty surprise.
    var actsOnList: Bool {
        switch self {
        case .moveDown, .moveUp, .top, .bottom, .playSelected, .remove: true
        default: false
        }
    }

    /// Goes somewhere else, so the panel gets out of the way.
    var leavesPanel: Bool {
        switch self {
        case .search, .addFiles, .menuBarPlayer, .settings, .help: true
        default: false
        }
    }

    /// Keeps going while the key is held.
    var repeats: Bool {
        switch self {
        case .moveDown, .moveUp, .volumeUp, .volumeDown: true
        default: false
        }
    }

    func binding(in scheme: KeyScheme) -> KeyBinding {
        let keys = bindings
        switch scheme {
        case .normal: return keys.normal
        case .vim: return keys.vim
        case .emacs: return keys.emacs
        }
    }

    private var bindings: (normal: KeyBinding, vim: KeyBinding, emacs: KeyBinding) {
        switch self {
        case .playPause:
            let space = KeyBinding.key("Space", KeyStroke.space)
            return (space, space, space)
        case .stop:
            return (.system("⌘.", ".", .command), .key("x", "x"), .key("⌃X", "x", .control))
        case .nextTrack:
            return (.system("⌘→", KeyStroke.right, .command), .key("l", "l"), .key("⌃F", "f", .control))
        case .previousTrack:
            return (.system("⌘←", KeyStroke.left, .command), .key("h", "h"), .key("⌃B", "b", .control))
        case .nextSubtune:
            return (.system("⌥⌘→", KeyStroke.right, [.option, .command]), .key("L", "L"), .key("⌥F", "f", .option))
        case .previousSubtune:
            return (.system("⌥⌘←", KeyStroke.left, [.option, .command]), .key("H", "H"), .key("⌥B", "b", .option))
        case .volumeUp:
            return (.system("⌘↑", KeyStroke.up, .command), .key("+", "+"), .key("⌃=", "=", .control))
        case .volumeDown:
            return (.system("⌘↓", KeyStroke.down, .command), .key("-", "-"), .key("⌃-", "-", .control))
        case .moveDown:
            return (.system("↓", KeyStroke.down), .key("j", "j"), .key("⌃N", "n", .control))
        case .moveUp:
            return (.system("↑", KeyStroke.up), .key("k", "k"), .key("⌃P", "p", .control))
        case .top:
            return (.key("Home", KeyStroke.home), .twice("g"), .key("⌥<", "<", .option))
        case .bottom:
            return (.key("End", KeyStroke.end), .key("G", "G"), .key("⌥>", ">", .option))
        case .playSelected:
            let enter = KeyBinding.system("Return", KeyStroke.enter)
            return (enter, enter, enter)
        case .remove:
            return (.system("⌫", KeyStroke.delete), .twice("d"), .key("⌃D", "d", .control))
        case .search:
            return (.system("⌘F", "f", .command), .key("/", "/"), .key("⌃S", "s", .control))
        case .addFiles:
            let add = KeyBinding.system("⌘O", "o", .command)
            return (add, add, add)
        case .shuffle:
            return (.system("⌥⌘S", "s", [.option, .command]), .key("s", "s"), .key("⌥S", "s", .option))
        case .surpriseMe:
            return (.system("⇧⌘R", "R", .command), .key("r", "r"), .key("⌥R", "r", .option))
        case .nowPlaying:
            return (.system("⇧⌘F", "F", .command), .key("f", "f"), .key("⌃O", "o", .control))
        case .underTheHood:
            return (.system("⌥⌘U", "u", [.option, .command]), .key("u", "u"), .key("⌥U", "u", .option))
        case .menuBarPlayer:
            let player = KeyBinding.system("⌃⌥⌘P", "p", [.control, .option, .command])
            return (player, player, player)
        case .settings:
            let settings = KeyBinding.system("⌘,", ",", .command)
            return (settings, settings, settings)
        case .help:
            let help = KeyBinding.system("⌘?", "?", .command)
            return (help, help, help)
        case .shortcuts:
            let question = KeyBinding.key("?", "?")
            return (question, question, question)
        case .close:
            let escape = KeyBinding.key("Esc", KeyStroke.escape)
            return (escape, escape, .key("⌃G", "g", .control))
        }
    }
}

/// Follows the keys pressed, for bindings of more than one key ("gg"). A
/// first key waits a second for its second.
struct KeySequenceMatcher {
    enum Match: Equatable {
        case none
        case pending
        case action(KeyAction)
    }

    static let timeout: TimeInterval = 1

    private var pending: KeyStroke?
    private var pendingSince: TimeInterval = 0

    mutating func feed(_ stroke: KeyStroke, in scheme: KeyScheme, at time: TimeInterval) -> Match {
        let bindings = KeyAction.allCases.map { (action: $0, sequence: $0.binding(in: scheme).sequence) }
        if let first = pending {
            pending = nil
            if time - pendingSince <= Self.timeout,
               let match = bindings.first(where: { $0.sequence == [first, stroke] }) {
                return .action(match.action)
            }
        }
        if let match = bindings.first(where: { $0.sequence == [stroke] }) {
            return .action(match.action)
        }
        if bindings.contains(where: { $0.sequence.count > 1 && $0.sequence.first == stroke }) {
            pending = stroke
            pendingSince = time
            return .pending
        }
        return .none
    }
}

/// A move through the panel's rows.
enum KeyHelpMove: Equatable {
    case up, down, left, right

    /// The arrows in every scheme, and each scheme's own movement keys.
    static func from(_ stroke: KeyStroke, in scheme: KeyScheme) -> KeyHelpMove? {
        switch stroke {
        case KeyStroke(KeyStroke.up): return .up
        case KeyStroke(KeyStroke.down): return .down
        case KeyStroke(KeyStroke.left): return .left
        case KeyStroke(KeyStroke.right): return .right
        default: break
        }
        switch (scheme, stroke) {
        case (.vim, KeyStroke("k")), (.emacs, KeyStroke("p", .control)): return .up
        case (.vim, KeyStroke("j")), (.emacs, KeyStroke("n", .control)): return .down
        case (.vim, KeyStroke("h")), (.emacs, KeyStroke("b", .control)): return .left
        case (.vim, KeyStroke("l")), (.emacs, KeyStroke("f", .control)): return .right
        default: return nil
        }
    }

    /// The row this move lands on. Sideways keeps the height, as far as the
    /// other column goes.
    func applied(to action: KeyAction) -> KeyAction {
        let columns = KeyAction.columns.map(\.actions)
        guard let column = columns.firstIndex(where: { $0.contains(action) }),
              let row = columns[column].firstIndex(of: action) else { return action }
        switch self {
        case .up: return columns[column][max(row - 1, 0)]
        case .down: return columns[column][min(row + 1, columns[column].count - 1)]
        case .left:
            let target = columns[max(column - 1, 0)]
            return target[min(row, target.count - 1)]
        case .right:
            let target = columns[min(column + 1, columns.count - 1)]
            return target[min(row, target.count - 1)]
        }
    }
}
