import Metal
import SceneKit
import SwiftUI

/// The live 3D desk in About Resonance: dark_igorek's Commodore 1702, C64,
/// 1541 and joystick (CC BY 4.0, prepared by design/crt-monitor/blender/scene.py
/// into Scenes/Desk.usdz), the tube drawn into a texture on the 1702's glass
/// by Shaders/Monitor.metal, the keys pressed as the C64 types and as you
/// type or click them, the camera gliding to the monitor on power. The
/// picture and its timing are MonitorModel's, as in the 2D MonitorCase,
/// which stays as the fallback. Reasons and measurements in
/// design/crt-monitor/README.md; the reference is design/crt-monitor/mockup-3d.html.
struct MonitorDesk: NSViewRepresentable {
    let store: PlayerStore
    let onPower: () -> Void

    func makeCoordinator() -> DeskScene? { DeskScene.make() }

    func makeNSView(context: Context) -> DeskView {
        let view = DeskView(frame: .zero, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue,
        ])
        context.coordinator?.attach(to: view, store: store)
        context.coordinator?.onPower = onPower
        return view
    }

    func updateNSView(_ view: DeskView, context: Context) {
        context.coordinator?.store = store
        context.coordinator?.onPower = onPower
    }

    static func dismantleNSView(_ view: DeskView, coordinator: DeskScene?) {
        coordinator?.detach(from: view)
    }
}

