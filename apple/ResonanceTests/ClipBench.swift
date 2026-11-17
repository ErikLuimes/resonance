import Accelerate
import AVFoundation
import Foundation
import Testing
import PhosphorCore
@testable import Resonance

/// The clip measurements: which H.264 bitrate keeps
/// every visualizer at SSIM 0.98 or more against a ProRes master, and
/// whether the short-memory visualizers' lead-ins are long enough. Slow
/// (about half an hour), so they run only when asked:
///
///     TEST_RUNNER_CLIP_BENCH=1 xcodebuild test … -only-testing:ResonanceTests/ClipBench
///
/// Results print and are attached to the test run.
@MainActor
struct ClipBench {
    nonisolated private static let commando = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Resonance/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid").path

    nonisolated private static var asked: Bool {
        ProcessInfo.processInfo.environment["CLIP_BENCH"] != nil && FileManager.default.fileExists(atPath: commando)
    }

    private func store() -> PlayerStore {
        let defaults = UserDefaults(suiteName: "clip-bench")!
        let session = FileManager.default.temporaryDirectory.appending(path: "clip-bench-session.m3u").path
        return PlayerStore(defaults: defaults, defaultHvscRoot: nil) { config in
            var config = config
            config.sessionPath = session
            return PlayerCore(config: config)
        }
    }

    private func plan(_ visual: NowPlayingVisual, shape: ClipMaker.Shape, length: Int, start: Double,
                      leadIn: Double? = nil) -> ClipMaker.Plan {
        let track = TrackDetails(path: Self.commando, title: "Commando", author: "Rob Hubbard", released: "1985 Elite",
                                 songs: 3, currentSong: 1, isPal: true, isRsid: false, numSids: 1, sidType: "PSID",
                                 sidModel: 1, md5: "")
        return ClipMaker.Plan(visual: visual, shape: shape, length: length, start: start, track: track,
                              engine: .reSidFp, forceStereo2sid: false, theme: .resonance,
                              link: URL(string: "https://useresonance.app/t/Xk3mR9_aQ2bF?v=85"),
                              heard: start + Double(length), leadIn: leadIn)
    }

    // MARK: Bitrate

