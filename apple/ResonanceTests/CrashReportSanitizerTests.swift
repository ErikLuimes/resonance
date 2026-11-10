import Foundation
import Testing
@testable import Resonance

struct CrashReportSanitizerTests {
    @Test func removesPrivateDataAndKeepsCrashEvidence() throws {
        let report: [String: Any] = [
            "report": [
                "id": "A1B2C3D4",
                "timestamp": "2026-11-10T10:00:00Z",
            ],
            "system": [
                "system_name": "macOS",
                "system_version": "26.1",
                "machine": "Mac17,8",
                "crash_reporter_key": "private-device-key",
                "hostname": "Alice's Mac",
                "executable_path": "/Applications/Resonance.app/Contents/MacOS/Resonance",
            ],
            "process": [
                "process_id": 83_612,
                "parent_process_id": 83_617,
                "process_start_monotonic_ns": 214_494_362_597_625,
                "process_start_wall_clock_ns": 1_794_266_425_662_622_000,
                "run_id": "684fdac1-0491-464c-9cad-f11d54b80be9",
                "app_uuid": "F858B1BD-284C-353E-BEC4-00DA26DFBC08",
            ],
            "user": [
                "track": "Secret Tune.sid",
                "playlist": "Private favorites",
            ],
            "crash": [
                "error": [
                    "type": "signal",
                    "reason": "Failed reading /Volumes/Alice Music/HVSC/Secret Tune.sid",
                    "contact": "alice@example.com",
                    "address": "192.168.1.42",
                ],
                "threads": [[
                    "backtrace": [
                        "contents": [[
                            "object_name": "Resonance",
                            "symbol_name": "PlayerStore.play()",
                            "object_addr": 4_294_967_296,
                            "source_file": "/Users/alice/Repositories/resonance/PlayerStore.swift",
                        ]],
                    ],
                ]],
            ],
            "binary_images": [[
                "name": "/Applications/Resonance.app/Contents/MacOS/Resonance",
                "uuid": "12345678-1234-1234-1234-123456789ABC",
            ]],
        ]

        let text = try #require(CrashReportSanitizer.jsonString(from: report))

        #expect(!text.contains("alice"))
        #expect(!text.contains("Alice"))
        #expect(!text.contains("Secret Tune"))
        #expect(!text.contains("Private favorites"))
        #expect(!text.contains("192.168.1.42"))
        #expect(!text.contains("83612"))
        #expect(!text.contains("83617"))
        #expect(!text.contains("214494362597625"))
        #expect(!text.contains("1794266425662622000"))
        #expect(!text.contains("684fdac1-0491-464c-9cad-f11d54b80be9"))
        #expect(!text.contains("A1B2C3D4"))
        #expect(!text.contains("Mac17,8"))
        #expect(text.contains("[redacted-path]"))
        #expect(text.contains("PlayerStore.play()"))
        #expect(text.contains("F858B1BD-284C-353E-BEC4-00DA26DFBC08"))
        #expect(text.contains("12345678-1234-1234-1234-123456789ABC"))
        #expect(text.contains("/Applications/Resonance.app/Contents/MacOS/Resonance"))
        #expect(text.contains("signal"))
        #expect(text.contains("26.1"))
    }

    @Test func leavesTheStoredReportUnchanged() {
        let report: [String: Any] = ["user": ["track": "Secret Tune.sid"]]

        _ = CrashReportSanitizer.sanitize(report)

        let user = report["user"] as? [String: String]
        #expect(user?["track"] == "Secret Tune.sid")
    }

    @Test func recursivelySanitizesArraysAndSnakeCaseKeys() throws {
        let report: [String: Any] = [
            "events": [
                ["user_name": "alice", "message": "Write failed for /home/alice/Music/private.sid"],
            ],
        ]

        let text = try #require(CrashReportSanitizer.jsonString(from: report))

        #expect(!text.contains("alice"))
        #expect(!text.contains("private.sid"))
        #expect(text.contains("[redacted]"))
        #expect(text.contains("[redacted-path]"))
    }
}
