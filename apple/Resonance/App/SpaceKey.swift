import AppKit

/// Space plays or pauses anywhere in Resonance, as in Music: in the
/// library, Now Playing and the menu bar player, whatever has the focus.
/// Not while typing (a text field or the search field has it), and not
/// with modifier keys. `AppKeys` sees the key.
@MainActor
enum SpaceKey {
    /// False lets the key go on to whatever has the focus.
    static func handle(store: PlayerStore, responder: NSResponder?) -> Bool {
        guard !(responder is NSText) else { return false }
        // Stopped, in My Playlist's list: let it start its selection.
        if store.state == .stopped, responder is NSTableView { return false }
        store.playPause()
        return true
    }
}
