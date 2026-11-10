import AppKit
import SceneKit
import simd
import Testing
@testable import Resonance

/// The 3D desk in About: the scene has the parts the app moves, and the tube
/// on the glass lands on the reference colors (design/crt-monitor/README.md:
/// border `#9e8be1`, background `#654db6`) once the room's reflection is in.
@MainActor
@Suite(.serialized)
struct MonitorDeskTests {
    @Test func theSceneHasEveryPartTheDeskMoves() throws {
        let desk = try #require(DeskScene.make())
        let root = desk.scene.rootNode
        for key in C64Key.allCases {
            #expect(root.childNode(withName: key.nodeName, recursively: true) != nil, "\(key.nodeName)")
        }
        for name in ["screen", "power_button", "power_led", "c64_power_led", "sticker"] {
            #expect(root.childNode(withName: name, recursively: true) != nil, "\(name)")
        }
    }

    @Test func theMacKeysPressTheC64Keys() {
        #expect(C64Key.keys(for: "\"") == [.leftShift, .digit2])
        #expect(C64Key.keys(for: "l") == [.l])
        #expect(C64Key.keys(for: "L") == [.l])
        #expect(C64Key.keys(for: ",") == [.comma])
        #expect(C64Key.keys(for: "?") == [.leftShift, .slash])
        #expect(C64Key(nodeName: "key_RUN_STOP") == .runStop)
        #expect(C64Key.allCases.count == 66)
    }

    @Test func whatTheC64TypesGoesDownOnItsKeys() throws {
        let desk = try #require(DeskScene.make())
        let view = DeskView(frame: NSRect(x: 0, y: 0, width: 320, height: 267))
        desk.attach(to: view, store: PlayerStore.preview)
        defer { desk.detach(from: view) }
        let key = try #require(desk.scene.rootNode.childNode(withName: "key_2", recursively: true))
        let shift = try #require(desk.scene.rootNode.childNode(withName: "key_LEFT_SHIFT", recursively: true))
        let rest = key.simdWorldPosition.y, shiftRest = shift.simdWorldPosition.y
        let now = CACurrentMediaTime()
        desk.update(at: now)
        MonitorModel.shared.typed?("\"")
        desk.update(at: now + 0.05)
        #expect(abs(rest - key.simdWorldPosition.y - DeskScene.keyTravel) < 0.001)
        #expect(abs(shiftRest - shift.simdWorldPosition.y - DeskScene.keyTravel) < 0.001)
        desk.update(at: now + 0.5)
        desk.update(at: now + 0.7)
        #expect(abs(rest - key.simdWorldPosition.y) < 0.001)
    }

