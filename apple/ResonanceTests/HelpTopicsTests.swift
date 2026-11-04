import Testing
@testable import Resonance

@MainActor
struct HelpTopicsTests {
    @Test func everyTopicIsThereOnce() {
        #expect(HelpTopic.all.map(\.id) == HelpTopic.ID.allCases)
    }

    @Test func relatedTopicsAreOthers() {
        for topic in HelpTopic.all {
            #expect(!topic.related.contains(topic.id), "\(topic.id) is related to itself")
        }
    }

    @Test func searchNeedsEveryWordIgnoringCaseAndAccents() {
        let soundsLike = HelpTopic.topic(.soundsLike)
        #expect(soundsLike.matches(""))
        #expect(soundsLike.matches("find SIMILAR"))
        #expect(soundsLike.matches("fingerprint scan"))
        #expect(!soundsLike.matches("fingerprint ultimate"))
        #expect(HelpTopic.topic(.library).matches("hülsbeck"))
        #expect(HelpTopic.topic(.library).matches("hulsbeck"))
    }

    @Test func searchSkipsMarkdown() {
        // "**Download** next to" in the text.
        #expect(HelpTopic.topic(.gettingStarted).matches("Download next"))
    }

    @Test func shortcutsAreSearchable() {
        #expect(HelpTopic.topic(.shortcuts).matches("⇧⌘R surprise"))
    }
}
