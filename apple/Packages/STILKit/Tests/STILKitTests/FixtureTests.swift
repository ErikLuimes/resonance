import XCTest
@testable import STILKit

/// Golden tests: every fixture in fixtures/manifest.json must produce exactly
/// the reference implementation's output.
final class FixtureTests: XCTestCase {

    struct ManifestItem: Decodable { let name: String; let entry: String; let exercises: String }

    func fixturesURL() throws -> URL {
        if let dir = ProcessInfo.processInfo.environment["FIXTURES_DIR"] {
            return URL(fileURLWithPath: dir)
        }
        return try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    }

    func testAllFixtures() throws {
        let dir = try fixturesURL()
        let manifest = try JSONDecoder().decode([ManifestItem].self,
                                                from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertFalse(manifest.isEmpty)
        for item in manifest {
            let raw = STILParser.decode(try Data(contentsOf: dir.appendingPathComponent("\(item.name).stil.txt")))
            let entries = STILParser.parse(raw)
            let entryRaw = try XCTUnwrap(entries[item.entry], "\(item.name): entry not parsed")
            let idx = STILEnricher.initialsIndex(entries)
            let got = STILEnricher.entry(entryRaw, initials: STILEnricher.initials(for: item.entry, in: idx))
            let want = try JSONDecoder().decode(STILEntry.self,
                                                from: Data(contentsOf: dir.appendingPathComponent("\(item.name).expected.json")))
            XCTAssertEqual(got, want, "\(item.name) — \(item.exercises)")
        }
    }

    func testReflowJoinsSoftWrapsAndKeepsRealBreaks() {
        let lines = [
            "\"When I first had a look at the 512b/1k Tiny SID compo, I thought it'd",
            "some music out of 128 bytes just for fun.",
            "I really wanted to feature the nature of the C=64, so I thought about",
        ]
        XCTAssertEqual(STILReflow.paragraphs(lines).count, 2)
    }

    func testMedleySegmentsUseNextStartForPointTimestamps() {
        let covers = [
            STILEnricher.parseTitle("BGM1 [from the arcade game Commando] (0:00)"),
            STILEnricher.parseTitle("Base [from the arcade game Commando] (0:53)"),
            STILEnricher.parseTitle("Level Complete [from the arcade game Commando] (1:16-1:32)"),
        ]
        let segs = STILEnricher.medleySegments(covers, songLength: 236)
        XCTAssertEqual(segs.map(\.start), [0, 53, 76])
        XCTAssertEqual(segs.map(\.end), [53, 76, 92])
    }

    /// Optional: run the whole real STIL.txt (set STIL_TXT) and make sure nothing crashes
    /// and the counts are in the same ballpark as corpus-stats.json.
    func testWholeFileSmoke() throws {
        guard let path = ProcessInfo.processInfo.environment["STIL_TXT"] else { throw XCTSkip("STIL_TXT not set") }
        let entries = STILParser.parse(STILParser.decode(try Data(contentsOf: URL(fileURLWithPath: path))))
        let idx = STILEnricher.initialsIndex(entries)
        var comments = 0
        for (p, raw) in entries {
            let e = STILEnricher.entry(raw, initials: STILEnricher.initials(for: p, in: idx))
            comments += e.sections.reduce(0) { $0 + $1.comments.count }
        }
        XCTAssertGreaterThan(entries.count, 18_000)
        XCTAssertGreaterThan(comments, 9_000)
    }
}
