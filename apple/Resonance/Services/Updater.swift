import Foundation
import Observation
import Sparkle

/// Automatic updates, through Sparkle: Check for Updates… in the app menu,
/// and the Updates section in Settings → Advanced.
///
/// Sparkle reads the feed (SUFeedURL, the website's appcast.xml) and only
/// installs an update whose EdDSA signature matches the public key built
/// into this app (SUPublicEDKey). That works for unsigned (ad-hoc) builds
/// too, and keeps working once releases are signed with Developer ID.
/// Both keys are empty in Debug builds, which then don't update themselves.
@Observable
final class Updater {
    /// Whether this build updates itself at all: a Release build, with a
    /// feed and a key.
    let isAvailable: Bool
    /// False while a check is running, or when updates aren't available.
    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?

    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return controller.updater.automaticallyChecksForUpdates }
        set {
            withMutation(keyPath: \.checksAutomatically) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var installsAutomatically: Bool {
        get { access(keyPath: \.installsAutomatically); return controller.updater.automaticallyDownloadsUpdates }
        set {
            withMutation(keyPath: \.installsAutomatically) {
                controller.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let versionDisplay = VersionDisplay()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(bundle: Bundle = .main) {
        isAvailable = Self.isConfigured(bundle)
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: versionDisplay)
        guard isAvailable else { return }
        controller.startUpdater()
        let updater = controller.updater
        observations = [
            // Sparkle changes both on the main thread.
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastCheck = updater.lastUpdateCheckDate }
            },
        ]
    }

    /// Checks now, showing what it finds (or that Resonance is up to date).
    func checkForUpdates() {
        guard isAvailable else { return }
        controller.checkForUpdates(nil)
    }

    /// "0.1.0-alpha.1": the version and its release stage (the project's
    /// RELEASE_STAGE, none for a final release), as About shows it.
    nonisolated static func appVersion(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let stage = info["ResonanceReleaseStage"] as? String ?? ""
        return stage.isEmpty ? version : "\(version)-\(stage)"
    }

    /// A feed URL and a public key in the Info.plist: Release builds.
    nonisolated static func isConfigured(_ bundle: Bundle) -> Bool {
        isConfigured(info: bundle.infoDictionary ?? [:])
    }

    nonisolated static func isConfigured(info: [String: Any]) -> Bool {
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        return feed?.scheme != nil && !key.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Sparkle's dialogs show CFBundleShortVersionString, "0.1.0" for every
/// alpha. These show the release stage too: the feed's entries have it
/// (release.sh writes it), and this app's comes from the Info.plist.
private final class VersionDisplay: NSObject, SPUStandardUserDriverDelegate, SUVersionDisplay {
    func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? { self }

    func formatUpdateVersion(
        fromUpdate update: SUAppcastItem,
        andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>,
        withBundleVersion bundleVersion: String
    ) -> String {
        inOutBundleDisplayVersion.pointee = Updater.appVersion() as NSString
        return update.displayVersionString
    }

    func formatBundleDisplayVersion(_ bundleDisplayVersion: String, withBundleVersion bundleVersion: String, matchingUpdate: SUAppcastItem?) -> String {
        Updater.appVersion()
    }
}
