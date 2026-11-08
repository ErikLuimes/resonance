import SwiftUI
import PhosphorCore

/// The About window, in the Mac's classic shape: the icon, the name and
/// version, a line on what it is, who it's built on, the license, and
/// buttons to the acknowledgments, the website and the source. A fixed
/// width, so the window's size follows its text and nothing else.
struct AboutView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    static let website = URL(string: "https://useresonance.app")!
    static let source = URL(string: "https://github.com/ErikLuimes/resonance")!

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .padding(.bottom, 10)

            Text("Resonance")
                .font(.title2.weight(.semibold))
            Text("Version \(Self.version)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            Text("The SID, played and seen.")
                .font(.callout)
                .padding(.top, 14)

            VStack(spacing: 3) {
                // The link as literal markdown: an interpolated link
                // isn't parsed.
                (Text("Built on ") + Text("[Phosphor](https://github.com/sandlbn/Phosphor)")
                    + Text(" \(phosphorVersion()) by Marcin Spoczynski."))
                    .tint(.accentColor)
                Text("SID emulation by reSIDfp, SIDLite and reSID.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 14)

            Text("© 2026 Erik Luimes. MIT license; distributed under the GNU GPL, version 3.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 14)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Credits") { openWindow(id: CreditsView.windowID) }
                    Button("Acknowledgments") { openWindow(id: AcknowledgmentsView.windowID) }
                }
                HStack(spacing: 8) {
                    Button("Website") { openURL(Self.website) }
                    Button("Source Code") { openURL(Self.source) }
                }
            }
            .controlSize(.small)
            .padding(.top, 18)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(width: 340)
    }

    /// "0.1.0-alpha.4 (4)": the version with its release stage, and the
    /// build number, for bug reports.
    private static var version: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(Updater.appVersion()) (\(build))"
    }
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

/// The licenses of the open-source code built into the app, from
/// Acknowledgments.txt (scripts/acknowledgments.sh writes it). One Text
/// per license, lazily: the whole file is too long for one.
struct AcknowledgmentsView: View {
    static let windowID = "acknowledgments"

    private let sections: [String] = {
        guard let url = Bundle.main.url(forResource: "Acknowledgments", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [String(localized: "The acknowledgments are missing from this build.")] }
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
