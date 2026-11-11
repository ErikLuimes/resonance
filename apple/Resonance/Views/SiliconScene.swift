import AppKit
import SceneKit
import simd

/// The Silicon visualizer's scene: a 6581 in its ceramic package with the
/// lid off, built to scale around the real die. The die is the chip's own
/// mask layers (`SiliconDie`, Scenes/SIDDie6581R3.lzfse) as a lit
/// material: glassy oxide over the colored silicon, aluminum that glints
/// as the camera moves. It sits in the package's gold well with a bond
/// wire from each pad up to its finger on the shelf, and the package's 28
/// gold pins run down its sides. Everything is in die widths: the die is
/// 1 across, the package about 7.4 long.
///
/// What's working is lit (`SiliconOverlay`): bits glow along their own
/// wiring, beads of light run the signals' ways, the three voices'
/// waveforms and the output's float just above the die, and each pin's
/// wire, finger and leg glow as the pin is used.
///
/// The camera starts on the whole package, comes down into the cavity,
/// hovers over one part of the die after another, and pulls back out.
final class SiliconScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let overlay: SiliconOverlay
    /// False when the die's layers couldn't be loaded.
    private(set) var isReady = false

    var voiceColors: [SIMD3<Float>] = Array(repeating: SIMD3(1, 1, 1), count: 3) {
        didSet { overlay.voiceColors = voiceColors }
    }

    // The package, in die widths. y is up; the die's top is at 0.
    static let bodyLength: Float = 7.4
    static let bodyWidth: Float = 2.9
    static let bodyTop: Float = 0.34
    static let bodyBottom: Float = -0.55
    static let shelf: Float = 0.1
    static let wellFloor: Float = -0.07
    static let wellHalf = SIMD2<Float>(0.64, 0.57)
    static let cavityHalf = SIMD2<Float>(1.18, 1.05)
    /// About 25 microns across on a die about 5 mm wide, as bond wire is.
    static let wireRadius: Float = 0.0025


    private let dieMaterial = SCNMaterial()
    /// The package's age (`SiliconWear`).
    private let wear: MTLTexture?
    private var pinMaterials: [SCNMaterial] = []
    private var wireMaterials: [SCNMaterial] = []
    private var legMaterials: [SCNMaterial] = []
    private let camera = SCNCamera()

    /// `library`, `layers` (the packed layers' file) and `wear` (the wear
    /// texture's) are the app's own unless given, as a harness outside the
    /// app does.
    /// The chip this is: its die and the package it came in.
    let die: SiliconDie

    init(die: SiliconDie = .mos6581, device: MTLDevice? = MTLCreateSystemDefaultDevice(), library: MTLLibrary? = nil,
         layers url: URL? = nil, wear wearURL: URL? = nil) {
        self.die = die
        moves = Self.tour(of: die)
        var at = 0.0
        starts = moves.map { move in
            defer { at += move.seconds }
            return at
        }
        length = at
        overlay = SiliconOverlay(die: die, device: device, library: library)
        wear = SiliconAssets.wear(device: device, from: wearURL)
        let layers = url.map { SiliconAssets.load($0, device: device) } ?? SiliconAssets.layers(die, device: device)
        isReady = layers != nil
        switch die.package {
        case .ceramic: buildPackage()
        case .plastic: buildPlasticPackage()
        }
        buildDie(layers: layers)
        buildLights()
        camera.fieldOfView = 32
        camera.zNear = 0.02
        camera.zFar = 80
        camera.wantsHDR = true
        camera.bloomIntensity = 0.3
        camera.bloomThreshold = 1.0
        camera.bloomBlurRadius = 10
        // Shade where surfaces meet: the cavity's corners, under the wires.
        camera.screenSpaceAmbientOcclusionIntensity = 1.1
        camera.screenSpaceAmbientOcclusionRadius = 0.35
        camera.wantsDepthOfField = true
        camera.fStop = 0.35
        camera.apertureBladeCount = 7
        camera.focalBlurSampleCount = 16
        camera.exposureOffset = -0.5
        // The lens darkens toward its corners, and the eye goes to the middle.
        camera.vignettingIntensity = 0.75
        camera.vignettingPower = 0.8
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scene.background.contents = NSColor.clear
        place(camera: camera(clock: 0))
    }

    /// A place on the die (0–1 across and down its picture) in the scene.
    func onDie(_ p: SIMD2<Float>, height: Float = 0) -> SIMD3<Float> {
        SIMD3(p.x - 0.5, height, (p.y - 0.5) * die.aspect)
    }

    // MARK: Building it

    private func material(_ color: NSColor, metalness: CGFloat, roughness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = metalness
        material.roughness.contents = roughness
        return material
    }

    private func box(from a: SIMD3<Float>, to b: SIMD3<Float>, _ material: SCNMaterial, chamfer: CGFloat = 0) -> SCNNode {
        let size = b - a
        let geometry = SCNBox(width: CGFloat(abs(size.x)), height: CGFloat(abs(size.y)), length: CGFloat(abs(size.z)), chamferRadius: chamfer)
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = (a + b) / 2
        return node
    }

    private func buildPackage() {
        let root = scene.rootNode
        // Fired alumina and gold plate, forty years old (`SiliconWear`).
        let ceramic = SiliconWear.material(SiliconWear.ceramic, wear: wear)
        let hx = Self.bodyLength / 2, hz = Self.bodyWidth / 2
        let cavity = Self.cavityHalf, well = Self.wellHalf

        // The body is pressed and fired, not machined: its outline wanders
        // a little, its corners are round, and its top edges, the cavity's
        // and the well's are all bevelled. Three pieces, none sharing a
        // face that shows: the body with the cavity cut through it, the
        // shelf that fills the cavity's lower part with the well cut
        // through that, and the well's floor.
        let outer = Self.outline(half: SIMD2(hx, hz), corner: 0.09, wander: 0.006, seed: 21)
        let cavityEdge = Self.outline(half: cavity, corner: 0.07, wander: 0.007, seed: 22)
        let wellEdge = Self.outline(half: well, corner: 0.05, wander: 0.006, seed: 23)
        root.addChildNode(slab(outer, hole: cavityEdge, from: Self.bodyBottom, to: Self.bodyTop, bevel: 0.03, ceramic))
        root.addChildNode(slab(Self.outline(half: cavity + 0.01, corner: 0.07, wander: 0, seed: 0), hole: wellEdge,
                               from: Self.bodyBottom + 0.01, to: Self.shelf, bevel: 0.018, ceramic))
        root.addChildNode(box(from: SIMD3(-well.x - 0.02, Self.bodyBottom + 0.02, -well.y - 0.02),
                              to: SIMD3(well.x + 0.02, Self.wellFloor, well.y + 0.02), ceramic))

        // Gold, printed on thick and fired: the well's floor under the
        // die, and the wide band round the cavity that the lid was sealed
        // to. Matte, sandy, and soft at its edges.
        let plate = SiliconWear.material(SiliconWear.gold, wear: wear, matte: 1)
        root.addChildNode(slab(Self.outline(half: well - 0.012, corner: 0.05, wander: 0.008, seed: 24), hole: nil,
                               from: Self.wellFloor, to: Self.wellFloor + 0.006, bevel: 0.003, plate))
        let ring: Float = 0.36
        root.addChildNode(slab(Self.outline(half: cavity + ring, corner: 0.1, wander: 0.012, seed: 25),
                               hole: Self.outline(half: cavity + 0.035, corner: 0.08, wander: 0.01, seed: 26),
                               from: Self.bodyTop - 0.002, to: Self.bodyTop + 0.012, bevel: 0.006, plate))

        // What held the die down: a silvery pool that spread past its edges.
        let attach = SCNNode(geometry: Self.blob(radii: SIMD2(0.6, 0.52), unevenness: 0.09, height: 0.006, seed: 11))
        attach.geometry?.materials = [material(NSColor(srgbRed: 0.8, green: 0.8, blue: 0.78, alpha: 1), metalness: 0.7, roughness: 0.42)]
        attach.simdPosition = SIMD3(0.01, Self.wellFloor + 0.004, 0.015)
        attach.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        root.addChildNode(attach)

        // What held the lid on: glue, clear and glossy, left in beads along
        // the band and run over the cavity's edge where it was pried off.
        let glue = SCNMaterial()
        glue.lightingModel = .physicallyBased
        glue.diffuse.contents = NSColor(srgbRed: 0.86, green: 0.8, blue: 0.68, alpha: 1)
        glue.metalness.contents = 0.0
        // Glossy, but not a mirror: a mirror lying flat only shows the lamp.
        glue.roughness.contents = 0.16
        glue.clearCoat.contents = 0.5
        glue.clearCoatRoughness.contents = 0.25
        // Nearly clear: what shows is its shine and its edge.
        glue.transparency = 0.4
        glue.transparencyMode = .dualLayer
        glue.writesToDepthBuffer = false
        if let wear {
            glue.shaderModifiers = [.fragment: SiliconWear.glue]
            glue.setValue(SCNMaterialProperty(contents: wear), forKey: "wear")
        }
        let beads: [(center: SIMD2<Float>, radii: SIMD2<Float>, turn: Float, seed: UInt64)] = [
            (SIMD2(0.35, -cavity.y - 0.2), SIMD2(0.7, 0.07), 0.02, 3),
            (SIMD2(-0.75, -cavity.y - 0.24), SIMD2(0.28, 0.06), -0.08, 5),
            (SIMD2(cavity.x + 0.2, -cavity.y + 0.35), SIMD2(0.06, 0.4), 0.05, 7),
            (SIMD2(cavity.x + 0.1, -cavity.y - 0.1), SIMD2(0.16, 0.13), 0.4, 9),
            (SIMD2(-cavity.x - 0.22, 0.4), SIMD2(0.055, 0.45), -0.03, 13),
            (SIMD2(0.55, cavity.y + 0.22), SIMD2(0.6, 0.06), -0.03, 17),
        ]
        for bead in beads {
            let node = SCNNode(geometry: Self.blob(radii: bead.radii, unevenness: 0.34, height: 0.03, seed: bead.seed))
            node.geometry?.materials = [glue]
            node.simdPosition = SIMD3(bead.center.x, Self.bodyTop + 0.012, bead.center.y)
            node.simdEulerAngles = SIMD3(-.pi / 2, bead.turn, 0)
            root.addChildNode(node)
        }

        // The lead frame: a row of gold fingers along each side of the
        // shelf, each running out under the cavity's wall to its pin. The
        // pads are taken in order round the die, so no two wires cross.
        // Then the pin's leg down the package's side. One material a pin,
        // so it can glow.
        let pitch = Self.bodyLength / 15
        let inner = SIMD2(well.x + 0.07, well.y + 0.07)
        /// The 28 fingers' inner ends, going round as the pads do: from the
        /// middle of the far side leftward, down the left, along the near
        /// side, up the right, and back along the far side.
        func slot(_ index: Int) -> (end: SIMD2<Float>, out: SIMD2<Float>) {
            let along: [Float] = [-0.72, -0.48, -0.24, 0, 0.24, 0.48, 0.72]
            switch index {
            case 0..<4: return (SIMD2(-along[index + 3] * 0.82, -inner.y), SIMD2(0, -1))
            case 4..<11: return (SIMD2(-inner.x, along[index - 4] * 0.72), SIMD2(-1, 0))
            case 11..<18: return (SIMD2(along[index - 11] * 0.82, inner.y), SIMD2(0, 1))
            case 18..<25: return (SIMD2(inner.x, -along[index - 18] * 0.72), SIMD2(1, 0))
            default: return (SIMD2(-along[index - 25] * 0.82, -inner.y), SIMD2(0, -1))
            }
        }
        for pad in 0..<28 {
            let pin = SiliconDie.pin(ofPad: pad)
            // Tinned up to just under the body, where it sat in its socket or its solder.
            let lit = SiliconWear.material(SiliconWear.gold, wear: wear, solder: Self.bodyBottom - 0.02, matte: 0.6)
            lit.emission.contents = NSColor.black
            legMaterials.append(lit)
            let fingerGold = SiliconWear.material(SiliconWear.gold, wear: wear, matte: 1)
            fingerGold.emission.contents = NSColor.black
            pinMaterials.append(fingerGold)
            // The wire is too fine for wear to show on: clean gold.
            // Drawn gold wire is mirror-smooth: it shows the lamp as a bright
            // point wherever it turns to face it.
            let fine = material(NSColor(srgbRed: 1.0, green: 0.7, blue: 0.34, alpha: 1), metalness: 1, roughness: 0.09)
            fine.emission.contents = NSColor.black
            wireMaterials.append(fine)

            let (end, out) = slot(pad)
            // From its inner end to the cavity's wall.
            let reach = (out.x != 0 ? cavity.x - abs(end.x) : cavity.y - abs(end.y))
            let across = SIMD2(abs(out.y), abs(out.x)) * 0.052
            let far = end + out * reach
            // Printed like the band: a little uneven, rounded at its end.
            let low = SIMD2(min(end.x, far.x) - across.x, min(end.y, far.y) - across.y)
            let high = SIMD2(max(end.x, far.x) + across.x, max(end.y, far.y) + across.y)
            let finger = slab(Self.outline(half: (high - low) / 2, corner: 0.03, wander: 0.006, seed: UInt64(40 + pad)), hole: nil,
                              from: Self.shelf - 0.002, to: Self.shelf + 0.011, bevel: 0.005, fingerGold)
            finger.simdPosition += SIMD3((low.x + high.x) / 2, 0, (low.y + high.y) / 2)
            root.addChildNode(finger)

            // No two wires are alike: the bonder's loop varies in height
            // and bows a little to one side, the wire stands up off its
            // ball before it turns, and it's pressed flat where it's
            // stitched to the finger.
            var chance = ChipDie.Scatter(seed: UInt64(700 + pad))
            let from = onDie(die.pads[pad], height: 0.004)
            let landing = SIMD3(end.x + out.x * (0.05 + 0.05 * Float(chance.next())), Self.shelf + 0.014,
                                end.y + out.y * (0.05 + 0.05 * Float(chance.next())))
            let run = landing - from
            let sideways = simd_normalize(SIMD3(-run.z, 0, run.x)) * (Float(chance.next()) - 0.5) * 0.07
            let loop = 0.02 + 0.05 * Float(chance.next())
            let knots = [
                from,
                from + SIMD3(0, 0.03 + 0.015 * Float(chance.next()), 0) + run * 0.015,
                from + run * (0.3 + 0.2 * Float(chance.next())) + sideways + SIMD3(0, loop + (Self.shelf - from.y) * 0.5, 0),
                landing - run * 0.07 + sideways * 0.2 + SIMD3(0, 0.014 + 0.012 * Float(chance.next()), 0),
                landing,
            ]
            let wire = SCNNode(geometry: Self.tube(along: Self.curve(through: knots, steps: 9), radius: Self.wireRadius, sides: 12))
            wire.geometry?.materials = [fine]
            root.addChildNode(wire)
            // The ball, squashed onto the pad by the bonder's tip.
            let ball = SCNNode(geometry: SCNSphere(radius: CGFloat(Self.wireRadius * 2.3)))
            ball.geometry?.materials = [fine]
            ball.simdPosition = from - SIMD3(0, 0.002, 0)
            ball.simdScale = SIMD3(1, 0.55, 1)
            root.addChildNode(ball)
            // The stitch: the wire's end, flattened along the finger.
            let stitch = SCNNode(geometry: SCNSphere(radius: CGFloat(Self.wireRadius * 2.6)))
            stitch.geometry?.materials = [fine]
            stitch.simdPosition = landing - SIMD3(0, 0.003, 0)
            stitch.simdScale = SIMD3(out.x != 0 ? 1.8 : 0.8, 0.25, out.x != 0 ? 0.8 : 1.8)
            root.addChildNode(stitch)

            // Pins 1–14 run left to right along the near side, 15–28 back
            // along the far side.
            let near = pin < 14
            let x = near ? -hx + pitch * Float(pin + 1) : hx - pitch * Float(pin - 13)
            let z = near ? hz : -hz
            let side: Float = near ? 1 : -1
            // Brazed to the side: a wide shoulder, narrowing to the leg.
            let leg = SCNNode(geometry: Self.leg(top: Self.bodyTop - 0.1))
            leg.geometry?.materials = [lit]
            leg.simdPosition = SIMD3(x, 0, z + side * 0.004)
            if !near { leg.simdEulerAngles = SIMD3(0, .pi, 0) }
            root.addChildNode(leg)
        }

        // A gold stripe from the pin 1 end to the sealing band, and the
        // cross that marks that end.
        root.addChildNode(box(from: SIMD3(-hx, Self.bodyTop, 0.22), to: SIMD3(-cavity.x - ring, Self.bodyTop + 0.004, 0.34), plate))
        root.addChildNode(box(from: SIMD3(-hx + 0.14, Self.bodyTop, hz - 0.3), to: SIMD3(-hx + 0.38, Self.bodyTop + 0.004, hz - 0.26), plate))
        root.addChildNode(box(from: SIMD3(-hx + 0.24, Self.bodyTop, hz - 0.4), to: SIMD3(-hx + 0.28, Self.bodyTop + 0.004, hz - 0.16), plate))

        // The lid, pried off and set down on the package's other end: gold,
        // scratched, with the chip's marking printed on it.
        let lidGold = SiliconWear.material(SiliconWear.gold, wear: wear)
        let lid = box(from: SIMD3(-1.2, 0, -1.1), to: SIMD3(1.2, 0.03, 1.1), lidGold, chamfer: 0.012)
        lid.simdPosition = SIMD3(hx - 0.85, Self.bodyTop + 0.03, 0.14)
        lid.simdEulerAngles = SIMD3(0, 0.1, 0)
        root.addChildNode(lid)
        if let marking = SiliconWear.marking(die.marking, ink: NSColor(white: 0.04, alpha: 0.88)) {
            let plane = SCNPlane(width: 2.0, height: 1.5)
            let ink = SCNMaterial()
            ink.lightingModel = .physicallyBased
            ink.diffuse.contents = marking
            ink.roughness.contents = 0.7
            plane.materials = [ink]
            let node = SCNNode(geometry: plane)
            node.simdPosition = SIMD3(0, 0.0165, 0)
            node.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
            lid.addChildNode(node)
        }
    }

    /// A rounded rectangle's outline that isn't quite true: it wanders in
    /// and out by `wander` as it goes round, as a pressed or printed edge
    /// does. Points go counterclockwise from the right side's middle.
    static func outline(half: SIMD2<Float>, corner: Float, wander: Float, seed: UInt64) -> [CGPoint] {
        var random = ChipDie.Scatter(seed: seed)
        let phases = (0..<5).map { _ in Float(random.next()) * 2 * .pi }
        let r = min(corner, min(half.x, half.y) * 0.9)
        // The corners' centers, and the straight runs between them.
        var points: [SIMD2<Float>] = []
        let centers = [SIMD2(half.x - r, half.y - r), SIMD2(-half.x + r, half.y - r),
                       SIMD2(-half.x + r, -half.y + r), SIMD2(half.x - r, -half.y + r)]
        for (k, center) in centers.enumerated() {
            let next = centers[(k + 1) % 4]
            for step in 0...6 {
                let angle = (Float(k) + Float(step) / 6) * .pi / 2
                points.append(center + SIMD2(cos(angle), sin(angle)) * r)
            }
            // Along the side to the next corner, a point every tenth or so.
            let a = center + SIMD2(cos(Float(k + 1) * .pi / 2), sin(Float(k + 1) * .pi / 2)) * r
            let b = next + SIMD2(cos(Float(k + 1) * .pi / 2), sin(Float(k + 1) * .pi / 2)) * r
            let pieces = max(2, Int(simd_length(b - a) / 0.09))
            for step in 1..<pieces { points.append(a + (b - a) * (Float(step) / Float(pieces))) }
        }
        var along: Float = 0
        return points.enumerated().map { i, point in
            if i > 0 { along += simd_length(point - points[i - 1]) }
            var push: Float = 0
            for (k, phase) in phases.enumerated() { push += sin(along * (2.1 + 1.7 * Float(k)) + phase) / Float(k + 1) }
            let out = simd_normalize(point)
            let moved = point + out * push * wander
            return CGPoint(x: CGFloat(moved.x), y: CGFloat(moved.y))
        }
    }

    /// A slab with `outline` as seen from above (and `hole` cut through
    /// it), from one height to another, its top edges bevelled.
    private func slab(_ outline: [CGPoint], hole: [CGPoint]?, from bottom: Float, to top: Float, bevel: Float,
                      _ material: SCNMaterial) -> SCNNode {
        let path = NSBezierPath()
        path.move(to: outline[0])
        for point in outline.dropFirst() { path.line(to: point) }
        path.close()
        if let hole {
            // Backward, so it's cut out.
            path.move(to: hole[hole.count - 1])
            for point in hole.dropLast().reversed() { path.line(to: point) }
            path.close()
        }
        path.windingRule = .evenOdd
        path.flatness = 0.001
        let shape = SCNShape(path: path, extrusionDepth: CGFloat(top - bottom))
        shape.chamferRadius = CGFloat(bevel)
        shape.chamferMode = .front
        shape.materials = [material]
        let node = SCNNode(geometry: shape)
        // Drawn in x and y, raised along z: laid flat, its front face up.
        node.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        node.simdPosition = SIMD3(0, (top + bottom) / 2, 0)
        return node
    }

    /// A smooth curve through `knots` (Catmull-Rom), `steps` points
    /// between each two.
    static func curve(through knots: [SIMD3<Float>], steps: Int) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for i in 0..<knots.count - 1 {
            let p0 = knots[max(i - 1, 0)], p1 = knots[i], p2 = knots[i + 1], p3 = knots[min(i + 2, knots.count - 1)]
            for step in 0..<steps {
                let t = Float(step) / Float(steps), t2 = t * t, t3 = t2 * t
                let a = p1 * 2
                let b = (p2 - p0) * t
                let c = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
                let d = (p1 * 3 - p0 - p2 * 3 + p3) * t3
                points.append((a + b + c + d) * 0.5)
            }
        }
        points.append(knots[knots.count - 1])
        return points
    }

    /// A leg's outline, pressed from sheet: the shoulder brazed to the
    /// package's side, its taper, and the pin that goes in the socket.
    /// It faces out along z, with its top at the shelf's height.
    static func leg(top: Float) -> SCNGeometry {
        let top = CGFloat(top), neck = CGFloat(bodyBottom + 0.12), waist = CGFloat(bodyBottom - 0.04)
        let tip = CGFloat(bodyBottom - 0.8)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: -0.14, y: top))
        path.line(to: CGPoint(x: 0.14, y: top))
        path.line(to: CGPoint(x: 0.14, y: neck))
        path.line(to: CGPoint(x: 0.05, y: waist))
        path.line(to: CGPoint(x: 0.045, y: tip + 0.08))
        path.line(to: CGPoint(x: 0.02, y: tip))
        path.line(to: CGPoint(x: -0.02, y: tip))
        path.line(to: CGPoint(x: -0.045, y: tip + 0.08))
        path.line(to: CGPoint(x: -0.05, y: waist))
        path.line(to: CGPoint(x: -0.14, y: neck))
        path.close()
        return SCNShape(path: path, extrusionDepth: 0.028)
    }

    /// A flat, uneven pool of something that ran and set: an outline that
    /// wanders in and out, `height` thick with a rounded edge. It lies in
    /// its own x and y; turn it flat.
    static func blob(radii: SIMD2<Float>, unevenness: Float, height: Float, seed: UInt64) -> SCNGeometry {
        var random = ChipDie.Scatter(seed: seed)
        let phases = (0..<4).map { _ in Float(random.next()) * 2 * .pi }
        let path = NSBezierPath()
        let steps = 72
        for i in 0..<steps {
            let angle = Float(i) / Float(steps) * 2 * .pi
            var wander: Float = 0
            for (k, phase) in phases.enumerated() { wander += sin(angle * Float(k + 2) + phase) / Float(k + 1) }
            // Squarer than an ellipse, as a bead along an edge is.
            let c = cos(angle), sn = sin(angle)
            let square = pow(pow(abs(c), 4) + pow(abs(sn), 4), -0.25)
            let r = square * (1 + unevenness * wander * 0.6)
            let point = CGPoint(x: CGFloat(c * r * radii.x), y: CGFloat(sn * r * radii.y))
            i == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.close()
        path.flatness = 0.002
        let shape = SCNShape(path: path, extrusionDepth: CGFloat(height))
        shape.chamferRadius = CGFloat(height * 0.45)
        shape.chamferMode = .front
        return shape
    }

    /// A round tube along `path`.
    static func tube(along path: [SIMD3<Float>], radius: Float, sides: Int = 8) -> SCNGeometry {
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [UInt32] = []
        for (i, point) in path.enumerated() {
            let ahead = simd_normalize(path[min(i + 1, path.count - 1)] - path[max(i - 1, 0)])
            let across = simd_normalize(simd_cross(ahead, abs(ahead.y) < 0.95 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
            let up = simd_cross(across, ahead)
            for s in 0..<sides {
                let angle = Float(s) / Float(sides) * 2 * .pi
                let out = across * cos(angle) + up * sin(angle)
                vertices.append(SCNVector3(point + out * radius))
                normals.append(SCNVector3(out))
            }
            guard i > 0 else { continue }
            for s in 0..<sides {
                let a = UInt32((i - 1) * sides + s), b = UInt32((i - 1) * sides + (s + 1) % sides)
                let c = UInt32(i * sides + s), d = UInt32(i * sides + (s + 1) % sides)
                indices += [a, c, b, b, c, d]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// The die's look, from its layers: what each pixel is made of, how
    /// rough and how metallic, and what's lit there.
    private static let dieSurface = """
    #pragma arguments
    texture2d<float> layers;
    texture2d<float> working;
    float lamp;

    #pragma body
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 uv = _surface.diffuseTexcoord;
    float2 texels = float2(layers.get_width(), layers.get_height());
    // Close up, where a texel is larger than a pixel, the layers' blurred
    // edges are drawn back to sharp ones.
    float per_pixel = max(length(fwidth(uv * texels)) * 0.7, 0.001);
    float soft = clamp(per_pixel * 0.5, 0.06, 0.5);
    float keep = saturate(per_pixel - 0.5);
    float4 raw = layers.sample(smp, uv);
    float4 c = mix(smoothstep(0.5 - soft, 0.5 + soft, raw), raw, keep);
    float2 toward_light = float2(-1.0, -1.0) / texels * max(per_pixel, 1.0) * 1.3;
    float lit_raw = layers.sample(smp, uv + toward_light).b;
    float dark_raw = layers.sample(smp, uv - toward_light).b;
    float lit_side = mix(smoothstep(0.5 - soft, 0.5 + soft, lit_raw), lit_raw, keep);
    float dark_side = mix(smoothstep(0.5 - soft, 0.5 + soft, dark_raw), dark_raw, keep);
    float diffusion = c.r, poly = c.g, metal = c.b, contact = c.a;

    // Glass over silicon: interference colors, which drift across the die.
    float drift = sin(uv.x * 23.0 + sin(uv.y * 17.0) * 2.0) * 0.5;
    float grain = fract(sin(dot(floor(uv * texels * 2.0), float2(127.1, 311.7))) * 43758.5453);
    float3 field = float3(0.33, 0.39, 0.56) + float3(0.05, 0.02, -0.04) * drift;
    float3 doped = float3(0.16, 0.37, 0.40) + float3(-0.04, 0.05, 0.06) * drift;
    float3 gate = float3(0.46, 0.15, 0.21);
    float3 wire = float3(0.68, 0.36, 0.41) + float3(0.05, -0.03, 0.05) * drift;
    float3 color = mix(field, doped, diffusion);
    color = mix(color, mix(wire, gate, diffusion), poly);
    color *= 0.96 + 0.06 * grain;
    // The aluminum's shadow on what's under it, then the aluminum.
    color *= 1.0 - 0.45 * saturate(lit_side - metal);
    float3 aluminum = float3(0.93, 0.91, 0.84) * (0.84 + 0.2 * grain);
    aluminum *= 1.0 + 0.3 * saturate(metal - lit_side) - 0.3 * saturate(metal - dark_side);
    color = mix(color, aluminum, metal);
    color = mix(color, color * float3(0.38, 0.33, 0.3), contact * 0.85);

    // The lamp is low: the die sits in the dark of Now Playing, and what's
    // working is what lights it.
    _surface.diffuse = float4(color * 0.3, 1.0);
    _surface.metalness = metal * 0.85;
    // The oxide is glass: it mirrors the lamp in one small spot instead of
    // hazing over. The aluminum is grainy and spreads it.
    _surface.roughness = mix(0.12, 0.34 + 0.1 * grain, metal);

    // What's working glows along its own wiring: the polysilicon and
    // diffusion most, the aluminum a little.
    float3 glow = working.sample(smp, uv).rgb;
    float wiring = saturate(poly * 0.9 + diffusion * 0.5 + metal * 0.3);
    _surface.emission = float4(glow * (0.06 + 0.8 * wiring) + color * lamp, 1.0);
    """

    /// The 8580's package: black molded plastic, opened the way they're
    /// opened, with acid, which leaves a ragged pit down to the die. The
    /// die sits on the lead frame's paddle with its wires running out to
    /// the frame's fingers, which disappear into the plastic. The legs
    /// are tinned and come out of the sides' middle.
    private func buildPlasticPackage() {
        let root = scene.rootNode
        let plastic = SiliconWear.aged(SiliconWear.plastic, wear: wear, ["etched": 0])
        let etched = SiliconWear.aged(SiliconWear.plastic, wear: wear, ["etched": 1])
        let frame = SiliconWear.material(SiliconWear.gold, wear: wear, solder: 100)
        let hx = Self.bodyLength / 2, hz = Self.bodyWidth / 2
        let floor: Float = -0.085

        // The body, with the notch at its pin 1 end, and the pit eaten
        // into it in two steps, each wider than the one below.
        var outer = Self.outline(half: SIMD2(hx, hz), corner: 0.06, wander: 0.003, seed: 31)
        outer = outer.map { point in
            let fromEnd = Float(point.x) + hx, across = Float(point.y)
            guard fromEnd < 0.3, abs(across) < 0.2 else { return point }
            return CGPoint(x: CGFloat(-hx + (0.04 - across * across).squareRoot()), y: point.y)
        }
        let rim = Self.outline(half: SIMD2(1.02, 0.96), corner: 0.55, wander: 0.05, seed: 32)
        let pit = Self.outline(half: SIMD2(0.86, 0.8), corner: 0.42, wander: 0.045, seed: 33)
        root.addChildNode(slab(outer, hole: rim, from: Self.bodyBottom, to: Self.bodyTop, bevel: 0.035, plastic))
        root.addChildNode(slab(Self.outline(half: SIMD2(1.1, 1.04), corner: 0.5, wander: 0, seed: 0), hole: pit,
                               from: Self.bodyBottom + 0.01, to: 0.14, bevel: 0.03, etched))
        root.addChildNode(box(from: SIMD3(-1.0, Self.bodyBottom + 0.02, -0.95), to: SIMD3(1.0, floor, 0.95), etched))
        // The paddle the die is glued to.
        root.addChildNode(slab(Self.outline(half: SIMD2(0.6, 0.56), corner: 0.03, wander: 0.003, seed: 34), hole: nil,
                               from: floor, to: Self.wellFloor, bevel: 0.004, frame))
        // A mold's ejector pin leaves a shallow round mark by pin 1.
        let mark = SCNNode(geometry: SCNCylinder(radius: 0.13, height: 0.004))
        mark.geometry?.materials = [material(NSColor(white: 0.03, alpha: 1), metalness: 0, roughness: 0.25)]
        mark.simdPosition = SIMD3(-hx + 0.42, Self.bodyTop, hz - 0.42)
        root.addChildNode(mark)

        let pitch = Self.bodyLength / 15
        for pad in 0..<28 {
            let pin = SiliconDie.pin(ofPad: pad)
            let tin = SiliconWear.material(SiliconWear.gold, wear: wear, solder: 100)
            tin.emission.contents = NSColor.black
            legMaterials.append(tin)
            let fingerTin = SiliconWear.material(SiliconWear.gold, wear: wear, solder: 100)
            fingerTin.emission.contents = NSColor.black
            pinMaterials.append(fingerTin)
            let fine = material(NSColor(srgbRed: 1.0, green: 0.7, blue: 0.34, alpha: 1), metalness: 1, roughness: 0.09)
            fine.emission.contents = NSColor.black
            wireMaterials.append(fine)

            // The frame's fingers point at the die from all round, each
            // from the pad's own direction.
            let from = onDie(die.pads[pad], height: 0.004)
            let outward = simd_normalize(SIMD2(from.x, from.z))
            let reach = min(0.7 / max(abs(outward.x), 1e-4), 0.66 / max(abs(outward.y), 1e-4))
            let tip = outward * reach
            let finger = box(from: SIMD3(0, floor + 0.004, -0.03), to: SIMD3(0.6, floor + 0.016, 0.03), fingerTin)
            finger.simdPosition = SIMD3(tip.x + outward.x * 0.3, floor + 0.01, tip.y + outward.y * 0.3)
            finger.simdEulerAngles = SIMD3(0, -atan2(outward.y, outward.x), 0)
            root.addChildNode(finger)

            var chance = ChipDie.Scatter(seed: UInt64(900 + pad))
            let landing = SIMD3(tip.x + outward.x * (0.04 + 0.05 * Float(chance.next())), floor + 0.02,
                                tip.y + outward.y * (0.04 + 0.05 * Float(chance.next())))
            let run = landing - from
            let sideways = simd_normalize(SIMD3(-run.z, 0, run.x)) * (Float(chance.next()) - 0.5) * 0.05
            // Up off the ball, over the die's edge, and down to the finger.
            let knots = [
                from,
                from + SIMD3(0, 0.03 + 0.015 * Float(chance.next()), 0) + run * 0.02,
                from + run * (0.35 + 0.2 * Float(chance.next())) + sideways + SIMD3(0, 0.05 + 0.04 * Float(chance.next()), 0),
                landing - run * 0.08 + sideways * 0.2 + SIMD3(0, 0.02, 0),
                landing,
            ]
            let wire = SCNNode(geometry: Self.tube(along: Self.curve(through: knots, steps: 9), radius: Self.wireRadius, sides: 12))
            wire.geometry?.materials = [fine]
            root.addChildNode(wire)
            let ball = SCNNode(geometry: SCNSphere(radius: CGFloat(Self.wireRadius * 2.3)))
            ball.geometry?.materials = [fine]
            ball.simdPosition = from - SIMD3(0, 0.002, 0)
            ball.simdScale = SIMD3(1, 0.55, 1)
            root.addChildNode(ball)

            let near = pin < 14
            let x = near ? -hx + pitch * Float(pin + 1) : hx - pitch * Float(pin - 13)
            let z = near ? hz : -hz
            let leg = SCNNode(geometry: Self.leg(top: -0.02))
            leg.geometry?.materials = [tin]
            leg.simdPosition = SIMD3(x, 0, z + (near ? 0.004 : -0.004))
            if !near { leg.simdEulerAngles = SIMD3(0, .pi, 0) }
            root.addChildNode(leg)
        }

        // The marking, printed on the plastic in pale ink, beside the pit.
        if let marking = SiliconWear.marking(die.marking, ink: NSColor(srgbRed: 0.5, green: 0.63, blue: 0.82, alpha: 0.8)) {
            let plane = SCNPlane(width: 2.0, height: 1.5)
            let ink = SCNMaterial()
            ink.lightingModel = .physicallyBased
            ink.diffuse.contents = marking
            ink.roughness.contents = 0.6
            plane.materials = [ink]
            let node = SCNNode(geometry: plane)
            node.simdPosition = SIMD3(-hx + 1.5, Self.bodyTop + 0.002, 0)
            node.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
            root.addChildNode(node)
        }
    }

    private func buildDie(layers: MTLTexture?) {
        let aspect = CGFloat(die.aspect)
        // The silicon itself, a slab with the picture on top.
        let slab = box(from: SIMD3(-0.5, Self.wellFloor + 0.004, -Float(aspect) / 2), to: SIMD3(0.5, -0.001, Float(aspect) / 2),
                       material(NSColor(white: 0.07, alpha: 1), metalness: 0.4, roughness: 0.35))
        scene.rootNode.addChildNode(slab)

        dieMaterial.lightingModel = .physicallyBased
        dieMaterial.diffuse.contents = layers ?? NSColor.darkGray
        dieMaterial.metalness.contents = 0.0
        dieMaterial.roughness.contents = 0.3
        dieMaterial.emission.contents = NSColor.black
        if let layers, let working = overlay.light {
            dieMaterial.shaderModifiers = [.surface: Self.dieSurface]
            dieMaterial.setValue(SCNMaterialProperty(contents: layers), forKey: "layers")
            dieMaterial.setValue(SCNMaterialProperty(contents: working), forKey: "working")
            dieMaterial.setValue(Float(0.03), forKey: "lamp")
        }
        let top = SCNPlane(width: 1, height: aspect)
        top.materials = [dieMaterial]
        let die = SCNNode(geometry: top)
        die.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        scene.rootNode.addChildNode(die)

        // The signals and waveforms, as light just above the die.
        let glow = SCNMaterial()
        glow.lightingModel = .constant
        glow.diffuse.contents = NSColor.black
        glow.emission.contents = overlay.signals ?? NSColor.black
        glow.blendMode = .add
        glow.writesToDepthBuffer = false
        glow.isDoubleSided = true
        let sheet = SCNPlane(width: 1, height: aspect)
        sheet.materials = [glow]
        let floating = SCNNode(geometry: sheet)
        floating.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        floating.simdPosition = SIMD3(0, 0.012, 0)
        floating.renderingOrder = 10
        scene.rootNode.addChildNode(floating)
    }

    /// One warm lamp over the chip, as on a workbench: its pool of light
    /// falls on the cavity and thins out toward the package's ends. The
    /// room gives only a little back, and a faint cool light from the
    /// other side keeps the shadows from going to black.
    private func buildLights() {
        scene.lightingEnvironment.contents = SiliconWear.room()
        scene.lightingEnvironment.intensity = 0.3
        let lamp = SCNLight()
        lamp.type = .spot
        lamp.intensity = 620
        lamp.temperature = 3900
        lamp.spotInnerAngle = 10
        lamp.spotOuterAngle = 62
        lamp.castsShadow = true
        lamp.shadowRadius = 9
        lamp.shadowSampleCount = 16
        lamp.shadowMapSize = CGSize(width: 2048, height: 2048)
        lamp.shadowColor = NSColor(white: 0, alpha: 0.85)
        lamp.zNear = 1
        lamp.zFar = 30
        let over = SCNNode()
        over.light = lamp
        over.simdPosition = SIMD3(-2.6, 6.2, 2.8)
        over.simdLook(at: SIMD3(0.2, 0, 0))
        scene.rootNode.addChildNode(over)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 70
        fill.temperature = 8500
        let other = SCNNode()
        other.light = fill
        other.simdPosition = SIMD3(4, 3, -4)
        other.simdLook(at: SIMD3(0, 0, 0))
        scene.rootNode.addChildNode(other)
    }

    // MARK: The camera

    /// Where the camera is: what it looks at, from how far, how high above
    /// the horizon and from which side.
    struct Shot {
        var target: SIMD3<Float>
        var distance: Float
        var pitch: Float
        var yaw: Float

        var position: SIMD3<Float> {
            target + SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
        }
    }

    /// One move of the camera: from one shot to another, over so many
    /// seconds, at a steady pace.
    struct Move {
        var from: Shot
        var to: Shot
        var seconds: Double

        /// Where it is `t` of the way through; a little before 0 or past 1
        /// carries the move on, which is what lets one run into the next.
        func shot(at t: Double) -> Shot {
            let t = Float(min(max(t, -0.3), 1.3))
            return Shot(target: from.target + (to.target - from.target) * t,
                        distance: from.distance * pow(to.distance / from.distance, t),
                        pitch: from.pitch + (to.pitch - from.pitch) * t,
                        yaw: from.yaw + (to.yaw - from.yaw) * t)
        }
    }

    /// The tour, shot like a product's reveal: the camera is never still.
    /// It slides low along the package from its pin 1 end, rises and
    /// circles it, comes down over the cavity, skims round the bond
    /// wires, and then works the die: pushing in, sliding low across the
    /// voices from one to the next, down an envelope generator, along
    /// the filter's edge, before pulling all the way back out.
    let moves: [Move]
    /// When each move starts, and how long the whole tour is.
    private let starts: [Double]
    private let length: Double

    /// Seconds over which one move runs into the next: three at least,
    /// and longer the more the camera has to pull back, come in or go
    /// round, so it never snaps from one view to another. It's never more
    /// than six tenths of the move itself.
    private func blend(from move: Move, to next: Move) -> Double {
        let zoom = abs(log(Double(next.from.distance / move.to.distance)))
        // And the more it has to travel, for how close it is.
        let travel = Double(simd_length(next.from.position - move.to.position) / min(next.from.distance, move.to.distance))
        return min(move.seconds * 0.6, max(3, 2.3 * zoom, 2.6 * travel))
    }

    static func tour(of die: SiliconDie) -> [Move] {
        func on(_ index: Int) -> SIMD3<Float> {
            let center = die.sights[index].center
            return SIMD3(center.x - 0.5, 0, (center.y - 0.5) * die.aspect)
        }
        let middle = SIMD3<Float>(0, 0, 0)
        let hx = bodyLength / 2
        return [
            // Low along the package, close, from the pin 1 end toward the cavity.
            Move(from: Shot(target: SIMD3(-hx + 0.9, 0.2, 0.5), distance: 2.6, pitch: 0.2, yaw: -0.75),
                 to: Shot(target: SIMD3(0.2, 0.25, 0.2), distance: 3.0, pitch: 0.27, yaw: -0.25), seconds: 13),
            // Up and round the whole of it.
            Move(from: Shot(target: middle, distance: 8.6, pitch: 0.48, yaw: 0.2),
                 to: Shot(target: middle, distance: 7.6, pitch: 0.72, yaw: 1.0), seconds: 14),
            // Down over the cavity.
            Move(from: Shot(target: middle, distance: 5.2, pitch: 1.25, yaw: -0.5),
                 to: Shot(target: middle, distance: 2.5, pitch: 0.95, yaw: -0.1), seconds: 11),
            // Low round the bond wires.
            Move(from: Shot(target: SIMD3(0, 0.03, 0), distance: 1.75, pitch: 0.36, yaw: 0.5),
                 to: Shot(target: SIMD3(0, 0.03, 0), distance: 1.6, pitch: 0.44, yaw: 1.55), seconds: 13),
            // Onto the die.
            Move(from: Shot(target: middle, distance: 1.7, pitch: 1.25, yaw: 0.2),
                 to: Shot(target: on(3), distance: 0.95, pitch: 1.05, yaw: 0.0), seconds: 9),
            // Skimming across the three voices' oscillators.
            Move(from: Shot(target: on(0), distance: 0.36, pitch: 0.46, yaw: 0.45),
                 to: Shot(target: on(6), distance: 0.36, pitch: 0.5, yaw: 0.25), seconds: 15),
            // Down one voice's waveform and noise, close.
            Move(from: Shot(target: on(1), distance: 0.26, pitch: 0.85, yaw: -0.3),
                 to: Shot(target: on(2), distance: 0.34, pitch: 0.7, yaw: -0.1), seconds: 11),
            // Back across the envelope generators.
            Move(from: Shot(target: on(7), distance: 0.42, pitch: 0.5, yaw: -0.5),
                 to: Shot(target: on(2), distance: 0.42, pitch: 0.55, yaw: -0.2), seconds: 14),
            // Along the filter, from the cutoff to the output.
            Move(from: Shot(target: on(4), distance: 0.3, pitch: 0.6, yaw: 0.35),
                 to: Shot(target: on(5), distance: 0.3, pitch: 0.7, yaw: 0.1), seconds: 11),
            // Along the address decoder.
            Move(from: Shot(target: on(8) + SIMD3(0.25, 0, 0), distance: 0.34, pitch: 0.55, yaw: 0.2),
                 to: Shot(target: on(8) - SIMD3(0.25, 0, 0), distance: 0.34, pitch: 0.6, yaw: -0.1), seconds: 10),
            // And out, until it's a chip on a bench again.
            Move(from: Shot(target: middle, distance: 1.6, pitch: 1.15, yaw: -0.3),
                 to: Shot(target: middle, distance: 8.8, pitch: 0.6, yaw: -0.9), seconds: 13),
        ]
    }

    /// The shot at `clock`: partway through one move, or, in a move's
    /// last seconds, on its way over to the next one's path, which it
    /// joins already moving. It breathes a little throughout.
    func camera(clock: Double) -> Shot {
        let time = clock.truncatingRemainder(dividingBy: length)
        let index = (starts.lastIndex { $0 <= time } ?? 0)
        let move = moves[index], next = moves[(index + 1) % moves.count]
        let local = time - starts[index]
        var shot = move.shot(at: local / move.seconds)
        let left = move.seconds - local
        let handover = blend(from: move, to: next)
        if left < handover {
            let w = 1 - left / handover
            let ease = Float(w * w * w * (w * (w * 6 - 15) + 10))
            let onward = next.shot(at: -left / next.seconds)
            shot = Shot(target: shot.target + (onward.target - shot.target) * ease,
                        distance: shot.distance * pow(onward.distance / shot.distance, ease),
                        pitch: shot.pitch + (onward.pitch - shot.pitch) * ease,
                        yaw: shot.yaw + (onward.yaw - shot.yaw) * ease)
        }
        shot.target += SIMD3(Float(sin(clock * 0.23)), 0, Float(cos(clock * 0.17))) * 0.008 * shot.distance
        shot.pitch += 0.015 * Float(sin(clock * 0.13))
        return shot
    }

    private func place(camera shot: Shot) {
        cameraNode.simdPosition = shot.position
        cameraNode.simdLook(at: shot.target, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        camera.focusDistance = CGFloat(shot.distance)
        // The closer the camera, the thinner what's sharp: the lens stops
        // down as it comes in, so a close-up of the die isn't a blur with
        // one sharp line across it.
        camera.fStop = CGFloat(min(8, max(0.35, 1.6 / shot.distance)))
    }

    // MARK: Every frame

    /// Lights the chip as `state` has it working, and moves the camera to
    /// where it is at `clock`.
    func update(state: ChipState, clock: Double) {
        overlay.draw(state: state, clock: clock)
        place(camera: camera(clock: clock))

        // The pins at work, as on the Chip visualizer: the clock always,
        // the bus on every write, the filter's capacitors and the audio
        // pin as they're used.
        var glow = [SIMD3<Float>](repeating: .zero, count: 28)
        let white = SiliconOverlay.shared
        let writing = state.written.max() ?? 0
        let latest = state.written.indices.max { state.written[$0] < state.written[$1] } ?? 0
        let owner = latest < 21 ? voiceColors[(latest / 7) % voiceColors.count] : white
        glow[ChipDie.Pin.clock] = white * Float(0.3 + 0.25 * sin(clock * 12))
        glow[ChipDie.Pin.write] = white * writing
        glow[ChipDie.Pin.select] = white * writing
        for (bit, pin) in ChipDie.Pin.address.enumerated() where latest >> bit & 1 == 1 { glow[pin] = white * writing }
        for (bit, pin) in ChipDie.Pin.data.enumerated() where state.registers[latest] >> bit & 1 == 1 { glow[pin] = owner * writing * 1.3 }
        var filterLevel: Float = 0, loudest: Float = 0
        for v in 0..<3 {
            if state.voices[v].filtered { filterLevel = max(filterLevel, state.voices[v].level) }
            if state.isHeard(v) { loudest = max(loudest, state.voices[v].level) }
        }
        for pin in ChipDie.Pin.filterCaps { glow[pin] = white * filterLevel * 0.9 }
        glow[ChipDie.Pin.audio] = white * min(1.5, loudest * Float(state.volume) / 15 * 1.6)
        for pad in 0..<min(28, pinMaterials.count) {
            // Enough to tint the gold, not to flatten it: the wire keeps its shine.
            let c = glow[SiliconDie.pin(ofPad: pad)] * 0.38
            let color = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            // The leg and finger take less of it than the wire: lit too far, worn
            // metal reads as paint.
            let dimmed = color.blended(withFraction: 0.55, of: .black) ?? color
            pinMaterials[pad].emission.contents = dimmed
            legMaterials[pad].emission.contents = dimmed
            wireMaterials[pad].emission.contents = color
        }
    }
}
