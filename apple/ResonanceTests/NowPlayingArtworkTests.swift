import AppKit
import Foundation
import PhosphorCore
import Testing
@testable import Resonance

@MainActor
struct NowPlayingArtworkTests {
    private func pixels(_ image: NSImage?) -> Data? {
        image?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider?.data as Data?
    }

    @Test func aScannedTuneShowsItsOwnSphere() throws {
        let first = try #require(NowPlayingArtwork.image(fingerprint: fingerprint(mix: [1, 0, 0, 0]), composer: "Rob Hubbard"))
        let second = NowPlayingArtwork.image(fingerprint: fingerprint(mix: [0, 0, 1, 0]), composer: "Rob Hubbard")
        #expect(first.size == CGSize(width: 576, height: 576))
        #expect(pixels(first) != pixels(second))
    }

    @Test func anUnscannedTuneShowsItsComposersColors() {
        let hubbard = NowPlayingArtwork.image(fingerprint: nil, composer: "Rob Hubbard")
        let galway = NowPlayingArtwork.image(fingerprint: nil, composer: "Martin Galway")
        #expect(hubbard != nil)
        #expect(pixels(hubbard) != pixels(galway))
    }

    /// No logo in its place: macOS's own placeholder says it better.
    @Test func withNothingToGoByThereIsNoPicture() {
        #expect(NowPlayingArtwork.image(fingerprint: nil, composer: "") == nil)
    }

    /// macOS asks off the main thread; a main-actor closure would crash here.
    @Test func theImageCanBeAskedForOffTheMainThread() async throws {
        let image = try #require(NowPlayingArtwork.image(fingerprint: nil, composer: "Rob Hubbard"))
        let artwork = NowPlayingArtwork.artwork(image)
        nonisolated(unsafe) let unsafeArtwork = artwork
        let found = await Task.detached { unsafeArtwork.image(at: CGSize(width: 100, height: 100)) != nil }.value
        #expect(found)
    }
}
