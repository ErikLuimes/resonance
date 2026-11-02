import XCTest
@testable import STILKit

/// Whole-corpus parity with the Python reference. Opt-in:
///   STIL_TXT=/path/STIL.txt DUMP_OUT=/tmp/swift_all.json swift test --filter ParityTests
///   python3 design/stil/reference/compare_dump.py /path/STIL.txt /tmp/swift_all.json
final class ParityTests: XCTestCase {
    func testDumpAllEntries() throws {
        guard let path = ProcessInfo.processInfo.environment["STIL_TXT"],
              let out = ProcessInfo.processInfo.environment["DUMP_OUT"] else { throw XCTSkip("STIL_TXT / DUMP_OUT not set") }
        let entries = STILParser.parse(STILParser.decode(try Data(contentsOf: URL(fileURLWithPath: path))))
        let idx = STILEnricher.initialsIndex(entries)
        var all: [String: STILEntry] = [:]
        for (p, raw) in entries { all[p] = STILEnricher.entry(raw, initials: STILEnricher.initials(for: p, in: idx)) }
        try JSONEncoder().encode(all).write(to: URL(fileURLWithPath: out))
    }
}