    @Test func clickingTheInstalledCartridgeOpensTheFreezeMenu() throws {
        let desk = try #require(DeskScene.make())
        let view = DeskView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1000))
        let store = PlayerStore.preview
        let model = MonitorModel.shared
        model.startOver()
        desk.attach(to: view, store: store)
        defer { desk.detach(from: view); model.startOver() }

        let cartridge = try #require(desk.scene.rootNode.childNode(withName: "action_replay", recursively: true))
        let button = try #require(cartridge.childNode(withName: "freeze_button", recursively: true))
        let reset = try #require(cartridge.childNode(withName: "reset_button", recursively: true))
        let power = try #require(desk.scene.rootNode.childNode(withName: "power_button", recursively: true))
        let powerRest = power.simdWorldPosition
        // Warm the renderer before powering up. A slow first snapshot can
        // otherwise trip the monitor's idle reset in the middle of this test.
        _ = view.snapshot()
        let now = CACurrentMediaTime()
        desk.update(at: now)
        model.hostGrown = true
        model.showPlayer(store: store)
        desk.update(at: now + 0.01)
        desk.update(at: now + 1.5)
        SCNTransaction.flush()
        let powerTravel = power.simdWorldPosition - powerRest
        #expect(simd_dot(powerTravel, DeskScene.buttonNormal) < -0.01)
        #expect(simd_length(simd_cross(powerTravel, DeskScene.buttonNormal)) < 0.001)

        func point(of node: SCNNode) -> CGPoint {
            let projected = view.projectPoint(node.worldPosition)
            return CGPoint(x: projected.x, y: projected.y)
        }

        let freezePoint = point(of: button)
        #expect(view.bounds.contains(freezePoint))
        #expect(desk.isClickable(at: freezePoint))
        let camera = try #require(view.pointOfView)
        let restPosition = camera.simdWorldPosition
        desk.pointerMoved(to: point(of: power))
        desk.update(at: now + 1.6)
        #expect(simd_distance(camera.simdWorldPosition, restPosition) < 0.001)

        desk.pointerMoved(to: freezePoint)
        for frame in 17...21 {
            desk.update(at: now + Double(frame) / 10)
        }
        try #require(model.isOn)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(camera.simdWorldPosition.y > restPosition.y + 2)
        }

        let leanedPosition = camera.simdWorldPosition
        SCNTransaction.flush()
        desk.pointerMoved(to: point(of: power))
        desk.update(at: now + 2.2)
        #expect(simd_distance(camera.simdWorldPosition, leanedPosition) < 0.001)

        let raisedPoint = point(of: button)
        #expect(view.bounds.contains(raisedPoint))
        desk.mouseDown(at: raisedPoint, flags: [])
        #expect(model.mode == .frozen)
        desk.update(at: now + 2.22)
        var menuTitle = C64Frame()
        menuTitle.line(10, "               FREEZE MENU")
        let row = (10 * C64Frame.columns)..<(11 * C64Frame.columns)
        #expect(model.frame.cells[row] == menuTitle.cells[row])

        desk.mouseDown(at: point(of: reset), flags: [])
        #expect(model.mode == .boot)
        #expect(model.power == .on)
        #expect(model.hostGrown)
    }

    @Test func theMonitorHatchStartsOpenAndTogglesWithTheTubeOff() throws {
        let desk = try #require(DeskScene.make())
        let view = DeskView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1000))
        let model = MonitorModel.shared
        model.startOver()
        desk.attach(to: view, store: PlayerStore.preview)
        defer { desk.detach(from: view); model.startOver() }
        desk.update(at: CACurrentMediaTime())
        _ = view.snapshot()

        let hinge = try #require(desk.scene.rootNode.childNode(withName: "monitor_hatch_hinge", recursively: true))
        // A point on the panel itself, clear of the side brackets.
        let surfaceInHinge = SIMD3<Float>(-0.5, 0.074, -0.06) - DeskScene.hatchHinge
        func clickHatch() {
            let projected = view.projectPoint(SCNVector3(hinge.simdConvertPosition(surfaceInHinge, to: nil)))
            let point = CGPoint(x: projected.x, y: projected.y)
            #expect(desk.isClickable(at: point))
            desk.mouseDown(at: point, flags: [])
            desk.update(at: CACurrentMediaTime() + 0.35)
            SCNTransaction.flush()
        }

        #expect(abs(hinge.simdEulerAngles.x) < 0.001)
        clickHatch()
        #expect(abs(hinge.simdEulerAngles.x - DeskScene.hatchClosedAngle) < 0.001)
        clickHatch()
        #expect(abs(hinge.simdEulerAngles.x) < 0.001)
        #expect(model.power == .off)
    }

    @Test func draggingTheKnobsAdjustsThemAndClickingResetsThem() throws {
        let desk = try #require(DeskScene.make())
        let view = DeskView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1000))
        let store = PlayerStore.preview
        let oldVolume = store.volume
        let model = MonitorModel.shared
        model.startOver()
        store.volume = 0.5
        desk.attach(to: view, store: store)
        defer {
            store.volume = oldVolume
            desk.detach(from: view)
            model.startOver()
        }

        desk.update(at: CACurrentMediaTime())
        _ = view.snapshot()
        let knob = try #require(desk.scene.rootNode.childNode(withName: "knob_volume", recursively: true))
        let material = try #require(knob.childNodes.first?.geometry?.firstMaterial)
        let emission = material.emission.contents as? NSColor
        let orientation = knob.simdWorldOrientation
        func point(of knob: SCNNode) -> CGPoint {
            let projected = view.projectPoint(SCNVector3(knob.simdWorldPosition + SIMD3(0, 0, 0.075)))
            return CGPoint(x: projected.x, y: projected.y)
        }

        let start = point(of: knob)
        #expect(desk.pointerMoved(to: start))
        #expect(material.emission.contents as? NSColor != emission)

        desk.mouseDown(at: start, flags: [])
        desk.mouseDragged(to: CGPoint(x: start.x + 30, y: start.y))
        #expect(abs(store.volume - 0.7) < 0.001)
        #expect(abs(simd_dot(knob.simdWorldOrientation.vector, orientation.vector)) < 0.99)
        desk.mouseUp()
        #expect(material.emission.contents as? NSColor == emission)
        desk.mouseDragged(to: start)
        #expect(abs(store.volume - 0.7) < 0.001)

        desk.mouseDown(at: start, flags: [])
        desk.mouseDragged(to: CGPoint(x: start.x + 1, y: start.y))
        desk.mouseUp()
        #expect(store.volume == PlayerStore.defaultVolume)

        let brightness = try #require(desk.scene.rootNode.childNode(withName: "knob_brightness", recursively: true))
        let neutral = brightness.simdWorldOrientation.vector
        let brightnessPoint = point(of: brightness)
        func adjustBrightness() {
            desk.mouseDown(at: brightnessPoint, flags: [])
            desk.mouseDragged(to: CGPoint(x: brightnessPoint.x + 30, y: brightnessPoint.y))
            desk.mouseUp()
            #expect(abs(simd_dot(brightness.simdWorldOrientation.vector, neutral)) < 0.99)
        }

        adjustBrightness()
        desk.mouseDown(at: brightnessPoint, flags: [])
        desk.mouseUp()
        #expect(abs(simd_dot(brightness.simdWorldOrientation.vector, neutral)) > 0.999)

        adjustBrightness()
        store.volume = 0.65
        model.hostGrown = true
        model.showPlayer(store: store)
        desk.update(at: CACurrentMediaTime())
        model.powerOff(animated: false)
        desk.update(at: CACurrentMediaTime())
        #expect(abs(simd_dot(brightness.simdWorldOrientation.vector, neutral)) > 0.999)
        #expect(store.volume == 0.65)
    }

    @Test func theStickerPeelsSticksToTheDriveAndFallsOnAMiss() throws {
        let desk = try #require(DeskScene.make())
        let view = DeskView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1000))
        let model = MonitorModel.shared
        model.startOver()
        desk.attach(to: view, store: PlayerStore.preview)
        defer { desk.detach(from: view); model.startOver() }
        let root = desk.scene.rootNode
        let original = try #require(root.childNode(withName: "sticker", recursively: true))
        let paper = try #require(root.childNode(withName: "sticker_paper", recursively: true))
        // A thin lip on the drive, between the original placement samples.
        let ridge = SCNNode(geometry: SCNBox(width: 0.035, height: 0.06, length: 0.36, chamferRadius: 0))
        ridge.position = SCNVector3(-4.25, 1.015, -0.71)
        root.addChildNode(ridge)
        defer { ridge.removeFromParentNode() }
        _ = view.snapshot()
        var now = CACurrentMediaTime()
        desk.update(at: now)
        SCNTransaction.flush()

        func project(_ world: SCNVector3) -> CGPoint {
            let p = view.projectPoint(world)
            return CGPoint(x: p.x, y: p.y)
        }
        func advance(_ frames: Int) {
            for _ in 0..<frames {
                now += 1.0 / 60
                desk.update(at: now)
            }
            SCNTransaction.flush()
        }

        desk.mouseDown(at: project(original.worldPosition), flags: [])
        try #require(desk.isHoldingSticker)
        let eye = try #require(view.pointOfView).simdWorldPosition
        let breadbin = SCNVector3(-0.5, 0.45, 4.05)
        desk.mouseDragged(to: project(breadbin))
        advance(42)
        let near = simd_distance(eye, paper.simdWorldPosition)
        #expect(near + 0.25 < simd_distance(eye, SIMD3<Float>(breadbin)))

        let drive = project(SCNVector3(-4.4, 0.95, -0.8))
        desk.mouseDragged(to: drive)
        advance(42)
        #expect(original.isHidden)
        #expect(!paper.isHidden)
        let carried = simd_distance(eye, paper.simdWorldPosition)
        #expect(carried > near + 0.5)
        desk.mouseUp(at: drive)
        advance(8)
        #expect(paper.parent === root)
        #expect(simd_distance(eye, paper.simdWorldPosition) > carried + 0.04)
        advance(42)
        #expect(paper.parent?.parent?.name == "drive_1541")
        let aboveRidge = paper.convertPosition(SCNVector3(-4.25, 1.5, -0.71), from: nil)
        let belowRidge = paper.convertPosition(SCNVector3(-4.25, 0.93, -0.71), from: nil)
        let stickerAtRidge = try #require(paper.hitTestWithSegment(from: aboveRidge, to: belowRidge, options: nil).first)
        #expect(stickerAtRidge.worldCoordinates.y > 1.045)

        desk.mouseDown(at: project(paper.worldPosition), flags: [])
        try #require(desk.isHoldingSticker)
        let blank = CGPoint(x: 40, y: 920)
        desk.mouseDragged(to: blank)
        advance(34)
        #expect(paper.worldPosition.y > 1)
        desk.mouseUp(at: blank)
        advance(150)
        #expect(paper.parent === root)
        #expect(paper.worldPosition.y < 0.04)
    }

    @Test func clickingTheFloppyPlaysCreditsOnTheTubeAndReturnsToThePlayer() async throws {
        let desk = try #require(DeskScene.make())
        let view = DeskView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1000), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue,
        ])
        let store = PlayerStore.preview
        let model = MonitorModel.shared
        model.startOver()
        desk.attach(to: view, store: store)
        defer { desk.detach(from: view); model.startOver() }
        let root = desk.scene.rootNode
        let disk = try #require(root.childNode(withName: "credits_floppy", recursively: true))
        let latch = try #require(root.childNode(withName: "drive_door_hinge", recursively: true))
        let rest = disk.simdWorldPosition
        #expect(disk.hitTestWithSegment(from: SCNVector3(0, 0.1, 0), to: SCNVector3(0, -0.1, 0), options: nil).isEmpty)
        #expect(!disk.hitTestWithSegment(from: SCNVector3(0, 0.1, -0.35), to: SCNVector3(0, -0.1, -0.35), options: nil).isEmpty)
        _ = view.snapshot()
        desk.update(at: CACurrentMediaTime() - 2)
        model.hostGrown = true
        model.showPlayer(store: store)
        let now = CACurrentMediaTime()
        desk.update(at: now - 1.5)
        desk.update(at: now)
        SCNTransaction.flush()

        func picture(_ name: String? = nil) throws -> NSColor {
            _ = view.snapshot()
            let rep = try #require(view.snapshot().tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            if let name { Self.printForALook(rep, name) }
            let point = view.projectPoint(SCNVector3(0, DeskScene.screenCenterY + DeskScene.glassHalf.y * 0.8,
                                                     DeskScene.screenFrontZ))
            let x = Int(point.x / view.bounds.width * CGFloat(rep.pixelsWide))
            let y = Int((1 - point.y / view.bounds.height) * CGFloat(rep.pixelsHigh))
            return try #require(rep.colorAt(x: x, y: y))
        }

        let player = try picture("credits-disk")
        let camera = try #require(view.pointOfView)
        let glassCenter = SIMD3<Float>(0, DeskScene.screenCenterY, DeskScene.screenFrontZ)
        let playerDistance = simd_distance(camera.simdWorldPosition, glassCenter)
        let projected = view.projectPoint(disk.convertPosition(SCNVector3(0, 0, -0.35), to: nil))
        let point = CGPoint(x: projected.x, y: projected.y)
        try #require(view.bounds.contains(point))
        try #require(desk.isClickable(at: point))
        desk.mouseDown(at: point, flags: [])
        let clicked = CACurrentMediaTime()
        desk.update(at: clicked + 1.52)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(disk.simdWorldPosition.x < rest.x - 1)
            #expect((disk.geometry?.value(forKey: "diskBend") as? NSNumber)?.floatValue ?? 0 > 0.14)
            #expect(abs(latch.simdEulerAngles.x) < 0.01)
            let readEdge = disk.simdConvertPosition([0, 0, 0.68], to: nil)
            #expect(readEdge.z < disk.simdWorldPosition.z)
            if ProcessInfo.processInfo.environment["MONITOR_DESK_SNAPSHOT"] != nil,
               let rep = view.snapshot().tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) {
                Self.printForALook(rep, "credits-inserting")
            }
            let contact = disk.simdWorldPosition.z
            desk.update(at: clicked + 2.03)
            #expect(!disk.isHidden)
            #expect(disk.simdWorldPosition.z > contact + 0.2)
            #expect(abs(latch.simdEulerAngles.x) < 0.01)
        }
        desk.update(at: clicked + 3.34)
        #expect(disk.isHidden)
        #expect(latch.simdEulerAngles.x > 0.8)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           ProcessInfo.processInfo.environment["MONITOR_DESK_SNAPSHOT"] != nil,
           let rep = view.snapshot().tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) {
            Self.printForALook(rep, "credits-drive-light")
        }
        desk.update(at: clicked + 4.52)
        desk.update(at: clicked + 6.72)
        var credits = player
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(8))
            desk.update(at: clicked + 6.72)
            credits = try picture()
            if credits.blueComponent < player.blueComponent - 0.3 { break }
        }
        #expect(credits.blueComponent < player.blueComponent - 0.3)
        #expect(simd_distance(camera.simdWorldPosition, glassCenter) < playerDistance * 0.70)

        // A native fullscreen transition changes the viewport in place and may pause draws.
        model.setHostFullscreen(true)
        try await Task.sleep(for: .milliseconds(550))
        view.setFrameSize(NSSize(width: 1600, height: 900))
        desk.update(at: clicked + 7)
        #expect(model.isOn)
        SCNTransaction.flush()
        _ = view.snapshot()
        let sticker = try #require(root.childNode(withName: "sticker", recursively: true))
        let stickerPoint = view.projectPoint(sticker.worldPosition)
        let grip = CGPoint(x: stickerPoint.x, y: stickerPoint.y)
        #expect(!desk.pointerMoved(to: grip))
        desk.mouseDown(at: grip, flags: [])
        #expect(!desk.isHoldingSticker)
        model.setHostFullscreen(false)

        let tune = store.nowPlaying.map { CreditsScene.Tune(title: $0.displayTitle, author: $0.author) }
        let end = clicked + 5.3 + CreditsScene.length(tune: tune)
        desk.update(at: end)
        desk.update(at: end + 2)
        #expect(!disk.isHidden)
        #expect(abs(latch.simdEulerAngles.x) < 0.01)
        #expect(simd_distance(disk.simdWorldPosition, rest) < 0.001)
        #expect(model.mode == .player)
        #expect(abs(simd_distance(camera.simdWorldPosition, glassCenter) - playerDistance) < 0.4)
        let returned = try picture("credits-returned")
        #expect(abs(returned.blueComponent - player.blueComponent) < 0.15)
        let returnedStickerPoint = view.projectPoint(sticker.worldPosition)
        desk.mouseDown(at: CGPoint(x: returnedStickerPoint.x, y: returnedStickerPoint.y), flags: [])
        #expect(desk.isHoldingSticker)
        desk.mouseUp()
    }

    @Test func theGlassShowsTheReferenceColors() throws {
        let desk = try #require(DeskScene.make())
        let view = DeskView(frame: NSRect(x: 0, y: 0, width: 1680, height: 1400), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue,
        ])
        let store = PlayerStore.preview
        let model = MonitorModel.shared
        model.startOver()
        desk.attach(to: view, store: store)
        defer { desk.detach(from: view); model.startOver() }
        model.hostGrown = true
        model.showPlayer(store: store)
        let now = CACurrentMediaTime()
        desk.update(at: now)
        desk.update(at: now + 2)
        desk.update(at: now + 2.02)
        _ = view.snapshot()     // the first frame draws the tube; the second shows it
        let image = view.snapshot()

        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        Self.printForALook(rep, "on")

        // A point of the border (top, middle, where the vignette is least) and of the background
        // (row 13, the empty one between the list and PLAYING).
        func color(u: Float, v: Float) -> NSColor? {
            let x = (u * 2 - 1) * DeskScene.glassHalf.x, y = DeskScene.screenCenterY - (v * 2 - 1) * DeskScene.glassHalf.y
            let p = view.projectPoint(SCNVector3(x, y, DeskScene.screenFrontZ))
            let sx = Int(p.x / view.bounds.width * CGFloat(rep.pixelsWide))
            let sy = Int((1 - p.y / view.bounds.height) * CGFloat(rep.pixelsHigh))
            return rep.colorAt(x: sx, y: sy)
        }
        func hex(_ c: NSColor?) -> String {
            guard let c else { return "none" }
            return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        // The background: the darkest point along row 13, the empty one
        // between the list and PLAYING.
        let border = color(u: 0.5, v: 0.1)
        let background = stride(from: Float(0.3), through: 0.9, by: 0.02).compactMap { color(u: $0, v: 0.527) }
            .min { $0.brightnessComponent < $1.brightnessComponent }
        print("MonitorDeskTests: border \(hex(border)) (reference #9e8be1), background \(hex(background)) (#654db6)")
        // The glass alone, for the reflection's share: the same view with the tube dark.
        model.startOver()
        model.hostGrown = true
        desk.update(at: now + 2.04)
        _ = view.snapshot()
        let darkRep = view.snapshot().tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        if let darkRep { Self.printForALook(darkRep, "rest") }
        func darkColor(u: Float, v: Float) -> NSColor? {
            let x = (u * 2 - 1) * DeskScene.glassHalf.x, y = DeskScene.screenCenterY - (v * 2 - 1) * DeskScene.glassHalf.y
            let p = view.projectPoint(SCNVector3(x, y, DeskScene.screenFrontZ))
            return darkRep?.colorAt(x: Int(p.x), y: Int(1400 - p.y))
        }
        print("MonitorDeskTests: dark glass \(hex(darkColor(u: 0.06, v: 0.5))) and \(hex(darkColor(u: 0.75, v: 0.527)))")
        func close(_ c: NSColor?, _ r: Int, _ g: Int, _ b: Int, within: Int) -> Bool {
            guard let c else { return false }
            return abs(Int(c.redComponent * 255) - r) <= within && abs(Int(c.greenComponent * 255) - g) <= within
                && abs(Int(c.blueComponent * 255) - b) <= within
        }
        #expect(close(border, 0x9e, 0x8b, 0xe1, within: 10), "border \(hex(border))")
        #expect(close(background, 0x65, 0x4d, 0xb6, within: 10), "background \(hex(background))")
    }

    @Test func resizingAboutHoldsTheCameraInPlace() throws {
        let desk = try #require(DeskScene.make())
        let view = DeskView(frame: NSRect(x: 0, y: 0, width: 320, height: 267))
        let model = MonitorModel.shared
        let store = PlayerStore.preview
        model.startOver()
        desk.attach(to: view, store: store)
        defer { desk.detach(from: view); model.startOver() }
        let camera = try #require(view.pointOfView)
        let now = CACurrentMediaTime()
        desk.update(at: now)

        model.hostGrown = true
        model.setHostFullscreen(true)
        model.holdsCameraForWindowResize = true
        model.showPlayer(store: store)
        view.setFrameSize(NSSize(width: 1600, height: 900))
        desk.update(at: now + 2)
        #expect(camera.simdPosition == DeskScene.restPose.position)

        model.holdsCameraForWindowResize = false
        desk.update(at: now + 2.01)
        desk.update(at: now + 3.5)
        let poweredPosition = camera.simdPosition
        #expect(simd_distance(poweredPosition, DeskScene.restPose.position) > 1)

        model.holdsCameraForWindowResize = true
        model.powerOff(animated: false)
        view.setFrameSize(NSSize(width: 320, height: 267))
        desk.update(at: now + 5)
        #expect(camera.simdPosition == poweredPosition)
    }

    /// The snapshot as base64 JPEG on one line, to look at from outside the
    /// app's sandbox, when the run sets TEST_RUNNER_MONITOR_DESK_SNAPSHOT=1.
    private static func printForALook(_ rep: NSBitmapImageRep, _ name: String) {
        guard ProcessInfo.processInfo.environment["MONITOR_DESK_SNAPSHOT"] != nil,
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        print("MonitorDeskTests snapshot \(name): " + jpeg.base64EncodedString())
    }
}
