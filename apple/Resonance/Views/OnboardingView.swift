import SwiftUI
import PhosphorCore

/// One screen of the welcome. Each remembers on its own that it's been seen,
/// so someone who already has a collection skips the first, and a step added
/// in a later version is all that existing users see of it.
enum OnboardingStep: String, CaseIterable, Identifiable {
    case collection, smartPlaylists, soundsLike
#if CSDB
    case scene
#endif

    var id: Self { self }

    var title: String {
        switch self {
        case .collection: String(localized: "Welcome to Resonance")
        case .smartPlaylists: String(localized: "Say What You'd Like to Hear")
        case .soundsLike: String(localized: "Find What Sounds Alike")
#if CSDB
        case .scene: String(localized: "Follow the Scene")
#endif
        }
    }

    var subtitle: String {
        switch self {
        case .collection: String(localized: "A player for Commodore 64 music.")
        case .smartPlaylists: String(localized: "Your words, your Mac. Nothing leaves it.")
        case .soundsLike: String(localized: "Nothing to set up. It works with the collection.")
#if CSDB
        case .scene: String(localized: "Optional. Everything so far works without it.")
#endif
        }
    }

    var feature: String {
        switch self {
        case .collection: String(localized: "Get the Collection")
        case .smartPlaylists: String(localized: "Smart Playlists")
        case .soundsLike: String(localized: "Sounds Like")
#if CSDB
        case .scene: String(localized: "News from CSDb")
#endif
        }
    }

    var text: String {
        switch self {
        case .collection:
            String(localized: "The High Voltage SID Collection holds more than 60,000 tunes, organized by composer and documented by volunteers since 1996.")
        case .smartPlaylists:
            String(localized: "Describe a mood, a composer, a year or a length in your own words, and Resonance makes the playlist from the collection.")
        case .soundsLike:
            String(localized: "Start from a tune you love and Resonance finds others that sound like it, by any composer. It compares how they sound and how they drive the SID chip.")
#if CSDB
        case .scene:
            String(localized: "The C64 scene still releases music. CSDb is its database. Turn this on for Scene Pulse, with new releases and parties, and for composers' groups and credits.")
#endif
        }
    }

    /// The small print under the text.
    var note: String? {
        switch self {
        case .collection:
            String(localized: "About 81 MB to download and 460 MB on disk. It keeps going in the background.")
#if CSDB
        case .scene:
            String(localized: "Resonance would contact csdb.dk, a site we don't run: to fetch the news, look up composers you open, and download CSDb tunes you play. If you say no, it never does. You can change this in Settings.")
#endif
        default:
            nil
        }
    }

    /// The steps this person hasn't been through yet. The scene counts as
    /// answered once either choice is stored, in Settings too.
    static func pending(hasCollection: Bool, isDownloading: Bool, seen: Set<String>, sceneAnswered: Bool) -> [Self] {
        allCases.filter { step in
            if seen.contains(step.rawValue) { return false }
            switch step {
            case .collection: return !hasCollection && !isDownloading
            case .smartPlaylists, .soundsLike: return true
#if CSDB
            case .scene: return !sceneAnswered
#endif
            }
        }
    }

    /// Every step that still means something, from the Help menu.
    static func all(hasCollection: Bool, isDownloading: Bool) -> [Self] {
        pending(hasCollection: hasCollection, isDownloading: isDownloading, seen: [], sceneAnswered: false)
    }

    /// What to show as the app starts.
    @MainActor
    static func pendingAtLaunch(store: PlayerStore, defaults: UserDefaults = .standard) -> [Self] {
#if CSDB
        let sceneAnswered = defaults.object(forKey: Pref.csdbEnabled) != nil
#else
        let sceneAnswered = true
#endif
        return pending(
            hasCollection: store.hasCollection,
            isDownloading: store.hvscSync?.running == true,
            seen: Set(defaults.stringArray(forKey: Pref.onboardingSeen) ?? []),
            sceneAnswered: sceneAnswered
        )
    }

