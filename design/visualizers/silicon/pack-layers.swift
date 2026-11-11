// Packs a SID's mask layers into the one file the Silicon visualizer
// loads for it (apple/Resonance/Scenes/SIDDie6581R3.lzfse and
// SIDDie8580R5.lzfse).
//
//   swift pack-layers.swift <6581R3 or 8580R5> <folder of the layer PNGs> <output file>
//
// The layers are Tommi Lempinen's MOS_6581R3_layer_bitmaps.zip and
// MOS_8580R5_layer_bitmaps.zip (see README.md here): one-bit PNGs,
// 16820 × 14629 for the 6581 and 15012 × 14202 for the 8580. This scales each to a
// quarter of that, so a pixel holds how much of it the layer covers, and
// writes them side by side as RGBA bytes (diffusion, polysilicon, metal,
// contacts), compressed with LZFSE. The file starts with the width and
// height as two little-endian 32-bit numbers.
import CoreGraphics
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count == 4, ["6581R3", "8580R5"].contains(arguments[1]) else {
    print("usage: swift pack-layers.swift <6581R3 or 8580R5> <layers folder> <output>")
    exit(2)
}
let chip = arguments[1]
let folder = URL(fileURLWithPath: arguments[2])
let scale = 4

/// A layer as bytes, 0–255 for how much of each pixel it covers.
func layer(_ name: String) -> (bytes: [UInt8], width: Int, height: Int) {
    let url = folder.appendingPathComponent("MOS_\(chip)_\(name).png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("can't read \(url.path)")
        exit(1)
    }
    let width = image.width / scale, height = image.height / scale
    var bytes = [UInt8](repeating: 0, count: width * height)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    let covered = bytes.reduce(0) { $0 + Int($1) } / 255
    print("\(name): \(image.width) × \(image.height) → \(width) × \(height), \(100 * covered / bytes.count)% covered")
    return (bytes, width, height)
}

let diffusion = layer("diffusion"), metal = layer("metal")
// The 6581's polysilicon was redrawn once; the 8580's is in two files.
var poly = layer(chip == "6581R3" ? "poly_updated_revision" : "poly_main")
if chip == "8580R5" {
    let more = layer("poly_additional")
    for i in poly.bytes.indices { poly.bytes[i] = min(poly.bytes[i], more.bytes[i]) }
}
let contact = layer("contact"), buried = layer("buried")
let width = diffusion.width, height = diffusion.height
var packed = [UInt8](repeating: 0, count: width * height * 4)
for i in 0..<width * height {
    // The masks are drawn dark on light: a covered pixel is 0.
    packed[i * 4] = 255 - diffusion.bytes[i]
    packed[i * 4 + 1] = 255 - poly.bytes[i]
    packed[i * 4 + 2] = 255 - metal.bytes[i]
    // Contacts through the oxide in full; buried ones, under it, at half.
    packed[i * 4 + 3] = max(255 - contact.bytes[i], (255 - buried.bytes[i]) / 2)
}
var header = Data()
for value in [UInt32(width), UInt32(height)] { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
let compressed = try (Data(packed) as NSData).compressed(using: .lzfse) as Data
try (header + compressed).write(to: URL(fileURLWithPath: arguments[3]))
print("wrote \(arguments[3]): \(width) × \(height), \((header.count + compressed.count) / 1024) KB")
