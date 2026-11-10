import AppKit
import SceneKit
import simd

/// A little sheet of paper. Points are simulated in scene space, then baked
/// into the sheet's local mesh. Once stuck, the sheet moves with its object.
@MainActor
final class DeskSticker {
    private static let side = 7
    private static let count = side * side
    private static let floor: Float = 0.017
    private static let step: Float = 1.0 / 120
    private static let clearance: Float = 0.009
    private static let meshOptions = [SCNHitTestOption.backFaceCulling.rawValue: false]
    private static let singleMeshOptions = [
        SCNHitTestOption.backFaceCulling.rawValue: false,
        SCNHitTestOption.ignoreChildNodes.rawValue: true
    ]
    private static let paperVertices = (0..<count).filter { isPaperPixel(gridPoint($0)) }
    private static let surfaces: Set<String> = [
        "monitor_white", "monitor_black", "monitor_cap", "screen",
        "c64_body", "c64_details", "drive_1541", "joystick", "power_supply", "action_replay"
    ]

    private struct Link {
        let a: Int
        let b: Int
        let length: Float
        let stiffness: Float
    }

    private struct Grab {
        let start: CGPoint
        let pinOffset: CGPoint
        let depth: CGFloat
        let pin: Int
        let attached: [SIMD3<Float>]
        let right: SIMD3<Float>
        let down: SIMD3<Float>
        var point: CGPoint
        var carryDistance: Float?
        var needsCarryDepth = false
        var elapsed: Float = 0
        var peeled = false
    }

    private struct Landing {
        let node: SCNNode
        let pin: Int
        let origin: SIMD3<Float>
        let orientation: simd_quatf
        let shape: [SIMD3<Float>]
        let target: [SIMD3<Float>]
        let flightTime: Float
        var elapsed: Float = 0
    }

    @MainActor private struct MeshCandidate {
        let node: SCNNode
        let worldToLocal: simd_float4x4

        func hits(from start: SIMD3<Float>, to end: SIMD3<Float>) -> [SCNHitTestResult] {
            let a = worldToLocal * SIMD4(start, 1)
            let b = worldToLocal * SIMD4(end, 1)
            return node.hitTestWithSegment(from: SCNVector3(a.x, a.y, a.z), to: SCNVector3(b.x, b.y, b.z),
                                          options: DeskSticker.singleMeshOptions)
        }
    }

    private let original: SCNNode
    private let root: SCNNode
    private let sheet = SCNNode()
    private let originalPoints: [SIMD3<Float>]
    private let links: [Link]
    private let bends: [(start: Int, middle: Int, end: Int)]
    private let coordinates: SCNGeometrySource
    private let faces: [SCNGeometryElement]
    private let triangleIndices: [Int]
    private let landingSamples: [[Int]]
    private let materials: [SCNMaterial]
    private let width: Float
    private let height: Float
    private var localPoints: [SIMD3<Float>] = []
    private var points: [SIMD3<Float>] = []
    private var previous: [SIMD3<Float>] = []
    private var grab: Grab?
    private var landing: Landing?
    private var falling: Float?
    private var accumulator: Float = 0

    var isGrabbed: Bool { grab != nil }

