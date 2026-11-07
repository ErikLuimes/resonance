import AppKit
import QuickLookUI
import SwiftUI

/// Space on a `.sid` file in Finder: what its header says. It can't play the
/// tune, so it doesn't pretend to; Quick Look's Open button does that.
final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: SIDHeader.length) ?? Data()
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")

        let hosting = NSHostingView(rootView: SIDPreviewView(header: SIDHeader(data), fileName: name))
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.addSubview(hosting)
        preferredContentSize = CGSize(width: 480, height: 180)
    }
}

struct SIDPreviewView: View {
    let header: SIDHeader?
    let fileName: String

    private var title: String {
        guard let title = header?.title, !title.isEmpty, title != "<?>" else { return fileName }
        return title
    }

    private var author: String? {
        guard let author = header?.author, !author.isEmpty, author != "<?>" else { return nil }
        return author
    }

    private var released: String? {
        guard let released = header?.released, !released.isEmpty, released != "<?>" else { return nil }
        return released
    }

    var body: some View {
        HStack(spacing: 20) {
            ComposerColorField(name: author ?? title)
                .frame(width: 112, height: 112)
                .clipShape(.rect(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                if let author {
                    Text(author)
                        .font(.title3)
                }
                if let released {
                    Text(released)
                        .foregroundStyle(.secondary)
                }
                Text(header?.facts.joined(separator: " · ") ?? "Commodore 64 tune")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
