import AppKit
import PhosphorCore

/// The menu on Resonance's Dock icon: what's playing, the transport, and
/// Sounds Like one click away. Built afresh each time it opens, so unlike
/// the Playback menu its items can say what applies right now.
enum DockMenu {
    static func make(store: PlayerStore, library: LibraryStore, fingerprints: FingerprintStore) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let track = store.nowPlaying

        if let track {
            menu.addItem(ActionItem(track.displayTitle, enabled: false) {})
            menu.addItem(.separator())
        }

        menu.addItem(ActionItem(store.isPlaying ? "Pause" : "Play", enabled: track != nil || store.currentRow != nil) {
            store.playPause()
        })
        menu.addItem(ActionItem("Next Track", enabled: track != nil) { store.next() })
        menu.addItem(ActionItem("Previous Track", enabled: track != nil) { store.previous() })
        menu.addItem(.separator())

        let scanned = track.map { fingerprints.fingerprint($0.path) != nil } ?? false
        menu.addItem(ActionItem("Play Something Like This", enabled: scanned) {
            guard let track else { return }
            Task { _ = await fingerprints.playSimilar(to: track, with: library) }
        })
        menu.addItem(ActionItem("Drift From This Tune", enabled: scanned) {
            guard let track else { return }
            Task { _ = await fingerprints.startDrift(from: track, with: library) }
        })
        menu.addItem(ActionItem("Surprise Me", enabled: library.hasRoot) {
            Task { await library.surpriseMe() }
        })
        return menu
    }
}

/// A menu item that runs a closure. Items only hold their target weakly, so
/// the item also keeps it as its represented object.
private func ActionItem(_ title: String, enabled: Bool, run: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(run)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
    item.target = action
    item.representedObject = action
    item.isEnabled = enabled
    return item
}

private final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) { self.run = run }

    @objc func fire() { run() }
}