/// The SCNView, passing its clicks and the pointer to the desk.
final class DeskView: SCNView {
    weak var desk: DeskScene?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) {
        desk?.mouseDown(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
        if desk?.isHoldingSticker == true { NSCursor.closedHand.set() }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let wasHoldingSticker = desk?.isHoldingSticker == true
        desk?.mouseUp(at: point)
        if wasHoldingSticker {
            (desk?.isClickable(at: point) == true ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        desk?.mouseDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hot = desk?.pointerMoved(to: point) ?? false
        (hot ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        desk?.pointerMoved(to: nil)
        NSCursor.arrow.set()
    }

    // The window drags from its background, not from the desk.
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The scene and everything that moves in it. Updated once per display frame
/// on the main thread (`step`); the tube's texture is drawn on SceneKit's
/// render thread just before each frame (`renderer(_:willRenderScene:atTime:)`).
final class DeskScene: NSObject, SCNSceneRendererDelegate {
    static let url = Bundle.main.url(forResource: "Desk", withExtension: "usdz")
    static var available: Bool { url != nil && MTLCreateSystemDefaultDevice() != nil }

    // The scene's measurements, in its units (Y up, the machines facing +Z).
    /// Half the screen mesh's front, its center, and how far forward it is.
    static let meshHalf = SIMD2<Float>(1.5288, 1.10525)
    static let screenCenterY: Float = 2.26355
    static let screenFrontZ: Float = -0.196
    /// The glass that shows inside the bezel, a little smaller than the mesh
    /// (measured on the still render: 1308 of 1362 px wide, 958 of 983 tall).
    static let glassHalf = meshHalf * SIMD2(1308 / 1362, 958 / 983)
    /// About 4 mm: the caps are 0.22 wide, a C64's are 18 mm.
    static let keyTravel: Float = 0.05
    /// The POWER rocker goes in 3 mm, along the panel's normal.
    static let buttonNormal = simd_normalize(SIMD3<Float>(0, 0.548, 0.837))
    /// The asset's control-panel cover is modeled open, on this hinge.
    static let hatchHinge: SIMD3<Float> = [0, 0.224, -0.190]
    static let hatchClosedAngle: Float = -.pi / 2

    /// The camera at rest (the whole desk, three-quarters from the front) and
    /// on (the monitor with the keyboard in front of it), from the mockup.
    struct Pose {
        var position: SIMD3<Float>
        var target: SIMD3<Float>
    }
    static let restPose = Pose(position: [-3.6, 8.2, 17.5], target: [-0.2, 1.0, 0.3])
    static let onPose = Pose(position: [-0.25, 5.0, 10.6], target: [-0.25, 1.6, 1.0])
    private static let drivePose = Pose(position: [-5.6, 2.8, 6.35], target: [-3.95, 0.56, 0.84])

    let scene: SCNScene
    nonisolated let tube: TubePass
    var store: PlayerStore?
    var onPower: (() -> Void)?
    private weak var view: DeskView?
    private var link: CADisplayLink?

    private let cameraNode = SCNNode()
    private let screenMaterial = SCNMaterial()
    private let ledMaterial = SCNMaterial()
    private let screenLight = SCNLight()
    private var creditsDisk: DeskCreditsDisk?
    private var paperSticker: DeskSticker?
    var isHoldingSticker: Bool { paperSticker?.isGrabbed == true }
    private var button: (node: SCNNode, rest: SIMD3<Float>)?
    private var hatchPivot: SCNNode?
    private var hatchMotion: (from: Float, to: Float, start: Double)?
    private enum CartridgeButton: String, CaseIterable {
        case freeze = "freeze_button"
        case reset = "reset_button"
    }
    private var cartridgeButtons: [CartridgeButton: (node: SCNNode, rest: SIMD3<Float>, travel: SIMD3<Float>, pressedAt: Double)] = [:]
    private enum MonitorKnob: String, CaseIterable {
        case tint = "knob_tint"
        case color = "knob_color"
        case brightness = "knob_brightness"
        case contrast = "knob_contrast"
        case horizontal = "knob_horizontal"
        case vertical = "knob_vertical"
        case volume = "knob_volume"
    }
    private var knobs: [MonitorKnob: (node: SCNNode, rest: simd_quatf)] = [:]
    private var knobValues: [MonitorKnob: Float] = [:]
    private var knobDrag: (knob: MonitorKnob, lastX: CGFloat, hasDragged: Bool)?
    private var verticalPhase: Float = 0
    private var hoverMaterials: [String: [(material: SCNMaterial, emission: Any?)]] = [:]
    private var hoveredControl: String?
    private var caps: [C64Key: (node: SCNNode, rest: SIMD3<Float>, depth: Float)] = [:]

    // The frame on the tube, as last handed to the render thread.
    private var pixels = [UInt32](repeating: 0, count: C64Frame.width * C64Frame.height)
    private var uploaded: C64Frame?
    private var uploadedCursor: (x: Int, y: Int)?
    private var uploadedBlink = false
    private var frames: UInt32 = 0
    private var targetHeight = 0

    // The camera's power glide and its gentle drift while on.
    private var glide = (from: DeskScene.restPose, to: DeskScene.restPose, start: 0.0, duration: 1.0)
    private var bodyDrift = CameraNoise(interval: 3...7)
    private var handDrift = CameraNoise(interval: 0.6...1.5)
    private var driftRate: Float = 0
    private var driftResumeAt: Double = 0
    private var cartridgeLook: Float = 0
    private var cartridgeLookTarget: Float = 0
    private var pointerNearPower = false
    private var lastPower = MonitorModel.Power.off
    private var lastResets = -1
    private var buttonPressedAt = -10.0
    private var lastStep = 0.0

    // What holds the keys down.
    private var keyboardHeld: [UInt16: [C64Key]] = [:]
    private var modifiersHeld = Set<C64Key>()
    private var mouseHeld: C64Key?
    /// Shifts clicked with the mouse: they stay down until the next key
    /// (SHIFT LOCK until it's clicked again, as on the C64).
    private var latched = Set<C64Key>()
    private var taps: [C64Key: Double] = [:]
    private var keysDownLastFrame = Set<C64Key>()

    /// The desk, or nil without the scene or Metal. Loading the scene takes
    /// a few tenths of a second, so it's kept for the next time About opens;
    /// each opening still starts clean, from MonitorModel.startOver and the
    /// camera snapping back with it.
    static func make() -> DeskScene? {
        if let shared { return shared }
        guard let url, let device = MTLCreateSystemDefaultDevice(),
              let scene = try? SCNScene(url: url, options: nil),
              let tube = TubePass(device: device)
        else { return nil }
        shared = DeskScene(scene: scene, tube: tube)
        return shared
    }
    private static var shared: DeskScene?

    private init(scene: SCNScene, tube: TubePass) {
        self.scene = scene
        self.tube = tube
        super.init()
        build()
    }

    // MARK: Building the scene

    private func build() {
        let root = scene.rootNode

        for key in C64Key.allCases {
            if let node = root.childNode(withName: key.nodeName, recursively: true) {
                caps[key] = (node, node.simdWorldPosition, 0)
            }
        }
        if let node = root.childNode(withName: "power_button", recursively: true) {
            button = (node, node.simdPosition)
            prepareHover(on: node, named: "power_button")
        }
        if let hatch = root.childNode(withName: "monitor_cap", recursively: true) {
            let openTransform = hatch.simdWorldTransform
            let pivot = SCNNode()
            pivot.name = "monitor_hatch_hinge"
            root.addChildNode(pivot)
            pivot.simdWorldPosition = Self.hatchHinge
            pivot.addChildNode(hatch)
            hatch.simdWorldTransform = openTransform
            hatchPivot = pivot
        }
        for knob in MonitorKnob.allCases {
            guard let node = root.childNode(withName: knob.rawValue, recursively: true) else { continue }
            knobs[knob] = (node, node.simdWorldOrientation)
            prepareHover(on: node, named: knob.rawValue)
        }
        if let url = Bundle.main.url(forResource: "ActionReplay", withExtension: "usdz"),
           let cartridge = try? SCNScene(url: url, options: nil) {
            let mount = SCNNode()
            mount.name = "action_replay"
            for part in cartridge.rootNode.childNodes { mount.addChildNode(part) }
            // Behind the keyboard on its right, connector into the rear port.
            mount.simdPosition = [1.39, 0.46, 1.51]
            root.addChildNode(mount)
            for control in CartridgeButton.allCases {
                guard let cap = mount.childNode(withName: control.rawValue, recursively: true),
                      let parent = cap.parent else { continue }
                let travel = parent.simdConvertVector([0, 0, 0.032], from: mount)
                cartridgeButtons[control] = (cap, cap.simdPosition, travel, -10)
                prepareHover(on: cap, named: control.rawValue)
            }
        }

        // The glass: dark and glossy, the room in it, the tube's light added.
        if let screen = root.childNode(withName: "screen", recursively: true), let mesh = Self.geometryNode(in: screen) {
            let glass = mesh.geometry?.firstMaterial
            screenMaterial.lightingModel = .physicallyBased
            screenMaterial.diffuse.contents = glass?.diffuse.contents
            screenMaterial.diffuse.intensity = 0.03
            screenMaterial.metalness.contents = 0.0
            screenMaterial.roughness.contents = 0.2
            screenMaterial.clearCoat.contents = 0.5
            screenMaterial.clearCoatRoughness.contents = 0.05
            screenMaterial.diffuse.mappingChannel = 1        // the model's own UV map
            screenMaterial.emission.mappingChannel = 0       // "crt", which SceneKit lists first
            // Mipmapped: while the camera moves, the glass can be smaller
            // on screen than its texture for a frame or two.
            screenMaterial.emission.mipFilter = .linear
            screenMaterial.emission.contents = tube.resize(width: 512, height: 370)
            mesh.geometry?.materials = [screenMaterial]
            mesh.castsShadow = false
            // Out of the screen light's reach (it lights category 1 only):
            // the glass shows the tube's light, it isn't lit by it.
            mesh.categoryBitMask = 2
        }
        if let led = root.childNode(withName: "power_led", recursively: true), let mesh = Self.geometryNode(in: led) {
            ledMaterial.lightingModel = .physicallyBased
            ledMaterial.diffuse.contents = NSColor(red: 0.06, green: 0.19, blue: 0.10, alpha: 1)
            ledMaterial.roughness.contents = 0.35
            ledMaterial.emission.contents = NSColor.black
            mesh.geometry?.materials = [ledMaterial]
        }
        // The breadbin's LED is a 0.03-radius dome in the original mesh.
        // Fit a lit lens over it. This computer stays on when the CRT is off.
        let lens = SCNSphere(radius: 0.0308)
        let lensMaterial = SCNMaterial()
        lensMaterial.lightingModel = .physicallyBased
        lensMaterial.diffuse.contents = NSColor(srgbRed: 0.34, green: 0.02, blue: 0.015, alpha: 1)
        lensMaterial.emission.contents = NSColor(srgbRed: 0.69, green: 0.065, blue: 0.035, alpha: 1)
        lensMaterial.roughness.contents = 0.32
        lens.materials = [lensMaterial]
        let computerLED = SCNNode(geometry: lens)
        computerLED.name = "c64_power_led"
        computerLED.simdPosition = [1.61185, 0.8064, 2.34875]
        computerLED.castsShadow = false
        root.addChildNode(computerLED)
        if root.childNode(withName: "drive_1541", recursively: true) != nil {
            creditsDisk = DeskCreditsDisk(root: root)
        }
        if let sticker = root.childNode(withName: "sticker", recursively: true), let mesh = Self.geometryNode(in: sticker) {
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = Self.stickerImage()
            material.roughness.contents = 0.55
            material.transparencyMode = .aOne
            material.isDoubleSided = false
            mesh.geometry?.materials = [material]
            paperSticker = DeskSticker(original: sticker, mesh: mesh, root: root, front: material)
        }

        // The camera: a 30° lens, the picture's colors untouched (no HDR).
        let camera = SCNCamera()
        camera.fieldOfView = 30
        camera.projectionDirection = .vertical
        camera.zNear = 0.1
        camera.zFar = 100
        camera.wantsHDR = false
        cameraNode.camera = camera
        cameraNode.name = "desk camera"
        root.addChildNode(cameraNode)
        place(Self.restPose)

        // A warm key light from the front top left, with soft shadows on the
        // desk; a cool fill from the right; a soft room around it all.
        let key = SCNLight()
        key.type = .directional
        key.color = NSColor(red: 1, green: 0.96, blue: 0.91, alpha: 1)
        key.intensity = 1500
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowSampleCount = 16
        key.shadowRadius = 4
        key.orthographicScale = 9
        key.zNear = 1
        key.zFar = 40
        key.shadowColor = NSColor(white: 0, alpha: 0.4)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdPosition = [-6, 11, 9]
        keyNode.simdLook(at: .zero)
        root.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.color = NSColor(red: 0.91, green: 0.93, blue: 1, alpha: 1)
        fill.intensity = 350
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.simdPosition = [8, 4, 6]
        fillNode.simdLook(at: .zero)
        root.addChildNode(fillNode)

        scene.lightingEnvironment.contents = Self.roomImage()
        scene.lightingEnvironment.intensity = 1.0

        // The desk: only its shadows show.
        let floor = SCNFloor()
        floor.reflectivity = 0
        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .shadowOnly
        floor.materials = [floorMaterial]
        let floorNode = SCNNode(geometry: floor)
        floorNode.simdPosition = [0, 0.011, 0]
        root.addChildNode(floorNode)

        // The screen's own light on the keyboard and the desk, in the picture's purple.
        screenLight.type = .area
        screenLight.areaType = .rectangle
        screenLight.areaExtents = simd_float3(2 * Self.glassHalf.x, 2 * Self.glassHalf.y, 0)
        screenLight.color = NSColor(red: 0.48, green: 0.40, blue: 0.82, alpha: 1)
        screenLight.intensity = 0
        screenLight.categoryBitMask = 1
        let screenLightNode = SCNNode()
        screenLightNode.light = screenLight
        screenLightNode.simdPosition = [0, Self.screenCenterY, -0.15]
        screenLightNode.simdLook(at: [0, Self.screenCenterY, 10])
        root.addChildNode(screenLightNode)
    }

    /// The node carrying a part's mesh: USD puts it a level under the part's own.
    private static func geometryNode(in node: SCNNode) -> SCNNode? {
        if node.geometry != nil { return node }
        for child in node.childNodes {
            if let found = geometryNode(in: child) { return found }
        }
        return nil
    }

    private func prepareHover(on node: SCNNode, named name: String) {
        guard let geometry = Self.geometryNode(in: node)?.geometry else { return }
        // The cartridge shell and caps can share materials. Give each
        // interactive control its own copy before changing its emission.
        let materials = geometry.materials.compactMap { $0.copy() as? SCNMaterial }
        guard materials.count == geometry.materials.count, !materials.isEmpty else { return }
        geometry.materials = materials
        hoverMaterials[name] = materials.map { ($0, $0.emission.contents) }
    }

    private func setHoveredControl(_ part: String?) {
        let next = part.flatMap { hoverMaterials[$0] == nil ? nil : $0 }
        guard next != hoveredControl else { return }
        if let hoveredControl, let materials = hoverMaterials[hoveredControl] {
            for entry in materials { entry.material.emission.contents = entry.emission }
        }
        hoveredControl = next
        if let next, let materials = hoverMaterials[next] {
            let glow = NSColor(srgbRed: 0.28, green: 0.22, blue: 0.16, alpha: 1)
            for entry in materials { entry.material.emission.contents = glow }
        }
    }

    /// The app icon sticker, as About's 2D monitor draws it, straight and
    /// without its shadow: the plane is turned and lit in the scene.
    private static func stickerImage() -> NSImage? {
        let renderer = ImageRenderer(content: IconSticker(size: 512, mounted: false))
        renderer.scale = 1
        return renderer.nsImage
    }

    /// The room the glass reflects: a dim studio, lighter above, with two
    /// soft boxes, one large at the front left and one small at the right.
    private static func roomImage() -> CGImage? {
        let width = 1024, height = 512
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = [CGColor(gray: 0.62, alpha: 1), CGColor(gray: 0.36, alpha: 1), CGColor(gray: 0.12, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.5, 1])!
        // Image rows run top down in an equirectangular map; CG's y runs up.
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        // Front is the map's middle; left of it is the room's left.
        context.fill(CGRect(x: 330, y: 300, width: 150, height: 110))
        context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        context.fill(CGRect(x: 700, y: 290, width: 70, height: 60))
        return context.makeImage()
    }

    // MARK: Attaching to a view

    func attach(to view: DeskView, store: PlayerStore) {
        if self.view != nil { detach() }
        self.view = view
        self.store = store
        view.desk = self
        view.scene = scene
        view.pointOfView = cameraNode
        view.delegate = self
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.allowsCameraControl = false

        MonitorModel.shared.typed = { [weak self] character in self?.tap(character) }
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Lets go of `view`, if it's still the one shown (a new About can attach
    /// before the old one goes).
    func detach(from view: DeskView) {
        if view === self.view { detach() }
    }

    private func detach() {
        onPower = nil
        keyboardHeld = [:]
        modifiersHeld = []
        mouseHeld = nil
        driftResumeAt = 0
        cartridgeLook = 0
        cartridgeLookTarget = 0
        pointerNearPower = false
        setHoveredControl(nil)
        hatchMotion = nil
        hatchPivot?.simdEulerAngles.x = 0
        knobDrag = nil
        paperSticker?.reset()
        creditsDisk?.reset()
        resetPictureControls()
        latched = []
        taps = [:]
        keysDownLastFrame = []
        for (control, button) in cartridgeButtons {
            button.node.simdPosition = button.rest
            cartridgeButtons[control]?.pressedAt = -10
        }
        link?.invalidate()
        link = nil
        MonitorModel.shared.typed = nil
        view?.delegate = nil
        view?.desk = nil
        view?.scene = nil
        view = nil
    }

    // MARK: Each frame

    @objc private func step(_ link: CADisplayLink) {
        update(at: CACurrentMediaTime())
    }

    /// Everything that moves, at `now`: the model's tick, the frame on the
    /// tube, the camera, the keys, the button, the light, the LED.
    func update(at now: Double) {
        let model = MonitorModel.shared
        let picture = model.tick(store: store)
        let dt = lastStep == 0 ? 0 : Float(min(0.1, max(0, now - lastStep)))
        lastStep = now

        followPower(model, now: now)
        if !model.isOn {
            if creditsDisk?.canLoad == false { creditsDisk?.reset() }
        } else {
            if model.mode != .player { stopCredits(at: now) }
            if creditsDisk?.update(at: now, audible: view?.window != nil) == true {
                startGlide(to: Self.onPose, duration: 0.66, now: now)
            }
        }

        // The frame, when it changed. The BASIC cursor blinks at the C64's 3 Hz.
        let blink = Int(now * 3) % 2 == 0
        let cursor = model.cursor
        var changed: [UInt32]?
        if creditsDisk?.render(at: now, into: &pixels) == true {
            changed = pixels
            uploaded = nil
        } else if creditsDisk?.isShowingIntro != true,
                  uploaded != model.frame || uploadedBlink != blink || uploadedCursor?.x != cursor?.x || uploadedCursor?.y != cursor?.y {
            model.frame.render(into: &pixels, cursor: blink ? cursor : nil)
            uploaded = model.frame
            uploadedBlink = blink
            uploadedCursor = cursor
            changed = pixels
        }

        advanceDrift(model, now: now, dt: dt)
        place(cartridgePose(pose(at: now), powered: model.isOn, dt: dt))
        if let view { paperSticker?.update(dt: dt, in: view) }
        moveKeys(now: now, dt: dt, audible: model.isOn && view?.window != nil)
        updateHatch(at: now)
        // Reflect changes made from the player or its keyboard shortcuts.
        turnKnob(.volume)

        let brightness = picture.bright * (0.45 + 1.1 * knobValue(.brightness))
        let vertical = (knobValue(.vertical) - 0.5) * 2
        let rolling = model.isOn && abs(vertical) > 0.1
        verticalPhase = rolling ? (verticalPhase + vertical * dt).truncatingRemainder(dividingBy: 1) : 0

        if let button {
            button.node.simdPosition = button.rest - Self.buttonNormal * 0.03 * Self.buttonDepth(now - buttonPressedAt)
        }
        for button in cartridgeButtons.values {
            button.node.simdPosition = button.rest + button.travel * Self.buttonDepth(now - button.pressedAt)
        }
        ledMaterial.emission.contents = model.isOn ? NSColor(red: 0.36, green: 1, blue: 0.5, alpha: 1) : NSColor.black
        let lit = picture.collapse > 0.5 ? max(picture.scaleX, 0.05) * 0.3 : min(picture.scaleX, picture.scaleY)
        screenLight.intensity = CGFloat(220 * brightness * lit)

        // The tube's texture, the size the glass has on screen, so the
        // shader's footprint terms see the pixels the picture really gets.
        let height = glassPixelHeight()
        if height != targetHeight {
            targetHeight = height
            let width = Int((Float(height) * Self.meshHalf.x / Self.meshHalf.y).rounded())
            screenMaterial.emission.contents = tube.resize(width: width, height: height)
        }
        let glassPixels = Float(height) * Self.glassHalf.y / Self.meshHalf.y
        frames &+= 1
        let uniforms = TubeUniforms(
            meshHalf: Self.meshHalf, glassHalf: Self.glassHalf,
            scale: SIMD2(picture.scaleX, picture.scaleY),
            linePx: glassPixels * 0.93 / Float(C64Frame.height),
            minWidth: 1.4 / (glassPixels * 0.5),
            time: Float(now.truncatingRemainder(dividingBy: 1000)),
            bright: brightness, focus: picture.focus, wobble: picture.wobble,
            seed: Float(frames % 1000), collapse: picture.collapse,
            tint: (knobValue(.tint) - 0.5) * 2,
            color: knobValue(.color) * 2,
            contrast: 0.4 + knobValue(.contrast) * 1.2,
            horizontal: (knobValue(.horizontal) - 0.5) * 0.48,
            verticalPhase: verticalPhase, rolling: rolling ? 1 : 0)
        tube.submit(uniforms, pixels: changed)
    }

    /// The glass's height on screen in device pixels, rounded up to 64,
    /// between one texel a line and 2048.
    private func glassPixelHeight() -> Int {
        guard let view, view.bounds.height > 0 else { return 370 }
        let top = view.projectPoint(SCNVector3(0, Self.screenCenterY + Self.meshHalf.y, Self.screenFrontZ))
        let bottom = view.projectPoint(SCNVector3(0, Self.screenCenterY - Self.meshHalf.y, Self.screenFrontZ))
        let scale = view.window?.backingScaleFactor ?? view.layer?.contentsScale ?? 1
        let pixels = abs(top.y - bottom.y) * scale
        return min(2048, max(C64Frame.height, Int((pixels / 64).rounded(.up)) * 64))
    }

    // MARK: The camera

    /// Glides to the monitor when the power comes on, back to the desk once
    /// the dot has faded, and snaps back when About starts over.
    private func followPower(_ model: MonitorModel, now: Double) {
        if model.resets != lastResets {
            lastResets = model.resets
            glide = (Self.restPose, Self.restPose, now, 1)
            cartridgeLook = 0
            cartridgeLookTarget = 0
            pointerNearPower = false
        }
        let power = model.power
        if power == .on, lastPower == .off {
            bodyDrift = CameraNoise(interval: 3...7)
            handDrift = CameraNoise(interval: 0.6...1.5)
            driftRate = 0
            startGlide(to: Self.onPose, duration: 1.4, now: now)
        } else if power == .off, lastPower == .dying {
            startGlide(to: Self.restPose, duration: 1.1, now: now)
        }
        if power == .off, lastPower != .off { resetPictureControls() }
        lastPower = power
    }

    private func advanceDrift(_ model: MonitorModel, now: Double, dt: Float) {
        guard model.isOn, !model.busy, !pointerNearPower, !isHoldingSticker, knobDrag == nil,
              creditsDisk?.isLoading != true,
              now >= glide.start + glide.duration,
              now >= driftResumeAt, mouseHeld == nil, keyboardHeld.isEmpty, modifiersHeld.isEmpty,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            driftRate = 0
            return
        }

        // Slow shifts in stance with smaller, quicker hand corrections.
        driftRate = min(1, driftRate + dt)
        let elapsed = dt * driftRate
        let broad = bodyDrift.advance(by: elapsed)
        let fine = handDrift.advance(by: elapsed)
        let yaw = (broad.x * 4.5 + fine.x * 0.65) * .pi / 180
        let pitch = (broad.y * 1.8 + fine.y * 0.3) * .pi / 180
        let distance = 1 + broad.z * 0.014 + fine.z * 0.003
        let rotation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        let offset = Self.onPose.position - Self.onPose.target
        // The power-off glide starts from this exact angle.
        glide.to.position = Self.onPose.target + rotation.act(offset * distance)
    }

    /// Bounded random waypoints, with smooth velocity and acceleration at each join.
    private struct CameraNoise {
        let interval: ClosedRange<Float>
        private var from: SIMD3<Float> = .zero
        private var to = SIMD3<Float>.random(in: -1...1)
        private var elapsed: Float = 0
        private var duration: Float

        init(interval: ClosedRange<Float>) {
            self.interval = interval
            duration = .random(in: interval)
        }

        mutating func advance(by seconds: Float) -> SIMD3<Float> {
            elapsed += seconds
            if elapsed >= duration {
                elapsed -= duration
                from = to
                to = .random(in: -1...1)
                duration = .random(in: interval)
            }
            let t = elapsed / duration
            let eased = t * t * t * (t * (t * 6 - 15) + 10)
            return from + (to - from) * eased
        }
    }

    private func pauseDrift() {
        driftResumeAt = CACurrentMediaTime() + 1.2
    }

    /// Lean over the breadbin to reveal the controls on the cartridge's rear edge.
    private func cartridgePose(_ pose: Pose, powered: Bool, dt: Float) -> Pose {
        if !powered { cartridgeLookTarget = 0 }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            cartridgeLook = 0
            return pose
        }
        cartridgeLook += (cartridgeLookTarget - cartridgeLook) * (1 - exp(-dt * 7))
        let angle = cartridgeLook * (-15 * .pi / 180)
        let pitch = simd_quatf(angle: angle, axis: SIMD3(1, 0, 0))
        return Pose(position: pose.target + pitch.act(pose.position - pose.target), target: pose.target)
    }

    private func startGlide(to pose: Pose, duration: Double, now: Double) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        glide = (self.pose(at: now), pose, now, reduce ? 0 : duration)
    }

    private func pose(at now: Double) -> Pose {
        guard glide.duration > 0 else { return glide.to }
        let u = min(1, max(0, (now - glide.start) / glide.duration))
        let e = Float(u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2)
        return Pose(position: simd_mix(glide.from.position, glide.to.position, SIMD3(repeating: e)),
                    target: simd_mix(glide.from.target, glide.to.target, SIMD3(repeating: e)))
    }

    private func place(_ pose: Pose) {
        cameraNode.simdPosition = pose.position
        cameraNode.simdLook(at: pose.target)
    }

    // MARK: The keys

    /// Each cap goes down in 30 ms while anything holds it and comes back
    /// up in 80; a typed character holds its keys for 90 ms.
    private func moveKeys(now: Double, dt: Float, audible: Bool) {
        var down = modifiersHeld.union(latched)
        for keys in keyboardHeld.values { down.formUnion(keys) }
        if let mouseHeld { down.insert(mouseHeld) }
        for (key, until) in taps {
            if until > now { down.insert(key) } else { taps[key] = nil }
        }
        if audible {
            // A chord (such as SHIFT + 2) should not stack several loud attacks.
            let pressed = down.subtracting(keysDownLastFrame)
            let released = keysDownLastFrame.subtracting(down)
            if !pressed.isEmpty { MonitorSounds.shared.playKey(pressed: true, spacebar: pressed.contains(.space)) }
            if !released.isEmpty { MonitorSounds.shared.playKey(pressed: false, spacebar: released.contains(.space)) }
        }
        keysDownLastFrame = down
        for (key, cap) in caps {
            let target: Float = down.contains(key) ? 1 : 0
            var depth = cap.depth
            if target > depth {
                depth = dt == 0 ? target : min(target, depth + dt / 0.03)
            } else {
                depth = dt == 0 ? target : max(target, depth - dt / 0.08)
            }
            guard depth != cap.depth else { continue }
            caps[key]?.depth = depth
            // Ease the way up, as a spring returns.
            let shown = target > 0 ? depth : depth * depth * (3 - 2 * depth)
            cap.node.simdWorldPosition = cap.rest - SIMD3(0, Self.keyTravel * shown, 0)
        }
    }

    /// A character the boot types: its keys, briefly.
    private func tap(_ character: Character) {
        let until = CACurrentMediaTime() + 0.12
        for key in C64Key.keys(for: character) { taps[key] = until }
    }

    /// AppKeys forwards the physical event before dispatching the shortcut.
    static func observeKeyEvent(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, let desk = shared, desk.view?.window === window else { return false }
        desk.keyEvent(event)
        if event.type == .keyDown, !event.isARepeat, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return desk.stopCredits(at: CACurrentMediaTime())
        }
        return false
    }

    private func keyEvent(_ event: NSEvent) {
        pauseDrift()
        switch event.type {
        case .flagsChanged:
            modifiersHeld = C64Key.modifierKeys(event.modifierFlags)
        case .keyDown:
            guard !event.isARepeat else { return }
            let keys = C64Key.keys(for: event)
            guard !keys.isEmpty else { return }
            // Let even a tap between two frames move the cap. With ⌘ down,
            // macOS can omit key-up, so use the tap alone in that case.
            let command = event.modifierFlags.contains(.command)
            let until = CACurrentMediaTime() + (command ? 0.12 : 0.045)
            for key in keys { taps[key] = max(taps[key] ?? 0, until) }
            if !command {
                keyboardHeld[event.keyCode] = keys
            }
        case .keyUp:
            keyboardHeld[event.keyCode] = nil
        default:
            break
        }
    }

    // MARK: The mouse

    private func loadCredits() {
        let model = MonitorModel.shared
        guard let creditsDisk, creditsDisk.canLoad, model.isOn, !model.busy, model.mode != .frozen else { return }
        if model.mode == .boot { model.skipBoot() }
        let tune = store?.nowPlaying.map { CreditsScene.Tune(title: $0.displayTitle, author: $0.author) }
        let now = CACurrentMediaTime()
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        cartridgeLookTarget = 0
        creditsDisk.load(at: now, tune: tune, reduceMotion: still)
        if !still { startGlide(to: Self.drivePose, duration: 0.45, now: now) }
    }

    @discardableResult
    private func stopCredits(at now: Double) -> Bool {
        guard let creditsDisk, creditsDisk.isActive else { return false }
        if creditsDisk.isLoading { startGlide(to: Self.onPose, duration: 0.66, now: now) }
        creditsDisk.eject(at: now)
        return true
    }

    private func knobValue(_ knob: MonitorKnob) -> Float {
        knob == .volume ? Float(store?.volume ?? PlayerStore.defaultVolume) : knobValues[knob, default: 0.5]
    }

    private func turnKnob(_ knob: MonitorKnob) {
        guard let (node, rest) = knobs[knob] else { return }
        let angle = (0.5 - knobValue(knob)) * (1.5 * .pi)
        node.simdWorldOrientation = simd_quatf(angle: angle, axis: [0, 0, 1]) * rest
    }

    private func setKnob(_ knob: MonitorKnob, to value: Double) {
        if knob == .volume {
            store?.volume = value
        } else {
            knobValues[knob] = value == 0.5 ? nil : Float(value)
        }
        turnKnob(knob)
    }

    private func resetPictureControls() {
        let adjusted = Array(knobValues.keys)
        knobValues.removeAll()
        for knob in adjusted { turnKnob(knob) }
    }

    func mouseDragged(to point: CGPoint) {
        if isHoldingSticker {
            paperSticker?.drag(to: point)
            return
        }
        guard let drag = knobDrag else { return }
        let distance = point.x - drag.lastX
        guard drag.hasDragged || abs(distance) >= 3 else { return }
        knobDrag = (drag.knob, point.x, true)
        let delta = Double(distance) / 150
        setKnob(drag.knob, to: min(1, max(0, Double(knobValue(drag.knob)) + delta)))
    }

    @discardableResult
    func pointerMoved(to point: CGPoint?) -> Bool {
        if knobDrag != nil || isHoldingSticker { return true }
        let hit = point.flatMap { part(at: $0) }
        setHoveredControl(hit)
        updateCameraHover(at: point)
        return hit != nil
    }

    private func updateCameraHover(at point: CGPoint?) {
        pointerNearPower = false
        guard creditsDisk?.isLoading != true else { return }
        guard MonitorModel.shared.isOn, let point, let view else {
            cartridgeLookTarget = 0
            return
        }
        if let power = button?.node, let center = projectedPoint(of: power, in: view),
           hypot(point.x - center.x, point.y - center.y) <= min(48, max(24, view.bounds.height * 0.05)) {
            pointerNearPower = true
            cartridgeLookTarget = cartridgeLook
            return
        }
        guard let freeze = cartridgeButtons[.freeze]?.node, let button = projectedPoint(of: freeze, in: view) else {
            cartridgeLookTarget = 0
            return
        }
        let radius = min(110, max(55, view.bounds.height * 0.13))
        let distance = hypot(point.x - button.x, point.y - button.y)
        // Hold the full lean near the switch while the pointer moves to click it.
        let proximity = Float(min(1, max(0, (radius - distance) / (radius * 0.7))))
        cartridgeLookTarget = proximity * proximity * (3 - 2 * proximity)
    }

    private func projectedPoint(of node: SCNNode, in view: DeskView) -> CGPoint? {
        let point = view.projectPoint(node.worldPosition)
        guard (0...1).contains(point.z) else { return nil }
        return CGPoint(x: point.x, y: point.y)
    }

    private static func buttonDepth(_ elapsed: Double) -> Float {
        if elapsed < 0.05 { return Float(max(0, elapsed) / 0.05) }
        return Float(max(0, 1 - (elapsed - 0.05) / 0.12))
    }

    private func toggleHatch(at now: Double) {
        guard let hatchPivot else { return }
        let angle = hatchPivot.simdEulerAngles.x
        let target: Float = (hatchMotion?.to ?? angle) == 0 ? Self.hatchClosedAngle : 0
        hatchMotion = (angle, target, now)
        pauseDrift()
        updateHatch(at: now)
    }

    private func updateHatch(at now: Double) {
        guard let hatchPivot, let motion = hatchMotion else { return }
        let closing = motion.to == Self.hatchClosedAngle
        let duration = closing ? 0.22 : 0.28
        let progress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 1 : min(1, max(0, (now - motion.start) / duration))
        if progress == 1 {
            hatchPivot.simdEulerAngles.x = motion.to
            hatchMotion = nil
            if closing { MonitorSounds.shared.playHatchClose() }
        } else {
            // The opening falls into its stop. Closing accelerates into the latch.
            let eased = closing ? pow(progress, 1.8) : 1 - pow(1 - progress, 2.5)
            hatchPivot.simdEulerAngles.x = motion.from + (motion.to - motion.from) * Float(eased)
        }
    }

    private func part(at point: CGPoint) -> String? {
        guard let view else { return nil }
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        if paperSticker?.pick(at: point, in: view, blocker: hits.first) != nil { return "sticker" }
        var node = hits.first?.node
        while let current = node {
            if let name = current.name {
                if name == DeskCreditsDisk.name, creditsDisk?.canLoad == true {
                    let model = MonitorModel.shared
                    return model.isOn && !model.busy && model.mode != .frozen ? name : nil
                }
                if name == "power_button" || name == "monitor_cap" || name.hasPrefix("key_") { return name }
                if hatchMotion == nil, hatchPivot?.simdEulerAngles.x == 0, MonitorKnob(rawValue: name) != nil {
                    return name
                }
            }
            node = current.parent
        }
        if hatchMotion == nil, hatchPivot?.simdEulerAngles.x == 0 {
            var nearest: MonitorKnob?
            var distance = min(15, max(6, view.bounds.height * 0.011))
            for (knob, part) in knobs {
                let front = part.node.simdWorldPosition + SIMD3<Float>(0, 0, 0.075)
                let projected = view.projectPoint(SCNVector3(front))
                let gap = hypot(point.x - projected.x, point.y - projected.y)
                if (0...1).contains(projected.z), gap < distance {
                    nearest = knob
                    distance = gap
                }
            }
            if let nearest { return nearest.rawValue }
        }
        // SceneKit can miss the imported switches. Pick the nearest cap
        // within the small screen-space target around each control.
        if MonitorModel.shared.isOn {
            var nearest: CartridgeButton?
            var distance = max(9, view.bounds.height * 0.015)
            for (control, button) in cartridgeButtons {
                guard let center = projectedPoint(of: button.node, in: view) else { continue }
                let gap = hypot(point.x - center.x, point.y - center.y)
                if gap < distance {
                    nearest = control
                    distance = gap
                }
            }
            return nearest?.rawValue
        }
        return nil
    }

    func isClickable(at point: CGPoint) -> Bool { part(at: point) != nil }

    func mouseDown(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let name = part(at: point) else { return }
        if name == DeskCreditsDisk.name {
            loadCredits()
            return
        }
        if name == "sticker", let view, paperSticker?.begin(at: point, in: view) == true {
            setHoveredControl(nil)
            cartridgeLookTarget = cartridgeLook
            pauseDrift()
            return
        }
        if name == "power_button" {
            buttonPressedAt = CACurrentMediaTime()
            if let onPower { onPower() } else { MonitorModel.shared.pressPower(store: store) }
            return
        }
        if name == "monitor_cap" {
            toggleHatch(at: CACurrentMediaTime())
            return
        }
        if let knob = MonitorKnob(rawValue: name) {
            knobDrag = (knob, point.x, false)
            cartridgeLookTarget = cartridgeLook
            setHoveredControl(name)
            pauseDrift()
            return
        }
        if let control = CartridgeButton(rawValue: name) {
            let model = MonitorModel.shared
            switch control {
            case .freeze:
                guard let store, model.handleFreezeKey(.f5, shifted: true, store: store) else { return }
            case .reset:
                model.resetComputer()
            }
            pauseDrift()
            cartridgeButtons[control]?.pressedAt = CACurrentMediaTime()
            MonitorSounds.shared.playKey(pressed: true, spacebar: false)
            return
        }
        guard let key = C64Key(nodeName: name) else { return }
        pauseDrift()
        if key.isModifier {
            if latched.contains(key) { latched.remove(key) } else { latched.insert(key) }
            return
        }
        mouseHeld = key
        if key == .runStop, stopCredits(at: CACurrentMediaTime()) { return }
        let shifted = flags.contains(.shift) || !latched.isDisjoint(with: [.leftShift, .rightShift, .shiftLock])
        latched = latched.intersection([.shiftLock])
        let model = MonitorModel.shared
        if let store, model.handleFreezeKey(key, shifted: shifted, store: store) { return }
        if let action = key.action(shifted: shifted) {
            AppKeys.monitorAction(action)
        } else if model.mode == .boot {
            model.skipBoot()
        }
    }

    func mouseUp(at point: CGPoint? = nil) {
        if isHoldingSticker, let view {
            paperSticker?.release(at: point, in: view)
            pointerMoved(to: point)
            pauseDrift()
        }
        if let drag = knobDrag {
            knobDrag = nil
            if !drag.hasDragged {
                let value = drag.knob == .volume ? PlayerStore.defaultVolume : 0.5
                setKnob(drag.knob, to: value)
            }
            pointerMoved(to: point)
            pauseDrift()
        }
        if mouseHeld != nil { pauseDrift() }
        mouseHeld = nil
    }

    // MARK: The tube, on the render thread

    nonisolated func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let queue = renderer.commandQueue else { return }
        tube.encode(on: queue)
    }
}

