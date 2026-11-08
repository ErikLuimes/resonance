import Testing
@testable import Resonance

struct FeatureFlagTests {
    /// Asking permission comes first: CSDb can't reach a download by accident.
    @Test func csdbIsRestricted() {
        #expect(Feature.csdb.tier == .restricted)
    }

    @Test func theListMatchesTheBuild() {
        #if CSDB
        #expect(Feature.csdb.isCompiledIn)
        #else
        #expect(!Feature.csdb.isCompiledIn)
        #endif
        #if ALPHA
        #expect(Feature.hasExperiments)
        #else
        #expect(!Feature.hasExperiments)
        #endif
    }

    /// A beta or final build has no experiment's code.
    @Test func experimentsNeedAnAlphaBuild() {
        for feature in Feature.allCases where feature.tier == .experimental && !Feature.hasExperiments {
            #expect(!feature.isCompiledIn, "\(feature.title)")
        }
    }

    @Test func everyFlagSaysWhatEndsIt() {
        for feature in Feature.allCases {
            #expect(!feature.title.isEmpty)
            #expect(!feature.shipsWhen.isEmpty, "\(feature.title)")
        }
    }
}