    init?(original: SCNNode, mesh: SCNNode, root: SCNNode, front: SCNMaterial) {
        guard let corners = Self.corners(of: mesh) else { return nil }
        let side = Self.side
        self.original = original
        self.root = root
        width = simd_distance(corners[0], corners[1])
        height = simd_distance(corners[0], corners[2])
        var grid: [SIMD3<Float>] = []
        var uv: [CGPoint] = []
        for row in 0..<side {
            for column in 0..<side {
                let u = Float(column) / Float(side - 1), v = Float(row) / Float(side - 1)
                grid.append(corners[0] + (corners[1] - corners[0]) * u + (corners[2] - corners[0]) * v)
                uv.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
            }
        }
        originalPoints = grid
        coordinates = SCNGeometrySource(textureCoordinates: uv + uv)

        var links: [Link] = []
        var bends: [(start: Int, middle: Int, end: Int)] = []
        var frontFaces: [Int16] = []
        for row in 0..<side {
            for column in 0..<side {
                let a = row * side + column
                if row + 1 < side, column + 1 < side {
                    frontFaces += [a, a + side, a + 1, a + 1, a + side, a + side + 1].map(Int16.init)
                }
                // Edge lengths keep the paper from stretching in either direction.
                for (dx, dy, stiffness): (Int, Int, Float) in [
                    (1, 0, 0.96), (0, 1, 0.96), (1, 1, 0.88), (-1, 1, 0.88)
                ] where (0..<side).contains(column + dx) && row + dy < side {
                    let b = a + dy * side + dx
                    links.append(Link(a: a, b: b, length: simd_distance(grid[a], grid[b]), stiffness: stiffness))
                }
                if column + 2 < side { bends.append((a, a + 1, a + 2)) }
                if row + 2 < side { bends.append((a, a + side, a + 2 * side)) }
            }
        }
        self.links = links
        self.bends = bends
        triangleIndices = frontFaces.map(Int.init)
        var edges = Set<Int>()
        var samples: [[Int]] = []
        for offset in stride(from: 0, to: triangleIndices.count, by: 3) {
            let a = triangleIndices[offset], b = triangleIndices[offset + 1], c = triangleIndices[offset + 2]
            for (first, second) in [(a, b), (b, c), (a, c)] {
                let key = min(first, second) * Self.count + max(first, second)
                if edges.insert(key).inserted { samples.append([first, second]) }
            }
            samples.append([a, b, c])
        }
        landingSamples = samples.filter { indices in
            Self.isPaperPixel(indices.map(Self.gridPoint).reduce(.zero, +) / Float(indices.count))
        }
        let backFaces = Array(frontFaces.reversed()).map { $0 + Int16(Self.count) }
        faces = [
            SCNGeometryElement(indices: frontFaces, primitiveType: .triangles),
            SCNGeometryElement(indices: backFaces, primitiveType: .triangles)
        ]
        let back = SCNMaterial()
        back.lightingModel = .physicallyBased
        back.diffuse.contents = NSColor(srgbRed: 0.76, green: 0.73, blue: 0.63, alpha: 1)
        back.transparent.contents = front.diffuse.contents
        back.transparencyMode = .aOne
        back.roughness.contents = 0.84
        materials = [front, back]

        sheet.name = "sticker_paper"
        sheet.isHidden = true
        root.addChildNode(sheet)
    }

    func reset() {
        grab = nil
        landing = nil
        falling = nil
        accumulator = 0
        sheet.isHidden = true
        root.addChildNode(sheet)
        original.isHidden = false
    }

    private func contains(_ node: SCNNode) -> Bool {
        node === sheet || node === original
    }

    private func visiblePoints() -> [SIMD3<Float>] {
        original.isHidden ? localPoints.map { sheet.simdConvertPosition($0, to: nil) } : originalPoints
    }

