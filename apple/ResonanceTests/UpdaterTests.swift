import Foundation
import Testing
@testable import Resonance

struct UpdaterTests {
    private let key = "pU9u4JZ6OrEeAqiZ3h3cs4OH4+13HA6+4Sl0eKIfEKo="
    private let feed = "https://erikluimes.github.io/resonance/appcast.xml"

    @Test func releaseBuildsWithAFeedAndKeyUpdate() {
        #expect(Updater.isConfigured(info: ["SUFeedURL": feed, "SUPublicEDKey": key]))
    }

    /// Debug builds: the build settings are empty.
    @Test func emptySettingsDontUpdate() {
        #expect(!Updater.isConfigured(info: ["SUFeedURL": "", "SUPublicEDKey": ""]))
        #expect(!Updater.isConfigured(info: ["SUFeedURL": feed, "SUPublicEDKey": " "]))
        #expect(!Updater.isConfigured(info: ["SUFeedURL": "", "SUPublicEDKey": key]))
        #expect(!Updater.isConfigured(info: [:]))
    }

    /// The test host is a Debug build, so it doesn't update itself.
    @Test @MainActor func debugBuildIsNotAvailable() {
        #expect(!Updater.isConfigured(.main))
    }

    /// The channels nest: alpha sees betas too, and stable names none, which
    /// leaves Sparkle's default channel, the final releases.
    @Test func channelsNameWhatTheyMayTake() {
        #expect(UpdateChannel.stable.sparkleChannels.isEmpty)
        #expect(UpdateChannel.beta.sparkleChannels == ["beta"])
        #expect(UpdateChannel.alpha.sparkleChannels == ["alpha", "beta"])
    }

    @Test func aBuildStartsOnItsReleaseStagesChannel() {
        #expect(UpdateChannel.forReleaseStage("alpha.7") == .alpha)
        #expect(UpdateChannel.forReleaseStage("beta.2") == .beta)
        #expect(UpdateChannel.forReleaseStage("") == .stable)
        // release.sh refuses any other stage; this is only the fallback.
        #expect(UpdateChannel.forReleaseStage("nightly.1") == .stable)
    }

    @Test func aChosenChannelBeatsTheBuilds() throws {
        let suite = "UpdaterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alphaBuild = ["ResonanceReleaseStage": "alpha.7"]

        #expect(UpdateChannel.current(defaults: defaults, info: alphaBuild) == .alpha)
        defaults.set(UpdateChannel.stable.rawValue, forKey: Pref.updateChannel)
        #expect(UpdateChannel.current(defaults: defaults, info: alphaBuild) == .stable)
        // A value this version doesn't know falls back to the build's.
        defaults.set("nightly", forKey: Pref.updateChannel)
        #expect(UpdateChannel.current(defaults: defaults, info: alphaBuild) == .alpha)
    }
}

struct UpdateFailureTests {
    private let sparkle = "SUSparkleErrorDomain"

