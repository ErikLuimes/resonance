// Cuts cells out of a shot of the Visualizer Pictures window and writes each
// as a HEIC of the given size. Run by visualizer-pictures.sh (sips can't be
// trusted with a crop at the shot's left or top edge).
//
//   swift visualizer-pictures-cut.swift <shot.png> <columns> <rows> <width> <height> <index>=<out.heic>…
import AppKit
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count > 6,
      let columns = Int(arguments[2]), let rows = Int(arguments[3]),
      let width = Int(arguments[4]), let height = Int(arguments[5]),
      let shot = NSImage(contentsOfFile: arguments[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("usage: visualizer-pictures-cut.swift <shot.png> <columns> <rows> <width> <height> <index>=<out.heic>…\n".utf8))
    exit(2)
}
let cell = CGSize(width: shot.width / columns, height: shot.height / rows)
for pair in arguments.dropFirst(6) {
    let parts = pair.split(separator: "=", maxSplits: 1)
    guard parts.count == 2, let index = Int(parts[0]), index < columns * rows else { fatalError("bad cell: \(pair)") }
    // A CGImage's rows count from the top, like the window's.
    let rect = CGRect(x: CGFloat(index % columns) * cell.width, y: CGFloat(index / columns) * cell.height,
                      width: cell.width, height: cell.height)
    guard let cut = shot.cropping(to: rect),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fatalError("can't cut \(pair)") }
    context.interpolationQuality = .high
    context.draw(cut, in: CGRect(x: 0, y: 0, width: width, height: height))
    let url = URL(fileURLWithPath: String(parts[1]))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)
    else { fatalError("can't write \(url.path)") }
    // A tenth of a PNG's size, and there are a dozen for every theme.
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("can't write \(url.path)") }
}
