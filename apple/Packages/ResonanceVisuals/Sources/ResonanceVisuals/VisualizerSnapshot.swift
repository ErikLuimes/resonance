import CoreGraphics
import Foundation
import Metal
import simd

/// A rendered visualizer frame as an image, for tests and checks.
public nonisolated enum VisualizerSnapshot {
    /// `texture` (bgra8Unorm, premultiplied, shared storage) over `background`.
    public static func image(of texture: MTLTexture, background: SIMD3<Float>) -> CGImage? {
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let under = [background.z, background.y, background.x].map { $0 * 255 }
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Float(bytes[i + 3]) / 255
            for c in 0..<3 {
                bytes[i + c] = UInt8(min(255, Float(bytes[i + c]) + under[c] * (1 - a)))
            }
            bytes[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
