import AppKit
import SceneKit
import simd

/// A 5¼-inch disk and the intro it loads into the desk's CRT.
@MainActor
final class DeskCreditsDisk {
    static let name = "credits_floppy"
    private static let side: Float = 1.36
    private static let thickness: Float = 0.014
    private static let hubRadius = side * 31 / 256
    private static let doorHinge = SIMD3<Float>(-4.42, 0.551, 0.55)
    private static let insertEnd = 2.95
    private static let latchTime = 0.21
    private static let seekTime = 1.30
    private static let rest = Waypoint(0, [-2.08, 0.735, 0.274], [1.13, 0.10, -0.16])
    private static let grip = Waypoint(0.58, [-2.53, 1.38, 0.98], [0.88, 0.60, -0.13])
    private static let swing = Waypoint(0.88, [-3.47, 1.22, 1.82], [0.34, 2.03, -0.07])
    // Yawing half a turn sends the read window in first with the notch on the left.
    private static let slot = Waypoint(2.40, [-4.44, 0.499, 1.62], [0, .pi, 0])
    private static let inside = Waypoint(insertEnd, [-4.44, 0.499, -0.33], [0, .pi, 0])
    private static let insertion = [
        Waypoint(0.22, rest.position, rest.angles),
        grip,
        swing,
        Waypoint(1.12, [-4.40, 0.556, 1.62], [0, .pi - 0.09, -0.025]),
        Waypoint(1.32, [-4.43, 0.543, 1.426], [0, .pi - 0.018, 0], bend: 0.036),
        // Pitch the hand down under pressure while the caught edge flexes up.
        Waypoint(1.52, [-4.43, 0.543, 1.437], [0.16, .pi - 0.012, 0], bend: 0.158),
        Waypoint(1.64, [-4.43, 0.549, 1.441], [0.15, .pi - 0.016, 0], bend: 0.134),
        Waypoint(2.03, [-4.43, 0.565, 1.67], [0.06, .pi - 0.03, 0], bend: -0.020),
        slot,
        inside
    ]
    private static let removal = [
        Waypoint(latchTime, inside.position, inside.angles),
        Waypoint(0.69, slot.position, slot.angles),
        Waypoint(0.96, swing.position, swing.angles),
        Waypoint(1.23, grip.position, grip.angles),
        Waypoint(1.59, rest.position, rest.angles)
    ]

    let node: SCNNode
    private let door = SCNNode()
    private let led = SCNMaterial()
    private let jacket: SCNGeometry
    private var phase = Phase.resting
    private var renderer: CreditsRenderer?
    private var tune: CreditsScene.Tune?
    private var still = false
    private var lastFrame = -1
    private var driveSoundStarted = false
    private var bend: Float?

    private struct Waypoint {
        let time: Double
        let position: SIMD3<Float>
        let angles: SIMD3<Float>
        let bend: Float

        init(_ time: Double, _ position: SIMD3<Float>, _ angles: SIMD3<Float>, bend: Float = 0) {
            self.time = time
            self.position = position
            self.angles = angles
            self.bend = bend
        }
    }

    private enum Phase {
        case resting, loading(Double), playing(Double), ejecting(Double)
    }

