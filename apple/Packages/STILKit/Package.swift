// swift-tools-version:5.9
// STILKit — parse, reflow and enrich HVSC STIL.txt for Resonance.
// Port of a Python reference parser, stil_reference.py (kept outside this repo). Tests compare against its golden output.
import PackageDescription

let package = Package(
    name: "STILKit",
    // iOS for Resonance Remote, which shows the notes the Mac sends.
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "STILKit", targets: ["STILKit"])],
    targets: [
        .target(name: "STILKit"),
        .testTarget(
            name: "STILKitTests",
            dependencies: ["STILKit"],
            // Regenerate with make_fixtures.py, beside the reference parser
            // (or point FIXTURES_DIR elsewhere; see FixtureTests.swift).
            resources: [.copy("Fixtures")]
        ),
    ]
)
