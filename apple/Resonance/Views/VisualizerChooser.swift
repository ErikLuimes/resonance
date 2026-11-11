import SwiftUI

/// Chooses Now Playing's visualizers from pictures of them: a card each,
/// with the chosen ones outlined. The pictures are stills that ship with
/// the app (Assets: VisualizerPictures, made by
/// scripts/visualizer-pictures.sh), a set in each preset theme's colors;
/// only the card under the pointer runs live, small, and only while a tune
/// plays for it to show. A dozen visualizers working at once is too much for a modest
/// Mac. Up to `NowPlayingVisual.lineupSize` can be chosen and at least one
/// stays. Settings › Appearance shows it, and so does Now Playing, from
/// its Visualizers… button.
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

/// One visualizer: its picture, name and what it shows. Chosen ones
/// have the accent outline, like Settings' Appearance pictures.
private struct VisualizerCard: View {
    let visual: NowPlayingVisual
    let width: CGFloat
    let isChosen: Bool
    let isEnabled: Bool
    let toggle: () -> Void

    @State private var isHovering = false
    @Environment(\.voiceTheme) private var theme
    @Environment(PlayerStore.self) private var store

    /// The theme's picture of it. There's a set for each preset; a custom
    /// theme's colors can be anything, so it shows the default theme's.
    private var picture: String {
        let set = VoiceTheme.presets.contains { $0.id == theme.id } ? theme.id : VoiceTheme.resonance.id
        return "VisualizerPictures/\(set)/\(visual.rawValue)"
    }

    var body: some View {
        let size = CGSize(width: width, height: (width * 0.62).rounded())
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    Image(decorative: picture)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .clipShape(.rect(cornerRadius: 7))
                    // Made only while the pointer is here, so nothing of a
                    // visualizer exists for the other cards. With no tune
                    // playing it would have nothing to show: the picture stays.
                    if isHovering, store.isPlaying {
                        VisualizerPreview(visual: visual, size: size)
                            .transition(.opacity)
                    }
                }
                    .animation(.easeOut(duration: 0.2), value: isHovering && store.isPlaying)
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