    /// Intersect the thin paper from either side. The imported decal itself
    /// isn't always returned by SceneKit's mesh hit test.
    func pick(at point: CGPoint, in view: SCNView, blocker: SCNHitTestResult?) -> SIMD3<Float>? {
        let near = SIMD3<Float>(view.unprojectPoint(SCNVector3(point.x, point.y, 0)))
        let far = SIMD3<Float>(view.unprojectPoint(SCNVector3(point.x, point.y, 1)))
        let ray = Self.unit(far - near, fallback: [0, 0, -1])
        let points = visiblePoints()
        var nearest = Float.infinity
        for offset in stride(from: 0, to: triangleIndices.count, by: 3) {
            let a = triangleIndices[offset], b = triangleIndices[offset + 1], c = triangleIndices[offset + 2]
            let first = points[b] - points[a], second = points[c] - points[a]
            let cross = simd_cross(ray, second)
            let det = simd_dot(first, cross)
            guard abs(det) > 0.00001 else { continue }
            let relative = near - points[a]
            let u = simd_dot(relative, cross) / det
            let q = simd_cross(relative, first)
            let v = simd_dot(ray, q) / det
            let t = simd_dot(second, q) / det
            guard u >= 0, v >= 0, u + v <= 1, t >= 0, t < nearest else { continue }
            let grid = Self.gridPoint(a) * (1 - u - v) + Self.gridPoint(b) * u + Self.gridPoint(c) * v
            guard Self.isPaperPixel(grid) else { continue }
            nearest = t
        }
        guard nearest.isFinite else { return nil }
        if let blocker, !isPaper(blocker.node),
           simd_distance(near, SIMD3<Float>(blocker.worldCoordinates)) + 0.025 < nearest {
            return nil
        }
        return near + ray * nearest
    }

    private func isPaper(_ hit: SCNNode) -> Bool {
        var node: SCNNode? = hit
        while let current = node {
            if contains(current) { return true }
            node = current.parent
        }
        return false
    }

    private static func gridPoint(_ index: Int) -> SIMD2<Float> {
        SIMD2(Float(index % side), Float(index / side)) / Float(side - 1)
    }

