// swift-tools-version:6.0
// ResonanceVisuals: the visualizers' renderers and shaders, shared by the Mac
// app and Resonance Remote on iPhone and iPad. Each app feeds them from its
// own frames: the Mac from its visualizer feed, the remote from the Mac's.
import PackageDescription

let package = Package(
    name: "ResonanceVisuals",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [.library(name: "ResonanceVisuals", targets: ["ResonanceVisuals"])],
    targets: [
        .target(name: "ResonanceVisuals", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ResonanceVisualsTests", dependencies: ["ResonanceVisuals"]),
    ]
)
