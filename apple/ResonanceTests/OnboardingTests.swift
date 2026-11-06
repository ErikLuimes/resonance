import Foundation
import Testing
@testable import Resonance

struct OnboardingTests {
    private func pending(
        hasCollection: Bool = false,
        isDownloading: Bool = false,
        seen: Set<String> = [],
        sceneAnswered: Bool = false
    ) -> [OnboardingStep] {
        OnboardingStep.pending(hasCollection: hasCollection, isDownloading: isDownloading,
                               seen: seen, sceneAnswered: sceneAnswered)
    }

    private var core: [OnboardingStep] { [.collection, .smartPlaylists, .soundsLike] }

    /// Someone who went through the welcome when it ended on the visualizers.
    @Test func aNewStepIsAllThatExistingUsersSee() {
        #expect(pending(hasCollection: true, seen: ["collection", "soundsLike", "visualizers"], sceneAnswered: true) == [.smartPlaylists])
    }

    @Test func aCollectionOrADownloadSkipsTheFirstStep() {
        #expect(!pending(hasCollection: true).contains(.collection))
        #expect(!pending(isDownloading: true).contains(.collection))
        #expect(pending().first == .collection)
    }

    @Test func seenStepsDoNotComeBack() {
        let seen = Set(core.map(\.rawValue))
        #expect(pending(seen: seen).allSatisfy { !core.contains($0) })
    }

    @Test func theHelpMenuIgnoresWhatWasSeen() {
        let all = OnboardingStep.all(hasCollection: true, isDownloading: false)
        #expect(all.contains(.soundsLike))
        #expect(all.contains(.smartPlaylists))
        #expect(!all.contains(.collection))
    }

    @Test func seenIsRemembered() throws {
        let name = "OnboardingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        OnboardingStep.smartPlaylists.markSeen(in: defaults)
        OnboardingStep.soundsLike.markSeen(in: defaults)
        #expect(Set(defaults.stringArray(forKey: Pref.onboardingSeen) ?? []) == ["smartPlaylists", "soundsLike"])
    }

#if CSDB
    @Test func theSceneComesLastUntilAnswered() {
        #expect(pending().last == .scene)
        #expect(!pending(sceneAnswered: true).contains(.scene))
    }

    /// When CSDb ships, people past the welcome see this one step.
    @Test func existingUsersSeeOnlyTheScene() {
        let seen = Set(core.map(\.rawValue))
        #expect(pending(hasCollection: true, seen: seen) == [.scene])
    }
#else
    @Test func withoutTheFlagThereAreThreeSteps() {
        #expect(pending() == core)
        #expect(OnboardingStep.allCases == core)
    }
#endif
}
