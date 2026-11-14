import SwiftUI
import AppKit
struct Spec: View {
    let t: Double
    var body: some View {
        Canvas { gc, size in
            for v in 0..<3 {
                var p = Path(); p.move(to: .init(x: 0, y: size.height))
                for k in 0...512 { p.addLine(to: .init(x: size.width * Double(k) / 512, y: size.height * (0.5 + 0.4 * sin(Double(k) * 0.05 + t * Double(v + 1))))) }
                p.addLine(to: .init(x: size.width, y: size.height))
                let c: Color = [.orange, .pink, .cyan][v]
                gc.fill(p, with: .linearGradient(.init(colors: [c.opacity(0.6), c.opacity(0)]), startPoint: .zero, endPoint: .init(x: 0, y: size.height)))
                gc.stroke(p, with: .color(c), lineWidth: 2)
            }
        }.frame(width: 540, height: 540).background(.black)
    }
}
let lib = ShaderLibrary(url: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fx.metallib"))
struct Fx: View {
    let t: Double
    var body: some View {
        Rectangle().fill(.black).frame(width: 540, height: 540)
            .colorEffect(lib.tint(.float(Float(t))))
    }
}
func lit(_ img: CGImage) -> Int {
    let rep = NSBitmapImageRep(cgImage: img); var n = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 8) { for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
        if let c = rep.colorAt(x: x, y: y), c.redComponent + c.greenComponent + c.blueComponent > 0.3 { n += 1 } } }
    return n
}
MainActor.assumeIsolated {
    for (name, make) in [("Canvas", { (t: Double) in AnyView(Spec(t: t)) }), ("colorEffect", { AnyView(Fx(t: $0)) })] {
        let r0 = ImageRenderer(content: make(0)); r0.scale = 2
        guard let img = r0.cgImage else { print(name, "no image"); continue }
        print(name, "size", img.width, img.height, "lit samples", lit(img), "of", (img.width/8)*(img.height/8))
        let n = 120; let s = Date()
        let ctx = CGContext(data: nil, width: 1080, height: 1080, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!; for i in 0..<n { let r = ImageRenderer(content: make(Double(i)/60)); r.scale = 2; let im = r.cgImage!; ctx.draw(im, in: CGRect(x: 0, y: 0, width: 1080, height: 1080)) }
        print(name, String(format: "%.2f ms per 1080x1080 frame", Date().timeIntervalSince(s) / Double(n) * 1000))
    }
}
