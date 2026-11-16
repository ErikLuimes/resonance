import AVFoundation
import CoreImage
import Metal
import Observation
import PhosphorCore
import QuartzCore
import SwiftUI


/// Makes a clip: a stretch of the playing tune with its visualizer, as an
/// .mp4 to post or send (design/clip-sharing).
///
/// A `ClipRenderer` (core/src/residfp_player/clip.rs) plays the stretch
/// silently on an engine of its own, one video frame at a time. The
/// visualizer's painter draws each frame from the clip's feed, the
/// compositor adds the background and the burned-in card, and the writer
/// takes the frame and its audio with timestamps from the same sample
/// count, so picture and sound line up by construction.
@MainActor @Observable
final class ClipMaker {
    enum Shape: String, CaseIterable, Identifiable {
        case square, wide
        var id: Self { self }

        /// Pixels: 1080 tall at most, square or 16:10.
        var size: CGSize {
            switch self {
            case .square: CGSize(width: 1080, height: 1080)
            case .wide: CGSize(width: 1728, height: 1080)
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .square: "Square"
            case .wide: "Wide"
            }
        }
    }

    /// Seconds. Never more than 30: a clip is an excerpt, credited, not a
    /// way to take the tune (design/clip-sharing, Music rights).
    static let lengths = [6, 15, 30]
    static let defaultLength = 15
    nonisolated static let framesPerSecond = 60
    static let sampleRate = 48_000
    /// H.264's bits a second for `visual`, at 1080 lines and 60 fps.
    /// Measured (design/clip-sharing, Bitrate; `ClipBench.bitrates`): 8
    /// keeps the rest at SSIM 0.98 or more in both shapes; these three
    /// don't get there even at 12 (fine detail moving everywhere), so they
    /// get 12, the most that was measured.
    static func videoBitRate(_ visual: NowPlayingVisual) -> Int {
        switch visual {
        case .liquidLight, .silicon, .particles: 12_000_000
        default: 8_000_000
        }
    }

    /// How the video is encoded: H.264 for clips; ProRes 422 HQ in a .mov
    /// as the bench's master, to measure H.264's bitrates against.
    nonisolated enum Encoding: Equatable, Sendable {
        case h264(bitRate: Int)
        case master
    }
    static let audioBitRate = 256_000
    /// The player's fade (`FADE` in residfp_player), at the clip's two ends.
    static let fade = 0.010

    enum Phase: Equatable {
        case idle
        case rendering(done: Double)
        case finished(URL, bytes: Int64)
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private var task: Task<Void, Never>?

    /// What the clip shows and says.
    struct Plan {
        var visual: NowPlayingVisual
        var shape: Shape
        var length: Int
        /// Seconds into the subtune.
        var start: Double
        var track: TrackDetails
        var engine: Engine
        var forceStereo2sid: Bool
        var theme: VoiceTheme
        /// The share link, nil when the tune can't be shared.
        var link: URL?
        /// Seconds into the subtune being heard when the sheet opened.
        var heard: Double
        /// "/MUSICIANS/H/Hubbard_Rob/Commando.sid", nil for a tune outside
        /// the collection.
        var hvscPath: String? = nil
        /// Seconds drawn before the clip and not kept; nil for the
        /// visualizer's own (`ClipPainters.leadIn`). Only the bench sets it.
        var leadIn: Double? = nil

        var leadInSecs: Double { leadIn ?? ClipPainters.leadIn(visual) }

        var title: String { track.title.isEmpty ? URL(filePath: track.path).deletingPathExtension().lastPathComponent : track.title }
        var composer: String { track.author.isEmpty || track.author == "<?>" ? String(localized: "Unknown composer") : track.author }

        /// The header's release line ("1985 Elite"), nil when it's empty or
        /// unknown.
        var released: String? {
            let released = track.released.trimmingCharacters(in: .whitespaces)
            return released.isEmpty || released == "<?>" ? nil : released
        }

        /// The release line's year, when it starts with one.
        var year: String? {
            guard let year = released?.prefix(4), year.count == 4, year.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return String(year)
        }

        /// A file's path in the collection, with a leading slash, as HVSC
        /// and STIL write it; nil outside it.
        static func hvscPath(of path: String, root: String?) -> String? {
            guard let root, !root.isEmpty else { return nil }
            let folder = root.hasSuffix("/") ? root : root + "/"
            guard path.hasPrefix(folder) else { return nil }
            return "/" + path.dropFirst(folder.count)
        }

