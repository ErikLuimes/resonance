import SwiftUI
import PhosphorCore

/// The inspector's "Sounds Like": the playing tune's sphere and its sound
/// in a sentence, then the tunes in HVSC that sound most like it, each a
/// link to where it is in the library, and a way to play them all. Until
/// the scan reaches the tune, how far the scan has got.
struct SoundsLikeSection: View {
    let path: String

    @Environment(FingerprintStore.self) private var fingerprints
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player

    /// The tune these sound like, for "Playing from Sounds like …".
    private var seedTitle: String {
        if let track = player.nowPlaying, track.path == path, !track.title.isEmpty { return track.title }
        return URL(filePath: path).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
    }

    var body: some View {
        let fp = fingerprints.fingerprint(path)
        VStack(alignment: .leading, spacing: 6) {
            Text("Sounds Like")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 10) {
                if let fp {
                    HStack(alignment: .center, spacing: 10) {
                        // Closer in than the fit-anything default, like the
                        // hover card's.
                        MorphSphere(fingerprint: fp, zoom: 1.2)
                            .frame(width: 76, height: 76)
                        Text(fp.summary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    matches
                } else {
                    scanStatus
                }
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        }
        .task(id: path) { fingerprints.load([path]) }
        // Per tune, and again once its fingerprint arrives: a tune that was
        // already scanned when it started playing needs its matches too.
        .task(id: SimilarKey(path: path, scanned: fp != nil)) {
            if fp != nil { await fingerprints.loadSimilar(path) }
        }
    }

    private struct SimilarKey: Equatable {
        let path: String
        let scanned: Bool
    }

    @ViewBuilder
    private var matches: some View {
        if let similar = fingerprints.similar[path] {
            if similar.isEmpty {
                Text("Nothing else has been fingerprinted yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(similar, id: \.item.path) { match in
                        row(match)
                        if match.item.path != similar.last?.item.path {
                            Divider()
                        }
                    }
                }
                Button("Play These") {
                    library.play(similar.map { LibraryRow(item: $0.item) }, from: .soundsLike(title: seedTitle))
                }
                .controlSize(.small)
                .help("Play these tunes, most alike first")
            }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func row(_ match: SimilarTune) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                AccentLink(match.item.title) { library.reveal(tunePath: match.item.path) }
                    .lineLimit(1)
                    .help("Show in the library")
                Text(match.item.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(Int((max(0, match.score) * 100).rounded()))% alike")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var scanStatus: some View {
        if let status = fingerprints.status, status.total > 0, !status.finished {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not fingerprinted yet. \(status.done.formatted()) of \(status.total.formatted()) tunes are done.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: Double(status.done), total: Double(max(status.total, 1)))
                    .controlSize(.small)
                AccentLink(fingerprints.paused ? "Resume Fingerprinting" : "Pause Fingerprinting") {
                    fingerprints.paused.toggle()
                }
            }
        } else {
            Text(library.category(of: path) == nil
                 ? "Only tunes in the HVSC collection are fingerprinted."
                 : "This tune couldn't be fingerprinted.")
                .foregroundStyle(.secondary)
        }
    }
}
