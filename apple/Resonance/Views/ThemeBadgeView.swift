import SwiftUI

/// The theme's badge: a small strip drawn in its colors, e.g. the C64's
/// rainbow bars or Noir's scanner light. Draws nothing when badges are turned
/// off in Settings. Scales to whatever size it's given; designed at about
/// 10:1. The drawing is `BadgeDrawing`'s, in `BadgeLayerView`.
struct ThemeBadgeView: View {
    @Environment(\.voiceTheme) private var theme
    @AppStorage(Pref.themeBadge) private var showsBadge = true

    /// Whether the badge moves; false where nobody can see it.
    var isAnimating = true

    var body: some View {
        if showsBadge {
            BadgeLayerView(theme: theme, isAnimating: isAnimating)
                .accessibilityHidden(true)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        ForEach(VoiceTheme.presets + [VoiceTheme.defaultCustom]) { theme in
            ThemeBadgeView()
                .frame(width: 300, height: 20)
                .padding(8)
                .background(theme.background.color)
                .environment(\.voiceTheme, theme)
        }
    }
    .padding()
}
