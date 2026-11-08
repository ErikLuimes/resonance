/// Every feature that isn't in all builds, and how far it may go. The rules and
/// how to add one: design/feature-flags/README.md.
///
/// Code stays out of a build through `#if` on the feature's compilation flag,
/// because a hidden setting would still ship the code. This list says what
/// exists. scripts/feature-markers.tsv names what each feature must not leave
/// behind, and scripts/feature-flags.sh keeps the two in step and checks releases.
nonisolated enum FeatureTier: String {
    /// Needs someone's permission: only on a Mac whose own
    /// Config/Signing.local.xcconfig sets the flag. Never in a download.
    case restricted
    /// Unfinished: in Debug and alpha builds, and out of beta and final ones.
    case experimental
}

nonisolated enum Feature: String, CaseIterable, Identifiable {
    case csdb

    var id: Self { self }

    var title: String {
        switch self {
        case .csdb: "CSDb and composer photos"
        }
    }

    var tier: FeatureTier {
        switch self {
        case .csdb: .restricted
        }
    }

    /// What would let this flag go. A flag without an end tends to stay.
    var shipsWhen: String {
        switch self {
        case .csdb: "CSDb's admins agree to how the app uses their site."
        }
    }

    /// Whether this build has the feature's code.
    var isCompiledIn: Bool {
        switch self {
        case .csdb:
            #if CSDB
            true
            #else
            false
            #endif
        }
    }

    /// Whether this build may have experimental features: Debug and alpha.
    static var hasExperiments: Bool {
        #if ALPHA
        true
        #else
        false
        #endif
    }
}
