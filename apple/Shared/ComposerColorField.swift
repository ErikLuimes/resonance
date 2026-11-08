import SwiftUI

/// A composer's colors, from their name alone. It fills the frame it's given.
/// Shared with the Quick Look extension, so a composer looks the same there.
struct ComposerColorField: View {
    let name: String

    var body: some View {
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        let hue = Double(seed) / 360
        let first = Color(hue: hue, saturation: 0.75, brightness: 0.9)
        let second = Color(hue: (hue + 0.42).truncatingRemainder(dividingBy: 1), saturation: 0.72, brightness: 1)
        ZStack {
            Color(red: 0.11, green: 0.16, blue: 0.25)
            GeometryReader { proxy in
                let reach = max(proxy.size.width, proxy.size.height)
                ZStack {
                    RadialGradient(colors: [first, .clear], center: UnitPoint(x: 0.3, y: 0.25),
                                   startRadius: 0, endRadius: reach * 0.55)
                    RadialGradient(colors: [second, .clear], center: UnitPoint(x: 0.75, y: 0.72),
                                   startRadius: 0, endRadius: reach * 0.6)
                }
            }
        }
    }
}
