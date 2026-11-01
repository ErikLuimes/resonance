import AppKit
import Testing
@testable import Resonance

@MainActor
struct ZZSlideProbe {
    @Test func probe() async throws {
        try await Task.sleep(for: .seconds(2))
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "Resonance" }),
              let root = w.contentView?.superview else { print("ZZ no window"); return }
        func toggle() {
            for item in NSApp.mainMenu?.items ?? [] {
                if let menu = item.submenu, let i = menu.items.firstIndex(where: { $0.title.hasSuffix("Now Playing") }) {
                    menu.performActionForItem(at: i); return
                }
            }
        }
        func snap(_ name: String) throws {
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/claude-501/-Users-erik-Repositories-Personal-resonance/92cea16b-d034-4f4a-b7c4-3c042316c96c/scratchpad/slide-\(name).png"))
        }
        let start = Date()
        toggle()
        for ms in [900, 3000] {
            let wait = Double(ms) / 1000 - Date().timeIntervalSince(start)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            try snap(String(format: "%04d", ms))
            // Topmost row whose middle pixel isn't the library's grey.
            if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                let x = rep.pixelsWide / 2
                var firstDark = -1
                for y in 0..<rep.pixelsHigh {
                    if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.05 || c.brightnessComponent > 0.95 { firstDark = y; break }
                }
                print("ZZ \(ms)ms overlay top ≈ \(firstDark) px of \(rep.pixelsHigh)")
            }
        }
    }
}