    private func sparkleError(_ code: Int, _ text: String = "An error occurred.", underlying: NSError? = nil, url: URL? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: text]
        info[NSUnderlyingErrorKey] = underlying
        info[NSURLErrorFailingURLErrorKey] = url
        return NSError(domain: sparkle, code: code, userInfo: info)
    }

    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "UpdateFailureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    /// Sparkle's download dialog is this error: a generic sentence, with the
    /// reason under it and CFNetwork's number under that.
    @Test func aDownloadFailureGivesTheRealReason() throws {
        let cf = NSError(domain: kCFErrorDomainCFNetwork as String, code: -1005)
        let url = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [
            NSLocalizedDescriptionKey: "The network connection was lost.",
            NSUnderlyingErrorKey: cf,
        ])
        let failure = try #require(UpdateFailure(
            error: sparkleError(2001, underlying: url),
            updateVersion: "0.1.0-alpha.8",
            appVersion: "0.1.0-alpha.7"
        ))
        #expect(failure.stage == .download)
        #expect(failure.message == "Couldn't download 0.1.0-alpha.8: The network connection was lost.")
        #expect(failure.errors.count == 3)
        #expect(failure.details.contains("NSURLErrorDomain -1005"))
        #expect(failure.details.contains("Resonance: 0.1.0-alpha.7"))
    }

    @Test func eachPhaseGetsItsSentence() throws {
        func message(_ code: Int) throws -> String {
            try #require(UpdateFailure(error: sparkleError(code, "Why."), updateVersion: "2", appVersion: "1")).message
        }
        #expect(try message(1002) == "Couldn't check for updates: Why.")
        #expect(try message(2000) == "Couldn't download 2: Why.")
        #expect(try message(3001) == "Couldn't verify 2: Why.")
        #expect(try message(4005) == "Couldn't install 2: Why.")
        #expect(try message(5000) == "Updating stopped: Why.")
    }

    @Test func noUpdateAndCancelingArentFailures() {
        for code in [1001, 4007, 4008] {
            #expect(UpdateFailure(error: sparkleError(code), updateVersion: nil, appVersion: "1") == nil)
        }
        let canceled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(UpdateFailure(error: sparkleError(2001, underlying: canceled), updateVersion: nil, appVersion: "1") == nil)
    }

    @Test func aDownloadsTokenStaysOutOfTheDetails() throws {
        let url = try #require(URL(string: "https://release-assets.example.com/a.dmg?sig=secret"))
        let failure = try #require(UpdateFailure(error: sparkleError(2001, url: url), updateVersion: nil, appVersion: "1"))
        #expect(failure.url == "https://release-assets.example.com/a.dmg")
    }

    /// Being offline at the daily check isn't worth a row, and must not wipe a
    /// real failure. Asking for a check and being told it failed is.
    @Test func aDailyCheckThatsOfflineChangesNothing() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let error = sparkleError(1002, underlying: offline)
        #expect(UpdateLog.outcome(of: error, background: true, updateVersion: nil, appVersion: "1") == .keep)
        guard case .failed = UpdateLog.outcome(of: error, background: false, updateVersion: nil, appVersion: "1") else {
            Issue.record("A check you asked for should report the failure")
            return
        }
    }

    @Test func aGoodCheckClearsTheFailure() {
        #expect(UpdateLog.outcome(of: nil, background: true, updateVersion: nil, appVersion: "1") == .clear)
        #expect(UpdateLog.outcome(of: sparkleError(1001), background: false, updateVersion: nil, appVersion: "1") == .clear)
    }

    @Test func aFailureLastsUntilTheAppIsANewerVersion() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let failure = try #require(UpdateFailure(error: sparkleError(2001), updateVersion: "2", appVersion: "1"))
        UpdateLog.apply(.failed(failure), defaults: defaults)

        #expect(UpdateLog.atLaunch(appVersion: "1", defaults: defaults)?.stage == .download)
        #expect(UpdateLog.atLaunch(appVersion: "2", defaults: defaults) == nil)
        #expect(UpdateLog.atLaunch(appVersion: "1", defaults: defaults) == nil)
    }

    /// The installer runs after the app has quit, so the next launch is the
    /// only one to notice.
    @Test func stillTheOldVersionMeansTheInstallFailed() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        UpdateLog.willInstall(version: "2", appVersion: "1", defaults: defaults)

        let failure = try #require(UpdateLog.atLaunch(appVersion: "1", defaults: defaults))
        #expect(failure.stage == .install)
        #expect(failure.message.hasPrefix("Couldn't install 2:"))
        // It stays for the launches after, as any failure does.
        #expect(UpdateLog.atLaunch(appVersion: "1", defaults: defaults)?.updateVersion == "2")
    }

    @Test func theNewVersionMeansItWorked() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        UpdateLog.willInstall(version: "2", appVersion: "1", defaults: defaults)
        #expect(UpdateLog.atLaunch(appVersion: "2", defaults: defaults) == nil)
        #expect(defaults.data(forKey: Pref.updateAttempt) == nil)
    }

    /// A failure in the same session means the note is out of date.
    @Test func aFailureBeforeQuittingDropsTheInstallNote() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        UpdateLog.willInstall(version: "2", appVersion: "1", defaults: defaults)
        let failure = try #require(UpdateFailure(error: sparkleError(4005), updateVersion: "2", appVersion: "1"))
        UpdateLog.apply(.failed(failure), defaults: defaults)
        #expect(defaults.data(forKey: Pref.updateAttempt) == nil)
    }

    /// These are optional Objective-C methods: one whose Swift name is slightly
    /// off compiles and is simply never called.
    @Test @MainActor func sparkleCanSeeTheCallbacks() {
        let events = UpdaterEvents()
        #expect(events.responds(to: NSSelectorFromString("updater:didFinishUpdateCycleForUpdateCheck:error:")))
        #expect(events.responds(to: NSSelectorFromString("updater:willInstallUpdate:")))
        #expect(events.responds(to: NSSelectorFromString("updater:didFindValidUpdate:")))
        #expect(events.responds(to: NSSelectorFromString("allowedChannelsForUpdater:")))
    }
}

struct SettingsPageTests {
    @Test func everyPageIsInTheSidebarOnce() {
        let listed = SettingsPage.groups.flatMap(\.pages)
        #expect(listed.count == SettingsPage.allCases.count)
        #expect(Set(listed) == Set(SettingsPage.allCases))
    }

    @Test func updatesComeFirst() {
        #expect(SettingsPage.groups.first?.pages.first == .updates)
    }

    /// The saved value from when these were tabs: Advanced is gone, and
    /// `@AppStorage` falls back to its default for a value it can't read.
    @Test func savedTabsStillFindTheirPage() {
        #expect(SettingsPage(rawValue: "advanced") == nil)
        #expect(SettingsPage(rawValue: "appearance") == .appearance)
        #expect(SettingsPage(rawValue: "playback") == .playback)
        #expect(SettingsPage(rawValue: "collection") == .collection)
        #expect(SettingsPage(rawValue: "integrations") == .integrations)
        #expect(SettingsPage(rawValue: "history") == .history)
    }
}

struct AppAppearanceTests {
    @Test func eachModeNamesItsAppearance() {
        #expect(AppAppearance.light.appearanceName == .aqua)
        #expect(AppAppearance.dark.appearanceName == .darkAqua)
        #expect(AppAppearance.auto.appearanceName == nil)
    }

    @Test func itStartsOnAutoUntilChosen() throws {
        let suite = "AppAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppAppearance.saved(defaults: defaults) == .auto)
        defaults.set(AppAppearance.dark.rawValue, forKey: Pref.appAppearance)
        #expect(AppAppearance.saved(defaults: defaults) == .dark)
        // A value this version doesn't know follows the Mac.
        defaults.set("sepia", forKey: Pref.appAppearance)
        #expect(AppAppearance.saved(defaults: defaults) == .auto)
    }
}
