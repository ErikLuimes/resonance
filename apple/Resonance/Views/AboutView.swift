import SwiftUI
import PhosphorCore

/// The About window, in the Mac's classic shape with one difference: where
/// the icon would be stands a 1084S monitor, with the icon as a sticker on
/// its bezel. Then the name and version, a line on what it is, who it's
/// built on, the license, and buttons to the acknowledgments, the website
/// and the source. At rest its size follows its text and nothing else.
/// Switched on, the window grows to most of the screen with the monitor
/// filling it and the text gone, and shrinks back when the tube is off.
struct AboutView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    static let website = URL(string: "https://useresonance.app")!
    static let source = URL(string: "https://github.com/ErikLuimes/resonance")!

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PlayerStore.self) private var store

    /// The window has grown for the monitor: it fills the window, the text is gone.
    @State private var grown = false
    /// The window's content size, live, which the grown layout follows as
    /// the window animates.
    @State private var windowSize = CGSize.zero
    /// The window's frame before it grew, to go back to.
    @State private var offFrame: NSRect?
    /// Counts the window animations, so a finished one only acts if no
    /// newer one has started.
    @State private var animation = 0

    private var model: MonitorModel { MonitorModel.shared }

    static let width: CGFloat = 440
    /// The monitor's width with About at rest, where the icon was.
    static let monitorOffWidth: CGFloat = 320
    /// And grown: nearly the window's width, as tall as fits.
    static let monitorShare: CGFloat = 0.96

    var body: some View {
        let awake = model.power != .off
        let monitorWidth = grown
            ? min(windowSize.width * Self.monitorShare, max(0, windowSize.height - 40) / MonitorCase.aspect)
            : Self.monitorOffWidth
        let monitorHeight = monitorWidth * MonitorCase.aspect
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // The monitor's place in the layout; the monitor itself is
                // drawn over it, so it can grow without moving the text.
                Color.clear
                    .frame(width: Self.monitorOffWidth, height: Self.monitorOffWidth * MonitorCase.aspect)
                aboutText
            }
            .opacity(grown ? 0 : 1)
            .allowsHitTesting(!grown)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: grown)

            MonitorCase(store: store, live: true)
                .frame(width: monitorWidth, height: monitorHeight)
                .offset(y: grown ? max(0, (windowSize.height - monitorHeight) / 2) : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.7), value: grown)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: !grown)
        .frame(width: grown ? nil : Self.width, alignment: .top)
        .frame(maxWidth: grown ? .infinity : nil, maxHeight: grown ? .infinity : nil, alignment: .top)
        .background {
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size, initial: true) { _, size in windowSize = size }
            }
        }
        .onChange(of: awake) { _, on in
            if on { grow() } else { shrinkBack() }
        }
        // Off whenever About opens, and off when it closes. About's window
        // can outlive its view's appearance, so the window's own closing
        // counts too.
        .onAppear { model.powerOff(animated: false); grown = false; model.busy = false; window?.styleMask.remove(.resizable) }
        .onDisappear { model.powerOff(animated: false); grown = false; model.busy = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.identifier?.rawValue.hasPrefix(Self.windowID) == true {
                model.powerOff(animated: false)
                grown = false
                model.busy = false
            }
        }
    }

    private var aboutText: some View {
        VStack(spacing: 0) {
            Text("Resonance")
                .font(.title2.weight(.semibold))
                .padding(.top, 14)
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
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(Self.windowID) == true }
    }

    /// The window grows to three quarters of the screen's height, a little
    /// wider than tall, centered on the screen, over 0.7 s; the layout above
    /// follows its size as it goes, so the monitor grows with it.
    private func grow() {
        grown = true
        guard let window else { return }
        offFrame = window.frame
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let height = (screen.height * 0.75).rounded()
        let width = min((height * 1.1).rounded(), (screen.width * 0.9).rounded())
        let frame = window.frameRect(forContentRect: NSRect(
            x: (screen.midX - width / 2).rounded(), y: (screen.midY - height / 2).rounded(), width: width, height: height))
        animate(window, to: frame, duration: 0.7)
    }

    /// Back to About's own frame, then its own layout.
    private func shrinkBack() {
        guard grown else { return }
        guard let window, let offFrame else { grown = false; return }
        animate(window, to: offFrame, duration: 0.5) { grown = false }
    }

    /// Moves the window, with the power button locked until it's there.
    private func animate(_ window: NSWindow, to frame: NSRect, duration: Double, then done: (() -> Void)? = nil) {
        animation += 1
        let mine = animation
        model.busy = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: {
            guard mine == animation else { return }
            model.busy = false
            done?()
        })
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
        .environment(PlayerStore.preview)
}
