import AVFoundation
import PhosphorCore

/// Cartridge-style menu and machine-code monitor drawn on the About CRT.
@MainActor
final class SIDFreezeMonitor {
    private enum Page { case menu, machineCode, frozenPicture }

    private static let demo = [
        "LDA #$0F", "STA $D418",
        "LDA #$08", "STA $D405",
        "LDA #$A8", "STA $D406",
        "LDA #$1D", "STA $D401",
        "LDA #$21", "STA $D404",
        "LDY #$C0", "OUTER: LDX #$00",
        "INNER: DEX", "BNE INNER", "DEY", "BNE OUTER",
        "LDA #$27", "STA $D401", "RTS"
    ]

    private static let inputLimit = 256
    private static let programLimit = 8192
    private static let visibleLines = 13
    private let store: PlayerStore
    private let frozenFrame: C64Frame
    private var page: Page
    private var input = ""
    private var source: [String] = []
    private var sourceSize = 0
    private var listOffset = 0
    private var status = ""
    private var renderTask: Task<Void, Never>?
    private var audio: AVAudioPlayer?

    private(set) var frame = C64Frame()
    private(set) var cursor: (x: Int, y: Int)?

    init(store: PlayerStore, frozenFrame: C64Frame, direct: Bool) {
        self.store = store
        self.frozenFrame = frozenFrame
        page = direct ? .machineCode : .menu
        store.core.setMonitorFrozen(frozen: true)
        draw()
    }

    func close() {
        stopPreview()
        store.core.setMonitorFrozen(frozen: false)
    }

    /// Returns true if this key leaves the freezer and resumes the player.
    func key(_ key: C64Key, shifted: Bool, character: String? = nil) -> Bool {
        defer { draw() }
        if key == .f3, !shifted { return true }
        if key == .f5, shifted {
            stopPreview()
            page = .menu
            return false
        }
        if key == .f7, shifted {
            page = .machineCode
            return false
        }

        switch page {
        case .frozenPicture:
            page = .menu
        case .menu:
            switch key {
            case .runStop: return true
            case .m, .return: page = .machineCode
            case .f7: page = .frozenPicture
            default: break
            }
        case .machineCode:
            switch key {
            case .runStop:
                stopPreview()
                page = .menu
            case .return: submit()
            case .instDel: _ = input.popLast()
            case .crsrUpDown:
                listOffset = min(max(0, listOffset + (shifted ? -1 : 1)), lastOffset)
            default:
                if let text = character ?? key.monitorCharacter(shifted: shifted) {
                    appendInput(text)
                }
            }
        }
        return false
    }

    func paste(_ text: String) {
        guard page == .machineCode else { return }
        guard text.utf8.count <= Self.programLimit, text.utf8.allSatisfy({ $0 < 128 }) else {
            status = "PASTE MUST BE ASCII AND AT MOST 8 KB"
            draw()
            return
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if lines.count == 1, let line = lines.first {
            appendInput(line)
        } else {
            for line in lines {
                let clean = line.trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty, !appendSource(clean) { break }
            }
        }
        draw()
    }

    private func appendInput(_ text: String) {
        let printable = text.uppercased().filter { $0.asciiValue.map { (32...126).contains($0) } ?? false }
        input += printable.prefix(Self.inputLimit - input.count)
    }

    @discardableResult
    private func appendSource(_ line: String) -> Bool {
        let size = line.utf8.count + 1
        guard sourceSize + size <= Self.programLimit else {
            status = "PROGRAM FULL"
            return false
        }
        source.append(line)
        sourceSize += size
        listOffset = lastOffset
        status = ""
        return true
    }

    private func submit() {
        let command = input.trimmingCharacters(in: .whitespaces)
        input = ""
        switch command {
        case "", "A", "A C000", "A $C000":
            status = "ENTER 6502 INSTRUCTIONS BELOW"
        case "G", "G C000", "G $C000", "RUN":
            run(source.joined(separator: "\n"))
        case "DEMO":
            run(Self.demo.joined(separator: "\n"))
            if source.isEmpty {
                for line in Self.demo { appendSource(line) }
                listOffset = 0
                status = "RUNNING DEMO"
            }
        case "NEW":
            stopPreview()
            source = []
            sourceSize = 0
            listOffset = 0
            status = "PROGRAM CLEARED"
        case "U":
            if let line = source.popLast() { sourceSize -= line.utf8.count + 1 }
            listOffset = lastOffset
            status = "LAST LINE REMOVED"
        case "X":
            stopPreview()
            page = .menu
        default:
            appendSource(command)
        }
    }

    private func stopPreview() {
        renderTask?.cancel()
        renderTask = nil
        audio?.stop()
        audio = nil
    }

    private func run(_ program: String) {
        // Keep one render in flight while this page is open.
        guard renderTask == nil else { return }
        audio?.stop()
        audio = nil
        status = "RUNNING..."
        renderTask = Task { [weak self] in
            do {
                let data = try await renderSidProgram(source: program)
                guard !Task.isCancelled, let self else { return }
                let player = try AVAudioPlayer(data: data)
                player.volume = Float(store.volume)
                audio = player
                status = player.play() ? "OK" : "SID PLAYBACK FAILED"
            } catch {
                guard !Task.isCancelled, let self else { return }
                if case SidMonitorError.Failed(let message) = error {
                    status = message
                } else {
                    status = "SID PLAYBACK FAILED"
                }
            }
            self?.renderTask = nil
            self?.draw()
        }
    }

    private var lastOffset: Int { max(0, source.count - Self.visibleLines) }

    private func draw() {
        cursor = nil
        var f = C64Frame()
        switch page {
        case .frozenPicture:
            f = frozenFrame
            f.line(24, " FROZEN SCREEN     ANY KEY RETURNS", reversed: true)
        case .menu:
            f.line(2, "========================================")
            f.line(4, "         A C T I O N   R E P L A Y", reversed: true)
            f.line(6, "              R E S O N A N C E")
            f.line(8, "========================================")
            f.line(10, "               FREEZE MENU")
            f.line(13, "           M  - MACHINE CODE MONITOR")
            f.line(15, "          F3  - RESTART")
            f.line(17, "          F7  - VIEW FROZEN SCREEN")
            f.line(22, "           *** PROGRAM FROZEN ***")
        case .machineCode:
            f.line(0, " ACTION REPLAY     MACHINE CODE MONITOR ", reversed: true)
            f.line(2, " $C000 PROGRAM     $D400-$D418 SID I/O")
            f.line(3, " A C000 LDA #$0F   G C000 TO EXECUTE")
            f.line(4, " DEMO  PLAY SAMPLE      NEW  CLEAR")
            f.line(5, " U  UNDO LAST LINE      X  FREEZE MENU")
            for (row, line) in source.dropFirst(listOffset).prefix(Self.visibleLines).enumerated() {
                f.line(7 + row, String(format: "%03d ", listOffset + row + 1) + line)
            }
            f.line(21, status)
            let visibleInput = input.suffix(C64Frame.columns - 3)
            f.line(22, ". " + visibleInput)
            cursor = (2 + visibleInput.count, 22)
            f.line(24, " F3 RESTART     UP/DOWN SCROLL SOURCE", reversed: true)
        }
        frame = f
    }
}