    func begin(at point: CGPoint, in view: SCNView) -> Bool {
        let blocker = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]).first
        guard let world = pick(at: point, in: view, blocker: blocker) else { return false }
        let attached = visiblePoints()
        guard let pin = attached.indices.min(by: {
            simd_distance_squared(attached[$0], world) < simd_distance_squared(attached[$1], world)
        }) else { return false }

        let last = Self.side - 1
        let right = Self.unit(attached[last] - attached[0], fallback: [1, 0, 0])
        let down = Self.unit(attached[last * Self.side] - attached[0], fallback: [0, -1, 0])
        let projected = view.projectPoint(SCNVector3(attached[pin]))
        let offset = CGPoint(x: projected.x - point.x, y: projected.y - point.y)
        grab = Grab(start: point, pinOffset: offset, depth: projected.z, pin: pin,
                    attached: attached, right: right, down: down, point: point)
        return true
    }

    func drag(to point: CGPoint) {
        guard var grab else { return }
        grab.point = point
        if !grab.peeled, hypot(point.x - grab.start.x, point.y - grab.start.y) >= 3 {
            grab.peeled = true
            landing = nil
            falling = nil
            accumulator = 0
            points = grab.attached
            previous = points
            original.isHidden = true
            root.addChildNode(sheet)
            sheet.isHidden = false
            publish()
        }
        if grab.peeled {
            grab.needsCarryDepth = true
        }
        self.grab = grab
    }

    private func carryDistance(for grab: Grab, in view: SCNView) -> Float? {
        guard let eye = view.pointOfView?.simdWorldPosition else { return nil }
        let grip = CGPoint(x: grab.point.x + grab.pinOffset.x, y: grab.point.y + grab.pinOffset.y)
        let pin = view.projectPoint(SCNVector3(points[grab.pin]))
        let shift = CGPoint(x: grip.x - pin.x, y: grip.y - pin.y)
        let last = Self.side - 1
        var depths: [CGFloat] = []
        for i in [grab.pin, Self.count / 2, 0, last, last * Self.side, Self.count - 1] {
            let p = view.projectPoint(SCNVector3(points[i]))
            let sample = CGPoint(x: p.x + shift.x, y: p.y + shift.y)
            if let hit = visibleHit(at: sample, in: view) {
                depths.append(view.projectPoint(hit.worldCoordinates).z)
            }
        }
        let depth = depths.min() ?? grab.depth
        let surface = SIMD3<Float>(view.unprojectPoint(SCNVector3(grip.x, grip.y, depth)))
        // The gap leaves room for the whole sheet, including the edges that
        // lag behind the hand. Over empty space the paper stays lifted.
        let clearance: Float = depths.isEmpty ? 2.0 : 0.85
        return max(0.5, simd_distance(eye, surface) - clearance)
    }

    func release(at point: CGPoint?, in view: SCNView) {
        guard let grab else { return }
        self.grab = nil
        guard grab.peeled else { return }
        if let point, let landing = findLanding(at: point, pin: grab.pin, in: view, right: grab.right) {
            self.landing = landing
            return
        }
        // An edge grip can miss while the middle of the paper is over a surface.
        let middle = Self.count / 2
        let projected = view.projectPoint(SCNVector3(points[middle]))
        if point.map(view.bounds.contains) == true, projected.z > 0, projected.z < 1,
           let landing = findLanding(at: CGPoint(x: projected.x, y: projected.y),
                                     pin: middle, in: view, right: grab.right) {
            self.landing = landing
            return
        }

        // Release momentum plus a small torque from letting go by one corner.
        let center = points[Self.count / 2]
        let spin = SIMD3<Float>(3.7, -1.2, 2.4)
        for i in points.indices {
            let carried = Self.limited((points[i] - previous[i]) / Self.step, to: 4)
            previous[i] = points[i] - (carried * 0.56 + simd_cross(spin, points[i] - center)) * Self.step
        }
        falling = 0
    }

    func update(dt: Float, in view: SCNView) {
        if grab?.peeled == false { return }
        if var landing {
            let before = points
            landing.elapsed += dt
            let target = landing.target.map { landing.node.simdConvertPosition($0, to: nil) }
            if landing.elapsed >= landing.flightTime + 0.13 {
                points = target
                landing.node.addChildNode(sheet)
                self.landing = nil
            } else {
                let flight = min(1, landing.elapsed / landing.flightTime)
                let press = max(0, (landing.elapsed - landing.flightTime) / 0.13)
                let targetOrientation = Self.orientation(of: target)
                let orientation = simd_slerp(landing.orientation, targetOrientation,
                                             flight * flight * (3 - 2 * flight))
                let contact = target[landing.pin]
                let grip = landing.origin + (contact - landing.origin) * (flight * flight)
                for i in points.indices {
                    let shape = targetOrientation.inverse.act(target[i] - contact)
                    let spread = simd_distance(originalPoints[i], originalPoints[landing.pin])
                    let flatten = min(1, max(0, (press - spread * 0.55) / 0.53))
                    let conform = 0.8 * flight + 0.2 * flatten
                    var offset = landing.shape[i] + (shape - landing.shape[i]) * conform
                    // Keep any remaining curl above the surface while it presses flat.
                    if flight == 1 { offset.z = max(shape.z, offset.z) }
                    points[i] = grip + orientation.act(offset)
                }
                resolveMeshCollisions(from: before)
                self.landing = landing
            }
            publish()
            return
        }

        guard grab?.peeled == true || falling != nil else { return }
        accumulator += min(dt, 0.065)
        guard accumulator >= Self.step else { return }
        // Mouse events can arrive several times between frames. Only the
        // latest pointer position will be used by the simulation.
        if var grab, grab.needsCarryDepth {
            grab.carryDistance = carryDistance(for: grab, in: view)
            grab.needsCarryDepth = false
            self.grab = grab
        }
        while accumulator >= Self.step {
            simulate(in: view)
            accumulator -= Self.step
        }
        publish()
    }

    private func simulate(in view: SCNView) {
        let before = points
        let dt = Self.step
        let side = Self.side
        var pinned = Array(repeating: false, count: Self.count)
        var grabTarget: SIMD3<Float>?
        if var grab {
            grab.elapsed += dt
            let lifted = min(1, grab.elapsed / 0.17)
            let world = SIMD3<Float>(view.unprojectPoint(SCNVector3(
                grab.point.x + grab.pinOffset.x, grab.point.y + grab.pinOffset.y, grab.depth
            )))
            let eye = view.pointOfView?.simdWorldPosition ?? [0, 4, 10]
            let ray = Self.unit(world - eye, fallback: [0, 0, -1])
            let origin = grab.attached[grab.pin]
            let peeled = origin + Self.limited(world - origin, to: 0.22 * lifted) - ray * (0.34 * lifted)
            let carried = eye + ray * (grab.carryDistance ?? simd_distance(world, eye) - 0.8)
            let carry = min(1, max(0, (grab.elapsed - 0.10) / 0.19))
            let aim = peeled + (carried - peeled) * (carry * carry * (3 - 2 * carry))
            grabTarget = points[grab.pin] + Self.limited(aim - points[grab.pin], to: 0.28)
            pinned[grab.pin] = true
            // The grip moves first. The adhesive releases across the sheet.
            if lifted < 1 {
                let origin = grab.attached[grab.pin]
                for i in points.indices where i != grab.pin {
                    if simd_distance(grab.attached[i], origin) > hypot(width, height) * lifted {
                        pinned[i] = true
                        points[i] = grab.attached[i]
                        previous[i] = points[i]
                    }
                }
            }
            self.grab = grab
        } else if let elapsed = falling {
            falling = elapsed + dt
        }

        for i in points.indices where !pinned[i] {
            let old = points[i]
            var force = SIMD3<Float>(0, grab == nil ? -17 : -3, 0)
            if let grab, let target = grabTarget {
                let x = Float(i % side - grab.pin % side) / Float(side - 1)
                let y = Float(i / side - grab.pin / side) / Float(side - 1)
                let guide = target + grab.right * (width * x) + grab.down * (height * y)
                force += (guide - old) * 58
                force += simd_cross(grab.down, grab.right) * (1.4 * sin(grab.elapsed * 17 + x * 4 + y * 5))
            } else if let elapsed = falling {
                // Air catches the two edges at different times during the fall.
                force.x += 2.0 * sin(elapsed * 8 + Float(i / side) * 0.6)
                force.z += 2.5 * sin(elapsed * 10 + Float(i % side) * 0.7)
            }
            let travel = Self.limited(old - previous[i], to: 0.10)
            points[i] += travel * (grab == nil ? 0.982 : 0.947) + force * dt * dt
            previous[i] = old
        }
        if let grab, let target = grabTarget {
            previous[grab.pin] = points[grab.pin]
            points[grab.pin] = target
        }

        for _ in 0..<6 {
            for link in links {
                let weightA: Float = pinned[link.a] ? 0 : 1
                let weightB: Float = pinned[link.b] ? 0 : 1
                guard weightA + weightB > 0 else { continue }
                let delta = points[link.b] - points[link.a]
                let length = simd_length(delta)
                guard length > 0.0001 else { continue }
                let correction = delta * ((length - link.length) / length * link.stiffness / (weightA + weightB))
                points[link.a] += correction * weightA
                points[link.b] -= correction * weightB
            }
            // Resist curvature directly. Long distance springs alone let a
            // nearly flat sheet fold with very little resistance.
            for bend in bends {
                let a: Float = pinned[bend.start] ? 0 : 1
                let b: Float = pinned[bend.middle] ? 0 : 1
                let c: Float = pinned[bend.end] ? 0 : 1
                let weight = b + (a + c) * 0.25
                guard weight > 0 else { continue }
                let midpoint = (points[bend.start] + points[bend.end]) * 0.5
                let correction = (points[bend.middle] - midpoint) * (0.38 / weight)
                points[bend.start] += correction * (0.5 * a)
                points[bend.middle] -= correction * b
                points[bend.end] += correction * (0.5 * c)
            }
            for i in points.indices where !pinned[i] && points[i].y < Self.floor {
                let travel = points[i] - previous[i]
                points[i].y = Self.floor
                previous[i] = points[i] - SIMD3(travel.x * 0.68, max(0, -travel.y) * 0.14, travel.z * 0.68)
            }
        }
        resolveMeshCollisions(from: before, excluding: pinned)
        if let elapsed = falling, elapsed > 0.4,
           (points.allSatisfy({ $0.y < Self.floor + 0.014 })
            || (elapsed > 1.2 && points.indices.allSatisfy {
                simd_distance_squared(before[$0], points[$0]) < 0.0015 * 0.0015
            })) {
            falling = nil
        }
    }

    private func resolveMeshCollisions(from before: [SIMD3<Float>], excluding pinned: [Bool]? = nil) {
        for i in Self.paperVertices where pinned?[i] != true {
            let movement = points[i] - before[i]
            guard simd_length_squared(movement) > 0.0000001,
                  let hit = meshHit(from: before[i], to: points[i], entering: movement) else { continue }
            let normal = Self.unit(SIMD3<Float>(hit.worldNormal), fallback: [0, 1, 0])
            points[i] = SIMD3<Float>(hit.worldCoordinates) + normal * Self.clearance
            let normalTravel = simd_dot(movement, normal)
            let slide = movement - normal * normalTravel
            previous[i] = points[i] - slide * 0.64 + normal * (normalTravel * 0.10)
        }
    }

    private func findLanding(at point: CGPoint, pin: Int, in view: SCNView, right gripRight: SIMD3<Float>) -> Landing? {
        guard let hit = surfaceHit(at: point, in: view), let eye = view.pointOfView?.simdWorldPosition else { return nil }
        let contact = SIMD3<Float>(hit.worldCoordinates)
        var normal = Self.unit(SIMD3<Float>(hit.worldNormal), fallback: [0, 0, 1])
        if simd_dot(normal, eye - contact) < 0 { normal = -normal }
        let tangent = gripRight - normal * simd_dot(gripRight, normal)
        let alternate = simd_cross(normal, abs(normal.y) > 0.9 ? [0, 0, 1] : [0, -1, 0])
        let right = Self.unit(tangent, fallback: simd_normalize(alternate))
        let down = simd_cross(right, normal)
        let grip = Self.gridPoint(pin)
        let center = contact + right * ((0.5 - grip.x) * width) + down * ((0.5 - grip.y) * height)

        let footprint = points.indices.map { i in
            let grid = Self.gridPoint(i) - SIMD2<Float>(repeating: 0.5)
            return center + right * (grid.x * width) + down * (grid.y * height)
        }
        guard let heights = landingHeights(over: footprint, normal: normal, surface: hit.node) else { return nil }
        let target = footprint.indices.map { i in
            hit.node.simdConvertPosition(footprint[i] + normal * heights[i], from: nil)
        }
        let origin = points[pin]
        let orientation = Self.orientation(of: points)
        let shape = points.map { orientation.inverse.act($0 - origin) }
        let flightTime = min(0.55, max(0.17, sqrt(2 * simd_distance(origin, contact) / 19)))
        return Landing(node: hit.node, pin: pin, origin: origin, orientation: orientation,
                       shape: shape, target: target, flightTime: flightTime)
    }

    private func landingHeights(over footprint: [SIMD3<Float>], normal: SIMD3<Float>, surface: SCNNode) -> [Float]? {
        let above = normal * max(width, height)
        let below = normal * 0.16
        // Find nearby meshes once, then reuse their transforms for every probe.
        let candidates = meshCandidates(over: footprint, above: above, below: below)
        func probe(_ point: SIMD3<Float>) -> SCNHitTestResult? {
            let start = point + above
            let end = point - below
            var closest: SCNHitTestResult?
            var distance = Float.infinity
            for candidate in candidates {
                for hit in candidate.hits(from: start, to: end) {
                    guard simd_dot(SIMD3<Float>(hit.worldNormal), normal) > 0.00001 else { continue }
                    let hitDistance = simd_distance_squared(start, SIMD3<Float>(hit.worldCoordinates))
                    if hitDistance < distance {
                        closest = hit
                        distance = hitDistance
                    }
                }
            }
            return closest
        }

        let maxLift: Float = 0.11
        var heights = Array(repeating: Float(0.024), count: Self.count)
        var support = 0
        for i in Self.paperVertices {
            guard let hit = probe(footprint[i]) else { continue }
            let height = simd_dot(SIMD3<Float>(hit.worldCoordinates) - footprint[i], normal)
            if hit.node === surface {
                heights[i] = height + Self.clearance
                support += 1
            } else {
                heights[i] = max(heights[i], height + Self.clearance)
            }
            guard heights[i] < maxLift else { return nil }
        }
        guard support >= 12 else { return nil }

        // Check each shared edge and triangle center once. Subsequent lifts
        // only raise the sheet, so they can't invalidate an earlier sample.
        for indices in landingSamples {
            let count = Float(indices.count)
            let sample = indices.reduce(SIMD3<Float>.zero) { $0 + footprint[$1] } / count
            guard let hit = probe(sample) else { continue }
            let height = simd_dot(SIMD3<Float>(hit.worldCoordinates) - sample, normal) + Self.clearance
            let paper = indices.reduce(Float.zero) { $0 + heights[$1] } / count
            let lift = max(0, height - paper)
            for i in indices {
                heights[i] += lift
                // The sheet can bridge shallow seams, but can't wrap around a sharp corner.
                guard heights[i] < maxLift else { return nil }
            }
        }
        return heights
    }

    private func meshCandidates(over footprint: [SIMD3<Float>], above: SIMD3<Float>,
                                below: SIMD3<Float>) -> [MeshCandidate] {
        let padding = SIMD3<Float>(repeating: 0.0001)
        let low = footprint.reduce(SIMD3<Float>(repeating: .infinity), simd_min) + simd_min(above, -below) - padding
        let high = footprint.reduce(SIMD3<Float>(repeating: -.infinity), simd_max) + simd_max(above, -below) + padding
        var candidates: [MeshCandidate] = []
        func visit(_ node: SCNNode) {
            guard !node.isHidden, !contains(node) else { return }
            if let geometry = node.geometry, !(geometry is SCNFloor) {
                let (min, max) = geometry.boundingBox
                let center = (SIMD3<Float>(min) + SIMD3<Float>(max)) * 0.5
                let extent = SIMD3<Float>(max) - center
                let world = node.simdWorldTransform
                let position = world * SIMD4(center, 1)
                let radius = simd_abs(world.columns.0) * extent.x + simd_abs(world.columns.1) * extent.y
                           + simd_abs(world.columns.2) * extent.z
                let minimum = position - radius
                let maximum = position + radius
                if minimum.x <= high.x, minimum.y <= high.y, minimum.z <= high.z,
                   maximum.x >= low.x, maximum.y >= low.y, maximum.z >= low.z {
                    candidates.append(MeshCandidate(node: node, worldToLocal: world.inverse))
                }
            }
            for child in node.childNodes { visit(child) }
        }
        visit(root)
        return candidates
    }

    private func surfaceHit(at point: CGPoint, in view: SCNView) -> SCNHitTestResult? {
        guard let hit = visibleHit(at: point, in: view) else { return nil }
        var node: SCNNode? = hit.node
        while let current = node {
            if let name = current.name, Self.surfaces.contains(name) { return hit }
            node = current.parent
        }
        return nil
    }

    private func visibleHit(at point: CGPoint, in view: SCNView) -> SCNHitTestResult? {
        guard view.bounds.contains(point) else { return nil }
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        return hits.first { !isPaper($0.node) && !($0.node.geometry is SCNFloor) }
    }

    private func meshHit(from start: SIMD3<Float>, to end: SIMD3<Float>, entering movement: SIMD3<Float>) -> SCNHitTestResult? {
        let a = SCNVector3(root.simdConvertPosition(start, from: nil))
        let b = SCNVector3(root.simdConvertPosition(end, from: nil))
        let hits = root.hitTestWithSegment(from: a, to: b, options: Self.meshOptions)
        return hits.first {
            !isPaper($0.node) && !($0.node.geometry is SCNFloor)
                && simd_dot(SIMD3<Float>($0.worldNormal), movement) < -0.00001
        }
    }

    private static func isPaperPixel(_ uv: SIMD2<Float>) -> Bool {
        let corner = simd_max(simd_abs(uv - SIMD2<Float>(0.5, 0.5)) - SIMD2(0.28, 0.28), .zero)
        return simd_length_squared(corner) <= 0.22 * 0.22
    }

    private func publish() {
        let center = points.reduce(SIMD3<Float>.zero, +) / Float(Self.count)
        sheet.simdWorldPosition = center
        localPoints = points.map { sheet.simdConvertPosition($0, from: nil) }
        let side = Self.side
        let normals = localPoints.indices.map { i in
            let row = i / side, column = i % side
            let dx = localPoints[row * side + min(side - 1, column + 1)] - localPoints[row * side + max(0, column - 1)]
            let dy = localPoints[min(side - 1, row + 1) * side + column] - localPoints[max(0, row - 1) * side + column]
            return Self.unit(simd_cross(dy, dx), fallback: [0, 0, 1])
        }
        let vertices = SCNGeometrySource(vertices: (localPoints + localPoints).map { SCNVector3($0) })
        let lighting = SCNGeometrySource(normals: (normals + normals.map { -$0 }).map { SCNVector3($0) })
        let geometry = SCNGeometry(sources: [vertices, lighting, coordinates], elements: faces)
        geometry.materials = materials
        sheet.geometry = geometry
    }

    private static func unit(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        simd_length_squared(vector) > 0.000001 ? simd_normalize(vector) : fallback
    }

    private static func orientation(of points: [SIMD3<Float>]) -> simd_quatf {
        let right = unit(points[side - 1] - points[0], fallback: [1, 0, 0])
        let down = points[count - side] - points[0]
        let normal = unit(simd_cross(down, right), fallback: [0, 0, 1])
        return simd_quatf(simd_float3x3(columns: (right, simd_cross(normal, right), normal)))
    }

    private static func limited(_ vector: SIMD3<Float>, to limit: Float) -> SIMD3<Float> {
        let length = simd_length(vector)
        return length > limit ? vector * (limit / length) : vector
    }

    private static func corners(of mesh: SCNNode) -> [SIMD3<Float>]? {
        guard let vertices = mesh.geometry?.sources(for: .vertex).first,
              let uv = mesh.geometry?.sources(for: .texcoord).first,
              vertices.vectorCount == 4, uv.vectorCount == 4,
              vertices.bytesPerComponent == 4, uv.bytesPerComponent == 4,
              vertices.usesFloatComponents, uv.usesFloatComponents else { return nil }
        func component(_ source: SCNGeometrySource, _ index: Int, _ column: Int) -> Float {
            source.data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: source.dataOffset + index * source.dataStride + column * 4, as: Float.self)
            }
        }
        var result = Array(repeating: SIMD3<Float>.zero, count: 4)
        for i in 0..<4 {
            let x = component(uv, i, 0) > 0.5 ? 1 : 0
            let y = component(uv, i, 1) > 0.5 ? 1 : 0
            let local = SIMD3(component(vertices, i, 0), component(vertices, i, 1), component(vertices, i, 2))
            result[y * 2 + x] = mesh.simdConvertPosition(local, to: nil)
        }
        return result
    }
}
