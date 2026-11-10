import SwiftUI
import PhosphorCore

/// The About window, in the Mac's classic shape with one difference: where
/// the icon would be stands a 1084S monitor, with the icon as a sticker on
/// its bezel. Then the name and version, a line on what it is, who it's
/// built on, the license, and links to the credits intro, licenses, the website
/// and the source. At rest its size follows its text and nothing else.
/// Switched on, the window grows to most of the screen with the monitor
/// filling it and the text gone, and shrinks back when the tube is off.
struct AboutView: View {
    @Environment(\.openWindow) private var openWindow

    static let website = URL(string: "https://useresonance.app")!
    static let source = URL(string: "https://github.com/ErikLuimes/resonance")!

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PlayerStore.self) private var store

    /// The window is resizing or expanded for the monitor.
    @State private var grown = false
    @State private var showsAboutText = true
    /// Scene bounds and window frame share one transition clock.
    @State private var monitorSize = Self.monitorOffSize
    /// The window's frame before it grew, to go back to.
    @State private var offFrame: NSRect?
    /// Invalidates animation completions when About resets or starts a new transition.
    @State private var animation = 0

    private var model: MonitorModel { MonitorModel.shared }
    private static let textFadeDuration = 0.2
    private var textFade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: Self.textFadeDuration)
    }

    static let width: CGFloat = 360
    /// The monitor's size with About at rest, where the icon was.
    private static let monitorOffSize = CGSize(width: 320, height: 320 * MonitorCase.aspect)

    var body: some View {
        let awake = model.power != .off
        VStack(spacing: 0) {
            // Reserve the monitor's resting space without letting its animated
            // size affect the window's minimum size.
            Color.clear
                .frame(width: Self.monitorOffSize.width, height: Self.monitorOffSize.height)
            aboutText
        }
        .opacity(showsAboutText ? 1 : 0)
        .allowsHitTesting(showsAboutText)
        .accessibilityHidden(!showsAboutText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: !grown)
        .frame(width: grown ? nil : Self.width, alignment: .top)
        .frame(maxWidth: grown ? .infinity : nil, maxHeight: grown ? .infinity : nil, alignment: .top)
        .overlay(alignment: .top) {
            Group {
                if DeskScene.available {
                    MonitorDesk(store: store, onPower: pressPower)
                } else {
                    MonitorCase(store: store, live: true, onPower: pressPower)
                }
            }
            .frame(width: monitorSize.width, height: monitorSize.height)
        }
        .ignoresSafeArea(.container, edges: grown ? .all : [])
        .onChange(of: awake) { _, on in
            if on {
                grow()
            } else {
                MonitorSounds.shared.stop()
                shrinkBack()
            }
        }
        .onChange(of: grown, initial: true) { _, isGrown in model.hostGrown = isGrown }
        // The model found About had been away: About goes back to rest too.
        .onChange(of: model.resets) { _, _ in if grown || !showsAboutText { settle() } }
        // Off whenever About opens, and off when it goes. About's window can
        // outlive its view's appearance and come back without a new one, so
        // the window's own closing counts, and so does its going out of
        // sight, which is what closing looks like when the window is kept.
        .onAppear {
            reset()
            guard let window else { return }
            // Restore the resting frame and apply the compact width on first open.
            var content = window.contentRect(forFrameRect: AboutSession.shared.restFrame ?? window.frame)
            content.origin.x += (content.width - Self.width) / 2
            content.size.width = Self.width
            let rest = window.frameRect(forContentRect: content)
            if window.frame != rest {
                window.setFrame(rest, display: false)
            }
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
        .onDisappear { reset() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if isAbout(note.object) { reset() }
        }
        // Out of sight, it starts over: off, nothing running, About at rest.
        // (Only out of sight: a window's occlusion is re-reported as it
        // resizes, and the grow must not switch the monitor off.)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if let window = note.object as? NSWindow, isAbout(window), !window.occlusionState.contains(.visible) { reset() }
        }
    }

    private func isAbout(_ object: Any?) -> Bool {
        (object as? NSWindow)?.identifier?.rawValue.hasPrefix(Self.windowID) == true
    }

    private func pressPower() {
        let previous = model.power
        model.pressPower(store: store)
        if model.power != previous {
            MonitorSounds.shared.update(power: model.power)
        }
    }

    /// The monitor off and About at rest, at once: no animation, the
    /// window straight back to its own frame if it had grown.
    private func reset() {
        model.startOver()
        MonitorSounds.shared.stop()
        settle()
    }

    /// About's window straight back to its own frame, the layout at rest.
    private func settle() {
        animation += 1
        if grown, let window, let rest = offFrame ?? AboutSession.shared.restFrame {
            window.setFrame(rest, display: false)
        }
        grown = false
        showsAboutText = true
        monitorSize = Self.monitorOffSize
        model.hostGrown = false
        model.busyUntil = 0
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

            Text("Try the power button.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Text("Built on Phosphor \(phosphorVersion()) by Marcin Spoczynski.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .tint(.accentColor)
                .padding(.top, 18)

            HStack(spacing: 16) {
                Button("Credits intro…") { openWindow(id: CreditsView.windowID) }
                Button("Licenses") { openWindow(id: AcknowledgmentsView.windowID) }
                Link("Website ↗", destination: Self.website)
                Link("Source ↗", destination: Self.source)
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.top, 14)

            Text("© 2026 Erik Luimes. MIT; distributed under GNU GPL v3.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(Self.windowID) == true }
    }

    /// The window grows to three quarters of the screen's height, a little
    /// wider than tall, centered on the screen, over 0.7 s; the layout above
    /// follows its size as it goes, so the monitor grows with it.
    private func grow() {
        guard let window else { return }
        animation += 1
        let mine = animation
        model.hostGrown = true
        let fadeDuration = reduceMotion ? 0 : Self.textFadeDuration
        model.busyUntil = CACurrentMediaTime() + fadeDuration + 0.2

        // Keep the compact layout in place until the text has fully faded.
        withAnimation(textFade, completionCriteria: .removed) {
            showsAboutText = false
        } completion: {
            guard mine == animation else { return }
            grown = true
            offFrame = window.frame
            AboutSession.shared.restFrame = window.frame
            let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
            let height = (screen.height * 0.75).rounded()
            let width = min((height * 1.1).rounded(), (screen.width * 0.9).rounded())
            let frame = window.frameRect(forContentRect: NSRect(
                x: (screen.midX - width / 2).rounded(), y: (screen.midY - height / 2).rounded(), width: width, height: height))
            animate(window, to: frame, expanded: true, duration: 0.7)
        }
    }

    /// Back to About's own frame, then its own layout.
    private func shrinkBack() {
        guard grown else {
            if !showsAboutText { settle() }
            return
        }
        guard let window, let offFrame else { settle(); return }
        guard window.isVisible else { reset(); return }
        animate(window, to: offFrame, expanded: false, duration: 0.6) {
            grown = false
            withAnimation(textFade) { showsAboutText = true }
        }
    }

    /// Moves the window, with the power button locked until it's there.
    private func animate(
        _ window: NSWindow,
        to frame: NSRect,
        expanded: Bool,
        duration: Double,
        then done: (@MainActor @Sendable () -> Void)? = nil
    ) {
        animation += 1
        let mine = animation
        let seconds = reduceMotion ? 0 : duration
        model.busyUntil = CACurrentMediaTime() + seconds + 0.2
        let startFrame = window.frame
        let startSize = monitorSize
        let endSize = expanded ? window.contentRect(forFrameRect: frame).size : Self.monitorOffSize
        // Resize the native window and its embedded view from the same progress.
        // SceneKit keeps its own camera glide; only its host bounds change here.
        Task { @MainActor in
            let start = CACurrentMediaTime()
            while mine == animation {
                let progress = seconds > 0 ? min(1, (CACurrentMediaTime() - start) / seconds) : 1
                let t = CGFloat(progress * progress * (3 - 2 * progress))
                let next = NSRect(
                    x: startFrame.minX + (frame.minX - startFrame.minX) * t,
                    y: startFrame.minY + (frame.minY - startFrame.minY) * t,
                    width: startFrame.width + (frame.width - startFrame.width) * t,
                    height: startFrame.height + (frame.height - startFrame.height) * t)
                monitorSize = CGSize(
                    width: startSize.width + (endSize.width - startSize.width) * t,
                    height: startSize.height + (endSize.height - startSize.height) * t)
                window.setFrame(next, display: true)
                if progress >= 1 {
                    model.busyUntil = 0
                    done?()
                    return
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
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
            Button("About Resonance") { AboutSession.shared.open(with: openWindow) }
        }
    }
}

extension AboutView {
    static let windowID = "about"
}

/// Each opening of About is a new instance: `generation` keys About's view
/// tree, so SwiftUI builds it afresh (a new renderer, fresh state) when the
/// menu opens the window, whether or not macOS kept the old window around.
/// `restFrame` is the window's frame at rest, to put back before it shows.
@MainActor @Observable
final class AboutSession {
    static let shared = AboutSession()
    var generation = 0
    var restFrame: NSRect?

    /// A new instance, then the window.
    func open(with openWindow: OpenWindowAction) {
        MonitorModel.shared.startOver()
        generation += 1
        openWindow(id: AboutView.windowID)
    }
}

/// About's window content: a new AboutView per opening.
struct AboutHost: View {
    var body: some View {
        AboutView()
            .id(AboutSession.shared.generation)
    }
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
