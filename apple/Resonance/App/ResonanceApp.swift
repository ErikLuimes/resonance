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
                .environment(appDelegate.fingerprints)
                .environment(appDelegate.playlists)
                .voiceThemed()
        }
        .defaultSize(width: 1100, height: 680)
        // At least as wide as ContentView's minimum, so the bottom bar never
        // collapses.
        .windowResizability(.contentMinSize)
        .commands {
            AboutCommands()
            HelpCommands()
            PlaybackCommands(store: appDelegate.store, library: appDelegate.library)
            #if DEBUG
            RecordingCommands()
            #endif
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

        Window("Acknowledgements", id: AcknowledgementsView.windowID) {
            AcknowledgementsView()
        }
        .defaultSize(width: 640, height: 640)
        .restorationBehavior(.disabled)
        // Opened from About Resonance only.
        .commandsRemoved()

        Window("Resonance Help", id: HelpView.windowID) {
            HelpView()
        }
        .defaultSize(width: 860, height: 600)
        .restorationBehavior(.disabled)
        // Opened from the Help menu only.
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(appDelegate.store)
                .environment(appDelegate.library)
                .environment(appDelegate.fingerprints)
                .environment(appDelegate.playlists)
                .voiceThemed()
        }

        #if DEBUG
        // Listed in the Window menu.
        Window("SID Monitor (Debug)", id: SIDMonitorDebugView.windowID) {
            SIDMonitorDebugView()
                .environment(appDelegate.store)
                .voiceThemed()
        }
        .defaultSize(width: 760, height: 400)
        .restorationBehavior(.disabled)
        #endif
    }
}
