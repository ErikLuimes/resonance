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

    @Test func fingerprintKeyExplainsEveryBarInOrder() {
        let keys = HelpTopic.topic(.readingFingerprints).blocks.compactMap { block -> [HelpTrait]? in
            if case .traitKey(let traits) = block { traits } else { nil }
        }
        #expect(keys.count == 1)
        #expect(keys.first?.map(\.trait) == SoundTrait.allCases)
    }

    @Test func fingerprintExamplesHaveEveryTraitAndAFullMix() {
        for block in HelpTopic.topic(.readingFingerprints).blocks {
            guard case .fingerprintExamples(let examples) = block else { continue }
            for example in examples {
                #expect(example.traits.count == SoundTrait.allCases.count)
                #expect(abs(example.mix.reduce(0, +) - 1) < 0.001, "\(example.caption)")
            }
        }
    }

    @Test func fingerprintTopicIsFoundByWhatItExplains() {
        let topic = HelpTopic.topic(.readingFingerprints)
        #expect(topic.matches("barcode vibrato"))
        #expect(topic.matches("sphere waveform"))
    }

    @Test func integrationsAreFoundByName() {
        #expect(HelpTopic.topic(.terminal).matches("skull fire"))
        #expect(HelpTopic.topic(.commands).matches("resonance pick --multi"))
        #expect(HelpTopic.topic(.assistants).matches("Copy Command"))
        #expect(HelpTopic.topic(.raycast).matches("hotkey alias"))
        #expect(HelpTopic.topic(.siriAndSpotlight).matches("Quick Look"))
        #expect(HelpTopic.topic(.dock).matches("Drift notification"))
        #expect(HelpTopic.topic(.sharing).matches("Copy Link"))
    }

    @Test func everySiriPhraseIsInHelp() {
        let text = HelpTopic.topic(.siriAndSpotlight).searchText
        for phrase in ["Surprise me", "Play something like this", "Drift from this tune", "Favorite this tune", "Play Favorites"] {
            #expect(text.contains(phrase), "\(phrase)")
        }
    }

    @Test func shortcutsAreSearchable() {
        #expect(HelpTopic.topic(.shortcuts).matches("⇧⌘R surprise"))
    }
}
