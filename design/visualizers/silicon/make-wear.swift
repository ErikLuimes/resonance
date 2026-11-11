// Makes the Silicon visualizer's wear texture
// (apple/Resonance/Scenes/SiliconWear.lzfse): four kinds of unevenness in
// one 512 × 512 picture, each repeating without a seam. Red is fine
// grain, green scratches, blue large blotches, alpha specks. The app's
// aged materials (SiliconWear.swift) read it.
//
//   swift make-wear.swift <output file>
//
// It's made the same way every time, so it's made here once and shipped,
// not worked out each time the app opens the visualizer (that took a
// third of a second). The file is in the same form as the dies' layers:
// the width and height as two little-endian 32-bit numbers, then the
// RGBA bytes compressed with LZFSE.
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: swift make-wear.swift <output>")
    exit(2)
}

/// Numbers between 0 and 1 that are the same every run.
struct Scatter {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }

    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
}

let n = 512
var random = Scatter(seed: 1982)
/// Smooth noise that repeats every `cells` cells across the texture.
func layer(cells: Int) -> [Float] {
    let lattice = (0..<cells * cells).map { _ in Float(random.next()) }
    var out = [Float](repeating: 0, count: n * n)
    for y in 0..<n {
        let fy = Float(y) / Float(n) * Float(cells)
        let y0 = Int(fy) % cells, y1 = (y0 + 1) % cells
        var ty = fy - fy.rounded(.down)
        ty = ty * ty * (3 - 2 * ty)
        for x in 0..<n {
            let fx = Float(x) / Float(n) * Float(cells)
            let x0 = Int(fx) % cells, x1 = (x0 + 1) % cells
            var tx = fx - fx.rounded(.down)
            tx = tx * tx * (3 - 2 * tx)
            let top = lattice[y0 * cells + x0] + (lattice[y0 * cells + x1] - lattice[y0 * cells + x0]) * tx
            let bottom = lattice[y1 * cells + x0] + (lattice[y1 * cells + x1] - lattice[y1 * cells + x0]) * tx
            out[y * n + x] = top + (bottom - top) * ty
        }
    }
    return out
}
func mixed(_ cells: [Int]) -> [Float] {
    var out = [Float](repeating: 0, count: n * n)
    var weight: Float = 1, total: Float = 0
    for count in cells {
        let noise = layer(cells: count)
        for i in 0..<n * n { out[i] += noise[i] * weight }
        total += weight
        weight *= 0.55
    }
    return out.map { $0 / total }
}
let grain = mixed([64, 128, 256])
let blotches = mixed([4, 8, 16, 32])

// Scratches and specks are drawn: thin lines, mostly one way with
// a few across, and dots of a few sizes. Each is drawn again
// shifted by the texture's size, so it carries over the edges.
func drawn(_ draw: (CGContext) -> Void) -> [Float] {
    var bytes = [UInt8](repeating: 0, count: n * n)
    bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return }
        for dx in [-n, 0, n] {
            for dy in [-n, 0, n] {
                context.saveGState()
                context.translateBy(x: CGFloat(dx), y: CGFloat(dy))
                draw(context)
                context.restoreGState()
            }
        }
    }
    return bytes.map { Float($0) / 255 }
}
let strokes = (0..<150).map { _ -> (CGPoint, CGPoint, CGFloat, CGFloat) in
    let from = CGPoint(x: random.next() * Double(n), y: random.next() * Double(n))
    // Most run nearly along x, as a part sliding in a tube leaves them.
    let angle = random.next() < 0.75 ? (random.next() - 0.5) * 0.35 : random.next() * .pi
    let length = 12 + random.next() * random.next() * 260
    return (from, CGPoint(x: from.x + cos(angle) * length, y: from.y + sin(angle) * length),
            0.5 + random.next() * 1.1, 0.25 + random.next() * 0.75)
}
let scratches = drawn { context in
    for (from, to, width, strength) in strokes {
        context.setStrokeColor(CGColor(gray: 1, alpha: strength))
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
    }
}
let dots = (0..<900).map { _ in
    (CGPoint(x: random.next() * Double(n), y: random.next() * Double(n)), 0.4 + random.next() * random.next() * 2.4,
     0.3 + random.next() * 0.7)
}
let specks = drawn { context in
    for (center, radius, strength) in dots {
        context.setFillColor(CGColor(gray: 1, alpha: strength))
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

var pixels = [UInt8](repeating: 0, count: n * n * 4)
for i in 0..<n * n {
    pixels[i * 4] = UInt8(max(0, min(255, grain[i] * 255)))
    pixels[i * 4 + 1] = UInt8(max(0, min(255, scratches[i] * 255)))
    // Stretched, so there are clear patches and clean ones.
    pixels[i * 4 + 2] = UInt8(max(0, min(255, (blotches[i] - 0.3) / 0.4 * 255)))
    pixels[i * 4 + 3] = UInt8(max(0, min(255, specks[i] * 255)))
}

var header = Data()
for value in [UInt32(n), UInt32(n)] { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
let compressed = try (Data(pixels) as NSData).compressed(using: .lzfse) as Data
try (header + compressed).write(to: URL(fileURLWithPath: arguments[1]))
print("wrote \(arguments[1]): \(n) × \(n), \((header.count + compressed.count) / 1024) KB")
