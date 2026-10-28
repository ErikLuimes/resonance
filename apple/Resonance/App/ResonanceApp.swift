import SwiftUI

@main
struct ResonanceApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // A single window: one player, one playlist.
        Window("Resonance", id: "main") {
            ContentView()
                .environment(appDelegate.store)
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            PlaybackCommands(store: appDelegate.store)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.store)
        }
    }
}
