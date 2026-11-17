import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import PhosphorCore
@testable import Resonance


/// Clip sharing: real clips of a real tune, through
/// every visualizer Now Playing offers. Needs HVSC on this Mac; skipped
/// without it.
@MainActor
struct ClipTests {
    nonisolated private static let commando = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Resonance/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid").path

    nonisolated private static var hasTune: Bool { FileManager.default.fileExists(atPath: commando) }

    private func store() -> PlayerStore {
        let defaults = UserDefaults(suiteName: "clip-tests")!
        let session = FileManager.default.temporaryDirectory.appending(path: "clip-tests-session.m3u").path
        return PlayerStore(defaults: defaults, defaultHvscRoot: nil) { config in
            var config = config
            config.sessionPath = session
            return PlayerCore(config: config)
        }
    }

    private func plan(_ visual: NowPlayingVisual, shape: ClipMaker.Shape = .square, length: Int, start: Double) -> ClipMaker.Plan {
        let track = TrackDetails(path: Self.commando, title: "Commando", author: "Rob Hubbard", released: "1985 Elite",
                                 songs: 3, currentSong: 1, isPal: true, isRsid: false, numSids: 1, sidType: "PSID",
                                 sidModel: 1, md5: "")
        return ClipMaker.Plan(visual: visual, shape: shape, length: length, start: start, track: track,
                              engine: .reSidFp, forceStereo2sid: false, theme: .resonance,
                              link: URL(string: "https://useresonance.app/t/Xk3mR9_aQ2bF?v=85"),
                              heard: start + Double(length), hvscPath: "/MUSICIANS/H/Hubbard_Rob/Commando.sid")
    }

