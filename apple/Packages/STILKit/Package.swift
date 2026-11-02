// swift-tools-version:5.9
// STILKit — parse, reflow and enrich HVSC STIL.txt for Resonance.
// Port of design/stil/reference/stil_reference.py. Tests compare against its golden output.
import PackageDescription

let package = Package(
    name: "STILKit",
    platforms: [.macOS(.v13)],
    products: [.library(name: "STILKit", targets: ["STILKit"])],
    targets: [
        .target(name: "STILKit"),
        .testTarget(
            name: "STILKitTests",
            dependencies: ["STILKit"],
            // Regenerate with design/stil/reference/make_fixtures.py
            // (or point FIXTURES_DIR elsewhere; see FixtureTests.swift).
            resources: [.copy("Fixtures")]
        ),
    ]
)
