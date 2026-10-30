import SwiftUI
import PhosphorCore

/// Visualizer and details of the playing tune.
struct NowPlayingInspector: View {
    @Environment(PlayerStore.self) private var store

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
                    LabeledContent("Title", value: track.title)
                    LabeledContent("Author", value: track.author)
                    LabeledContent("Released", value: track.released)
                    if track.songs > 1 {
                        LabeledContent("Song", value: "\(track.currentSong) of \(track.songs)")
                    }
                    if let duration = store.duration {
                        LabeledContent("Length", value: Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    }
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

    private func sidModelName(_ model: UInt8) -> String {
        switch model {
        case 1: "MOS 6581"
        case 2: "MOS 8580"
        case 3: "6581 or 8580"
        default: "Unspecified"
        }
    }
}

#Preview {
    NowPlayingInspector()
        .environment(PlayerStore.preview)
        .frame(width: 300, height: 700)
}