    @Test(.enabled(if: hasTune), arguments: NowPlayingVisual.offered)
    func everyOfferedVisualizerMakesAClip(_ visual: NowPlayingVisual) async throws {
        #expect(ClipPainters.canClip(visual))
        let started = Date()
        let url = try await ClipMaker.render(plan(visual, length: 2, start: 20), store: store()) { _ in }
        let took = Date().timeIntervalSince(started)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.03, "\(duration) s")
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 1080, height: 1080))
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)

        // The last frame shows the visualizer, not just the background.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (frame, _) = try await generator.image(at: CMTime(value: 115, timescale: 60))
        save(frame, as: "Clip-\(visual.rawValue).png")
        let picture = lit(frame, aboveBackground: 40, belowCard: 0.72)
        print("Clip \(visual.rawValue): 2 s square in \(String(format: "%.2f", took)) s, \(picture) lit samples")
        #expect(picture > 50, "\(visual.rawValue) drew nothing")
    }

    /// The visualizers' clocks are the tune's: the same part always opens
    /// on the same shot, a different part on a different one, and a clip of
    /// the tune's start opens on the start of Silicon's tour.
    @Test(.enabled(if: hasTune))
    func theSamePartGetsTheSameShots() async throws {
        func first(from start: Double) async throws -> CGImage {
            let url = try await ClipMaker.render(plan(.silicon, length: 1, start: start), store: store()) { _ in }
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: .zero).image
        }
        let start = try await first(from: 0)
        save(start, as: "Clip-silicon-from-0.png")
        let again = try await first(from: 0)
        let later = try await first(from: 30)
        save(later, as: "Clip-silicon-from-30.png")
        let same = difference(start, again), different = difference(start, later)
        print("Silicon's first frame: \(same) apart for the same part, \(different) for 30 s later")
        #expect(same < different / 4)
    }

    @Test(.enabled(if: hasTune))
    func wideClipsAreSixteenByTen() async throws {
        let url = try await ClipMaker.render(plan(.ferrofluid, shape: .wide, length: 1, start: 5), store: store()) { _ in }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let video = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 1728, height: 1080))
    }

    /// The audio is the engine's own and starts where the clip does: a
    /// clip from 2 s lines up with the tune rendered from 0 within a
    /// quarter of a millisecond (measured: 3 samples, 0.06 ms, against a
    /// video frame's 16.7 ms). Not sample for sample: the filter and
    /// resampler settle after the skip.
    @Test(.enabled(if: hasTune))
    func audioStartsWhereTheClipDoes() async throws {
        func samples(from ms: UInt64, frames: Int) throws -> [Float] {
            let clip = try ClipRenderer(config: ClipConfig(path: Self.commando, subtune: 1, engine: .reSidFp,
                                                           forceStereo2sid: false, fromMs: ms, framesPerSecond: 60,
                                                           sampleRate: 48_000))
            return (0..<frames).flatMap { _ in clip.nextFrame().floats }
        }
        let early = try samples(from: 0, frames: 5 * 60)
        let late = try samples(from: 2000, frames: 2 * 60)
        // Left channel, after the skipped run's first second has settled.
        func difference(lag: Int) -> Double {
            var sum = 0.0
            let range = 48_000..<(late.count / 2)
            for i in range { sum += Double(abs(late[i * 2] - early[(96_000 + i + lag) * 2])) }
            return sum / Double(range.count)
        }
        let lags = -24...24
        let near = lags.map(difference)
        let best = lags.lowerBound + near.indices.min { near[$0] < near[$1] }!
        let away = min(difference(lag: -100), difference(lag: 100))
        print("Clip audio from 2 s vs from 0: best lag \(best), mean difference \(near.min()!) there, \(away) 100 samples away")
        #expect(abs(best) <= 12)
        #expect(near.min()! < away / 2)
    }

    /// An .mp4 keeps only iTunes-style tags; the link rides in the comment.
    @Test(.enabled(if: hasTune))
    func theFileCarriesTheTuneAndItsLink() async throws {
        let url = try await ClipMaker.render(plan(.ink, length: 1, start: 5), store: store()) { _ in }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let items = try await AVURLAsset(url: url).load(.metadata)
        func value(_ id: AVMetadataIdentifier) async throws -> String? {
            try await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first?.load(.stringValue)
        }
        #expect(try await value(.iTunesMetadataSongName) == "Commando")
        #expect(try await value(.iTunesMetadataArtist) == "Rob Hubbard")
        #expect(try await value(.iTunesMetadataUserComment) == "https://useresonance.app/t/Xk3mR9_aQ2bF?v=85")
        #expect(try await value(.iTunesMetadataCopyright) == "1985 Elite")
        #expect(try await value(.iTunesMetadataReleaseDate) == "1985")
        #expect(try await value(.iTunesMetadataDescription) == "HVSC /MUSICIANS/H/Hubbard_Rob/Commando.sid")
    }

    @Test func aTuneInTheCollectionHasItsHvscPath() {
        #expect(ClipMaker.Plan.hvscPath(of: "/C64/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid", root: "/C64/HVSC")
                == "/MUSICIANS/H/Hubbard_Rob/Commando.sid")
        #expect(ClipMaker.Plan.hvscPath(of: "/C64/HVSC/GAMES/A-F/Commando.sid", root: "/C64/HVSC/") == "/GAMES/A-F/Commando.sid")
        #expect(ClipMaker.Plan.hvscPath(of: "/C64/HVSC2/Mine.sid", root: "/C64/HVSC") == nil)
        #expect(ClipMaker.Plan.hvscPath(of: "/Downloads/Mine.sid", root: nil) == nil)
    }

    @Test func aSavedClipSaysWhereItCameFrom() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "where-from-\(UUID().uuidString).mp4")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        ClipSheet.setWhereFrom(URL(string: "https://useresonance.app/t/Xk3mR9_aQ2bF")!, on: file)
        let size = getxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0)
        #expect(size > 0)
        var data = Data(count: max(size, 0))
        _ = data.withUnsafeMutableBytes { getxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, size, 0, 0) }
        let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        #expect(list == ["https://useresonance.app/t/Xk3mR9_aQ2bF"])
    }

    @Test func theCardShowsTheLinkWithoutItsScheme() {
        #expect(ClipCard.shown(URL(string: "https://useresonance.app/t/Xk3mR9_aQ2bF?v=85")) == "useresonance.app/t/Xk3mR9_aQ2bF")
        #expect(ClipCard.shown(URL(string: "https://useresonance.app/t/Xk3mR9_aQ2bF?s=2&v=85")) == "useresonance.app/t/Xk3mR9_aQ2bF?s=2")
        #expect(ClipCard.shown(nil) == "useresonance.app")
    }

    @Test func theEndsFadeAndTheMiddleDoesnt() {
        var samples = [Float](repeating: 1, count: 2000 * 2)
        ClipWriter.fade(&samples, frames: 2000, from: 0, total: 2000, length: 480)
        #expect(samples[0] == 0)
        #expect(samples[1000 * 2] == 1)
        #expect(samples[1999 * 2] == 0)
        #expect(samples[240 * 2] > 0.49 && samples[240 * 2] < 0.51)
    }

    // MARK: Pictures

    /// The mean difference between two pictures' levels (0–255), sampled
    /// every 8 pixels above the card.
    private func difference(_ a: CGImage, _ b: CGImage) -> Double {
        func levels(_ image: CGImage) -> [UInt8] {
            let width = image.width, height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            data.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return data
        }
        let x = levels(a), y = levels(b)
        var sum = 0.0, count = 0
        for row in stride(from: 0, to: Int(Double(a.height) * 0.72), by: 8) {
            for column in stride(from: 0, to: a.width, by: 8) {
                let i = (row * a.width + column) * 4
                for c in 0..<3 { sum += abs(Double(x[i + c]) - Double(y[i + c])) }
                count += 3
            }
        }
        return sum / Double(max(count, 1))
    }

    /// Samples, every 8 pixels, above the card's band, brighter than the
    /// background by `threshold` (0–255).
    private func lit(_ image: CGImage, aboveBackground threshold: Int, belowCard: Double) -> Int {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return context.data }()
        else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let bg = VoiceTheme.resonance.background
        let base = Int((bg.red + bg.green + bg.blue) / 3 * 255)
        var count = 0
        // Rows from the top of the picture; the context's rows run from the
        // top too.
        for y in stride(from: 0, to: Int(Double(height) * belowCard), by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let i = (y * width + x) * 4
                let level = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
                if abs(level - base) > threshold { count += 1 }
            }
        }
        return count
    }

    /// The frame, at a quarter of its size, as an attachment to the test's
    /// results (the test host's sandbox keeps its temporary folder private):
    /// `xcrun xcresulttool export attachments` gets them out.
    private func save(_ image: CGImage, as name: String) {
        let width = image.width / 4, height = image.height / 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, small, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        Attachment.record(data as Data, named: name)
    }
}
