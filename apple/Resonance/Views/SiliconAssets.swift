import Foundation
import Metal

/// The Silicon visualizer's two textures, loaded once and kept: the
/// package's wear and a die's layers (61 MB to unpack and upload). Both
/// ship as files. `warm` loads them away from the main thread, so
/// opening the visualizer doesn't hold the app up; whoever asks first
/// without warming just loads them where it stands.
///
/// The wear is kept for good: it's small. Only the last die's layers are
/// kept, since each is large and a tune has one chip.
nonisolated enum SiliconAssets {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var wearTexture: MTLTexture?
    nonisolated(unsafe) private static var layersTexture: (name: String, texture: MTLTexture)?

    /// `url` is the app's own file unless given, as a harness outside the
    /// app does.
    static func wear(device: MTLDevice?, from url: URL? = nil) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if let wearTexture { return wearTexture }
        wearTexture = load(url ?? Bundle.main.url(forResource: SiliconWear.file, withExtension: "lzfse"), device: device)
        return wearTexture
    }

    /// `die`'s layers from the app's bundle.
    static func layers(_ die: SiliconDie, device: MTLDevice?) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if let layersTexture, layersTexture.name == die.layers { return layersTexture.texture }
        guard let texture = load(Bundle.main.url(forResource: die.layers, withExtension: "lzfse"), device: device) else { return nil }
        layersTexture = (die.layers, texture)
        return texture
    }

    /// Loads what `die`'s scene needs, on another thread, and returns
    /// when it's there.
    static func warm(_ die: SiliconDie) async {
        await Task.detached(priority: .userInitiated) {
            let device = MTLCreateSystemDefaultDevice()
            _ = wear(device: device)
            _ = layers(die, device: device)
        }.value
    }

    /// Packed layers (design/visualizers/silicon/pack-layers.swift) as a
    /// texture with all its smaller copies.
    static func load(_ url: URL?, device: MTLDevice?) -> MTLTexture? {
        guard let url, let device, let file = try? Data(contentsOf: url), file.count > 8 else { return nil }
        let width = Int(file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian)
        let height = Int(file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }.littleEndian)
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              let pixels = try? (file.dropFirst(8) as NSData).decompressed(using: .lzfse) as Data,
              pixels.count == width * height * 4 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        if let commands = device.makeCommandQueue()?.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
        }
        return texture
    }
}
