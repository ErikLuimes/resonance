import AppKit
import SwiftUI

#if DEBUG
/// Window → Size for Recording: the main window at exactly the size the
/// website's videos are recorded at (16:10, like their frames), so every
/// clip matches. Debug builds only.
struct RecordingCommands: Commands {
    static let size = CGSize(width: 1440, height: 900)

    var body: some Commands {
        CommandGroup(after: .windowSize) {
            Button("Size for Recording (1440 × 900)") {
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
                    ?? NSApp.mainWindow,
                    let screen = window.screen ?? NSScreen.main
                else { return }
                // Its top left kept where it is, but on screen.
                let visible = screen.visibleFrame
                let top = min(window.frame.maxY, visible.maxY)
                let left = max(min(window.frame.minX, visible.maxX - Self.size.width), visible.minX)
                window.setFrame(CGRect(x: left, y: top - Self.size.height, width: Self.size.width, height: Self.size.height),
                                display: true, animate: true)
            }
        }
    }
}
#endif
