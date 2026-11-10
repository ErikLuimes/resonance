import AppKit
import SceneKit
import simd

/// A 5¼-inch disk and the intro it loads into the desk's CRT.
@MainActor
final class DeskCreditsDisk {
    static let name = "credits_floppy"
    private static let side: CGFloat = 1.36
    private static let thickness: CGFloat = 0.014
    private static let rest = SIMD3<Float>(-2.64, 0.021, 0.04)
    // Measured on the 1541 mesh. The sleeve clears both lips of the slot.
    private static let slot = SIMD3<Float>(-4.44, 0.499, 1.43)
    private static let inside = SIMD3<Float>(-4.44, 0.499, -0.33)
    private static let angle: Float = 0.17

    let node: SCNNode
    private let led = SCNMaterial()
    private var phase = Phase.resting
    private var renderer: CreditsRenderer?
    private var tune: CreditsScene.Tune?
    private var still = false
    private var lastFrame = -1

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
        let sleeve = SCNBox(width: Self.side, height: Self.thickness, length: Self.side, chamferRadius: 0.006)
        let plastic = SCNMaterial()
        plastic.lightingModel = .physicallyBased
        plastic.diffuse.contents = NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1)
        plastic.roughness.contents = 0.85
        sleeve.materials = [plastic]
        node = SCNNode(geometry: sleeve)
        node.name = Self.name
        root.addChildNode(node)

        let face = SCNPlane(width: Self.side - 0.008, height: Self.side - 0.008)
        let print = SCNMaterial()
        print.lightingModel = .physicallyBased
        print.diffuse.contents = Self.labelImage()
        print.diffuse.mipFilter = .linear
        print.roughness.contents = 0.82
        face.materials = [print]
        let label = SCNNode(geometry: face)
        label.eulerAngles.x = -.pi / 2
        label.position.y = Self.thickness / 2 + 0.001
        label.castsShadow = false
        node.addChildNode(label)

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
        place(insertion: 0)
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
    func update(at now: Double) -> Bool {
        switch phase {
        case .resting:
            break
        case .loading(let start):
            let elapsed = now - start
            if !still { place(insertion: (elapsed - 0.28) / 1.20) }
            setActivity(elapsed > 0.83 && Int(elapsed * 13) % 3 != 1)
            if elapsed >= (still ? 0.25 : 1.90) {
                node.isHidden = true
                setActivity(false)
                phase = .playing(now + (still ? 0 : 0.68))
                return true
            }
        case .playing(let start):
            if seconds(since: start, at: now) >= CreditsScene.length(tune: tune) { eject(at: now) }
        case .ejecting(let start):
            let progress = (now - start) / 0.85
            if progress >= 1 {
                reset()
            } else {
                place(insertion: 1 - progress)
            }
        }
        return false
    }

    var isShowingIntro: Bool {
        if case .playing = phase { return lastFrame >= 0 }
        return false
    }

    /// Use the same 320×200 picture as the separate intro, with a dark
    /// border in the C64 raster. SceneKit still applies the tube's controls.
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
            context.setFillColor(CGColor(srgbRed: 5 / 255, green: 6 / 255, blue: 8 / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: C64Frame.width, height: C64Frame.height))
            context.draw(image, in: CGRect(x: CGFloat(C64Frame.originX), y: CGFloat(C64Frame.originY),
                                           width: CreditsScene.width, height: CreditsScene.height))
            return true
        }
        if drawn { lastFrame = frame }
        return drawn
    }

    private func seconds(since start: Double, at now: Double) -> Double {
        now - start + (still ? CreditsScene.timing.namesFrom : 0)
    }

    private func place(insertion: Double) {
        let lift = Float(min(1, max(0, insertion / 0.48)))
        let slide = Float(min(1, max(0, (insertion - 0.48) / 0.52)))
        // Draw the disk forward to clear the case before moving across to the slot.
        let forward = min(1, lift / 0.55)
        let across = max(0, (lift - 0.24) / 0.76)
        let easedForward = forward * forward * (3 - 2 * forward)
        let easedAcross = across * across * (3 - 2 * across)
        let easedSlide = slide * slide * (3 - 2 * slide)
        node.simdPosition = simd_mix(Self.rest, Self.slot, SIMD3(easedAcross, easedAcross, easedForward))
                          + (Self.inside - Self.slot) * easedSlide
        node.simdEulerAngles.y = Self.angle * (1 - easedForward)
        node.isHidden = insertion >= 1
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
            NSBezierPath(ovalIn: CGRect(x: 97, y: 97, width: 62, height: 62)).fill()
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
