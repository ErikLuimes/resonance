import Foundation
import PhosphorCore

/// UserDefaults keys for the settings `PlayerStore` persists.
nonisolated enum Pref {
    static let engine = "engine"
    static let volume = "volume"
    static let shuffle = "shuffle"
    static let repeatMode = "repeat"
    static let skipRSID = "skipRSID"
    static let defaultSongLength = "defaultSongLengthSecs"
    static let forceStereo2SID = "forceStereo2SID"
    static let pseudoStereo = "pseudoStereo"
    static let hvscRoot = "hvscRoot"
    static let visualizerMode = "visualizerMode"
    static let nowPlayingVisualizer = "nowPlayingVisualizer"
    static let theme = "theme"
    static let customTheme = "customTheme"
    static let themeBadge = "themeBadge"
    static let fingerprintScanPaused = "fingerprintScanPaused"
    static let settingsTab = "settingsTab"
    static let homeShownForRoot = "homeShownForRoot"
    static let homeSeenRelease = "homeSeenRelease"
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
        case "sidlite": self = .sidLite
        case "resid": self = .reSid
        default: return nil
        }
    }

    var storageValue: String {
        switch self {
        case .sidLite: "sidlite"
        case .reSid: "resid"
        }
    }

    var displayName: String {
        switch self {
        case .sidLite: "SIDLite (libsidplayfp)"
        case .reSid: "reSID"
        }
    }
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

    /// Games and Demos are split into alphabetical sections, not authors.
    var groupNoun: String {
        self == .musicians ? "authors" : "sections"
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