/// Matches `TubeUniforms` in Shaders/Monitor.metal.
nonisolated struct TubeUniforms {
    var meshHalf: SIMD2<Float>
    var glassHalf: SIMD2<Float>
    var scale: SIMD2<Float>
    var linePx: Float
    var minWidth: Float
    var time: Float
    var bright: Float
    var focus: Float
    var wobble: Float
    var seed: Float
    var collapse: Float
    var tint: Float
    var color: Float
    var contrast: Float
    var horizontal: Float
    var verticalPhase: Float
    var rolling: Float
}

/// The tube's pass: the 384×272 frame as a mipmapped texture, drawn through
/// monitorTubeFragment into the texture the glass shows. The main thread
/// hands over the uniforms and any new frame; SceneKit's render thread
/// draws, on SceneKit's own command queue so it lands before the frame.
nonisolated final class TubePass: @unchecked Sendable {
    let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let frame: MTLTexture
    private let lock = NSLock()
    private var target: MTLTexture?
    private var uniforms: TubeUniforms?
    private var pixels: [UInt32]?

    init?(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "monitorVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "monitorTubeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let frameDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: C64Frame.width, height: C64Frame.height, mipmapped: true)
        frameDescriptor.usage = .shaderRead
        frameDescriptor.storageMode = .shared
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let frame = device.makeTexture(descriptor: frameDescriptor)
        else { return nil }
        self.device = device
        self.pipeline = pipeline
        self.frame = frame
    }

    /// A new texture for the glass, `width` × `height`: the material shows it from now on.
    func resize(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        lock.lock()
        target = texture
        lock.unlock()
        return texture
    }

    func submit(_ uniforms: TubeUniforms, pixels: [UInt32]?) {
        lock.lock()
        self.uniforms = uniforms
        if let pixels { self.pixels = pixels }
        lock.unlock()
    }

    func encode(on queue: MTLCommandQueue) {
        lock.lock()
        let target = target, pending = uniforms, newPixels = pixels
        pixels = nil
        lock.unlock()
        guard let target, var uniforms = pending, let commands = queue.makeCommandBuffer() else { return }
        if let newPixels {
            newPixels.withUnsafeBytes { bytes in
                frame.replace(region: MTLRegionMake2D(0, 0, C64Frame.width, C64Frame.height), mipmapLevel: 0,
                              withBytes: bytes.baseAddress!, bytesPerRow: C64Frame.width * 4)
            }
            if let blit = commands.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: frame)
                blit.endEncoding()
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TubeUniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        if let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: target)
            blit.endEncoding()
        }
        commands.commit()
    }
}
