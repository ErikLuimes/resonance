import AppKit
import Foundation
import SwiftUI
import Testing
import PhosphorCore
@testable import Resonance

/// A fingerprint with the given mix (triangle, saw, pulse, noise), tags
/// and traits.
func fingerprint(
    mix: [Float] = [0.04, 0, 0.72, 0.24],
    tags: [SoundTag] = [.arpeggios, .noiseDrums, .pulseBass],
    traits: [Float] = [0.74, 0.44, 0.17, 0, 0.24, 0.02, 0, 0.72, 0.25],
    arpeggioRate: Float = 22,
    silent: Bool = false
) -> TuneFingerprint {
    TuneFingerprint(
        subtune: 1, scannedSecs: 180, activity: Data(repeating: 128, count: 384), bins: 128,
        mix: WaveformMix(triangle: mix[0], saw: mix[1], pulse: mix[2], noise: mix[3]),
        tags: tags, notesPerSec: 13.4, arpeggioRate: arpeggioRate, filterUsage: 0, ringMod: 0.04, sync: 0.007,
        digi: 0, pulseWidthDepth: 0.084, vibratoRate: 2, noiseHits: 8.7, traits: traits, chips: 1, silent: silent
    )
}

struct FingerprintDescriptionTests {
    @Test func summarySaysTheMainWaveformAndTags() {
        #expect(fingerprint().summary == "Mostly pulse, with arpeggios, noise drums, and pulse bass.")
        #expect(fingerprint(mix: [0.5, 0.4, 0.1, 0], tags: [], arpeggioRate: 0).summary == "Triangle and saw.")
        #expect(fingerprint(tags: [.arpeggios], arpeggioRate: 40).summary == "Mostly pulse, with fast arpeggios.")
        #expect(fingerprint(silent: true).summary == "Silent in the part that was scanned.")
    }

    @Test func waveformsLeaveOutTheOnesThatBarelySound() {
        let names = fingerprint(mix: [0.01, 0.3, 0.6, 0.09]).waveforms.map(\.name)
        #expect(names == ["Pulse", "Saw", "Noise"])
    }

    @Test func barcodeNamesTheStrongTraits() {
        #expect(SoundBarcode.description([0.8, 0, 0, 0.9, 0, 0, 0, 0, 0]) == "Sound fingerprint: Notes and Filter")
        #expect(SoundBarcode.description(Array(repeating: 0, count: 9)) == "Sound fingerprint")
    }

    @Test func spherePointsFollowTheMix() {
        #expect(MorphSphereShape.pick([0, 0, 1, 0], 0.3) == 2)
        #expect(MorphSphereShape.pick([0.5, 0, 0, 0.5], 0.9) == 3)
        #expect(MorphSphereShape.pick([0, 0, 0, 0], 0.5) == 2)
        let shape = MorphSphereShape(fingerprint(mix: [1, 0, 0, 0]), count: 50)
        #expect(shape.points.count == 50)
        #expect(shape.points.allSatisfy { $0.color == 0 })
    }

    @Test func traitsBulgeTheSphere() {
        let flat = MorphSphereShape(fingerprint(traits: Array(repeating: 0, count: 9)))
        let full = MorphSphereShape(fingerprint(traits: Array(repeating: 1, count: 9)))
        let size = { (s: MorphSphereShape) in s.points.map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() }.max()! }
        #expect(abs(size(flat) - 0.36) < 0.001)
        #expect(size(full) > 0.8)
    }
}

@MainActor
struct FingerprintStoreTests {
    let fake = FakeCore()

    private func makeStore() -> FingerprintStore {
        let suite = "ResonanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let player = PlayerStore(defaults: defaults, phosphorHvscRoot: { "/HVSC" }) { _ in fake }
        return FingerprintStore(player: player, defaults: defaults)
    }

