import AppKit
import SceneKit
import Testing
@testable import Resonance

/// The 3D desk in About: the scene has the parts the app moves, and the tube
/// on the glass lands on the reference colors (design/crt-monitor/README.md:
/// border `#9e8be1`, background `#654db6`) once the room's reflection is in.
@MainActor
struct MonitorDeskTests {
    @Test func theSceneHasEveryPartTheDeskMoves() throws {
        let desk = try #require(DeskScene.make())
        let root = desk.scene.rootNode
        for key in C64Key.allCases {
            #expect(root.childNode(withName: key.nodeName, recursively: true) != nil, "\(key.nodeName)")
        }
        for name in ["screen", "power_button", "power_led", "sticker"] {
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

    /// The snapshot as base64 JPEG on one line, to look at from outside the
    /// app's sandbox, when the run sets TEST_RUNNER_MONITOR_DESK_SNAPSHOT=1.
    private static func printForALook(_ rep: NSBitmapImageRep, _ name: String) {
        guard ProcessInfo.processInfo.environment["MONITOR_DESK_SNAPSHOT"] != nil,
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        print("MonitorDeskTests snapshot \(name): " + jpeg.base64EncodedString())
    }
}
