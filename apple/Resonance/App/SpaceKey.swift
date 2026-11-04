import AppKit

/// Space plays or pauses anywhere in Resonance, as in Music: in the
/// library, Now Playing and the menu bar player, whatever has the focus.
/// Not while typing (a text field or the search field has it), and not
/// with modifier keys. A local monitor, because no one view has the focus
/// everywhere.
@MainActor
enum SpaceKey {
    private static var monitor: Any?

    static func start(_ store: PlayerStore) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
            guard event.keyCode == 49, // Space
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            else { return event }
            let responder = event.window?.firstResponder
            let handled = MainActor.assumeIsolated {
                guard let store, !(responder is NSText) else { return false }
                // Stopped, in My Playlist's list: let it start its selection.
                if store.state == .stopped, responder is NSTableView { return false }
                store.playPause()
                return true
            }
            return handled ? nil : event
        }
    }
}
