import SwiftUI

@main
struct ResonanceApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // A single window: one player, one playlist.
        Window("Resonance", id: "main") {
            ContentView()
                .environment(appDelegate.store)
                .environment(appDelegate.library)
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            AboutCommands()
            PlaybackCommands(store: appDelegate.store, library: appDelegate.library)
        }

        Window("About Resonance", id: AboutView.windowID) {
            AboutView()
                .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)
        // Opened from the app menu only, not listed in the Window menu.
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(appDelegate.store)
        }
    }
}