    @Test func batchesLookupsAndDoesntAskTwice() async throws {
        fake.set(fingerprints: ["/HVSC/a.sid": fingerprint()])
        let store = makeStore()
        store.load(["/HVSC/a.sid"])
        store.load(["/HVSC/b.sid", "/HVSC/a.sid"])
        try await Task.sleep(for: .milliseconds(150))
        #expect(fake.fingerprintLookups == [["/HVSC/a.sid", "/HVSC/b.sid"]])
        #expect(store.fingerprint("/HVSC/a.sid") != nil)
        #expect(store.fingerprint("/HVSC/b.sid") == nil)

        // Neither the found one nor the missing one is asked for again.
        store.load(["/HVSC/a.sid", "/HVSC/b.sid"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.fingerprintLookups.count == 1)
    }

    @Test func similarityLeavesOutUnscannedTunes() async {
        fake.set(fingerprints: ["/HVSC/a.sid": fingerprint(), "/HVSC/b.sid": fingerprint()])
        let scores = await makeStore().similarity(to: "/HVSC/a.sid", of: ["/HVSC/a.sid", "/HVSC/b.sid", "/HVSC/c.sid"])
        #expect(scores == ["/HVSC/a.sid": 1, "/HVSC/b.sid": 0.5])
    }

    @Test func downloadingTheSetRemembersItAndCounts() async {
        let store = makeStore()
        await store.downloadSet()
        #expect(store.setDownload == .added(12))
        #expect(fake.calls.contains("downloadFingerprints"))
    }

    @Test func pausingIsRemembered() {
        let store = makeStore()
        #expect(!store.paused)
        store.paused = true
        #expect(store.paused)
    }
}

/// Offscreen renders of the fingerprint views, for checking them by eye:
/// `RESONANCE_RENDER_DIR=<folder>` writes PNGs there.
@MainActor
struct FingerprintRenderTests {
    @Test func rendersTheGlyphsAndHoverCard() throws {
        guard let dir = ProcessInfo.processInfo.environment["RESONANCE_RENDER_DIR"]
            ?? (FileManager.default.fileExists(atPath: "/tmp/resonance-renders") ? "/tmp/resonance-renders" : nil)
        else { return }
        let tunes: [(String, TuneFingerprint)] = [
            ("Commando", fingerprint()),
            ("Delta", fingerprint(mix: [0.12, 0, 0.85, 0.03], tags: [.filterSweeps, .syncLeads, .pulseBass],
                                  traits: [0.68, 0, 0.39, 0.96, 0, 1, 0, 0.22, 0.02], arpeggioRate: 0)),
            ("Arkanoid", fingerprint(mix: [0.2, 0, 0.8, 0], tags: [.arpeggios, .digiSamples, .filterSweeps, .vibratoLeads],
                                     traits: [0.26, 0.26, 0.76, 0.43, 0, 0, 0.81, 0, 0.04], arpeggioRate: 13)),
        ]
        let card = SoundHoverCard(fingerprint: tunes[0].1, title: "Commando", subtitle: "Rob Hubbard",
                                  length: "3:56", onPlay: {}, onFindSimilar: {})
        try save(card.background(Color(nsColor: .windowBackgroundColor)), "hover-card", dir)

        let list = VStack(alignment: .leading, spacing: 8) {
            ForEach(tunes, id: \.0) { name, fp in
                HStack(spacing: 12) {
                    Text(name).frame(width: 90, alignment: .leading)
                    SoundBarcode(traits: fp.traits)
                    MorphSphere(fingerprint: fp, animated: false).frame(width: 22, height: 22)
                    MorphSphere(fingerprint: fp, animated: false).frame(width: 96, height: 96)
                    Text(fp.summary).frame(width: 220, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        try save(list, "glyphs", dir)
    }

    private func save(_ view: some View, _ name: String, _ dir: String) throws {
        for scheme in [ColorScheme.dark, .light] {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(filePath: dir).appending(path: "\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
