import SwiftUI
import PhosphorCore

/// The About window: Resonance's version, the Phosphor engine it runs on,
/// and where it comes from. A fixed-width column, so the window's size
/// follows its text and nothing else.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("Resonance")
                    .font(.title.weight(.semibold))
                Text("powered by Phosphor")
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
                Resonance is a native Mac interface for Phosphor, Marcin Spoczynski's \
                open-source SID music player. Phosphor itself is a Rust app for macOS, \
                Linux and Windows; Resonance plays through its engine unchanged — \
                SIDLite and reSID emulation, song lengths, STIL and the HVSC library — \
                and gives it a SwiftUI front end made only for the Mac.
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
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
        .frame(width: 380)
    }

    /// "0.1 (1)": the marketing version and the build number.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
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

#Preview {
    AboutView()
}
