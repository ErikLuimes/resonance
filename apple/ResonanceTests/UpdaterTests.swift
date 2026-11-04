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
}
