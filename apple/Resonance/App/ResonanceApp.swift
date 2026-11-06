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
#if CSDB
                .environment(appDelegate.csdb)
#endif
                .voiceThemed()
        }
        .defaultSize(width: 1100, height: 680)
        // At least as wide as ContentView's minimum, so the bottom bar never
        // collapses.
        .windowResizability(.contentMinSize)
        .commands {
            AboutCommands()
            UpdateCommands(updater: appDelegate.updater)
            MiniPlayerCommands()
            HelpCommands(store: appDelegate.store)
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
                .environment(appDelegate.updater)
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

/// The menu bar player's icon (Assets: MenuBarIcon), and the same with a
/// slash through it, the bars cut back around the slash as in SF Symbols'
/// slashed symbols. Drawn here: the asset compiler drops SVG clipping.
enum MenuBarIcon {
    static let playing: NSImage = NSImage(resource: .menuBarIcon)

    static let notPlaying: NSImage = {
        let size = playing.size
        let image = NSImage(size: size, flipped: true) { rect in
            playing.draw(in: rect)
            guard let gc = NSGraphicsContext.current?.cgContext else { return true }
            let from = CGPoint(x: rect.width * 0.06, y: rect.height * 0.06)
            let to = CGPoint(x: rect.width * 0.94, y: rect.height * 0.94)
            gc.setLineCap(.round)
            // The gap: clear a wide band, then draw the slash in it.
            gc.setBlendMode(.clear)
            gc.setLineWidth(3.6)
            gc.strokeLineSegments(between: [from, to])
            gc.setBlendMode(.normal)
            gc.setStrokeColor(NSColor.black.cgColor)
            gc.setLineWidth(1.4)
            gc.strokeLineSegments(between: [from, to])
            return true
        }
        image.isTemplate = true
        return image
    }()
}

