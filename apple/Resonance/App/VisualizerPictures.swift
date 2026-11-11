#if DEBUG
import AppKit
import SwiftUI

/// Debug: a bare window with every offered visualizer running large, in
/// the theme that's set, to photograph the chooser's pictures from
/// (Assets: VisualizerPictures; `VisualizerChooser` shows them). Opens when
/// the app is launched with RESONANCE_VISUALIZER_PICTURES set, behind
/// every other window: it can be photographed there. How the pictures
/// are made from it is in scripts/visualizer-pictures.sh.
@MainActor
enum VisualizerPictures {
    /// Twice the chooser's largest card, so the pictures stay sharp.
    static let cell = CGSize(width: 340, height: 211)
    static let columns = 3

    private static var window: NSWindow?

    static func openIfAsked(store: PlayerStore) {
        guard ProcessInfo.processInfo.environment["RESONANCE_VISUALIZER_PICTURES"] != nil else { return }
        let visuals = NowPlayingVisual.offered
        let rows = (visuals.count + columns - 1) / columns
        let defaults = UserDefaults.standard
        let theme = VoiceTheme.named(defaults.string(forKey: Pref.theme) ?? VoiceTheme.resonance.id,
                                     custom: defaults.data(forKey: Pref.customTheme) ?? Data())
        let grid = VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(visuals.dropFirst(row * columns).prefix(columns)) { visual in
                        VisualizerPreview(visual: visual, size: cell)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows))
        .background(theme.background.color)
        .environment(store)
        .environment(\.voiceTheme, theme)

        let host = NSHostingView(rootView: grid)
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.title = "Visualizer Pictures"
        if let screen = NSScreen.main {
            window.setFrameTopLeftPoint(CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY))
        }
        // Under the other windows, out of the way of whatever else is going on.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.orderFrontRegardless()
        self.window = window
    }
}
#endif
