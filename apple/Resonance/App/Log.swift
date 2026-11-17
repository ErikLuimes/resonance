import Foundation
import OSLog

/// The app's loggers, one per category, all in the unified log under the
/// app's subsystem. Paths, names and search text go
/// in `.private`; command names, counts and error kinds `.public`.
nonisolated enum Log {
    static let subsystem = "app.useresonance.resonance"

    /// Launch, quit, settings, Spotlight, the command line tool's links.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// The player: tunes, engines, audio output.
    static let playback = Logger(subsystem: subsystem, category: "playback")
    /// HVSC, playlists, favorites, fingerprints.
    static let library = Logger(subsystem: subsystem, category: "library")
    /// The control socket: who connected and what they asked.
    static let control = Logger(subsystem: subsystem, category: "control")
    /// Tune links and CSDb.
    static let sharing = Logger(subsystem: subsystem, category: "sharing")
    /// The iPhone remote.
    static let remote = Logger(subsystem: subsystem, category: "remote")
    /// Sparkle.
    static let updates = Logger(subsystem: subsystem, category: "updates")

    /// An error's kind, safe to log in public: "NSCocoaErrorDomain 4".
    static func kind(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