    /// Each visualizer's 15 s, in both shapes, as a ProRes master, then
    /// through the clip's own H.264 settings at each bitrate; the luma
    /// SSIM of every third frame against the master.
    @Test(.enabled(if: asked), .timeLimit(.minutes(60)))
    func bitrates() async throws {
        let rates = [4, 6, 8, 10, 12]
        var lines = ["visual\tshape\tMbit/s\tMB\tmean SSIM\tworst frame"]
        for shape in [ClipMaker.Shape.square, .wide] {
            for visual in NowPlayingVisual.offered {
                let master = try await ClipMaker.render(plan(visual, shape: shape, length: 15, start: 20),
                                                        store: store(), encoding: .master) { _ in }
                defer { try? FileManager.default.removeItem(at: master.deletingLastPathComponent()) }
                for rate in rates {
                    let encoded = try await Self.reencode(master, size: shape.size, bitRate: rate * 1_000_000)
                    defer { try? FileManager.default.removeItem(at: encoded) }
                    let bytes = (try encoded.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let score = try await Self.ssim(master, encoded, every: 3)
                    let line = "\(visual.rawValue)\t\(shape)\t\(rate)\t\(String(format: "%.1f", Double(bytes) / 1e6))\t"
                        + "\(String(format: "%.4f", score.mean))\t\(String(format: "%.4f", score.worst))"
                    print("Clip bench: " + line)
                    lines.append(line)
                }
            }
        }
        Attachment.record(lines.joined(separator: "\n"), named: "clip-bitrates.tsv")
    }

    /// The master through `ClipWriter.videoSettings`, video only.
    nonisolated static func reencode(_ master: URL, size: CGSize, bitRate: Int) async throws -> URL {
        let asset = AVURLAsset(url: master)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        let frames = reader.outputProvider(for: output)
        let url = FileManager.default.temporaryDirectory.appending(path: "clip-bench-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: ClipWriter.videoSettings(size: size, encoding: .h264(bitRate: bitRate)))
        let receiver = writer.inputReceiver(for: input)
        try reader.start()
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        // Waits for the input to be ready, then appends.
        while let sample = try await frames.next() {
            try await receiver.append(sample)
        }
        receiver.finish()
        await writer.finishWriting()
        if let error = writer.error ?? reader.error { throw error }
        return url
    }

    /// Luma SSIM of every `every`th frame of `b` against `a`.
    nonisolated static func ssim(_ a: URL, _ b: URL, every: Int) async throws -> (mean: Double, worst: Double) {
        typealias Frames = AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
        func open(_ url: URL) async throws -> (AVAssetReader, Frames) {
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            let frames = reader.outputProvider(for: output)
            try reader.start()
            return (reader, frames)
        }
        let (readerA, framesA) = try await open(a)
        let (readerB, framesB) = try await open(b)
        var scores: [Double] = []
        var n = 0
        while let x = try await framesA.next(), let y = try await framesB.next() {
            defer { n += 1 }
            guard n % every == 0 else { continue }
            let score: Double? = x.withUnsafeSampleBuffer { x in
                y.withUnsafeSampleBuffer { y in
                    guard let px = CMSampleBufferGetImageBuffer(x), let py = CMSampleBufferGetImageBuffer(y) else { return nil }
                    return ssim(luma(px), luma(py), width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
                }
            }
            if let score { scores.append(score) }
        }
        _ = (readerA, readerB)
        return (scores.reduce(0, +) / Double(max(scores.count, 1)), scores.min() ?? 0)
    }

    /// The Y plane, as floats.
    nonisolated static func luma(_ buffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: width * height)
        out.withUnsafeMutableBufferPointer { out in
            for row in 0..<height {
                vDSP_vfltu8(base + row * stride, 1, out.baseAddress! + row * width, 1, vDSP_Length(width))
            }
        }
        return out
    }

    /// SSIM as ffmpeg's `ssim` filter works it out: 8 × 8 windows a
    /// 4-pixel step apart, from 4 × 4 block sums; the mean over windows.
    nonisolated static func ssim(_ x: [Float], _ y: [Float], width: Int, height: Int) -> Double {
        let count = width * height
        var xx = [Float](repeating: 0, count: count), xy = [Float](repeating: 0, count: count)
        vDSP_vmul(x, 1, x, 1, &xx, 1, vDSP_Length(count))
        vDSP_vma(y, 1, y, 1, xx, 1, &xx, 1, vDSP_Length(count))
        vDSP_vmul(x, 1, y, 1, &xy, 1, vDSP_Length(count))
        let bw = width / 4, bh = height / 4
        // 4 × 4 block sums: across in fours, then down in fours.
        func blocks(_ plane: [Float]) -> [Float] {
            var across = [Float](repeating: 0, count: bw * height)
            let ones: [Float] = [1, 1, 1, 1]
            for row in 0..<height {
                plane.withUnsafeBufferPointer { p in
                    across.withUnsafeMutableBufferPointer { a in
                        vDSP_desamp(p.baseAddress! + row * width, 4, ones, a.baseAddress! + row * bw, vDSP_Length(bw), 4)
                    }
                }
            }
            var out = [Float](repeating: 0, count: bw * bh)
            for row in 0..<bh {
                for k in 0..<4 {
                    across.withUnsafeBufferPointer { a in
                        out.withUnsafeMutableBufferPointer { o in
                            let line = o.baseAddress! + row * bw
                            vDSP_vadd(line, 1, a.baseAddress! + (row * 4 + k) * bw, 1, line, 1, vDSP_Length(bw))
                        }
                    }
                }
            }
            return out
        }
        let s1 = blocks(x), s2 = blocks(y), ss = blocks(xx), s12 = blocks(xy)
        let c1 = 0.01 * 0.01 * 255 * 255 * 64, c2 = 0.03 * 0.03 * 255 * 255 * 64 * 63
        var total = 0.0
        for by in 0..<(bh - 1) {
            for bx in 0..<(bw - 1) {
                let i = by * bw + bx, quad = [i, i + 1, i + bw, i + bw + 1]
                var a = 0.0, b = 0.0, sq = 0.0, ab = 0.0
                for j in quad { a += Double(s1[j]); b += Double(s2[j]); sq += Double(ss[j]); ab += Double(s12[j]) }
                let variance = sq * 64 - a * a - b * b, covariance = ab * 64 - a * b
                total += (2 * a * b + c1) * (2 * covariance + c2) / ((a * a + b * b + c1) * (variance + c2))
            }
        }
        return total / Double((bw - 1) * (bh - 1))
    }

    // MARK: Preview

    /// How long the sheet's still takes for each visualizer, from 1:30 into
    /// the tune, in its parts (printed by `ClipMaker.still`): the engine's
    /// skip, making the painter, and drawing the lead-in. Twice each, as
    /// the first one pays for loading shaders.
    @Test(.enabled(if: asked))
    func stills() async throws {
        for visual in NowPlayingVisual.offered {
            for _ in 0..<2 {
                _ = try await ClipMaker.still(plan(visual, shape: .square, length: 15, start: 90), store: store())
            }
        }
    }

    // MARK: Lead-in

    /// The short-memory visualizers' first frame after their lead-in,
    /// against one after 20 s of lead-in: the mean difference in 8-bit
    /// levels and the luma SSIM. The same render twice gives the floor.
    @Test(.enabled(if: asked), .timeLimit(.minutes(30)))
    func leadIns() async throws {
        let visuals: [NowPlayingVisual] = [.terrain, .ferrofluid, .halo, .radial, .spectrum, .particles]
        let leads = [0, 0.5, 1, 2, 4, 8, 12, 16]
        var lines = ["visual\tlead-in s\tmean levels\tSSIM"]
        for visual in visuals {
            func still(_ lead: Double) async throws -> CGImage {
                try #require(try await ClipMaker.still(plan(visual, shape: .square, length: 15, start: 30, leadIn: lead),
                                                       store: store()))
            }
            let reference = try await still(20)
            for (label, lead) in [("20 again", 20.0)] + leads.map({ (String($0), $0) }) {
                let image = try await still(lead)
                let (levels, score) = Self.compare(reference, image)
                let line = "\(visual.rawValue)\t\(label)\t\(String(format: "%.3f", levels))\t\(String(format: "%.4f", score))"
                print("Clip bench: " + line)
                lines.append(line)
            }
        }
        Attachment.record(lines.joined(separator: "\n"), named: "clip-lead-ins.tsv")
    }

    /// Mean absolute difference over RGB (0–255) above the card's band,
    /// and luma SSIM over the whole frame.
    nonisolated static func compare(_ a: CGImage, _ b: CGImage) -> (levels: Double, ssim: Double) {
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            data.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return data
        }
        let x = pixels(a), y = pixels(b), width = a.width, height = a.height
        var sum = 0.0, count = 0
        // Row 0 is the top; the card is in the bottom 28%.
        for row in 0..<Int(Double(height) * 0.72) {
            for column in 0..<width {
                let i = (row * width + column) * 4
                for c in 0..<3 { sum += abs(Double(x[i + c]) - Double(y[i + c])) }
                count += 3
            }
        }
        func luma(_ p: [UInt8]) -> [Float] {
            (0..<(width * height)).map { i in
                0.2126 * Float(p[i * 4]) + 0.7152 * Float(p[i * 4 + 1]) + 0.0722 * Float(p[i * 4 + 2])
            }
        }
        return (sum / Double(max(count, 1)), ssim(luma(x), luma(y), width: width, height: height))
    }
}
