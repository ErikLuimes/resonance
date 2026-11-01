import SwiftUI

/// The inspector's visualizer card: one page per visualizer, swiped between
/// on a trackpad or picked with the dots along the card's bottom edge, which
/// show the visualizer's name on hover. Remembers the last one shown.
///
/// Each visualizer draws everything, labels included, into one Canvas. A
/// Canvas has no content-derived size, so per-frame text changes can't
/// alter the inspector's size; with SwiftUI Text labels, every new note
/// name changed the column's ideal width mid-layout and AppKit aborted the
/// app after re-running layout too many times.
struct VisualizerView: View {
    @AppStorage(Pref.visualizerMode) private var mode = VisualizerMode.scope
    /// The page scrolled to; nil until the scroll view reports one.
    @State private var page: VisualizerMode?
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(VisualizerMode.allCases) { mode in
                        visualizer(mode)
                            .padding([.top, .horizontal], 12)
                            // Room for the dots.
                            .padding(.bottom, 26)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)

            dots
                .padding(.bottom, 6)
        }
        .background(Self.background)
        .clipShape(.rect(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .onAppear { page = mode }
        .onChange(of: page) { _, page in
            if let page { mode = page }
        }
    }

    @ViewBuilder
    private func visualizer(_ mode: VisualizerMode) -> some View {
        switch mode {
        case .scope: ScopeVisualizer()
        case .bars: BarsVisualizer()
        case .envelope: EnvelopeVisualizer()
        }
    }

    private var dots: some View {
        let current = page ?? mode
        return HStack(spacing: 0) {
            ForEach(VisualizerMode.allCases) { mode in
                Button {
                    withAnimation { page = mode }
                } label: {
                    // The card is dark in both appearances.
                    Circle()
                        .fill(.white.opacity(mode == current ? 0.85 : 0.25))
                        .frame(width: 7, height: 7)
                        .padding(4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(mode.title)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(mode == current ? .isSelected : [])
            }
            // Fixed width, always laid out, so hovering never moves the dots.
            Text(current.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: Self.nameWidth, alignment: .leading)
                .padding(.leading, 4)
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .accessibilityHidden(true)
        }
        // Balance the name so the dots sit in the middle.
        .padding(.leading, Self.nameWidth + 4)
        .frame(height: 16)
    }

    private static let background = Color(red: 0x0E / 255, green: 0x0E / 255, blue: 0x10 / 255)
    private static let nameWidth: CGFloat = 56
}

nonisolated enum VisualizerMode: String, CaseIterable, Identifiable {
    case scope
    case bars
    case envelope

    var id: Self { self }

    var title: String {
        switch self {
        case .scope: "Scope"
        case .bars: "Bars"
        case .envelope: "Envelope"
        }
    }
}

#Preview {
    VisualizerView()
        .environment(PlayerStore.preview)
        .frame(width: 300, height: 204)
        .padding()
}
