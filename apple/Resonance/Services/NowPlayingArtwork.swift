import AppKit
import MediaPlayer
import PhosphorCore
import SwiftUI

/// The picture macOS shows beside the tune in Now Playing: the tune's own
/// fingerprint sphere, or before it's scanned (or outside HVSC) its
/// composer's colors. Never their photo: those are Debug-only, and their
/// licenses ask for a credit this has nowhere to show.
enum NowPlayingArtwork {
    /// Points, not pixels: the sphere's dots are a fixed size, so this keeps
    /// them in the proportion the inspector shows, sharply.
    private static let size = 96.0
    private static let scale = 6.0

    /// Nil with nothing to go by.
    static func image(fingerprint: TuneFingerprint?, composer: String) -> NSImage? {
        if let fingerprint { return render(SphereArtwork(fingerprint: fingerprint).voiceThemed()) }
        return composer.isEmpty ? nil : render(ComposerColorField(name: composer))
    }

    /// macOS asks for the image off the main thread: nothing here may be
    /// main-actor-isolated, which `@Sendable` sees to, as for remote commands.
    static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        nonisolated(unsafe) let image = image
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private static func render(_ content: some View) -> NSImage? {
        let renderer = ImageRenderer(content: content.frame(width: size, height: size))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSImage(cgImage: image, size: CGSize(width: size * scale, height: size * scale))
    }
}

/// The sphere held still, on its backdrop right into the corners.
private struct SphereArtwork: View {
    let fingerprint: TuneFingerprint

    @Environment(\.voiceTheme) private var theme

    var body: some View {
        MorphSphere(fingerprint: fingerprint, animated: false, zoom: 1.2)
            .background(theme.background.color)
    }
}