        /// "Commando — Rob Hubbard (Ink).mp4", safe as a file name.
        var fileName: String {
            let name = "\(title) — \(composer) (\(visual.title))"
            return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".mp4"
        }
    }

    func start(_ plan: Plan, store: PlayerStore) {
        cancel()
        phase = .rendering(done: 0)
        task = Task { [weak self] in
            do {
                let url = try await Self.render(plan, store: store) { done in
                    self?.phase = .rendering(done: done)
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                self?.phase = .finished(url, bytes: bytes)
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .finished(let url, _) = phase { try? FileManager.default.removeItem(at: url) }
        phase = .idle
    }

    // MARK: Rendering

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The second engine, at `from`. Made off the main thread: getting
    /// there replays the tune up to it, which would stall the window's
    /// visualizer.
    private static func engine(_ plan: Plan, from: Double) async throws -> ClipRenderer {
        let config = ClipConfig(
            path: plan.track.path, subtune: plan.track.currentSong, engine: plan.engine,
            forceStereo2sid: plan.forceStereo2sid, fromMs: UInt64((from * 1000).rounded()),
            framesPerSecond: UInt32(framesPerSecond), sampleRate: UInt32(sampleRate))
        return try await Task.detached(priority: .userInitiated) { try ClipRenderer(config: config) }.value
    }

    /// The clip's first frame, as it will be posted: for the sheet's
    /// preview.
    static func still(_ plan: Plan, store: PlayerStore) async throws -> CGImage? {
        let began = Date()
        func ms(_ seconds: TimeInterval) -> String { "\(Int(seconds * 1000)) ms" }
        let size = plan.shape.size
        let fps = Double(framesPerSecond)
        let leadFrames = Int((min(plan.leadInSecs, plan.start) * fps).rounded(.down))
        let from = max(0, plan.start - Double(leadFrames) / fps)
        let renderer = try await engine(plan, from: from)
        let engineReady = Date()
        let feed = VisualizerFeed(core: renderer, frames: nil)
        guard let painter = await ClipPainters.make(plan.visual, size: size, theme: plan.theme, store: store, track: plan.track),
              let compositor = ClipCompositor(size: size, plan: plan)
        else { return nil }
        let painterReady = Date()
        var picture: MTLTexture?
        for _ in 0...leadFrames {
            try Task.checkCancellation()
            let audio = renderer.nextFrame()
            picture = await painter.paint(ClipMoment(feed: feed, tuneTime: audio.positionSecs,
                                               clock: audio.positionSecs, dt: 1 / fps))
            await Task.yield()
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary,
                            &buffer)
        guard let buffer else { return nil }
        compositor.compose(picture: picture, flipped: painter.isFlipped, into: buffer)
        print("Clip still: \(plan.visual.rawValue), engine \(ms(engineReady.timeIntervalSince(began))), "
              + "painter \(ms(painterReady.timeIntervalSince(engineReady))), "
              + "\(leadFrames + 1) frames \(ms(Date().timeIntervalSince(painterReady)))")
        let image = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func render(_ plan: Plan, store: PlayerStore, encoding: Encoding? = nil,
                       progress: (Double) -> Void) async throws -> URL {
        let encoding = encoding ?? .h264(bitRate: videoBitRate(plan.visual))
        let size = plan.shape.size
        let fps = Double(framesPerSecond)
        // Starts on a frame: the lead-in is a whole number of frames before
        // the clip, cut short by the tune's start.
        let leadFrames = Int((min(plan.leadInSecs, plan.start) * fps).rounded(.down))
        let from = max(0, plan.start - Double(leadFrames) / fps)
        let clipFrames = plan.length * framesPerSecond

        let renderer = try await engine(plan, from: from)
        let feed = VisualizerFeed(core: renderer, frames: nil)
        guard let painter = await ClipPainters.make(plan.visual, size: size, theme: plan.theme, store: store, track: plan.track)
        else { throw Failure(String(localized: "This visualizer can't make clips yet.")) }
        guard let compositor = ClipCompositor(size: size, plan: plan) else {
            throw Failure(String(localized: "The Mac's graphics couldn't be set up for the clip."))
        }
        try Task.checkCancellation()

        let url = FileManager.default.temporaryDirectory
            .appending(path: "Clips-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: plan.fileName)
            .deletingPathExtension().appendingPathExtension(encoding == .master ? "mov" : "mp4")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try ClipWriter(url: url, size: size, plan: plan, encoding: encoding)

        let fadeFrames = Int(fade * Double(sampleRate))
        let totalSamples = clipFrames * sampleRate / framesPerSecond
        var written = 0
        let started = Date()
        for k in 0..<(leadFrames + clipFrames) {
            try Task.checkCancellation()
            let audio = renderer.nextFrame()
            let moment = ClipMoment(feed: feed, tuneTime: audio.positionSecs,
                                    clock: audio.positionSecs, dt: 1 / fps)
            let picture = await painter.paint(moment)
            guard k >= leadFrames else { continue }
            let n = k - leadFrames
            var samples = audio.floats
            ClipWriter.fade(&samples, frames: Int(audio.count), from: written, total: totalSamples, length: fadeFrames)
            try await writer.append(frame: n, fps: framesPerSecond) { target in
                compositor.compose(picture: picture, flipped: painter.isFlipped, into: target)
            }
            try await writer.append(audio: samples, frames: Int(audio.count), at: written)
            written += Int(audio.count)
            if n % 6 == 0 { progress(Double(n) / Double(clipFrames)) }
            // Lets the sheet draw its progress.
            await Task.yield()
        }
        try await writer.finish()
        progress(1)
        print("Clip: \(plan.visual.rawValue) \(Int(size.width))×\(Int(size.height)), \(plan.length) s "
              + "+ \(String(format: "%.2f", Double(leadFrames) / fps)) s lead-in, rendered in "
              + "\(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        return url
    }
}

nonisolated extension ClipAudio {
    /// The samples, interleaved stereo.
    var floats: [Float] {
        let count = Int(self.count) * 2
        return samples.withUnsafeBytes { bytes in
            [Float](unsafeUninitializedCapacity: count) { floats, filled in
                UnsafeMutableRawBufferPointer(floats).copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[0..<count * 4]))
                filled = count
            }
        }
    }
}

// MARK: Compositing

/// Puts a frame together on the GPU, into the writer's pixel buffer: the
/// picture over the theme's background, Silicon's vignette, the card.
@MainActor
final class ClipCompositor {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let vignette: MTLTexture
    private let card: MTLTexture
    private let clear: MTLTexture
    private var cache: CVMetalTextureCache?
    private let background: SIMD4<Float>

    init?(size: CGSize, plan: ClipMaker.Plan) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "clipVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "clipComposite")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let clear = clipTexture(device, CGSize(width: 1, height: 1))
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.clear = clear
        let bg = plan.theme.background
        background = SIMD4(Float(bg.red), Float(bg.green), Float(bg.blue), 1)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        let points = CGSize(width: size.width / clipBackingScale, height: size.height / clipBackingScale)
        func picture(_ view: some View) -> MTLTexture {
            let renderer = ImageRenderer(content: view.frame(width: points.width, height: points.height))
            renderer.scale = clipBackingScale
            renderer.isOpaque = false
            guard let image = renderer.cgImage, let upload = TextureUpload(device: device, size: size) else { return clear }
            return upload.upload(image) ?? clear
        }
        card = picture(ClipCard(title: plan.title, composer: plan.composer, link: ClipCard.shown(plan.link),
                                height: points.height))
        vignette = plan.visual == .silicon ? picture(SiliconVignette()) : clear
    }

    /// Draws the frame into the pixel buffer.
    func compose(picture: MTLTexture?, flipped: Bool, into buffer: CVPixelBuffer) {
        guard let cache else { return }
        var made: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, CVPixelBufferGetWidth(buffer),
                                                  CVPixelBufferGetHeight(buffer), 0, &made)
        guard let made, let target = CVMetalTextureGetTexture(made), let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        struct Uniforms { var background: SIMD4<Float>; var flip: Float }
        var uniforms = Uniforms(background: background, flip: flipped ? 1 : 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(picture ?? clear, index: 0)
        encoder.setFragmentTexture(vignette, index: 1)
        encoder.setFragmentTexture(card, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
    }
}

/// The same vignette `SiliconView` lays over its scene.
private struct SiliconVignette: View {
    var body: some View {
        EllipticalGradient(stops: [.init(color: .clear, location: 0.42),
                                   .init(color: .black.opacity(0.45), location: 0.75),
                                   .init(color: .black.opacity(0.88), location: 1)],
                           center: .center, startRadiusFraction: 0, endRadiusFraction: 0.72)
    }
}

/// What's burned into every frame, bottom left: the title, the composer
/// and the tune's link, over a gradient that keeps them readable on any
/// visualizer (Nimbus's sky is pale); the Resonance mark bottom right.
/// Sizes are shares of the clip's height (design/clip-sharing).
struct ClipCard: View {
    let title: String
    let composer: String
    /// The link as shown: no "https://", and only the subtune's `s`.
    let link: String
    /// Points.
    let height: CGFloat

    /// What the picture shows of a share link: `useresonance.app/t/<code>`,
    /// with `?s=` for a subtune other than the start song; the site for a
    /// tune that can't be shared.
    static func shown(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "useresonance.app"
        }
        components.queryItems = components.queryItems?.filter { $0.name == "s" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        let host = components.host ?? "useresonance.app"
        return host + components.path + (components.query.map { "?" + $0 } ?? "")
    }

    var body: some View {
        let margin = height * 0.044
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                .frame(height: height * 0.38)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: height * 0.004) {
                    Text(title)
                        .font(.system(size: height * 0.044, weight: .bold))
                    Text(composer)
                        .font(.system(size: height * 0.028))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(link)
                        .font(.system(size: height * 0.022, design: .monospaced))
                        .foregroundStyle(Color(red: 0.61, green: 0.78, blue: 1))
                        .padding(.top, height * 0.006)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                Spacer(minLength: margin)
                HStack(spacing: height * 0.008) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: height * 0.036, height: height * 0.036)
                    Text(verbatim: "Resonance")
                        .font(.system(size: height * 0.022, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(margin)
        }
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Writing

/// The .mp4: H.264 and AAC, both stamped from the clip's frame and sample
/// counts.
@MainActor
final class ClipWriter {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput.PixelBufferReceiver
    private let audio: AVAssetWriterInput.SampleBufferReceiver
    private let format: CMAudioFormatDescription

    /// The video input's settings; the bench re-encodes its master with
    /// these, so what it measures is what clips get.
    nonisolated static func videoSettings(size: CGSize, encoding: ClipMaker.Encoding) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        switch encoding {
        case .h264(let bitRate):
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: ClipMaker.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: ClipMaker.framesPerSecond * 2,
            ]
        case .master:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
        }
        return settings
    }

    init(url: URL, size: CGSize, plan: ClipMaker.Plan, encoding: ClipMaker.Encoding) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: encoding == .master ? .mov : .mp4)
        // Neither input is real-time (the default): each takes data as
        // fast as the encoder does.
        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: Self.videoSettings(size: size, encoding: encoding))
        let pixels: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        ]
        guard let pixelAttributes = CVPixelBufferCreationAttributes(CVPixelBufferAttributes(rawAttributes: pixels)) else {
            throw ClipMaker.Failure(String(localized: "The clip couldn't be written."))
        }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: ClipMaker.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: ClipMaker.audioBitRate,
        ])
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(ClipMaker.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var made: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &made)
        guard let made else { throw ClipMaker.Failure(String(localized: "The clip's audio couldn't be set up.")) }
        format = made
        if encoding != .master { writer.metadata = Self.metadata(plan) }
        video = writer.inputPixelBufferReceiver(for: videoInput, pixelBufferAttributes: pixelAttributes)
        audio = writer.inputReceiver(for: audioInput)
        do {
            try writer.start()
        } catch {
            throw writer.error ?? error
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// The title, the composer, the release line and year, the HVSC path
    /// and the whole link, in the file. An .mp4 keeps only iTunes-style
    /// tags: the common and QuickTime ones are dropped without an error
    /// (checked with ffprobe, 2026-11-14). The link goes in the comment,
    /// which players and Finder show, and the path in the description, so
    /// the tune can be found without the share server; services that
    /// re-encode an upload strip all of it, so the link is burned in too.
    static func metadata(_ plan: ClipMaker.Plan) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            return item
        }
        var items = [item(.iTunesMetadataSongName, plan.title),
                     item(.iTunesMetadataArtist, plan.composer),
                     item(.iTunesMetadataEncodingTool, "Resonance \(Bundle.main.shortVersion)")]
        if let link = plan.link { items.append(item(.iTunesMetadataUserComment, link.absoluteString)) }
        if let released = plan.released { items.append(item(.iTunesMetadataCopyright, released)) }
        if let year = plan.year { items.append(item(.iTunesMetadataReleaseDate, year)) }
        if let path = plan.hvscPath { items.append(item(.iTunesMetadataDescription, "HVSC \(path)")) }
        return items
    }

    // The writer interleaves its inputs: either one stops taking data
    // while the other is behind. So nothing waits on one input while the
    // other has data queued; a frame and its audio queue up and go in as
    // each input takes them.
    private var pendingVideo: [(CVReadOnlyPixelBuffer, CMTime)] = []
    private var pendingAudio: [CMReadySampleBuffer<CMSampleBuffer.DynamicContent>] = []
    /// Two seconds of frames: well past the writer's half-second
    /// interleave, small enough to stay a few hundred megabytes at most.
    private let queueLimit = ClipMaker.framesPerSecond * 2

    /// Frame `n`, drawn by `draw` into a buffer from the writer's pool.
    func append(frame n: Int, fps: Int, draw: (CVPixelBuffer) -> Void) async throws {
        guard let pool = video.pixelBufferPool, let buffer = try? pool.makeMutablePixelBuffer() else {
            throw writerFailure
        }
        buffer.withUnsafeBuffer { draw($0) }
        pendingVideo.append((CVReadOnlyPixelBuffer(buffer), CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps))))
        try await drain(until: queueLimit)
    }

    /// `frames` stereo frames starting `at` frames into the clip.
    func append(audio samples: [Float], frames: Int, at start: Int) async throws {
        let bytes = frames * 8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                           blockBufferOut: &block)
        guard let block else { throw writerFailure }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                    offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(ClipMaker.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw writerFailure }
        pendingAudio.append(CMReadySampleBuffer(unsafeBuffer: sample))
        try await drain(until: queueLimit)
    }

    func finish() async throws {
        var videoDone = false, audioDone = false
        try await drain(until: 0) {
            // An input with nothing left is finished, which lets the other
            // one take the rest.
            if self.pendingVideo.isEmpty && !videoDone { self.video.finish(); videoDone = true }
            if self.pendingAudio.isEmpty && !audioDone { self.audio.finish(); audioDone = true }
        }
        if !videoDone { video.finish() }
        if !audioDone { audio.finish() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writerFailure }
    }

    /// Hands queued data to whichever input takes it, waiting only while a
    /// queue is longer than `limit`. Gives up after ten seconds without
    /// progress rather than hang.
    private func drain(until limit: Int, whenStuck: () -> Void = {}) async throws {
        var stalled = ContinuousClock.now
        while true {
            if writer.status == .failed { throw writerFailure }
            var moved = false
            // Each returns false while its input isn't ready for more.
            do {
                while let next = pendingVideo.first, try video.appendImmediately(next.0, with: next.1) {
                    pendingVideo.removeFirst()
                    moved = true
                }
                while let sample = pendingAudio.first, try audio.appendImmediately(sample) {
                    pendingAudio.removeFirst()
                    moved = true
                }
            } catch {
                throw writer.error ?? error
            }
            if pendingVideo.count <= limit && pendingAudio.count <= limit { return }
            if moved { stalled = .now; continue }
            whenStuck()
            if ContinuousClock.now - stalled > .seconds(10) { throw writerFailure }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private var writerFailure: Error {
        writer.error ?? ClipMaker.Failure(String(localized: "The clip couldn't be written."))
    }

    /// The player's raised-cosine fade over the clip's first and last
    /// `length` frames, so its ends don't click. `from` is where `samples`
    /// starts in the clip, `total` the clip's length, both in frames.
    nonisolated static func fade(_ samples: inout [Float], frames: Int, from: Int, total: Int, length: Int) {
        guard length > 0 else { return }
        for i in 0..<frames {
            let pos = from + i
            let edge = min(pos, total - 1 - pos)
            guard edge < length else { continue }
            let gain = Float(0.5 - 0.5 * cos(Double.pi * Double(max(edge, 0)) / Double(length)))
            samples[i * 2] *= gain
            samples[i * 2 + 1] *= gain
        }
    }
}

private extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}
