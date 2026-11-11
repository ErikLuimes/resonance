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

/// Debug: one visualizer alone in a bare 1440 × 900 window, as large as in
/// Now Playing and with nothing over it, to record the website's videos of
/// it from (scripts/site-videos.sh). Opens when the app is launched with
/// RESONANCE_VISUALIZER_STAGE set to the visualizer's name (`ink`, `soundMap`…),
/// above the other windows: a video recording only gets what's on screen.
@MainActor
enum VisualizerStage {
    /// The size of the site's other recordings: 16:10.
    static let size = CGSize(width: 1440, height: 900)

    private static var window: NSWindow?

    static func openIfAsked(store: PlayerStore) {
        guard let name = ProcessInfo.processInfo.environment["RESONANCE_VISUALIZER_STAGE"],
              let visual = NowPlayingVisual(rawValue: name) else { return }
        let defaults = UserDefaults.standard
        let theme = VoiceTheme.named(defaults.string(forKey: Pref.theme) ?? VoiceTheme.resonance.id,
                                     custom: defaults.data(forKey: Pref.customTheme) ?? Data())
        let stage = StageView(visual: visual)
            .frame(width: size.width, height: size.height)
            .background(theme.background.color)
            .environment(\.colorScheme, .dark)
            .environment(store)
            .environment(\.voiceTheme, theme)

        let host = NSHostingView(rootView: stage)
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.title = "Visualizer Stage"
        if let screen = NSScreen.main {
            window.setFrameTopLeftPoint(CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY))
        }
        window.level = .floating
        window.orderFrontRegardless()
        self.window = window
    }

    /// The visualizer as Now Playing builds it.
    private struct StageView: View {
        let visual: NowPlayingVisual

        var body: some View {
            switch visual {
            case .halo: HaloView(isActive: true)
            case .particles: ParticlesView(isActive: true)
            case .radial: RadialView(isActive: true)
            case .soundMap: SoundMapView(isActive: true)
            case .notes: NotesView(isActive: true)
            case .spectrum: SpectrumView(isActive: true)
            case .terrain: TerrainView(isActive: true)
            case .ink: InkView(style: .ink, isActive: true)
            case .liquidLight: InkView(style: .liquidLight, isActive: true)
            case .ferrofluid: FerroView(isActive: true)
            case .chip: ChipView(isActive: true)
            case .rasters: RasterView(isActive: true)
            case .silicon: SiliconView(isActive: true)
            case .nimbus: NimbusView(isActive: true)
            }
        }
    }
}
#endif
