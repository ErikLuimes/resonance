import AppKit
import SceneKit
import simd

/// Static desk props. The printing is original artwork based on late-1980s
/// ZZAP!64 and the layout of RUN #77, May 1990, p. 8.
@MainActor
enum DeskMagazines {
    static func place(in root: SCNNode) {
        let stack = SCNNode()
        stack.name = "zzap64_stack"
        stack.simdPosition = [-4.49, 0.014, 2.04]
        root.addChildNode(stack)

        let issues: [(angle: Float, offset: SIMD3<Float>, date: String, color: UInt32)] = [
            (-0.17, [0.02, 0.00, 0.00], "OCTOBER 1988", 0x43576f),
            ( 0.14, [0.15, 0.055, -0.04], "NOVEMBER 1988", 0x6f563e),
            (-0.08, [-0.05, 0.112, 0.12], "DECEMBER 1988", 0x7b3d43),
        ]
        for (index, issue) in issues.enumerated() {
            let copy = SCNNode()
            copy.simdPosition = issue.offset
            copy.simdEulerAngles.y = issue.angle
            stack.addChildNode(copy)
            let width: Float = 1.78
            let depth: Float = 2.35
            copy.addChildNode(paperBlock(width: width, depth: depth, height: 0.052))
            copy.addChildNode(sheet(width: width + 0.027, depth: depth + 0.028,
                                    image: cover(date: issue.date, color: issue.color, seed: UInt64(index + 2))) { u, v in
                0.053 + 0.021 * u * u + 0.035 * pow(u * v, 8)
            })
        }

        let run = SCNNode()
        run.name = "run_77_open_at_8"
        // Behind the joystick, both pages stay inside the compact camera crop.
        // The cables reach 0.144 beneath the spread; rest the page block just above them.
        run.simdPosition = [3.84, 0.148, -0.92]
        run.simdEulerAngles.y = 0.15
        root.addChildNode(run)
        let width: Float = 3.24
        let depth: Float = 2.31
        run.addChildNode(paperBlock(width: width - 0.055, depth: depth - 0.042, height: 0.048))
        run.addChildNode(sheet(width: width, depth: depth, image: spread()) { u, v in
            let edge = abs(2 * u - 1)
            let hump = 0.096 * sin(.pi * pow(edge, 0.57))
            let curl = 0.068 * pow(edge * v, 7) + 0.026 * pow(edge * (1 - v), 5)
            return 0.052 + hump + curl
        })
    }

    private static func paperBlock(width: Float, depth: Float, height: Float) -> SCNNode {
        let box = SCNBox(width: CGFloat(width), height: CGFloat(height), length: CGFloat(depth), chamferRadius: 0.007)
        box.materials = [pageEdges]
        let node = SCNNode(geometry: box)
        node.simdPosition.y = height / 2
        return node
    }

    private static let pageEdges: SCNMaterial = {
        let paper = SCNMaterial()
        paper.diffuse.contents = artwork(width: 144, height: 24) {
            fill(0, 0, 144, 24, 0xbbab8b)
            for row in [2, 5, 9, 15, 17, 22] { fill(0, CGFloat(row), 144, 1, 0x857762, alpha: 0.56) }
        }
        paper.roughness.contents = 0.94
        return paper
    }()

