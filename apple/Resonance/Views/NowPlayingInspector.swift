import SwiftUI
import PhosphorCore

/// Visualizer and details of the playing tune.
struct NowPlayingInspector: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library

    var body: some View {
        // The visualizer redraws every frame, so it sits above the Form
        // rather than in a Form row (rows are table cells that get
        // re-measured whenever their content changes).
        VStack(spacing: 0) {
            VisualizerView()
                .frame(height: 180)
                .padding(12)
            details
        }
    }

    @ViewBuilder
    private var details: some View {
        if let track = store.nowPlaying {
            Form {
                Section("Now Playing") {
                    LabeledContent("Playing From") { source }
                    LabeledContent("Title", value: track.title)
                    LabeledContent("Author") { author(of: track) }
                    LabeledContent("Released", value: track.released)
                    if track.songs > 1 {
                        LabeledContent("Song", value: "\(track.currentSong) of \(track.songs)")
                    }
                    if let duration = store.duration {
                        LabeledContent("Length", value: Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    }
                    addToPlaylist(track)
                }
                if let stil = store.stil {
                    Section("STIL") {
                        Text(stil)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Section("Tune") {
                    LabeledContent("Format", value: track.sidType)
                    LabeledContent("SID Model", value: sidModelName(track.sidModel))
                    LabeledContent("Chips", value: "\(track.numSids)")
                    LabeledContent("Clock", value: track.isPal ? "PAL" : "NTSC")
                    LabeledContent("Engine", value: store.engine.displayName)
                }
                Section("File") {
                    LabeledContent("Name", value: URL(filePath: track.path).lastPathComponent)
                    if !track.md5.isEmpty {
                        LabeledContent("MD5") {
                            Text(track.md5).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: track.path)])
                    }
                }
            }
            .formStyle(.grouped)
            .labeledContentStyle(WrappingValueStyle())
            // The author link matches composers against the MUSICIANS list.
            .task(id: store.hvscRoot) { await library.loadAuthors(.musicians) }
        } else {
            ContentUnavailableView {
                Label("Not Playing", systemImage: "waveform")
            } description: {
                Text("Double-click a tune to play it. Its details and STIL commentary appear here.")
            }
            // Pinned like the playlist column: the empty state's ideal
            // width must not become the inspector column's.
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Which list Next and Previous walk.
    @ViewBuilder
    private var source: some View {
        if store.surpriseActive {
            Label("Surprise Me", systemImage: "dice.fill")
                .foregroundStyle(.tint)
                .help("Next plays another random tune from HVSC. Play anything else to stop.")
        } else if store.queueActive {
            Label("HVSC", systemImage: "books.vertical")
        } else {
            Label("Playlist", systemImage: "music.note.list")
        }
    }

    /// The author as a link to all their tunes in the HVSC browser, when
    /// the library can show them. Styled like the other values, with an
    /// accent arrow inside the text so a long name wraps with it.
    @ViewBuilder
    private func author(of track: TrackDetails) -> some View {
        if let reveal = library.revealAuthor(of: track) {
            let arrow = Text(Image(systemName: "arrow.forward.circle.fill")).foregroundStyle(.tint)
            Button {
                library.reveal = reveal
            } label: {
                // A no-break space: the arrow wraps with the last word
                // rather than ending up alone on a line.
                Text("\(track.author)\u{00A0}\(arrow)")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Show all tunes by \(track.author)")
            .accessibilityHint("Shows all tunes by \(track.author)")
        } else {
            Text(track.author)
        }
    }

    /// Keep what's playing — a surprise, or any tune played from the library.
    private func addToPlaylist(_ track: TrackDetails) -> some View {
        let inPlaylist = store.rows.contains { $0.id == track.path }
        return Button(
            inPlaylist ? "In Playlist" : "Add to Playlist",
            systemImage: inPlaylist ? "checkmark" : "text.badge.plus"
        ) {
            store.add([URL(filePath: track.path)])
        }
        .disabled(inPlaylist)
    }

    private func sidModelName(_ model: UInt8) -> String {
        switch model {
        case 1: "MOS 6581"
        case 2: "MOS 8580"
        case 3: "6581 or 8580"
        default: "Unspecified"
        }
    }
}

/// Label and value side by side, a long value wrapping in place on the
/// right. The form's own style moves a value that doesn't fit onto a line
/// of its own below the label, which read badly in the narrow inspector.
private struct WrappingValueStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Never squeezed: a value with no spaces to break at (an MD5)
            // would otherwise take the label's width too.
            configuration.label
                .fixedSize()
            Spacer(minLength: 0)
            configuration.content
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    NowPlayingInspector()
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .frame(width: 300, height: 700)
}