    var canLoad: Bool {
        if case .resting = phase { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var isActive: Bool {
        switch phase {
        case .loading, .playing: true
        case .resting, .ejecting: false
        }
    }

    init(root: SCNNode) {
        jacket = Self.makeJacket()
        node = SCNNode(geometry: jacket)
        node.name = Self.name
        root.addChildNode(node)

        if let latch = root.childNode(withName: "drive_door", recursively: true) {
            let openTransform = latch.simdWorldTransform
            door.name = "drive_door_hinge"
            root.addChildNode(door)
            door.simdWorldPosition = Self.doorHinge
            door.addChildNode(latch)
            latch.simdWorldTransform = openTransform
        }

        let lens = SCNSphere(radius: 0.022)
        led.lightingModel = .physicallyBased
        led.diffuse.contents = NSColor(srgbRed: 0.24, green: 0.043, blue: 0.025, alpha: 1)
        lens.materials = [led]
        let light = SCNNode(geometry: lens)
        light.name = "credits_drive_activity"
        // Overlay the red indicator already printed on the front panel.
        light.simdPosition = [-4.965, 0.36, 0.724]
        light.simdScale = [1, 1, 0.3]
        light.castsShadow = false
        root.addChildNode(light)
        reset()
    }

    func load(at now: Double, tune: CreditsScene.Tune?, reduceMotion: Bool) {
        guard canLoad else { return }
        self.tune = tune
        still = reduceMotion
        renderer = CreditsRenderer()
        lastFrame = -1
        phase = .loading(now)
        Task.detached(priority: .utility) { CreditsScene.prepareHeart() }
    }

    func reset() {
        phase = .resting
        renderer = nil
        tune = nil
        if driveSoundStarted {
            MonitorSounds.shared.stopDrive()
            driveSoundStarted = false
        }
        place(Self.rest, hidden: false)
        closeDoor(0)
        setActivity(false)
    }

    func eject(at now: Double) {
        if isLoading || still {
            reset()
        } else if isActive {
            phase = .ejecting(now)
            renderer = nil
            tune = nil
        }
    }

    /// Returns true when the camera can leave the drive and face the CRT.
    func update(at now: Double, audible: Bool) -> Bool {
        switch phase {
        case .resting:
            break
        case .loading(let start):
            let elapsed = max(0, now - start) + (still ? Self.insertEnd : 0)
            let latchEnd = Self.insertEnd + Self.latchTime
            let done = latchEnd + Self.seekTime
            let latch = min(1, max(0, (elapsed - Self.insertEnd) / Self.latchTime))
            if elapsed < Self.insertEnd {
                place(along: Self.insertion, at: elapsed)
            } else {
                place(Self.inside, hidden: true)
                closeDoor(still ? (latch == 1 ? 1 : 0) : Float(latch * latch))
            }
            if audible, elapsed >= latchEnd, elapsed < done, !driveSoundStarted {
                MonitorSounds.shared.playDriveLoad()
                driveSoundStarted = true
            }
            let seek = elapsed - latchEnd
            setActivity(seek > 0.13 && Int(seek * 13) % 5 != 4)
            if elapsed >= done {
                driveSoundStarted = false
                setActivity(false)
                phase = .playing(now + (still ? 0 : 0.68))
                return true
            }
        case .playing(let start):
            if seconds(since: start, at: now) >= CreditsScene.length(tune: tune) { eject(at: now) }
        case .ejecting(let start):
            let elapsed = now - start
            if elapsed >= Self.removal.last!.time {
                reset()
            } else {
                closeDoor(Float(max(0, 1 - elapsed / Self.latchTime)))
                if elapsed >= Self.latchTime { place(along: Self.removal, at: elapsed) }
            }
        }
        return false
    }

    var isShowingIntro: Bool {
        if case .playing = phase { return lastFrame >= 0 }
        return false
    }

    /// Use the same full raster as the player. SceneKit applies the tube's
    /// controls and rounded edges to both pictures.
    func render(at now: Double, into pixels: inout [UInt32]) -> Bool {
        guard case .playing(let start) = phase, now >= start, let renderer else { return false }
        let frame = Int((now - start) * 30)
        guard frame != lastFrame,
              let image = renderer.image(seconds: seconds(since: start, at: now), tune: tune, still: still)
        else { return false }
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            let format = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(data: bytes.baseAddress, width: C64Frame.width, height: C64Frame.height,
                                          bitsPerComponent: 8, bytesPerRow: C64Frame.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: format) else { return false }
            context.interpolationQuality = image.width > C64Frame.width ? .medium : .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: C64Frame.width, height: C64Frame.height))
            return true
        }
        if drawn { lastFrame = frame }
        return drawn
    }

    private func seconds(since start: Double, at now: Double) -> Double {
        now - start + (still ? CreditsScene.timing.namesFrom : 0)
    }

    private func place(along path: [Waypoint], at elapsed: Double) {
        guard let next = path.indices.dropFirst().first(where: { elapsed <= path[$0].time }) else {
            place(elapsed <= path[0].time ? path[0] : path[path.count - 1], hidden: false)
            return
        }
        let from = path[next - 1], to = path[next]
        let fraction = Float(max(0, (elapsed - from.time) / (to.time - from.time)))
        let eased = fraction * fraction * (3 - 2 * fraction)
        let amount = SIMD3<Float>(repeating: eased)
        place(Waypoint(elapsed, simd_mix(from.position, to.position, amount), simd_mix(from.angles, to.angles, amount),
                       bend: from.bend + (to.bend - from.bend) * eased), hidden: false)
    }

    private func place(_ pose: Waypoint, hidden: Bool) {
        node.simdPosition = pose.position
        let pitch = simd_quatf(angle: pose.angles.x, axis: [1, 0, 0])
        let yaw = simd_quatf(angle: pose.angles.y, axis: [0, 1, 0])
        let roll = simd_quatf(angle: pose.angles.z, axis: [0, 0, 1])
        node.simdOrientation = roll * yaw * pitch
        node.isHidden = hidden
        if pose.bend != bend {
            bend = pose.bend
            jacket.setValue(NSNumber(value: pose.bend), forKey: "diskBend")
        }
    }

    private func closeDoor(_ amount: Float) {
        door.simdEulerAngles.x = amount * 0.88
        // The catch comes forward out of its recess as it folds down.
        door.simdWorldPosition = Self.doorHinge + [0, 0, 0.092 * amount]
    }

    private static func makeJacket() -> SCNGeometry {
        let segments = 64, bands = 8
        let half = side / 2
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var texCoords: [CGPoint] = []
        func vertex(_ p: SIMD2<Float>, y: Float, normal: SCNVector3) {
            vertices.append(SCNVector3(p.x, y, p.y))
            normals.append(normal)
            texCoords.append(CGPoint(x: CGFloat((p.x + half) / side), y: CGFloat((p.y + half) / side)))
        }

        let directions = (0..<segments).map { i in
            let angle = 2 * Float.pi * Float(i) / Float(segments)
            return SIMD2<Float>(cos(angle), sin(angle))
        }
        let inner = directions.map { $0 * hubRadius }
        let outer = directions.map { $0 * (half / max(abs($0.x), abs($0.y))) }
        var front: [UInt16] = []
        var shell: [UInt16] = []
        // Concentric rows let both faces flex smoothly between the hole and the sleeve edge.
        for isTop in [true, false] {
            let offset = vertices.count
            let sign: Float = isTop ? 1 : -1
            for band in 0...bands {
                let fraction = Float(band) / Float(bands)
                for i in 0..<segments {
                    vertex(inner[i] + (outer[i] - inner[i]) * fraction,
                           y: sign * thickness / 2, normal: SCNVector3(0, sign, 0))
                }
            }
            for band in 0..<bands {
                for i in 0..<segments {
                    let a = UInt16(offset + band * segments + i)
                    let b = UInt16(offset + band * segments + (i + 1) % segments)
                    let c = a + UInt16(segments), d = b + UInt16(segments)
                    if isTop {
                        front += [a, b, c, b, d, c]
                    } else {
                        shell += [a, c, b, b, c, d]
                    }
                }
            }
        }
        // Close the sleeve's outside edge and line the inside of the spindle hole.
        for (rim, inside) in [(outer, false), (inner, true)] {
            for i in 0..<segments {
                let next = (i + 1) % segments
                let (a, b) = inside ? (rim[next], rim[i]) : (rim[i], rim[next])
                let tangent = b - a
                let outward = simd_normalize(SIMD2<Float>(tangent.y, -tangent.x))
                let normal = SCNVector3(outward.x, 0, outward.y)
                let offset = UInt16(vertices.count)
                for y in [thickness / 2, -thickness / 2] {
                    vertex(a, y: y, normal: normal)
                    vertex(b, y: y, normal: normal)
                }
                shell += [offset, offset + 1, offset + 2, offset + 1, offset + 3, offset + 2]
            }
        }

        let label = SCNMaterial()
        label.lightingModel = .physicallyBased
        label.diffuse.contents = labelImage()
        label.diffuse.mipFilter = .linear
        label.roughness.contents = 0.82
        let plastic = SCNMaterial()
        plastic.lightingModel = .physicallyBased
        plastic.diffuse.contents = NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1)
        plastic.roughness.contents = 0.85
        let geometry = SCNGeometry(sources: [
            SCNGeometrySource(vertices: vertices),
            SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: texCoords)
        ], elements: [
            SCNGeometryElement(indices: front, primitiveType: .triangles),
            SCNGeometryElement(indices: shell, primitiveType: .triangles)
        ])
        geometry.materials = [label, plastic]
        geometry.shaderModifiers = [.geometry: """
        #pragma arguments
        float diskBend;
        #pragma body
        float depth = clamp((_geometry.position.z + 0.68) / 1.36, 0.0, 1.0);
        _geometry.position.y += diskBend * depth * depth;
        _geometry.normal = normalize(_geometry.normal - float3(0.0, 0.0, _geometry.normal.y * diskBend * depth / 0.68));
        """]
        return geometry
    }

    private func setActivity(_ on: Bool) {
        led.emission.contents = on ? NSColor(srgbRed: 1, green: 0.12, blue: 0.025, alpha: 1) : NSColor.black
    }

    private static func labelImage() -> NSImage {
        NSImage(size: CGSize(width: 256, height: 256), flipped: false) { bounds in
            NSColor(srgbRed: 0.15, green: 0.14, blue: 0.13, alpha: 1).setFill()
            NSBezierPath(rect: bounds).fill()
            NSColor(srgbRed: 0.21, green: 0.20, blue: 0.18, alpha: 1).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 6, yRadius: 6).stroke()

            // The hub, read window and write-protect notch on the jacket.
            NSColor(srgbRed: 0.32, green: 0.30, blue: 0.27, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 92, y: 92, width: 72, height: 72)).fill()
            NSColor(srgbRed: 0.075, green: 0.064, blue: 0.058, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 112, y: 15, width: 32, height: 68), xRadius: 15, yRadius: 15).fill()
            NSBezierPath(rect: CGRect(x: 246, y: 173, width: 10, height: 21)).fill()
            NSBezierPath(ovalIn: CGRect(x: 164, y: 112, width: 10, height: 10)).fill()

            let paper = CGRect(x: 22, y: 172, width: 213, height: 64)
            NSColor(srgbRed: 0.83, green: 0.79, blue: 0.66, alpha: 1).setFill()
            NSBezierPath(roundedRect: paper, xRadius: 4, yRadius: 4).fill()
            NSColor(srgbRed: 0.65, green: 0.31, blue: 0.25, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(x: 28, y: 228, width: 201, height: 2)).fill()
            let ink: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "BradleyHandITCTT-Bold", size: 21) ?? NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 0.14, green: 0.22, blue: 0.41, alpha: 1)
            ]
            let title = NSAttributedString(string: "Resonance - Credits", attributes: ink)
            title.draw(at: CGPoint(x: paper.midX - title.size().width / 2, y: 197))
            return true
        }
    }
}
