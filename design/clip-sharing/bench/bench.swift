// Clip-sharing measurements: Metal offscreen into the encoder's own pixel
// buffers, and hardware H.264/HEVC through AVAssetWriter with an AAC track.
// SwiftUI through ImageRenderer is imagerenderer.swift.
import AVFoundation
import CoreVideo
import Metal

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vtx(uint id [[vertex_id]]) {
    float2 q = float2((id << 1) & 2, id & 2);
    V v; v.p = float4(q * 2 - 1, 0, 1); v.uv = q; return v;
}
// Busy enough to look like a visualizer: 24,000 particles is a vertex job,
// this stands in with a per-pixel field of moving points.
fragment float4 frag(V in [[stage_in]], constant float &t [[buffer(0)]]) {
    float3 c = 0;
    for (int i = 0; i < 48; i++) {
        float a = float(i) * 0.37 + t * (0.3 + 0.01 * i);
        float2 p = 0.5 + 0.35 * float2(cos(a * 1.3), sin(a * 0.9 + i));
        float d = length(in.uv - p);
        c += float3(0.9, 0.5 + 0.01 * i, 0.3) * 0.0009 / (d * d + 0.0004);
    }
    return float4(c, 1);
}
"""

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let library = try! device.makeLibrary(source: shaderSource, options: nil)
let pd = MTLRenderPipelineDescriptor()
pd.vertexFunction = library.makeFunction(name: "vtx")
pd.fragmentFunction = library.makeFunction(name: "frag")
pd.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try! device.makeRenderPipelineState(descriptor: pd)
var cache: CVMetalTextureCache?
CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)

func draw(into pb: CVPixelBuffer, t: Float) -> Double {
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    var cvTex: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(nil, cache!, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
    let tex = CVMetalTextureGetTexture(cvTex!)!
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = tex
    rp.colorAttachments[0].loadAction = .dontCare
    rp.colorAttachments[0].storeAction = .store
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
    enc.setRenderPipelineState(pipeline)
    var tt = t
    enc.setFragmentBytes(&tt, length: 4, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    return cb.gpuEndTime - cb.gpuStartTime
}

func bench(codec: AVVideoCodecType, w: Int, h: Int, fps: Int, seconds: Int, bitrate: Int) {
    let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        .appendingPathComponent("clip-\(codec.rawValue)-\(w)x\(h)-\(fps).mp4")
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                                          AVVideoExpectedSourceFrameRateKey: fps,
                                          AVVideoMaxKeyFrameIntervalKey: fps * 2],
    ])
    video.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ])
    let rate = 48_000.0
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ])
    audio.expectsMediaDataInRealTime = false
    writer.add(video); writer.add(audio)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 8,
        mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                   magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)

    let frames = fps * seconds
    let samplesPerFrame = Int(rate) / fps
    var gpu = 0.0, maxGPU = 0.0
    var phase = 0.0
    let start = Date()
    for i in 0..<frames {
        while !video.isReadyForMoreMediaData { usleep(200) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let g = draw(into: pb!, t: Float(i) / Float(fps))
        gpu += g; maxGPU = max(maxGPU, g)
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))

        // The audio for the same frame, stamped by sample count.
        while !audio.isReadyForMoreMediaData { usleep(200) }
        var pcm = [Float](repeating: 0, count: samplesPerFrame * 2)
        for s in 0..<samplesPerFrame {
            phase += 2 * .pi * 440 / rate
            pcm[s * 2] = Float(sin(phase)) * 0.2; pcm[s * 2 + 1] = pcm[s * 2]
        }
        var block: CMBlockBuffer?
        let bytes = pcm.count * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!,
            sampleCount: samplesPerFrame, presentationTimeStamp: CMTime(value: CMTimeValue(i * samplesPerFrame), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &sb)
        audio.append(sb!)
    }
    video.markAsFinished(); audio.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    let wall = Date().timeIntervalSince(start)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print(String(format: "%@ %dx%d@%d: %.1f s of video in %.2f s (%.1fx realtime), GPU %.2f ms avg / %.2f max per frame, %.1f MB",
                 codec.rawValue, w, h, fps, Double(seconds), wall, Double(seconds) / wall, gpu / Double(frames) * 1000,
                 maxGPU * 1000, Double(size) / 1_000_000), writer.status == .completed ? "" : "FAILED \(String(describing: writer.error))")
}

for (w, h) in [(1080, 1080), (1728, 1080), (1920, 1200)] {
    for codec in [AVVideoCodecType.h264, .hevc] {
        bench(codec: codec, w: w, h: h, fps: 60, seconds: 15, bitrate: 12_000_000)
    }
}
bench(codec: .h264, w: 1080, h: 1080, fps: 30, seconds: 15, bitrate: 8_000_000)
