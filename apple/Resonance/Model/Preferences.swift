import Foundation
import PhosphorCore

/// UserDefaults keys for the settings `PlayerStore` persists.
nonisolated enum Pref {
    /// What Spotlight last indexed (SpotlightTunes.mark).
    static let spotlightIndexed = "spotlightIndexed"
    static let engine = "engine"
    static let volume = "volume"
    static let shuffle = "shuffle"
    static let repeatMode = "repeat"
    static let skipRSID = "skipRSID"
    static let defaultSongLength = "defaultSongLengthSecs"
    static let forceStereo2SID = "forceStereo2SID"
    static let pseudoStereo = "pseudoStereo"
    static let hvscRoot = "hvscRoot"
    /// Bookmarks of folders and files chosen outside the sandbox (FileAccess).
    static let fileAccess = "fileAccess"
    static let visualizerMode = "visualizerMode"
    static let nowPlayingVisualizer = "nowPlayingVisualizer"
    static let theme = "theme"
    static let customTheme = "customTheme"
    static let themeBadge = "themeBadge"
    static let fingerprintScanPaused = "fingerprintScanPaused"
    static let settingsTab = "settingsTab"
    static let appAppearance = "appAppearance"
    static let updateChannel = "updateChannel"
    static let updateFailure = "updateFailure"
    static let updateAttempt = "updateAttempt"
    static let startPage = "startPage"
    static let homeShownForRoot = "homeShownForRoot"
    static let homeSeenRelease = "homeSeenRelease"
    static let playlistsRecent = "playlistsRecent"
    /// Per extractor version: a set of another version's fingerprints doesn't count.
    static let fingerprintSetImported = "fingerprintSetImported.x2"
    static let menuBarPlayer = "menuBarPlayer"
    /// Normal, Vim or Emacs keys (`KeyScheme`).
    static let keyScheme = "keyScheme"
    static let underTheHoodTab = "underTheHoodTab"
    /// The welcome steps already been through.
    static let onboardingSeen = "onboardingSeen"
#if CSDB
    /// Whether Resonance shows the scene from CSDb, and so talks to csdb.dk.
    static let csdbEnabled = "csdbEnabled"
    /// Whether composers' CSDb trivia shows. Off by default: it's unverified.
    static let csdbTrivia = "csdbTrivia"
    /// Whether composer profiles look for a photo on Wikimedia Commons.
    static let composerPhotos = "composerPhotos"
#endif
}

nonisolated extension PlaybackOptions {
    init(from defaults: UserDefaults) {
        self.init(
            skipRsid: defaults.bool(forKey: Pref.skipRSID),
            defaultSongLengthSecs: UInt32(clamping: defaults.integer(forKey: Pref.defaultSongLength)),
            forceStereo2sid: defaults.bool(forKey: Pref.forceStereo2SID),
            pseudoStereo: PseudoStereo(storageValue: defaults.string(forKey: Pref.pseudoStereo))
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(skipRsid, forKey: Pref.skipRSID)
        defaults.set(Int(defaultSongLengthSecs), forKey: Pref.defaultSongLength)
        defaults.set(forceStereo2sid, forKey: Pref.forceStereo2SID)
        defaults.set(pseudoStereo?.storageValue, forKey: Pref.pseudoStereo)
    }
}

// MARK: - Storage and display names for the core's enums

nonisolated extension Engine {
    init?(storageValue: String?) {
        switch storageValue {
        // Retired from Settings: a saved one lands on its nearest working engine.
        case "sidlite": self = .sidLiteDirect
        case "resid": self = .reSidFp
        case "residfp": self = .reSidFp
        case "sidlite-direct": self = .sidLiteDirect
        default: return nil
        }
    }

    var storageValue: String {
        switch self {
        case .sidLite: "sidlite"
        case .reSid: "resid"
        case .reSidFp: "residfp"
        case .sidLiteDirect: "sidlite-direct"
        }
    }

    var displayName: String {
        switch self {
        case .sidLite: "SIDLite"
        case .reSid: "reSID"
        case .reSidFp: "reSIDfp"
        case .sidLiteDirect: "SIDLite direct"
        }
    }

    /// What sets each engine apart, in a line: what a newcomer needs to pick one.
    var caption: String {
        switch self {
        case .sidLite: "Compact model, the original player."
        case .reSid: "Older model, the heaviest."
        case .reSidFp: "Most accurate sound."
        case .sidLiteDirect: "Lightest on the processor."
        }
    }

    /// The engine a fresh install plays on, and the one Settings recommends.
    static let recommended = Engine.reSidFp

    /// The engines as Settings lists them: the recommended one first, then
    /// the light one. `.sidLite` and `.reSid` are retired, with their code
    /// going in the next alpha.
    static let pickerOrder: [Engine] = [.reSidFp, .sidLiteDirect]
}

nonisolated extension Repeat {
    init?(storageValue: String?) {
        switch storageValue {
        case "off": self = .off
        case "all": self = .all
        case "one": self = .one
        default: return nil
        }
    }

    var storageValue: String {
        switch self {
        case .off: "off"
        case .all: "all"
        case .one: "one"
        }
    }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }

    var symbolName: String {
        self == .one ? "repeat.1" : "repeat"
    }
}

nonisolated extension HvscCategory {
    var displayName: String {
        switch self {
        case .musicians: "Musicians"
        case .games: "Games"
        case .demos: "Demos"
        }
    }

    var symbolName: String {
        switch self {
        case .musicians: "music.mic"
        case .games: "gamecontroller"
        case .demos: "sparkles.tv"
        }
    }
}

nonisolated extension PseudoStereo {
    init?(storageValue: String?) {
        switch storageValue {
        case "subtle": self = .subtle
        case "medium": self = .medium
        case "wide": self = .wide
        default: return nil
        }
    }

    var storageValue: String {
        switch self {
        case .subtle: "subtle"
        case .medium: "medium"
        case .wide: "wide"
        }
    }

    var displayName: String {
        switch self {
        case .subtle: "Subtle"
        case .medium: "Medium"
        case .wide: "Wide"
        }
    }
}
