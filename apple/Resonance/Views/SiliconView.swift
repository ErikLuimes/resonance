import SceneKit
import SwiftUI
import PhosphorCore

/// Silicon: the SID the tune was written for, in 3D, opened up and
/// working: a 6581 in its ceramic package with the gold lid off, or an
/// 8580 in black plastic with a pit etched down to the die. The package
/// is built to scale around the chip's real die, which is rendered from
/// its own mask layers (as Tommi Lempinen redrew them from microscope
/// photographs),
/// so every wire, contact and transistor is where it is on the chip. The
/// camera starts on the whole package, comes down into the cavity past
/// the bond wires, hovers close over one part of the die after another,
/// and pulls back out.
///
/// What's working shows as it does on the Chip visualizer, on the real
/// thing: bits glow along their own circuitry, beads of light run the
/// signals' ways to the filter and the output, each voice's waveform
/// floats over its envelope generator with the output's beside the
/// output stage, and the pins glow as they're used, all the way down
/// their bond wires and legs.
///
/// `SiliconDie` knows where things are and what's lit; `SiliconScene` is
/// the SceneKit scene and its camera; `SiliconOverlay` draws the light.
/// Shows the first chip, like the Halo.
struct SiliconView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    /// The chip the tune asks for: an 8580 when its header says so, else
    /// a 6581, which is what a tune that doesn't say was written on.
    private var die: SiliconDie {
        store.nowPlaying?.sidModel == 2 ? .mos8580 : .mos6581
    }

    var body: some View {
        SiliconSceneView(die: die, feed: store.visualizer, theme: theme, isActive: isActive)
            // A different chip is a different scene, built afresh.
            .id(die.name)
            // A vignette over the whole view, in its shape: the middle is
            // left alone and the edges fall away to the dark, corners most.
            .overlay {
                EllipticalGradient(stops: [.init(color: .clear, location: 0.42),
                                           .init(color: .black.opacity(0.45), location: 0.75),
                                           .init(color: .black.opacity(0.88), location: 1)],
                                   center: .center, startRadiusFraction: 0, endRadiusFraction: 0.72)
                    .allowsHitTesting(false)
            }
            .accessibilityElement()
            .accessibilityLabel("Silicon visualizer")
    }
}

private struct SiliconSceneView: NSViewRepresentable {
    let die: SiliconDie
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let isActive: Bool

    func makeCoordinator() -> SiliconDisplay {
        SiliconDisplay(die: die)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = PassThroughSceneView(frame: .zero, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue,
        ])
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = VisualizerFeed.framesPerSecond
        view.allowsCameraControl = false
        update(view, context.coordinator)
        context.coordinator.start(in: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        update(view, context.coordinator)
    }

    static func dismantleNSView(_ view: SCNView, coordinator: SiliconDisplay) {
        coordinator.stop()
    }

    private func update(_ view: SCNView, _ display: SiliconDisplay) {
        display.feed = feed
        display.voiceColors = theme.voices.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
        display.isActive = isActive
        view.rendersContinuously = isActive
        view.isPlaying = isActive
    }
}

/// An SCNView that never takes the mouse, like the Metal visualizers'.
private final class PassThroughSceneView: SCNView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Gets the scene ready without holding the app up, then reads the chip's
/// state and moves the scene on, once per display frame.
///
/// Opening it costs about 1.2 s the first time, measured: the package's
/// wear texture (0.4 s), unpacking the die, and compiling the scene's
/// shaders for its first frame (0.8 s). The textures are made on another
/// thread and kept (`SiliconAssets`), SceneKit compiles the shaders on
/// its own before the scene is shown, and the view fades in once there's
/// something to see. Only building the scene's nodes stays on the main
/// thread, at about 40 ms.
private final class SiliconDisplay: NSObject {
    let die: SiliconDie
    var feed: VisualizerFeed?
    var voiceColors: [SIMD3<Float>] = [] {
        didSet { silicon?.voiceColors = voiceColors }
    }
    var isActive = true {
        didSet { link?.isPaused = !isActive }
    }

    private var silicon: SiliconScene?
    private let chip = ChipModel()
    private var link: CADisplayLink?
    private var preparing: Task<Void, Never>?

    init(die: SiliconDie) {
        self.die = die
    }

    func start(in view: SCNView) {
        view.alphaValue = 0
        preparing = Task { [weak self, weak view, die] in
            await SiliconAssets.warm(die)
            guard let self, let view, !Task.isCancelled else { return }
            let silicon = SiliconScene(die: die)
            silicon.voiceColors = voiceColors
            silicon.update(state: chip.state, clock: CACurrentMediaTime())
            // SceneKit compiles the scene's shaders and uploads its
            // geometry on a thread of its own.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                view.prepare([silicon.scene]) { _ in done.resume() }
            }
            guard !Task.isCancelled else { return }
            self.silicon = silicon
            view.scene = silicon.scene
            view.pointOfView = silicon.cameraNode
            let link = view.displayLink(target: self, selector: #selector(step(_:)))
            // One update per frame SceneKit draws, not one per refresh of a
            // ProMotion display.
            let rate = Float(VisualizerFeed.framesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common)
            link.isPaused = !isActive
            self.link = link
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                view.animator().alphaValue = 1
            }
        }
    }

    func stop() {
        preparing?.cancel()
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let silicon else { return }
        if let feed { chip.update(feed: feed, at: .now) }
        silicon.update(state: chip.state, clock: CACurrentMediaTime())
    }
}

#Preview {
    SiliconView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
