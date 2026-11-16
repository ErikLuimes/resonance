import AppKit
import SwiftUI

/// Resonance with no Dock icon and no window, for when the terminal app is
/// all of it: `resonance --headless` starts the app this way. The menu bar
/// player still shows. Opening the app again, or anything that shows its
/// window, makes it a regular app for the rest of the run.
enum Headless {
    /// The command line tool asked for it (`launch` in cli/src/client.rs).
    static let asked = UserDefaults.standard.bool(forKey: "headlessForTerminal")

    /// Kept here, not read off the activation policy: macOS changes that by
    /// itself when a link opens the app (see `giveFocusBack`).
    private(set) static var isOn = false

    /// Before any window exists (the main one stays closed: ResonanceApp).
    static func start() {
        guard asked else { return }
        isOn = true
        NSApp.setActivationPolicy(.accessory)
        // No window has shown, so ContentView hasn't said how to open one,
        // and SwiftUI doesn't open it when the app is opened again either.
        MiniPlayer.openMainWindow = {
            leave()
            NSApp.activate()
            EnvironmentValues().openWindow(id: "main")
        }
    }

    static func leave() {
        guard isOn else { return }
        isOn = false
        Log.app.notice("Leaving headless")
        NSApp.setActivationPolicy(.regular)
    }

    // MARK: Focus

    /// Until this, becoming active is a link's doing.
    private static var handsBackUntil: ContinuousClock.Instant?

    /// A link went to the terminal app: stay out of the way. macOS brings
    /// forward the app a link opens, even one with nothing to show, and puts
    /// it back in the Dock; whatever was in front stops getting the keys.
    /// Hiding hands them back. The app has been active by the time the link
    /// arrives; `becameActive` is for when it isn't yet.
    static func giveFocusBack() {
        guard isOn else { return }
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        handsBackUntil = .now + .seconds(1)
        if NSApp.isActive { NSApp.hide(nil) }
    }

    static func becameActive() {
        guard isOn, let until = handsBackUntil, .now < until else { return }
        handsBackUntil = nil
        NSApp.hide(nil)
    }
}