    private static func sheet(width: Float, depth: Float, image: NSImage,
                              height: (Float, Float) -> Float) -> SCNNode {
        // An even count puts an actual vertex row at the open magazine's fold.
        let columns = 18, rows = 12
        var positions: [SCNVector3] = [], normals: [SCNVector3] = [], uv: [CGPoint] = []
        for row in 0...rows {
            let v = Float(row) / Float(rows)
            for column in 0...columns {
                let u = Float(column) / Float(columns)
                let x = (u - 0.5) * width + 0.011 * sin(v * 17) * pow(abs(2 * u - 1), 6)
                let z = (v - 0.5) * depth + 0.009 * sin(u * 29) * pow(abs(2 * v - 1), 6)
                let du = (height(min(1, u + 0.006), v) - height(max(0, u - 0.006), v)) / (0.012 * width)
                let dv = (height(u, min(1, v + 0.006)) - height(u, max(0, v - 0.006))) / (0.012 * depth)
                positions.append(SCNVector3(x, height(u, v), z))
                normals.append(SCNVector3(simd_normalize(SIMD3<Float>(-du, 1, -dv))))
                uv.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
            }
        }
        var triangles: [UInt16] = []
        for row in 0..<rows {
            for col in 0..<columns {
                let a = UInt16(row * (columns + 1) + col)
                let b = a + UInt16(columns + 1)
                triangles += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        let mesh = SCNGeometry(sources: [.init(vertices: positions), .init(normals: normals), .init(textureCoordinates: uv)],
                               elements: [.init(indices: triangles, primitiveType: .triangles)])
        let ink = SCNMaterial()
        ink.lightingModel = .physicallyBased
        ink.diffuse.contents = image
        ink.diffuse.mipFilter = .linear
        ink.roughness.contents = 0.86
        mesh.materials = [ink]
        return SCNNode(geometry: mesh)
    }

    private static func cover(date: String, color background: UInt32, seed: UInt64) -> NSImage {
        artwork(width: 360, height: 480) {
            fill(0, 0, 360, 480, 0xd2b78c)
            fill(4, 4, 352, 472, background)
            fill(10, 108, 340, 325, 0x282b43)
            // A screen-printed sci-fi illustration and packed newsstand typography.
            color(0xc2845d).setFill()
            NSBezierPath(ovalIn: CGRect(x: 141, y: 139, width: 166, height: 166)).fill()
            polygon([(10, 307), (85, 231), (124, 291), (209, 210), (349, 303), (349, 434), (10, 434)], 0x526173)
            polygon([(10, 362), (99, 304), (165, 363), (249, 292), (350, 348), (350, 434), (10, 434)], 0x38465a)
            polygon([(52, 310), (197, 231), (292, 245), (221, 273), (175, 308)], 0xe0bd81)
            polygon([(99, 282), (191, 246), (238, 249), (193, 267)], 0x536f7e)
            polygon([(52, 310), (175, 308), (151, 328), (71, 329)], 0xa45d4b)
            text("ZZAP!64", x: 17, y: 15, size: 72, weight: .black, ink: 0x202237, kern: -4)
            text("ZZAP!64", x: 14, y: 11, size: 72, weight: .black, ink: 0xebd18e, kern: -4)
            text(date, x: 18, y: 90, size: 12, weight: .heavy, ink: 0xf4dbac)
            text("C64 GAMES", x: 245, y: 90, size: 12, weight: .heavy, ink: 0xf4dbac)
            fill(13, 365, 200, 58, 0xa15042)
            text("ARCADE", x: 21, y: 364, size: 29, weight: .black, ink: 0xf0d095)
            text("ACTION SPECIAL", x: 23, y: 396, size: 16, weight: .heavy, ink: 0xf0d095)
            text("REVIEWS   •   TIPS   •   HIGH SCORES", x: 17, y: 441, size: 14, weight: .heavy, ink: 0xf5dcaa)
            wear(width: 360, height: 480, seed: seed, amount: 1)
        }
    }

    private static func spread() -> NSImage {
        artwork(width: 800, height: 560) {
            fill(0, 0, 800, 560, 0xd9c6a0)
            fill(8, 9, 784, 539, 0xe5d4b1)
            text("MAGIC", x: 26, y: 16, size: 67, weight: .black, ink: 0x2e7070, kern: -3)
            text("Type-in tips and tricks", x: 31, y: 93, size: 16, weight: .medium, ink: 0x433e36)
            fill(29, 119, 343, 2, 0x5a8177)
            text("$593  Raster Stripes 64", x: 29, y: 129, size: 24, weight: .bold, ink: 0x222e2c)
            text("JEFFREY PANICI", x: 31, y: 163, size: 11, weight: .semibold, ink: 0x565448)
            printLines(x: 30, y: 190, width: 164, count: 10)
            printLines(x: 207, y: 190, width: 165, count: 11)
            fill(28, 290, 346, 99, 0xd3c3a0)
            let commands = [
                "10 FOR T=49152 TO 49273:READ D:POKE T,D:NEXT",
                "20 DATA 72,138,72,152,72,164,2,200",
                "SYS 49196,C1,C2,C3,C4",
                "POKE 56591,81",
            ]
            for (row, command) in commands.enumerated() {
                text(command, x: 37, y: CGFloat(298 + row * 20), size: 12.5, weight: .medium,
                     ink: 0x34372e, mono: true)
            }
            polygon([(34, 355), (192, 353), (199, 355), (140, 357), (33, 357)], 0x506e89)
            text("Magic Square 128", x: 29, y: 407, size: 19, weight: .bold, ink: 0x343c34)
            printLines(x: 30, y: 440, width: 160, count: 9)
            printLines(x: 205, y: 410, width: 167, count: 12)
            text("8   RUN  •  MAY 1990", x: 30, y: 525, size: 12, weight: .bold, ink: 0x524d40)

            text("RUN", x: 425, y: 27, size: 34, weight: .black, ink: 0x3d6865, kern: -1)
            fill(425, 78, 346, 1, 0x5a8177)
            printLines(x: 425, y: 94, width: 161, count: 33)
            printLines(x: 606, y: 94, width: 165, count: 11)
            fill(606, 203, 158, 98, 0x686d67)
            for (row, ink) in [0x547c84, 0x9a7160, 0xb6a165, 0x68768a, 0x4f697c].enumerated() {
                fill(615, CGFloat(214 + row * 15), 139, 12, UInt32(ink))
            }
            printLines(x: 606, y: 319, width: 166, count: 18)
            text("RUN   9", x: 723, y: 525, size: 12, weight: .bold, ink: 0x524d40)
            for i in 0..<12 {
                fill(CGFloat(388 + i), 0, 1, 560, 0x574637, alpha: CGFloat(i) * 0.013)
                fill(CGFloat(400 + i), 0, 1, 560, 0x574637, alpha: CGFloat(12 - i) * 0.013)
            }
            wear(width: 800, height: 560, seed: 77, amount: 0.75)
        }
    }

    private static func printLines(x: CGFloat, y: CGFloat, width: CGFloat, count: Int) {
        for line in 0..<count {
            let length = line % 7 == 6 ? 0.44 + CGFloat(line % 4) * 0.1 : 0.92 + CGFloat(line % 3) * 0.04
            fill(x, y + CGFloat(line) * 9, width * length, 1.8, 0x514b3c, alpha: 0.53)
        }
    }

    private static func wear(width: CGFloat, height: CGFloat, seed: UInt64, amount: CGFloat) {
        var state = seed
        func noise() -> CGFloat {
            state = 2862933555777941757 &* state &+ 3037000493
            return CGFloat((state >> 32) & 0xffff) / 65_535
        }
        for _ in 0..<420 {
            let x = noise() * width
            let y = noise() * height
            let edge = min(x, width - x, y, height - y) < 16
            fill(x, y, noise() * (edge ? 7 : 2.7) + 0.5, noise() * 2 + 0.4,
                 edge ? 0xd8c19c : 0x5c482f, alpha: (edge ? 0.39 : 0.18) * amount)
        }
        // A broken crease on the upper right, visible in the ink as well as the mesh.
        polygon([(width - 44, 0), (width - 39, 1), (width - 1, 42), (width, 46)], 0xc4af8c, alpha: 0.65)
        polygon([(0, height - 14), (14, height - 1), (37, height), (0, height)], 0xab997c, alpha: 0.5)
    }

    private static func artwork(width: CGFloat, height: CGFloat, _ draw: () -> Void) -> NSImage {
        // Rasterize once when the cached scene loads, rather than drawing in its frame loop.
        let image = NSImage(size: CGSize(width: width, height: height))
        image.lockFocusFlipped(true)
        draw()
        image.unlockFocus()
        return image
    }

    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    private static func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32, alpha: CGFloat = 1) {
        color(hex, alpha: alpha).setFill()
        NSBezierPath(rect: CGRect(x: x, y: y, width: w, height: h)).fill()
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)], _ hex: UInt32, alpha: CGFloat = 1) {
        let shape = NSBezierPath()
        shape.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for (x, y) in points.dropFirst() { shape.line(to: CGPoint(x: x, y: y)) }
        shape.close()
        color(hex, alpha: alpha).setFill()
        shape.fill()
    }

    private static func text(_ label: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight,
                             ink: UInt32, kern: CGFloat = 0, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        (label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
            .font: font, .foregroundColor: color(ink), .kern: kern,
        ])
    }
}
