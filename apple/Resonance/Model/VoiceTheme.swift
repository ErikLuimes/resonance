import AppKit
import SwiftUI

/// A color theme for the visualizers: the three voices' colors and the
/// dark background they're drawn on, plus a badge drawn in them
/// (`ThemeBadgeView`). The app's accent stays the system's.
///
/// Picked in Settings and read from the environment (`\.voiceTheme`), set
/// on each window by `.voiceThemed()`.
nonisolated struct VoiceTheme: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var summary: String
    /// Voices 1–3 of a chip.
    var voices: [RGB]
    var background: RGB
    var badge: ThemeBadge

    func voice(_ i: Int) -> Color { voices[i % 3].color }

    static let resonance = VoiceTheme(
        id: "resonance", name: "Resonance", summary: String(localized: "Cyan, violet and amber"),
        voices: [0x5AC8E8, 0xA27CF6, 0xF2A154], background: 0x0E0E10, badge: .waves)

    static let presets: [VoiceTheme] = [
        resonance,
        VoiceTheme(id: "c64", name: "C64", summary: String(localized: "The rainbow badge on a breadbox"),
                   voices: [0xE2231A, 0xFFCC00, 0x1F6FC5], background: 0x16120E, badge: .rainbow),
        VoiceTheme(id: "noir", name: String(localized: "Noir"), summary: String(localized: "The dark side: saber red"),
                   voices: [0xFF2020, 0x8B0A14, 0x9A9DA6], background: 0x000000, badge: .saber),
        VoiceTheme(id: "ember", name: String(localized: "Ember"), summary: String(localized: "Fire: red, orange and gold"),
                   voices: [0xFF3B2F, 0xFF8C1A, 0xFFD25A], background: 0x140705, badge: .flame),
        VoiceTheme(id: "abyss", name: String(localized: "Abyss"), summary: String(localized: "Deep sea, low light"),
                   voices: [0x2F6FDB, 0x15A39A, 0x8A4DE0], background: 0x02060D, badge: .plasma),
        VoiceTheme(id: "phosphor", name: "Phosphor", summary: String(localized: "A green monochrome screen"),
                   voices: [0x39FF6E, 0x1FA84A, 0xC8FFD6], background: 0x030A05, badge: .screen),
        VoiceTheme(id: "grayscale", name: String(localized: "Grayscale"), summary: String(localized: "White, silver and graphite"),
                   voices: [0xFFFFFF, 0xA8A8A8, 0x5E5E5E], background: 0x0A0A0A, badge: .starfield),
    ]

    static let customID = "custom"

    /// The custom theme's starting colors.
    static let defaultCustom = VoiceTheme(
        id: customID, name: String(localized: "Custom"), summary: String(localized: "Your own colors"),
        voices: [0x7FE0C2, 0xF07A8A, 0xF5E27A], background: 0x101418, badge: .scroller)

    /// The custom theme as stored in `Pref.customTheme`, or its defaults.
    static func custom(from data: Data) -> VoiceTheme {
        guard var theme = try? JSONDecoder().decode(VoiceTheme.self, from: data),
              theme.voices.count == 3 else { return defaultCustom }
        theme.id = customID
        theme.badge = defaultCustom.badge
        return theme
    }

    static func named(_ id: String, custom: Data) -> VoiceTheme {
        if id == customID { return Self.custom(from: custom) }
        return presets.first { $0.id == id } ?? resonance
    }

    var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

/// What a theme's badge draws; see `ThemeBadgeView`.
nonisolated enum ThemeBadge: String, Codable, Hashable {
    /// Three interleaved sine waves.
    case waves
    /// The Commodore rainbow badge's colors as rotating raster bars.
    case rainbow
    /// A lit lightsaber.
    case saber
    /// Flames rising from the first voice's color to the third's.
    case flame
    /// A demoscene plasma.
    case plasma
    /// Scanlines, READY. and a blinking cursor.
    case screen
    /// A camera flying and turning through stars.
    case starfield
    /// A sine scroller.
    case scroller

    /// Unknown badges, e.g. a stored custom theme's from an older build, read as the scroller.
    init(from decoder: Decoder) throws {
        self = ThemeBadge(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .scroller
    }
}

/// An sRGB color, stored as 0xRRGGBB.
nonisolated struct RGB: Codable, Hashable, ExpressibleByIntegerLiteral {
    var hex: UInt32

    init(integerLiteral hex: UInt32) { self.hex = hex }

    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        hex = byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }

    var red: Double { Double(hex >> 16 & 0xFF) / 255 }
    var green: Double { Double(hex >> 8 & 0xFF) / 255 }
    var blue: Double { Double(hex & 0xFF) / 255 }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

extension EnvironmentValues {
    @Entry var voiceTheme = VoiceTheme.resonance
}

extension View {
    /// Sets `\.voiceTheme` to the theme picked in Settings.
    func voiceThemed() -> some View {
        modifier(VoiceThemed())
    }
}

private struct VoiceThemed: ViewModifier {
    @AppStorage(Pref.theme) private var id = VoiceTheme.resonance.id
    @AppStorage(Pref.customTheme) private var custom = Data()

    func body(content: Content) -> some View {
        content.environment(\.voiceTheme, VoiceTheme.named(id, custom: custom))
    }
}
