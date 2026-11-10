import SwiftUI
import PhosphorCore

/// The About window, in the Mac's classic shape with one difference: where
/// the icon would be stands a 1702 monitor, with the icon as a sticker on
/// its bezel. Then the name and version, a line on what it is, who it's
/// built on, the license, and links to the licenses, the website
/// and the source. At rest its size follows its text and nothing else.
/// The power switch opens the desk fullscreen and returns to compact About
/// when the tube turns off.
struct AboutView: View {
    @Environment(\.openWindow) private var openWindow

    static let website = URL(string: "https://useresonance.app")!
    static let source = URL(string: "https://github.com/ErikLuimes/resonance")!

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PlayerStore.self) private var store

    /// The desk is active and About's text is hidden.
    @State private var grown = false
    @State private var showsAboutText = true
    /// The compact frame AppKit should return to after fullscreen.
    @State private var offFrame: NSRect?
    @State private var compactContentHeight: CGFloat = 0
    @State private var fullscreenWidth: CGFloat = 0
    @State private var presentationBeforeFullscreen: NSApplication.PresentationOptions?
    @State private var transition = 0
    @State private var fullscreen = Fullscreen.windowed
    @State private var hostWindow: ObjectIdentifier?
    @State private var powerPingAt: TimeInterval?

    private enum Fullscreen { case windowed, entering, active, exiting }

    private var model: MonitorModel { MonitorModel.shared }
    private var showsPowerHint: Bool { fullscreen == .windowed && model.power == .off }
    private static let textFadeDuration = 0.2
    private var textFade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: Self.textFadeDuration)
    }

    static let width: CGFloat = 360
    private static let usesDesk = DeskScene.available
    // Crop the empty space above and below the resting desk without scaling it.
    private static let compactDeskTrim: CGFloat = usesDesk ? 30 : 0
    private static let monitorOffSize = CGSize(width: 320, height: 320 * MonitorCase.aspect - 2 * compactDeskTrim)

    var body: some View {
        VStack(spacing: 0) {
            // Reserve the monitor's resting space without letting its animated
            // size affect the window's minimum size.
            Color.clear
                .frame(width: Self.monitorOffSize.width, height: Self.monitorOffSize.height)
                .allowsHitTesting(false)
            aboutText
        }
        .opacity(showsAboutText ? 1 : 0)
        .allowsHitTesting(showsAboutText)
        .accessibilityHidden(!showsAboutText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: !grown)
        .frame(width: grown ? nil : Self.width, alignment: .top)
        .frame(maxWidth: grown ? .infinity : nil, maxHeight: grown ? .infinity : nil, alignment: .top)
        // Keep About's text in front of the native SceneKit view for pointer events.
        .background(alignment: .top) {
            GeometryReader { geometry in
                let compactShare = compactDeskShare(at: geometry.size.width)
                let size = deskSize(in: geometry.size, compactShare: compactShare)
                Group {
                    if Self.usesDesk {
                        MonitorDesk(store: store, showsPowerHint: showsPowerHint, powerPingAt: powerPingAt,
                                    reduceMotion: reduceMotion, onPower: pressPower)
                    } else {
                        MonitorCase(store: store, live: true, showsPowerHint: showsPowerHint,
                                    powerPingAt: powerPingAt, onPower: pressPower)
                    }
                }
                .frame(width: size.width, height: size.height + 2 * Self.compactDeskTrim * compactShare)
                .frame(width: size.width, height: size.height)
                .clipped()
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .top)
                .allowsHitTesting(fullscreen == .windowed || fullscreen == .active)
            }
        }
        .ignoresSafeArea(.container, edges: grown ? .all : [])
        .overlay(alignment: .topTrailing) {
            if fullscreen == .active {
                Button(action: exitPlayback) {
                    Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(20)
            }
        }
        .onChange(of: model.power) { _, power in
            if power == .off { exitPlayback() }
        }
        .onChange(of: grown, initial: true) { _, isGrown in model.hostGrown = isGrown }
        // The model found About had been away: About goes back to rest too.
        .onChange(of: model.resets) { _, _ in if grown || !showsAboutText { settle() } }
        // Off whenever About opens, and off when it goes. About's window can
        // outlive its view's appearance and come back without a new one, so
        // the window's own closing counts, and so does its going out of
        // sight, which is what closing looks like when the window is kept.
        .onAppear {
            guard fullscreen == .windowed else { return }
            reset()
            guard let window else { return }
            hostWindow = ObjectIdentifier(window)
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
        .onDisappear { if fullscreen == .windowed { reset() } }
        .task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            if window?.occlusionState.contains(.visible) == true { pingPower() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if isAbout(note.object) { reset() }
        }
        // Out of sight, it starts over: off, nothing running, About at rest.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if fullscreen == .windowed, let window = note.object as? NSWindow,
               isAbout(window),
               !window.occlusionState.contains(.visible) { reset() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if grown, isAbout(note.object) { hideSystemChrome() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if isAbout(note.object) { restoreSystemChrome() }
        }
    }

    private func compactDeskShare(at width: CGFloat) -> CGFloat {
        guard grown else { return 1 }
        return 1 - min(1, max(0, (width - Self.width) / max(1, fullscreenWidth - Self.width)))
    }

    private func deskSize(in size: CGSize, compactShare: CGFloat) -> CGSize {
        guard grown else { return Self.monitorOffSize }
        // Keep the desk's margins continuous as the same window changes size.
        return CGSize(
            width: max(1, size.width - compactShare * (Self.width - Self.monitorOffSize.width)),
            height: max(1, size.height - compactShare * (compactContentHeight - Self.monitorOffSize.height))
        )
    }

    private func hideSystemChrome() {
        guard presentationBeforeFullscreen == nil else { return }
        let previous = NSApp.presentationOptions
        presentationBeforeFullscreen = previous
        NSApp.presentationOptions = previous.subtracting([.hideDock, .hideMenuBar]).union([.autoHideDock, .autoHideMenuBar])
    }

    private func restoreSystemChrome() {
        guard let previous = presentationBeforeFullscreen else { return }
        NSApp.presentationOptions = previous
        presentationBeforeFullscreen = nil
    }

    private func beginFullscreenTransition(_ next: Fullscreen) {
        guard fullscreen != next else { return }
        transition += 1
        fullscreen = next
        model.setHostFullscreen(true)
        model.busyUntil = CACurrentMediaTime() + 2
    }

    private func isAbout(_ object: Any?) -> Bool {
        guard let window = object as? NSWindow else { return false }
        if let hostWindow { return ObjectIdentifier(window) == hostWindow }
        return window.identifier?.rawValue.hasPrefix(Self.windowID) == true
    }

    private func pressPower() {
        let previous = model.power
        model.pressPower(store: store)
        guard model.power != previous else { return }
        powerPingAt = nil
        MonitorSounds.shared.update(power: model.power)
        if model.power == .on {
            enterPlayback()
        } else {
            exitPlayback()
        }
    }

    private func pingPower() {
        guard showsPowerHint, !reduceMotion else { return }
        powerPingAt = CACurrentMediaTime()
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
        transition += 1
        if let window {
            if grown, let rest = offFrame, window.frame != rest {
                window.setFrame(rest, display: false)
            }
            window.standardWindowButton(.closeButton)?.isHidden = false
        }
        restoreSystemChrome()
        fullscreen = .windowed
        AboutSession.shared.exitFullscreen = nil
        grown = false
        withAnimation(textFade) { showsAboutText = true }
        model.hostGrown = false
        model.busyUntil = 0
    }

    private var aboutText: some View {
        VStack(spacing: 0) {
            Text("Resonance")
                .font(.title2.weight(.semibold))
                .padding(.top, 10)
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
                .contentShape(Rectangle())
                .onHover { if $0 { pingPower() } }
                .padding(.top, 6)

            Text("Built on Phosphor \(phosphorVersion()) by Marcin Spoczynski.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .tint(.accentColor)
                .padding(.top, 14)

            HStack(spacing: 16) {
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
        .padding(.bottom, 20)
    }

    private var window: NSWindow? {
        NSApp.windows.first { isAbout($0) }
    }

    private func enterPlayback() {
        guard let window, let screen = window.screen ?? NSScreen.main else { reset(); return }
        let target = screen.frame
        offFrame = window.frame
        compactContentHeight = window.contentView?.bounds.height ?? window.frame.height
        fullscreenWidth = target.width
        AboutSession.shared.restFrame = window.frame
        beginFullscreenTransition(.entering)
        let mine = transition
        model.hostGrown = true
        model.holdsCameraForWindowResize = true
        withAnimation(textFade) { showsAboutText = false }
        AboutSession.shared.exitFullscreen = { if fullscreen == .active { exitPlayback() } }
        Task { @MainActor in
            if !reduceMotion { try? await Task.sleep(for: .seconds(Self.textFadeDuration)) }
            guard mine == transition else { return }
            guard window.isVisible else { reset(); return }
            grown = true
            if window.isKeyWindow { hideSystemChrome() }
            window.standardWindowButton(.closeButton)?.isHidden = true
            await resize(window, to: target)
            guard mine == transition else { return }
            finishFullscreenEntry()
        }
    }

    private func finishFullscreenEntry() {
        fullscreen = .active
        grown = true
        model.holdsCameraForWindowResize = false
        model.busyUntil = 0
        if model.power == .off { exitPlayback() }
    }

    private func exitPlayback() {
        guard fullscreen == .active, let window, let offFrame else { return }
        beginFullscreenTransition(.exiting)
        let mine = transition
        let now = CACurrentMediaTime()
        if model.power == .on {
            model.powerOff()
            MonitorSounds.shared.update(power: model.power)
        }
        // The CRT collapse and camera pullback play inside a steady window.
        let cameraReadyAt = DeskScene.returnCamera(in: window, at: now) ?? now
        let exitAt = max(now + MonitorModel.pictureCollapseDuration, cameraReadyAt)
        Task { @MainActor in
            let delay = exitAt - CACurrentMediaTime()
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard mine == transition else { return }
            guard window.isVisible else { reset(); return }
            model.holdsCameraForWindowResize = true
            model.powerOff(animated: false)
            await resize(window, to: offFrame)
            guard mine == transition else { return }
            reset()
        }
    }

    private func resize(_ window: NSWindow, to frame: NSRect) async {
        guard !reduceMotion else {
            window.setFrame(frame, display: true)
            return
        }
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = window.animationResizeTime(frame)
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            } completionHandler: {
                continuation.resume()
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
    @ObservationIgnored var exitFullscreen: (() -> Void)?

    /// A new instance, then the window.
    func open(with openWindow: OpenWindowAction) {
        if exitFullscreen != nil, let fullscreen = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(AboutView.windowID) == true
        }) {
            fullscreen.makeKeyAndOrderFront(nil)
            return
        }
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
