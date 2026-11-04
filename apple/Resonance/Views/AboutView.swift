import SwiftUI
import PhosphorCore

/// The About window: Resonance's version, the Phosphor engine it runs on,
/// and where it comes from. A fixed-width column, so the window's size
/// follows its text and nothing else.
struct AboutView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("Resonance")
                    .font(.title.weight(.semibold))
                Text("The SID, played and seen")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Resonance \(Self.appVersion) · Phosphor \(phosphorVersion())")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }

            Text("""
                Resonance is a SID music player made only for the Mac. It plays \
                through the engine of Phosphor, Marcin Spoczynski's open-source SID \
                player for macOS, Linux and Windows — SIDLite and reSID emulation, \
                song lengths, STIL and the HVSC library — compiled in unchanged. \
                Use Phosphor too? Import its settings, favourites and history in \
                Settings → Advanced.
                """)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("For USBSID-Pico or Ultimate 64 hardware, use Phosphor.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 20) {
                Link("Phosphor on GitHub", destination: URL(string: "https://github.com/sandlbn/Phosphor")!)
                Link("Phosphor Website", destination: URL(string: "https://sandlbn.github.io/Phosphor/")!)
            }
            .font(.callout)

            VStack(spacing: 2) {
                Text("Resonance © 2026 Erik Luimes · MIT License")
                Text("Phosphor © 2026 Marcin Spoczynski · MIT License")
                // The SID emulators it includes are GPL, so the app is too.
                Text("This app includes reSID, SIDLite and libsidplayfp, and is distributed under the GNU GPL, version 3.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            AccentLink("Acknowledgements") { openWindow(id: AcknowledgementsView.windowID) }
                .font(.caption)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
        .frame(width: 380)
    }

    /// "0.1.0-alpha.1": the version and its release stage (the project's
    /// RELEASE_STAGE, none for a final release).
    private static var appVersion: String { Updater.appVersion() }
}

/// Replaces the standard About menu item, which can't show the Phosphor
/// version or the origin story.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            AboutButton()
        }
    }

    private struct AboutButton: View {
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("About Resonance") { openWindow(id: AboutView.windowID) }
        }
    }
}

extension AboutView {
    static let windowID = "about"
}

/// The licences of the open-source code built into the app, from
/// Acknowledgements.txt (scripts/acknowledgements.sh writes it). One Text
/// per licence, lazily: the whole file is too long for one.
struct AcknowledgementsView: View {
    static let windowID = "acknowledgements"

    private let sections: [String] = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return ["The acknowledgements are missing from this build."] }
        return text.components(separatedBy: "\n" + String(repeating: "-", count: 72) + "\n")
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(sections.indices, id: \.self) { index in
                    if index > 0 { Divider() }
                    Text(sections[index].trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }
}

#Preview {
    AboutView()
}