    func markSeen(in defaults: UserDefaults = .standard) {
        var seen = Set(defaults.stringArray(forKey: Pref.onboardingSeen) ?? [])
        seen.insert(rawValue)
        defaults.set(seen.sorted(), forKey: Pref.onboardingSeen)
    }
}

/// The welcome as a sheet on the main window: AppKit blocks the toolbar,
/// search and sidebar button while it shows, and nothing in the toolbar has
/// to change. Empty for the moment it takes to slide away.
struct OnboardingSheet: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Group {
            if !store.welcomeSteps.isEmpty {
                OnboardingView(steps: store.welcomeSteps)
            }
        }
        .frame(width: 720, height: 648)
    }
}

/// The welcome, one screen at a time.
struct OnboardingView: View {
    let steps: [OnboardingStep]
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var choosingFolder = false

    private var step: OnboardingStep { steps[min(index, steps.count - 1)] }
    private var isLast: Bool { index >= steps.count - 1 }

    /// Every step's picture is this tall, so nothing jumps between steps.
    static let pictureHeight: CGFloat = 170

    var body: some View {
        page
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                .help("Skip the rest of the welcome. Help → Welcome to Resonance brings it back.")
                .padding(14)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                FileAccess.shared.keep([url])
                store.hvscRoot = url.path
                advance()
            }
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 52)
            content
                .id(step)
                .transition(.opacity)
                // The same height on every step, so the title never jumps.
                .frame(height: 432, alignment: .top)
            Spacer(minLength: 12)
            actions
                .id("\(step.rawValue) actions")
                .transition(.opacity)
                // The same height on every step, so nothing above it jumps.
                .frame(height: 88, alignment: .bottom)
            OnboardingDownloadLine()
                .padding(.top, 10)
            Text(steps.count > 1 ? "\(index + 1) of \(steps.count)" : " ")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 32)
    }

    private var content: some View {
        VStack(spacing: 0) {
            Text(step.title)
                .font(.system(size: 44, weight: .light))
                .multilineTextAlignment(.center)
            Text(step.subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            picture
                .frame(height: Self.pictureHeight)
                .padding(.top, 24)
                .padding(.bottom, 22)
            Text(step.feature)
                .font(.title3.weight(.semibold))
            Text(step.text)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 540)
                .padding(.top, 6)
            if let note = step.note {
                // Readable: on the scene step this is what's being agreed to.
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 540)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var picture: some View {
        switch step {
        case .collection: OnboardingSections()
        case .smartPlaylists: OnboardingDescribe()
        case .soundsLike: OnboardingMatches()
#if CSDB
        case .scene: Tile(size: 130, symbol: "antenna.radiowaves.left.and.right")
#endif
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch step {
        case .collection:
            VStack(spacing: 8) {
                primaryButton(String(localized: "Download the Collection")) {
                    store.startHvscSync()
                    advance()
                }
                AccentLink(String(localized: "Choose a Folder You Already Have")) { choosingFolder = true }
                AccentLink(String(localized: "Not Now")) { advance() }
            }
        case .smartPlaylists, .soundsLike:
            primaryButton(isLast ? String(localized: "Start Listening") : String(localized: "Continue")) { advance() }
#if CSDB
        case .scene:
            // A real choice, so neither answer is the highlighted one.
            HStack(spacing: 10) {
                Button("Not Now") { answerScene(false) }
                Button("Show the Scene") { answerScene(true) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
#endif
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }

    /// Closing it means no thanks: the steps left aren't offered again, and
    /// the scene stays off.
    private func close() {
        steps[min(index, steps.count - 1)...].forEach { $0.markSeen() }
        store.welcomeSteps = []
    }

#if CSDB
    private func answerScene(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Pref.csdbEnabled)
        // Said yes: show them what they asked for.
        if enabled { library.shownSection = .scene }
        advance()
    }
#endif

    private func advance() {
        step.markSeen()
        if isLast {
            store.welcomeSteps = []
        } else {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { index += 1 }
        }
    }
}

/// How the download is going, or why it stopped. Its own view, so its updates
/// never redraw the buttons mid-click. Holds its height when there's nothing
/// to say.
private struct OnboardingDownloadLine: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Text(text ?? " ")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var text: String? {
        if let error = store.hvscSyncError ?? store.hvscSync?.error {
            return String(localized: "The download stopped: \(error)")
        }
        guard let sync = store.hvscSync, sync.running else { return nil }
        let progress = sync.progressText
        if sync.filesTotal > 0 { return String(localized: "Extracting the collection: \(progress)") }
        return progress.isEmpty ? String(localized: "Downloading the collection") : String(localized: "Downloading the collection: \(progress)")
    }
}

/// The collection's three sections, with roughly how many tunes each holds.
/// Rounded down, since the real counts aren't known before the download
/// (HVSC 85 has 56,568, 3,058 and 1,531).
private struct OnboardingSections: View {
    private let sections: [(category: HvscCategory, count: String, color: Color)] = [
        (.musicians, "56,000+", Palette.teal),
        (.demos, "3,000+", Palette.orange),
        (.games, "1,500+", Palette.purple),
    ]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(sections, id: \.count) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: section.category.symbolName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(section.color)
                        .frame(width: 38, height: 38)
                        .background(section.color.opacity(0.18), in: .rect(cornerRadius: 11))
                    Spacer(minLength: 0)
                    Text(section.count)
                        .font(.system(size: 26, weight: .bold))
                        .monospacedDigit()
                    Text(section.category.displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .modifier(CardBackground())
            }
        }
        .frame(width: 500, height: OnboardingView.pictureHeight)
    }
}

/// A real answer from Sounds Like: what it gave for this tune with the
/// method and fingerprints of November 2026, its top three in order.
private struct OnboardingMatches: View {
    private let matches: [(title: String, byline: String)] = [
        ("Miami Vice", "Martin Galway, 1986"),
        ("Comic Bakery", "Johan Öberg (Tango), 1990-95"),
        ("Name That Tune #1", "Stein Pedersen, 2010"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sounds like Comic Bakery by Martin Galway")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                if index > 0 { Divider() }
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Text(match.title)
                        .fontWeight(.semibold)
                    Spacer(minLength: 12)
                    Text(match.byline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(width: 500, height: OnboardingView.pictureHeight, alignment: .topLeading)
        .modifier(CardBackground())
    }
}

/// A real answer from Smart Playlists: the first two tunes and the last of a
/// list "slow to intense" made in November 2026, from 0.07 to 0.95 in intensity.
/// The field looks as it does while typing in it.
private struct OnboardingDescribe: View {
    @Environment(\.voiceTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tunes: [(place: Int, title: String, byline: String)] = [
        (1, "The Cry of Mankind", "Maciej Stankiewicz, 2003"),
        (2, "Allt under himmelens fäste (v2)", "Linus Åkesson, 2011"),
        (19, "Inhuman Race", "Péter Nagy-Miklós, 1999"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.voice(0))
                    .accessibilityHidden(true)
                Text("slow to intense")
                    .font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(height: 40)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: .capsule)
            .background {
                SmartWalkingBorder(colors: (0..<3).map { NSColor(theme.voice($0)) }, isMoving: !reduceMotion)
                    .padding(-SmartWalkingBorder.reach)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            Text("Starts calm, ends intense.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.leading, 20)
                .padding(.bottom, 4)
            ForEach(tunes, id: \.place) { tune in
                Divider()
                HStack(spacing: 12) {
                    Text("\(tune.place)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 16, alignment: .trailing)
                    Text(tune.title)
                        .fontWeight(.semibold)
                    Spacer(minLength: 12)
                    Text(tune.byline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }
        }
        // Room for the glow, under the subtitle.
        .padding(.top, 8)
        .frame(width: 500, height: OnboardingView.pictureHeight, alignment: .topLeading)
    }
}

#Preview {
    OnboardingView(steps: OnboardingStep.allCases)
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .voiceThemed()
        .frame(width: 720, height: 648)
}
