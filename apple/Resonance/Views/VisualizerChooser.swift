import SwiftUI

/// Chooses Now Playing's visualizers from pictures of them: a card each,
/// with the chosen ones outlined. A chosen card runs live, small, with
/// the tune that's playing, and so does the one under the pointer; the
/// rest run for a moment when the chooser opens, to have a picture, and
/// then hold it, so a dozen visualizers aren't all working at once. Up to `NowPlayingVisual.lineupSize` can be chosen and at
/// least one stays. Settings › Appearance shows it, and so does Now
/// Playing, from its Visualizers… button.
struct VisualizerChooser: View {
    /// Cards across, and how wide each one's picture is.
    var columns = 3
    var cardWidth: CGFloat = 156

    @AppStorage(Pref.nowPlayingLineup) private var stored = NowPlayingVisual.stored(NowPlayingVisual.defaultLineup)

    private var lineup: [NowPlayingVisual] {
        NowPlayingVisual.lineup(from: stored)
    }

    var body: some View {
        let lineup = lineup
        let isFull = lineup.count >= NowPlayingVisual.lineupSize
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth + 6), spacing: 12), count: columns),
                      alignment: .leading, spacing: 14) {
                ForEach(NowPlayingVisual.offered) { visual in
                    let isChosen = lineup.contains(visual)
                    VisualizerCard(visual: visual, width: cardWidth, isChosen: isChosen,
                                   // The last one stays, and a fourth has to wait for room.
                                   isEnabled: isChosen ? lineup.count > 1 : !isFull) {
                        set(visual, !isChosen)
                    }
                }
            }
            Group {
                if isFull {
                    Text("Three are chosen. Click one of them to make room for another.")
                } else {
                    Text("Choose up to three. Now Playing offers them at its top.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func set(_ visual: NowPlayingVisual, _ isOn: Bool) {
        var chosen = lineup.filter { $0 != visual }
        if isOn { chosen.append(visual) }
        guard !chosen.isEmpty else { return }
        // Stored in the order they're listed, as they show.
        stored = NowPlayingVisual.stored(NowPlayingVisual.offered.filter(chosen.contains))
    }
}

/// One visualizer: its live picture, name and what it shows. Chosen ones
/// have the accent outline, like Settings' Appearance pictures.
private struct VisualizerCard: View {
    let visual: NowPlayingVisual
    let width: CGFloat
    let isChosen: Bool
    let isEnabled: Bool
    let toggle: () -> Void

    @State private var isHovering = false
    /// True for its first moments, while it draws itself a picture.
    @State private var isWarmingUp = true

    /// Long enough for the slowest to have something to show: Notes
    /// waits for the tune's notes, the fluids for some dye.
    private static let warmUp = Duration.seconds(3)

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 5) {
                VisualizerPreview(visual: visual, size: CGSize(width: width, height: (width * 0.62).rounded()),
                                  isActive: isChosen || isHovering || isWarmingUp)
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isChosen ? Color.accentColor : .clear, lineWidth: 2.5)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(visual.title)
                        .font(.callout)
                        .fontWeight(isChosen ? .semibold : .regular)
                        .foregroundStyle(isChosen ? .primary : .secondary)
                    Text(visual.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 3)
            }
            .frame(width: width + 6, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .task {
            try? await Task.sleep(for: Self.warmUp)
            isWarmingUp = false
        }
        .disabled(!isEnabled)
        // Those that can't be chosen until there's room step back.
        .opacity(isEnabled || isChosen ? 1 : 0.45)
        .accessibilityLabel(visual.title)
        .accessibilityHint(visual.summary)
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }
}

/// A visualizer running small, on the theme's background. The ones drawn
/// by SwiftUI are laid out for a large view, so they're drawn at that size
/// and scaled down; the Metal ones fit themselves to any size.
struct VisualizerPreview: View {
    let visual: NowPlayingVisual
    let size: CGSize
    /// False holds its last picture.
    var isActive = true

    @Environment(\.voiceTheme) private var theme

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .background(theme.background.color)
            .clipShape(.rect(cornerRadius: 7))
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch visual {
        case .halo: scaled(HaloView(isActive: isActive), from: 640)
        case .radial: scaled(RadialView(isActive: isActive), from: 640)
        case .spectrum: scaled(SpectrumView(isActive: isActive), from: 1100)
        case .particles: ParticlesView(isActive: isActive)
        case .soundMap: SoundMapView(isActive: isActive, isMiniature: true)
        case .notes: NotesView(isActive: isActive)
        case .terrain: TerrainView(isActive: isActive)
        case .ink: InkView(style: .ink, isActive: isActive)
        case .liquidLight: InkView(style: .liquidLight, isActive: isActive)
        case .ferrofluid: FerroView(isActive: isActive)
        case .chip: scaled(ChipView(isActive: isActive), from: 1100)
        case .rasters: RasterView(isActive: isActive)
        case .silicon: SiliconView(isActive: isActive)
        case .nimbus: NimbusView(isActive: isActive)
        }
    }

    /// `view` laid out `width` wide, in the picture's shape, and shrunk to fit.
    private func scaled(_ view: some View, from width: CGFloat) -> some View {
        let scale = size.width / width
        return view
            .frame(width: width, height: size.height / scale)
            .scaleEffect(scale)
            .frame(width: size.width, height: size.height)
    }
}

#Preview {
    VisualizerChooser()
        .environment(PlayerStore.preview)
        .padding()
}
