import Foundation
import PhosphorCore

/// One setting, as Settings' search finds it: the name it's shown with, on
/// its page, and other words people may type for it.
nonisolated struct SettingsItem: Hashable {
    let page: SettingsPage
    let title: String
    var keywords = ""

    /// Every word appears in its name or its other words, ignoring case and
    /// accents.
    func matches(_ words: [Substring]) -> Bool {
        SettingsSearch.contains(words, in: title + " " + keywords)
    }
}

/// Settings' search field: the pages with a setting that has every word
/// typed, or whose own name has them, in the sidebar's order.
nonisolated enum SettingsSearch {
    /// Nil for an empty search, which shows the sidebar as it is.
    static func pages(matching query: String) -> [SettingsPage]? {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return SettingsPage.groups.flatMap(\.pages).filter { page in
            contains(words, in: page.title) || page.items.contains { $0.matches(words) }
        }
    }

    static func contains(_ words: [Substring], in text: String) -> Bool {
        words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

nonisolated extension SettingsPage {
    /// The page's settings, in its order, named as the page shows them. A
    /// row that only shows sometimes is here too: its page explains it.
    var items: [SettingsItem] {
        switch self {
        case .updates:
            [
                item("Update channel", keywords: String(localized: "beta alpha stable release", comment: "Settings search: other words for the update channel")),
                item("Check for updates automatically"),
                item("Download and install automatically"),
                item("Last checked", keywords: String(localized: "check now new version", comment: "Settings search: other words for checking for updates")),
            ]
        case .general:
            [
                item("Start page", keywords: String(localized: "open launch home", comment: "Settings search: other words for the start page")),
                item("Show the player in the menu bar", keywords: String(localized: "menubar status mini player", comment: "Settings search: other words for the menu bar player")),
                item("Keys", keywords: String(localized: "keyboard shortcuts vim emacs", comment: "Settings search: other words for the key scheme")),
            ]
        case .appearance:
            [
                item("Appearance", keywords: String(localized: "dark mode light auto", comment: "Settings search: other words for light and dark")),
                item("Theme", keywords: String(localized: "colors voices custom palette", comment: "Settings search: other words for the visualizers' theme")),
                item("Show theme badge"),
                item("Now Playing Visualizers", keywords: String(localized: "visualizer scope spectrum", comment: "Settings search: other words for the visualizers")),
            ]
        case .engine:
            Engine.pickerOrder.map { engine in
                item(verbatim: engine.displayName, keywords: engine.caption + " " + String(localized: "emulation SID chip", comment: "Settings search: other words for an engine"))
            }
        case .playback:
            [
                item("Skip RSID tunes"),
                item("Default song length", keywords: String(localized: "songlengths duration seconds silence", comment: "Settings search: other words for the default song length")),
                item("Play 2SID tunes in mirrored stereo"),
            ]
        case .collection:
            [
                item("HVSC", keywords: String(localized: "High Voltage SID Collection download update version", comment: "Settings search: other words for the collection")),
                item("Collection folder", keywords: String(localized: "location path choose", comment: "Settings search: other words for the collection folder")),
            ]
        case .fingerprints:
            [
                item("Fingerprinted", keywords: String(localized: "progress Sounds Like", comment: "Settings search: other words for the fingerprint scan's progress")),
                item("Scanning", keywords: String(localized: "pause resume start scan", comment: "Settings search: other words for the fingerprint scan")),
                item("Database", keywords: String(localized: "rebuild fingerprints", comment: "Settings search: other words for the fingerprint database")),
                item("Published set", keywords: String(localized: "download fingerprints", comment: "Settings search: other words for the published fingerprint set")),
            ]
        case .history:
            [
                item("Recently played", keywords: String(localized: "clear history", comment: "Settings search: other words for recently played")),
                item("Heard", keywords: String(localized: "reset SIDs heard count", comment: "Settings search: other words for heard tunes")),
            ]
#if CSDB
        case .csdb:
            [
                item("Show the C64 scene from CSDb", keywords: String(localized: "Scene Pulse demoscene", comment: "Settings search: other words for CSDb")),
                item("Show CSDb trivia about composers"),
                item("Show composer photos from Wikimedia Commons", keywords: String(localized: "Wikipedia", comment: "Settings search: other words for composer photos")),
            ]
#endif
        case .integrations:
            [
                item("Command Line Tool", keywords: String(localized: "terminal CLI install PATH shell", comment: "Settings search: other words for the command line tool")),
                item("Claude and other assistants", keywords: String(localized: "MCP AI Claude Code", comment: "Settings search: other words for assistants")),
                item("Siri and Shortcuts"),
                item("Spotlight"),
                item("Quick Look"),
                item("Notifications"),
                item("Dock icon"),
            ]
        case .remote:
            [
                item("Control Resonance from iPhone and iPad", keywords: String(localized: "Resonance Remote network", comment: "Settings search: other words for the remote")),
                item("Connect devices on your Apple Account without pairing", keywords: String(localized: "iCloud Keychain", comment: "Settings search: other words for joining through the Apple Account")),
                item("Pair a Device", keywords: String(localized: "QR code pairing", comment: "Settings search: other words for pairing a device")),
                item("Paired Devices", keywords: String(localized: "remove sign out", comment: "Settings search: other words for paired devices")),
            ]
        case .crashes:
            [
                item("Saved Reports", keywords: String(localized: "crash report bug GitHub delete", comment: "Settings search: other words for crash reports")),
            ]
        case .storage:
            [
                item("Resonance's folder", keywords: String(localized: "data folder Finder disk space size", comment: "Settings search: other words for Resonance's folder")),
                item("Downloaded collection", keywords: String(localized: "HVSC Trash", comment: "Settings search: other words for the downloaded collection")),
                item("Reset Resonance", keywords: String(localized: "everything start fresh erase delete", comment: "Settings search: other words for resetting Resonance")),
            ]
        }
    }

    private func item(_ title: LocalizedStringResource, keywords: String = "") -> SettingsItem {
        SettingsItem(page: self, title: String(localized: title), keywords: keywords)
    }

    private func item(verbatim title: String, keywords: String) -> SettingsItem {
        SettingsItem(page: self, title: title, keywords: keywords)
    }
}
