import Foundation
import Observation
import Sparkle

/// Automatic updates, through Sparkle: Check for Updates… in the app menu,
/// and the Updates page in Settings.
///
/// Sparkle reads the feed (SUFeedURL, the website's appcast.xml) and only
/// installs an update whose EdDSA signature matches the public key built
/// into this app (SUPublicEDKey). That works for unsigned (ad-hoc) builds
/// too, and keeps working once releases are signed with Developer ID.
/// Both keys are empty in Debug builds, which then don't update themselves.
///
/// Which of the feed's entries this app may take is its update channel.
@Observable
final class Updater {
    /// Whether this build updates itself at all: a Release build, with a
    /// feed and a key.
    let isAvailable: Bool
    /// False while a check is running, or when updates aren't available.
    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?
    /// Why the last update went wrong, for Settings. Gone after the next good
    /// check, or once this app is a newer version.
    private(set) var lastFailure: UpdateFailure?

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

    /// Sparkle asks for the channels at each check, so a change applies from
    /// the next one. Saved only when chosen: see `UpdateChannel.current`.
    var channel: UpdateChannel {
        get { access(keyPath: \.channel); return UpdateChannel.current() }
        set {
            withMutation(keyPath: \.channel) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Pref.updateChannel)
            }
        }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let versionDisplay = VersionDisplay()
    @ObservationIgnored private let events = UpdaterEvents()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(bundle: Bundle = .main) {
        isAvailable = Self.isConfigured(bundle)
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: events, userDriverDelegate: versionDisplay)
        lastFailure = UpdateLog.atLaunch(appVersion: Self.appVersion())
        events.onWillInstall = { version in
            UpdateLog.willInstall(version: version, appVersion: Self.appVersion())
        }
        events.onCycleFinished = { [weak self] background, error, version in
            self?.cycleFinished(background: background, error: error, updateVersion: version)
        }
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

    private func cycleFinished(background: Bool, error: Error?, updateVersion: String?) {
        let outcome = UpdateLog.outcome(
            of: error,
            background: background,
            updateVersion: updateVersion,
            appVersion: Self.appVersion()
        )
        switch outcome {
        case .keep: break
        case .clear: lastFailure = nil
        case .failed(let failure): lastFailure = failure
        }
        UpdateLog.apply(outcome)
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

/// Which releases this app updates to. The feed's entries without a channel
/// are final releases, and Sparkle always offers those on top of the channels
/// named here. Every entry shares one rising build number, so moving to a
/// quieter channel doesn't go back to an older build: this one stays until the
/// channel has a newer one.
nonisolated enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, beta, alpha

    var id: Self { self }

    var title: String {
        switch self {
        case .stable: String(localized: "Stable")
        case .beta: String(localized: "Beta")
        case .alpha: String(localized: "Alpha")
        }
    }

    var summary: String {
        switch self {
        case .stable: String(localized: "Finished releases only. If you've been testing, you'll keep this version until a newer stable release arrives.")
        case .beta: String(localized: "New features a little early, and finished releases too. Expect the odd rough edge.")
        case .alpha: String(localized: "The newest builds, as soon as they're ready, plus betas and finished releases. Things may break or change.")
        }
    }

    /// The feed's `sparkle:channel` names this channel may take.
    var sparkleChannels: Set<String> {
        switch self {
        case .stable: []
        case .beta: ["beta"]
        case .alpha: ["alpha", "beta"]
        }
    }

    /// The channel of a build's release stage: "alpha.7" is alpha. It's what
    /// you get until you choose, so a tester keeps getting test builds, and
    /// someone who installs a final release only gets final releases.
    static func forReleaseStage(_ stage: String) -> UpdateChannel {
        let name = stage.split(separator: ".").first.map(String.init) ?? ""
        return UpdateChannel(rawValue: name) ?? .stable
    }

    /// The channel chosen in Settings, or else this build's.
    static func current(
        defaults: UserDefaults = .standard,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> UpdateChannel {
        if let chosen = defaults.string(forKey: Pref.updateChannel).flatMap(UpdateChannel.init(rawValue:)) {
            return chosen
        }
        return forReleaseStage(info["ResonanceReleaseStage"] as? String ?? "")
    }
}

/// What went wrong with an update, in a sentence for Settings and in full for
/// a bug report. Sparkle's own dialog only says that something did: the reason
/// is further down the error's underlying errors.
nonisolated struct UpdateFailure: Codable, Equatable {
    enum Stage: String, Codable {
        case check, download, verify, install, other
    }

    var date: Date
    var stage: Stage
    /// The version that was running.
    var appVersion: String
    /// The version it was updating to, once one was found.
    var updateVersion: String?
    var reason: String
    /// Every error in the chain, with its domain and code.
    var errors: [String]
    var url: String?
    /// A feed that couldn't be reached. Normal for a laptop that's offline.
    var isUnreachableFeed = false

    var message: String {
        let target = updateVersion ?? String(localized: "the update")
        return switch stage {
        case .check: String(localized: "Couldn't check for updates: \(reason)")
        case .download: String(localized: "Couldn't download \(target): \(reason)")
        case .verify: String(localized: "Couldn't verify \(target): \(reason)")
        case .install: String(localized: "Couldn't install \(target): \(reason)")
        case .other: String(localized: "Updating stopped: \(reason)")
        }
    }

    /// The text behind Copy Details.
    var details: String {
        var lines = [
            "Resonance update failure",
            "Date: \(date.ISO8601Format())",
            "Resonance: \(appVersion)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Stage: \(stage.rawValue)",
        ]
        if let updateVersion { lines.append("Update: \(updateVersion)") }
        if let url { lines.append("URL: \(url)") }
        lines.append("Errors:")
        lines += errors.map { "  \($0)" }
        return lines.joined(separator: "\n")
    }

    /// Nil for what isn't a failure: no update, or the user canceling.
    init?(error: Error, updateVersion: String?, appVersion: String, date: Date = .now) {
        let chain = Self.chain(of: error)
        let top = chain[0]
        if top.domain == SUSparkleErrorDomain, Self.notFailures.contains(top.code) { return nil }
        if chain.contains(where: { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorCancelled }) { return nil }

        self.date = date
        self.appVersion = appVersion
        self.updateVersion = updateVersion
        stage = top.domain == SUSparkleErrorDomain ? Self.stage(ofCode: top.code) : .other
        reason = Self.reason(in: chain)
        errors = chain.map { "\($0.domain) \($0.code): \($0.localizedDescription)" }
        url = Self.url(in: chain)
        isUnreachableFeed = stage == .check && chain.contains { $0.domain == NSURLErrorDomain }
    }

    /// For an install that left the old version running.
    init(unfinishedInstallOf version: String, appVersion: String, date: Date = .now) {
        self.date = date
        self.appVersion = appVersion
        updateVersion = version
        stage = .install
        reason = String(localized: "Resonance is still \(appVersion) after the update tried to install. You can download the new version from the website.")
        errors = [String(localized: "The installer ran after Resonance quit, and left no error.")]
    }

    /// SUNoUpdateError, SUInstallationCanceledError and
    /// SUInstallationAuthorizeLaterError.
    private static let notFailures = [1001, 4007, 4008]

    /// Sparkle numbers its errors by phase: see SUErrors.h.
    private static func stage(ofCode code: Int) -> Stage {
        switch code {
        case 1000..<2000: .check
        case 2000..<3000: .download
        case 3000..<4000: .verify
        case 4000..<5000: .install
        default: .other
        }
    }

    private static func chain(of error: Error) -> [NSError] {
        var chain = [error as NSError]
        while let next = chain.last?.userInfo[NSUnderlyingErrorKey] as? NSError, chain.count < 10 {
            chain.append(next)
        }
        return chain
    }

    /// The deepest error with something to say. The top one is Sparkle's
    /// generic sentence, and CFNetwork's sit under NSURLError's and only
    /// repeat them as a number.
    private static func reason(in chain: [NSError]) -> String {
        let useful = chain.dropFirst().filter { $0.domain != kCFErrorDomainCFNetwork as String }
        return (useful.last ?? chain[0]).localizedDescription
    }

    /// Without its query: a download's redirect can carry a signed token.
    private static func url(in chain: [NSError]) -> String? {
        for error in chain {
            guard let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            parts.query = nil
            return parts.string
        }
        return nil
    }
}

/// Keeps the last failure across launches. An install has to be followed up on
/// the next launch: the app has quit by the time it runs, so its error never
/// reaches us, and a note left beforehand is the only way to tell.
nonisolated enum UpdateLog {
    enum Outcome: Equatable {
        case keep, clear
        case failed(UpdateFailure)
    }

    private struct Attempt: Codable {
        var version: String
        var from: String
    }

    static func willInstall(version: String, appVersion: String, defaults: UserDefaults = .standard) {
        let attempt = Attempt(version: version, from: appVersion)
        defaults.set(try? JSONEncoder().encode(attempt), forKey: Pref.updateAttempt)
    }

    /// The failure to show when the app starts: an install that didn't happen,
    /// or one saved earlier that still applies to this version.
    static func atLaunch(appVersion: String, defaults: UserDefaults = .standard, date: Date = .now) -> UpdateFailure? {
        if let data = defaults.data(forKey: Pref.updateAttempt) {
            defaults.removeObject(forKey: Pref.updateAttempt)
            if let attempt = try? JSONDecoder().decode(Attempt.self, from: data), attempt.from == appVersion {
                let failure = UpdateFailure(unfinishedInstallOf: attempt.version, appVersion: appVersion, date: date)
                save(failure, defaults: defaults)
                return failure
            }
        }
        guard let data = defaults.data(forKey: Pref.updateFailure),
              let failure = try? JSONDecoder().decode(UpdateFailure.self, from: data),
              failure.appVersion == appVersion else {
            defaults.removeObject(forKey: Pref.updateFailure)
            return nil
        }
        return failure
    }

    /// What a finished update cycle means for the row in Settings. Finding
    /// nothing, or an update the user dismissed, is a good check. A daily check
    /// that can't reach the feed is left out: that's a Mac that's offline, and
    /// it would replace a failure worth keeping.
    static func outcome(of error: Error?, background: Bool, updateVersion: String?, appVersion: String) -> Outcome {
        guard let error else { return .clear }
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, nsError.code == 1001 { return .clear }
        guard let failure = UpdateFailure(error: error, updateVersion: updateVersion, appVersion: appVersion) else {
            return .keep
        }
        return background && failure.isUnreachableFeed ? .keep : .failed(failure)
    }

    /// A failure in this session means the install isn't going to happen, so
    /// the note for the next launch goes too.
    static func apply(_ outcome: Outcome, defaults: UserDefaults = .standard) {
        switch outcome {
        case .keep:
            break
        case .clear:
            defaults.removeObject(forKey: Pref.updateFailure)
        case .failed(let failure):
            defaults.removeObject(forKey: Pref.updateAttempt)
            save(failure, defaults: defaults)
        }
    }

    private static func save(_ failure: UpdateFailure, defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(failure), forKey: Pref.updateFailure)
    }
}

/// What Sparkle asks of the app and tells it: which channels to look in, and
/// how each update went.
final class UpdaterEvents: NSObject, SPUUpdaterDelegate {
    var onWillInstall: (String) -> Void = { _ in }
    var onCycleFinished: (_ background: Bool, _ error: Error?, _ updateVersion: String?) -> Void = { _, _, _ in }
    private var updateVersion: String?

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.current().sparkleChannels
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateVersion = item.displayVersionString
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        onWillInstall(item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        onCycleFinished(updateCheck == .updatesInBackground, error, updateVersion)
        updateVersion = nil
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
