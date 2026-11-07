import SwiftUI
import PhosphorCore

/// Which view of the chip Under the Hood is showing.
enum UnderTheHoodTab: String, CaseIterable, Identifiable {
    case tracker, registers, sweeps, pitch

    var id: Self { self }

    var title: String {
        switch self {
        case .tracker: "Tracker"
        case .registers: "Registers"
        case .sweeps: "Sweeps"
        case .pitch: "Pitch Trail"
        }
    }
}

nonisolated extension TrackerSong {
    /// The row playing `secs` in.
    func row(atSecs secs: Double) -> Int {
        let frame = UInt32(clamping: Int(max(secs, 0) * frameRate))
        var low = 0
        var high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].frame <= frame { low = middle + 1 } else { high = middle }
        }
        return max(low - 1, 0)
    }

    /// The instrument each voice last started a note with, as of `row`.
    func currentInstruments(atRow row: Int) -> [TrackerInstrument?] {
        guard !rows.isEmpty else { return [nil, nil, nil] }
        let last = min(row, rows.count - 1)
        return (0..<3).map { voice in
            // A voice can be quiet for long, but not for ever.
            for index in stride(from: last, through: max(last - 2048, 0), by: -1) {
                let id = Int(rows[index].voices[voice].instrument)
                if id > 0, instruments.indices.contains(id - 1) { return instruments[id - 1] }
            }
            return nil
        }
    }
}

/// Remembers when each register last changed, so it can stay lit for a moment.
@MainActor
final class RegisterFlash {
    static let frames: UInt64 = 6

    private var last: [UInt8] = []
    private var lastIndex: UInt64 = 0
    private(set) var changed = [UInt64](repeating: 0, count: 29)

    func take(_ frames: [VizSidFrame], chip: Int) {
        // Back at the start: a new tune, or a rewind. Only the newest frame can say so, as
        // each batch overlaps the one before.
        if let newest = frames.last, newest.index < lastIndex {
            forget()
        }
        for frame in frames where frame.chips.indices.contains(chip) {
            if frame.index <= lastIndex, !last.isEmpty {
                continue
            }
            let now = [UInt8](frame.chips[chip].registers)
            if last.count == now.count {
                for register in now.indices where register < changed.count && now[register] != last[register] {
                    changed[register] = frame.index
                }
            }
            last = now
            lastIndex = frame.index
        }
    }

    func isLit(_ register: Int) -> Bool {
        changed.indices.contains(register) && changed[register] > 0 && lastIndex - changed[register] < Self.frames
    }

    func forget() {
        last = []
        lastIndex = 0
        changed = [UInt64](repeating: 0, count: 29)
    }
}

/// The tracker, registers, sweeps and pitch trail, in a drawer over the list. Reads the
/// same feed as the visualizers, and only while it's open.
struct UnderTheHoodView: View {
    /// Closes the drawer.
    let close: () -> Void

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme
    @AppStorage(Pref.underTheHoodTab) private var tab = UnderTheHoodTab.tracker
    @State private var selectedChip = 0
    /// One for each chip a tune can have.
    @State private var flashes = (0..<3).map { _ in RegisterFlash() }

    /// The whole drawer's size, so that the picker coming and going can't change the answer.
    @State private var size = CGSize.zero

    private var chips: Int { max(Int(store.nowPlaying?.numSids ?? 1), 1) }
    private var chip: Int { min(selectedChip, chips - 1) }
    private var collapsed: Bool { !Self.everyChipFits(tab: tab, chips: chips, in: size) }
    private var shown: [Int] { collapsed ? [chip] : Array(0..<chips) }

    /// Whether a tab can show `chips` chips readably in a drawer this big.
    static func everyChipFits(tab: UnderTheHoodTab, chips: Int, in size: CGSize) -> Bool {
        guard chips > 1 else { return true }
        // Allows for the header on two lines, and for a drawer not measured yet.
        let height = size.height - 76
        switch tab {
        case .tracker: return true
        case .registers: return size == .zero || (size.width >= VoiceLines.width && height >= VoiceLines.height(chips: chips))
        case .sweeps: return size == .zero || size.width / CGFloat(chips) >= 170
        case .pitch: return size == .zero || height / CGFloat(chips) >= 90
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .background(theme.background.color)
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    }

    /// On one line where it fits, and two where it doesn't, so nothing gets squeezed.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                tabs
                chipPicker
                Spacer(minLength: 12)
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                tabs
                HStack(spacing: 12) {
                    chipPicker
                    Spacer(minLength: 12)
                    buttons
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var tabs: some View {
        Picker("View", selection: $tab) {
            ForEach(UnderTheHoodTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .buttonBorderShape(.capsule)
        .fixedSize()
    }

    /// For the tracker, whose rows are worked out a chip at a time, and for the other tabs
    /// when there's no room for every chip.
    @ViewBuilder
    private var chipPicker: some View {
        if chips > 1, tab == .tracker || collapsed {
            Picker("Chip", selection: $selectedChip) {
                ForEach(0..<chips, id: \.self) { Text("SID \($0 + 1)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .buttonBorderShape(.capsule)
            .fixedSize()
        }
    }

    /// Slides the drawer back down.
    private var buttons: some View {
        Button(action: close) {
            Label("Close", systemImage: "arrow.down.square")
                .labelStyle(.iconOnly)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Close")
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if store.nowPlaying == nil {
            Text("Nothing is playing.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch tab {
            case .tracker:
                TrackerTab(chip: chip)
            case .registers:
                live(frames: 8) { frames, _ in
                    let _ = zip(flashes.indices, flashes).forEach { $1.take(frames, chip: $0) }
                    if chips > 1 {
                        VoiceLines(frame: frames.last, shown: shown, flashes: flashes)
                    } else {
                        RegistersCanvas(frame: frames.last, chip: 0, flash: flashes[0])
                    }
                }
            case .sweeps:
                live(frames: 512) { frames, colours in
                    SweepsCanvas(frames: frames, shown: shown, colours: colours)
                }
            case .pitch:
                live(frames: 256) { frames, colours in
                    PitchCanvas(frames: frames, shown: shown, colours: colours)
                }
            }
        }
    }

    /// Everything that changes per frame is one Canvas, so text changing can't resize anything.
    private func live<Content: View>(frames count: Int, @ViewBuilder content: @escaping ([VizSidFrame], [Color]) -> Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.isPlaying)) { _ in
            content(store.visualizer.history(count), (0..<3).map { theme.voice($0) })
        }
    }
}

// MARK: Tracker

private struct TrackerTab: View {
    let chip: Int

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme
    @State private var song: TrackerSong?
    @State private var problem: String?

    private struct Tune: Hashable {
        let path: String
        let song: Int
        let chip: Int
    }

    private var tune: Tune? {
        store.nowPlaying.map { Tune(path: $0.path, song: Int($0.currentSong), chip: chip) }
    }

    var body: some View {
        Group {
            if let song {
                GeometryReader { space in
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.isPlaying)) { _ in
                        let row = song.row(atSecs: store.visualizer.heardSecs ?? 0)
                        let colours = (0..<3).map { theme.voice($0) }
                        TrackerPage(song: song, tuneID: tune?.path ?? "", row: row, height: space.size.height, width: space.size.width, colours: colours)
                            .equatable()
                    }
                }
            } else {
                Text(problem ?? "Rebuilding the tune from what its player writes…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: tune) { await load() }
    }

    private func load() async {
        song = nil
        problem = nil
        guard let tune else { return }
        // Its known length, else the longest a tune with none usually gets.
        let secs = min((store.duration ?? 300) + 2, 900)
        do {
            let made = try await store.core.trackerSong(path: tune.path, subtune: UInt16(clamping: tune.song), secs: secs, chip: UInt32(clamping: tune.chip))
            guard !Task.isCancelled else { return }
            song = made
        } catch {
            guard !Task.isCancelled else { return }
            problem = "This tune couldn't be rebuilt."
        }
    }
}

/// Redrawn only when the row changes, not on every tick of the timeline.
struct TrackerPage: View, Equatable {
    let song: TrackerSong
    let tuneID: String
    let row: Int
    let height: CGFloat
    let width: CGFloat
    let colours: [Color]

    private static let rowHeight: CGFloat = 17
    private static let panelFrom: CGFloat = 640
    private static let font = Font.system(size: 12, design: .monospaced)
    private static let dim = Color(red: 0x8D / 255, green: 0x8E / 255, blue: 0x96 / 255)
    private static let empty = Color(red: 0x3A / 255, green: 0x3A / 255, blue: 0x42 / 255)

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.tuneID == b.tuneID && a.height == b.height && a.width == b.width
            && a.song.rows.count == b.song.rows.count && a.colours == b.colours
    }

    private var visible: Int { max(Int((height - 34) / Self.rowHeight), 1) }

    var body: some View {
        let current = song.currentInstruments(atRow: row)
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                heading(current)
                    .padding(.bottom, 6)
                ForEach(0..<visible, id: \.self) { slot in
                    rowView(at: row + slot - visible / 2, isCurrent: slot == visible / 2)
                }
            }
            .frame(width: 58 + 3 * 124, alignment: .leading)
            if width >= Self.panelFrom {
                panel(current)
            }
            Spacer(minLength: 0)
        }
        .font(Self.font)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
    }

    private func heading(_ current: [TrackerInstrument?]) -> some View {
        HStack(spacing: 0) {
            Text("ROW").foregroundStyle(Self.dim).frame(width: 58, alignment: .leading)
            ForEach(0..<3, id: \.self) { voice in
                let name = current[voice]?.name.components(separatedBy: " › ").last ?? ""
                Text("V\(voice + 1) \(name)")
                    .fontWeight(.semibold)
                    .foregroundStyle(colours[voice])
                    .frame(width: 124, alignment: .leading)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func rowView(at index: Int, isCurrent: Bool) -> some View {
        HStack(spacing: 0) {
            if song.rows.indices.contains(index) {
                let row = song.rows[index]
                Text(String(format: "%04X", index))
                    .foregroundStyle(isCurrent ? Color.accentColor : Self.dim)
                    .frame(width: 58, alignment: .leading)
                ForEach(0..<3, id: \.self) { voice in
                    cell(row.voices[voice], voice: voice, isCurrent: isCurrent)
                        .frame(width: 124, alignment: .leading)
                }
            }
        }
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.white.opacity(0.1) : .clear, in: .rect(cornerRadius: 3))
    }

    private func cell(_ cell: TrackerCell, voice: Int, isCurrent: Bool) -> some View {
        let note = cell.note ?? (cell.off ? "---" : "···")
        let hasNote = cell.note != nil
        let noteColour: Color = hasNote ? (isCurrent ? .white : colours[voice]) : (cell.off ? Self.dim : Self.empty)
        let effect: String? = switch cell.effect {
        case .arpeggio: "ARP"
        case .slide: "SLD"
        case .vibrato: "VIB"
        case .none: nil
        }
        return HStack(spacing: 8) {
            Text(note).foregroundStyle(noteColour).fontWeight(hasNote && isCurrent ? .bold : .regular)
            Text(cell.instrument > 0 ? String(format: "%02X", cell.instrument) : "··")
                .foregroundStyle(cell.instrument > 0 ? Self.dim : Self.empty)
            Text(effect ?? "···").foregroundStyle(effect == nil ? Self.empty : Color.white.opacity(0.85))
        }
    }

    private func panel(_ current: [TrackerInstrument?]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("INSTRUMENTS").fontWeight(.semibold).foregroundStyle(Self.dim)
            ForEach(0..<3, id: \.self) { voice in
                if let instrument = current[voice] {
                    Text("\(instrument.name)  \(String(format: "%02X %02X", instrument.attackDecay, instrument.sustainRelease))")
                        .foregroundStyle(colours[voice])
                        .lineLimit(1)
                }
            }
            Text("\(song.instruments.count) in this tune").foregroundStyle(Self.dim)
            if song.rows.indices.contains(row) {
                filter(song.rows[row])
                    .padding(.top, 10)
            }
            Text(song.hasGrid
                 ? "\(song.framesPerRow.formatted()) frames a row, \((song.frameRate / Double(song.framesPerRow)).formatted(.number.precision(.fractionLength(1)))) rows a second."
                 : "No steady beat found, so the rows are only a ruler.")
                .foregroundStyle(Self.dim)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            Text("Rebuilt from what the player writes to the chip, as SID files hold code, not patterns.")
                .foregroundStyle(Self.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 0, maxWidth: 340, alignment: .leading)
    }

    @ViewBuilder
    private func filter(_ row: TrackerRow) -> some View {
        Text("FILTER").fontWeight(.semibold).foregroundStyle(Self.dim)
        let modes = [(UInt8(1), "LP"), (2, "BP"), (4, "HP")].filter { row.filterMode & $0.0 != 0 }.map(\.1)
        if row.filterRouting == 0 || modes.isEmpty {
            Text("Not in use").foregroundStyle(Self.dim)
        } else {
            let violet = Color(red: 0xA2 / 255, green: 0x7C / 255, blue: 0xF6 / 255)
            HStack(spacing: 8) {
                Text(modes.joined(separator: "+")).foregroundStyle(violet)
                ZStack(alignment: .leading) {
                    Capsule().fill(Self.empty)
                    Capsule().fill(violet).frame(width: 150 * CGFloat(row.cutoff) / 2047)
                }
                .frame(width: 150, height: 6)
            }
            let voices = [(UInt8(1), "V1"), (2, "V2"), (4, "V3")].map { row.filterRouting & $0.0 != 0 ? $0.1 : "--" }
            Text("Resonance \(row.resonance), \(voices.joined(separator: " "))").foregroundStyle(Self.dim)
        }
    }
}

// MARK: Registers

private let monoFont = Font.system(size: 12, design: .monospaced)
private let dimColour = Color(red: 0x8D / 255, green: 0x8E / 255, blue: 0x96 / 255)
private let faintColour = Color(red: 0x3A / 255, green: 0x3A / 255, blue: 0x42 / 255)
private let violetColour = Color(red: 0xA2 / 255, green: 0x7C / 255, blue: 0xF6 / 255)

private func label(_ text: String, at point: CGPoint, colour: Color, bold: Bool = false, in gc: GraphicsContext) {
    gc.draw(Text(text).font(monoFont.weight(bold ? .semibold : .regular)).foregroundColor(colour), at: point, anchor: .leading)
}

struct RegistersCanvas: View {
    let frame: VizSidFrame?
    let chip: Int
    let flash: RegisterFlash

    @Environment(\.voiceTheme) private var theme

    private static let names = ["FREQ LO", "FREQ HI", "PW LO", "PW HI", "CTRL", "AD", "SR"]
    private static let bits = ["GATE", "SYNC", "RING", "TEST", "TRI", "SAW", "PUL", "NOI"]

    var body: some View {
        Canvas { gc, size in
            guard let frame, frame.chips.indices.contains(chip) else { return }
            let registers = [UInt8](frame.chips[chip].registers)
            guard registers.count >= 29 else { return }
            // Filter beside the voices where there's room, and under them where there isn't.
            let wide = size.width >= 28 + 4 * 150
            let column = wide ? (size.width - 28) / 4 : max((size.width - 28) / 3, 146)
            let rowHeight: CGFloat = 20
            let top: CGFloat = 20
            for voice in 0..<3 {
                let x = 14 + CGFloat(voice) * column
                label("VOICE \(voice + 1)", at: CGPoint(x: x, y: top), colour: theme.voice(voice), bold: true, in: gc)
                for (i, name) in Self.names.enumerated() {
                    row(register: voice * 7 + i, name: name, value: registers[voice * 7 + i], x: x, y: top + CGFloat(i + 1) * rowHeight, in: gc)
                }
                let control = registers[voice * 7 + 4]
                for (bit, name) in Self.bits.enumerated() {
                    let on = control & (1 << UInt8(bit)) != 0
                    label(name, at: CGPoint(x: x + CGFloat(bit % 4) * 34, y: top + CGFloat(8 + bit / 4) * rowHeight + 4),
                          colour: on ? .accentColor : faintColour, bold: on, in: gc)
                }
            }
            let filter = [(0x15, "CUT LO"), (0x16, "CUT HI"), (0x17, "RES/ROUT"), (0x18, "MODE/VOL")]
            let readOnly = [(0x1B, "OSC 3"), (0x1C, "ENV 3")]
            var bottom = top + 10 * rowHeight
            if wide {
                let x = 14 + 3 * column
                label("FILTER", at: CGPoint(x: x, y: top), colour: violetColour, bold: true, in: gc)
                for (i, item) in filter.enumerated() {
                    row(register: item.0, name: item.1, value: registers[item.0], x: x, y: top + CGFloat(i + 1) * rowHeight, in: gc)
                }
                label("READ-ONLY", at: CGPoint(x: x, y: top + 6 * rowHeight), colour: dimColour, bold: true, in: gc)
                for (i, item) in readOnly.enumerated() {
                    row(register: item.0, name: item.1, value: registers[item.0], x: x, y: top + CGFloat(i + 7) * rowHeight, lights: false, in: gc)
                }
            } else {
                let y = top + 10 * rowHeight + 6
                label("FILTER", at: CGPoint(x: 14, y: y), colour: violetColour, bold: true, in: gc)
                label("READ-ONLY", at: CGPoint(x: 14 + 2 * column, y: y), colour: dimColour, bold: true, in: gc)
                for (i, item) in filter.enumerated() {
                    row(register: item.0, name: item.1, value: registers[item.0], x: 14 + CGFloat(i % 2) * column, y: y + CGFloat(i / 2 + 1) * rowHeight, in: gc)
                }
                for (i, item) in readOnly.enumerated() {
                    row(register: item.0, name: item.1, value: registers[item.0], x: 14 + 2 * column, y: y + CGFloat(i + 1) * rowHeight, lights: false, in: gc)
                }
                bottom = y + 3 * rowHeight
            }
            label("Frame \(frame.index), \(frame.isPal ? "PAL" : "NTSC"). Bytes light up as the player writes them.",
                  at: CGPoint(x: 14, y: max(size.height - 14, bottom + 20)), colour: dimColour, in: gc)
        }
    }

    private func row(register: Int, name: String, value: UInt8, x: CGFloat, y: CGFloat, lights: Bool = true, in gc: GraphicsContext) {
        label(String(format: "$D4%02X", register), at: CGPoint(x: x, y: y), colour: dimColour, in: gc)
        label(name, at: CGPoint(x: x + 46, y: y), colour: .white.opacity(0.85), in: gc)
        let at = CGPoint(x: x + 118, y: y)
        if lights, flash.isLit(register) {
            gc.fill(Path(roundedRect: CGRect(x: at.x - 3, y: y - 8, width: 21, height: 16), cornerRadius: 3), with: .color(.accentColor))
            label(String(format: "%02X", value), at: at, colour: .black, bold: true, in: gc)
        } else {
            label(String(format: "%02X", value), at: at, colour: .white, in: gc)
        }
    }
}

/// Chips' registers as a line per voice and one for the filter, with byte pairs joined.
struct VoiceLines: View {
    let frame: VizSidFrame?
    let shown: [Int]
    let flashes: [RegisterFlash]

    @Environment(\.voiceTheme) private var theme

    private static let charWidth: CGFloat = 7.3
    private static let rowHeight: CGFloat = 19
    private static let columns: [(Int, String)] = [(6, "NOTE"), (12, "FREQ"), (19, "PW"), (25, "WAVE"), (33, "BITS"), (44, "AD"), (48, "SR")]
    /// Room for the filter's line whole.
    static let width: CGFloat = 28 + 64 * charWidth
    /// Room for the bars as well.
    static let barsWidth: CGFloat = 28 + 88 * charWidth
    static func height(chips: Int) -> CGFloat { CGFloat(1 + chips * 5 + (chips - 1) + 2) * rowHeight }

    /// What the waveform bits of a control byte say: a word, or initials for a mix.
    nonisolated static func waveName(_ control: UInt8) -> String {
        let on = [("TRI", "T"), ("SAW", "S"), ("PUL", "P"), ("NOI", "N")].enumerated()
            .filter { control & (0x10 << UInt8($0.offset)) != 0 }.map(\.element)
        switch on.count {
        case 0: return "—"
        case 1: return on[0].0
        default: return on.map(\.1).joined(separator: "+")
        }
    }

    /// What the other bits say: words where they fit the column, else initials.
    nonisolated static func bitsName(_ control: UInt8) -> String {
        let on = ["GATE", "SYNC", "RING", "TEST"].enumerated()
            .filter { control & (1 << UInt8($0.offset)) != 0 }.map(\.element)
        if on.isEmpty { return "—" }
        let words = on.joined(separator: " ")
        return words.count <= 10 ? words : on.map { String($0.prefix(1)) }.joined(separator: " ")
    }

    var body: some View {
        Canvas { gc, size in
            guard let frame else { return }
            let bars = size.width >= Self.barsWidth
            let at = bars ? Layout(freq: 24, pulse: 41, wave: 47, bits: 55, ad: 66, sr: 70) : Layout(freq: 12, pulse: 19, wave: 25, bits: 33, ad: 44, sr: 48)
            let column = { (n: Int) in 14 + CGFloat(n) * Self.charWidth }
            var y = Self.rowHeight
            var headings = [(6, "NOTE"), (at.freq, "FREQ"), (at.wave, "WAVE"), (at.bits, "BITS"), (at.ad, "AD"), (at.sr, "SR")]
            headings += bars ? [(12, "LEVEL"), (31, "PULSE WIDTH")] : [(at.pulse, "PW")]
            for (n, name) in headings {
                label(name, at: CGPoint(x: column(n), y: y), colour: dimColour, in: gc)
            }
            y += Self.rowHeight
            for index in shown where frame.chips.indices.contains(index) && frame.chips[index].registers.count >= 29 {
                let chip = frame.chips[index]
                let registers = [UInt8](chip.registers)
                let flash = flashes.indices.contains(index) ? flashes[index] : nil
                let isLit = { (lit: [Int]) -> Bool in lit.contains { flash?.isLit($0) == true } }
                if shown.count > 1 {
                    label("SID \(index + 1)", at: CGPoint(x: 14, y: y), colour: .white, bold: true, in: gc)
                    let rule = Path { $0.move(to: CGPoint(x: column(6), y: y)); $0.addLine(to: CGPoint(x: column(at.sr + 2), y: y)) }
                    gc.stroke(rule, with: .color(.white.opacity(0.12)), lineWidth: 1)
                    y += Self.rowHeight
                }
                for voice in 0..<3 {
                    let base = voice * 7
                    let control = registers[base + 4]
                    let open = control & 1 != 0
                    // Accent only ever means just written; a voice with its gate shut fades.
                    let colour = { (lit: [Int]) -> Color in isLit(lit) ? .accentColor : (open ? .white : dimColour) }
                    let point = { (n: Int) in CGPoint(x: column(n), y: y) }
                    label("V\(voice + 1)", at: point(0), colour: open ? theme.voice(voice) : dimColour, bold: open, in: gc)
                    let sound = chip.voices.indices.contains(voice) ? chip.voices[voice] : nil
                    label(sound?.note ?? "—", at: point(6), colour: sound?.note == nil ? faintColour : (open ? .white : dimColour), in: gc)
                    if bars {
                        Self.bar(Double(sound?.envLevel ?? 0), at: point(12), width: 9 * Self.charWidth, colour: open ? theme.voice(voice) : dimColour, in: gc)
                        let width = Double(UInt16(registers[base + 3] & 0x0F) << 8 | UInt16(registers[base + 2])) / 4095
                        // A pulse width means nothing to a voice not on a pulse wave.
                        Self.bar(width, at: point(31), width: 8 * Self.charWidth, colour: open && control & 0x40 != 0 ? theme.voice(voice) : dimColour, in: gc)
                    }
                    label(String(format: "%02X%02X", registers[base + 1], registers[base]), at: point(at.freq), colour: colour([base, base + 1]), bold: isLit([base, base + 1]), in: gc)
                    label(String(format: "%X%02X", registers[base + 3] & 0x0F, registers[base + 2]), at: point(at.pulse), colour: colour([base + 2, base + 3]), bold: isLit([base + 2, base + 3]), in: gc)
                    let wave = Self.waveName(control)
                    label(wave, at: point(at.wave), colour: wave == "—" ? faintColour : colour([base + 4]), bold: isLit([base + 4]), in: gc)
                    let bits = Self.bitsName(control)
                    label(bits, at: point(at.bits), colour: bits == "—" ? faintColour : (open ? .white : dimColour), bold: open && bits != "—", in: gc)
                    label(String(format: "%02X", registers[base + 5]), at: point(at.ad), colour: colour([base + 5]), bold: isLit([base + 5]), in: gc)
                    label(String(format: "%02X", registers[base + 6]), at: point(at.sr), colour: colour([base + 6]), bold: isLit([base + 6]), in: gc)
                    y += Self.rowHeight
                }
                let routed = (0..<3).filter { registers[0x17] & (1 << UInt8($0)) != 0 }.map { "V\($0 + 1)" }
                let modes = [("LP", UInt8(0x10)), ("BP", 0x20), ("HP", 0x40)].filter { registers[0x18] & $0.1 != 0 }.map(\.0)
                let colour = { (lit: [Int]) -> Color in isLit(lit) ? .accentColor : .white }
                label("FILT", at: CGPoint(x: 14, y: y), colour: violetColour, bold: true, in: gc)
                let cutoff = UInt16(registers[0x16]) << 3 | UInt16(registers[0x15] & 7)
                var x = 6
                var parts: [(name: String, value: String, lit: [Int])] = []
                if bars {
                    label(modes.joined(separator: "+"), at: CGPoint(x: column(6), y: y), colour: colour([0x18]), bold: isLit([0x18]), in: gc)
                    // Registers can hold old values with no voice going through the filter.
                    Self.bar(Double(cutoff) / 2047, at: CGPoint(x: column(12), y: y), width: 9 * Self.charWidth, colour: routed.isEmpty ? dimColour : violetColour, in: gc)
                    label(String(format: "%03X", cutoff), at: CGPoint(x: column(at.freq), y: y), colour: colour([0x15, 0x16]), bold: isLit([0x15, 0x16]), in: gc)
                    label("cutoff", at: CGPoint(x: column(at.freq + 4), y: y), colour: dimColour, in: gc)
                    x = at.freq + 12
                } else {
                    parts.append(("cutoff", String(format: "%03X", cutoff), [0x15, 0x16]))
                }
                parts += [
                    ("res", String(format: "%X", registers[0x17] >> 4), [0x17]),
                    ("through", routed.isEmpty ? "—" : routed.joined(separator: " "), [0x17]),
                ]
                if !bars, !modes.isEmpty { parts.append(("", modes.joined(separator: "+"), [0x18])) }
                parts += [
                    ("vol", String(format: "%X", registers[0x18] & 0x0F), [0x18]),
                    ("osc3", String(format: "%02X", registers[0x1B]), []),
                    ("env3", String(format: "%02X", registers[0x1C]), []),
                ]
                for part in parts {
                    if !part.name.isEmpty {
                        label(part.name, at: CGPoint(x: column(x), y: y), colour: dimColour, in: gc)
                        x += part.name.count + 1
                    }
                    label(part.value, at: CGPoint(x: column(x), y: y), colour: colour(part.lit), bold: isLit(part.lit), in: gc)
                    x += part.value.count + 2
                }
                y += Self.rowHeight * 2
            }
            label("Accent: just written. Faded: gate shut. FREQ and PW join two bytes each.",
                  at: CGPoint(x: 14, y: max(size.height - 14, y)), colour: dimColour, in: gc)
        }
    }

    /// Where each column starts, in characters.
    private struct Layout {
        let freq, pulse, wave, bits, ad, sr: Int
    }

    private static func bar(_ share: Double, at point: CGPoint, width: CGFloat, colour: Color, in gc: GraphicsContext) {
        let track = CGRect(x: point.x, y: point.y - 4, width: width, height: 8)
        gc.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(faintColour))
        // Anything sounding at all shows.
        let filled = share > 0 ? max(width * CGFloat(min(share, 1)), 2) : 0
        gc.fill(Path(roundedRect: CGRect(x: track.minX, y: track.minY, width: filled, height: 8), cornerRadius: 2), with: .color(colour))
    }
}

// MARK: Sweeps

/// Each chip shown in a column of its own.
struct SweepsCanvas: View {
    let frames: [VizSidFrame]
    let shown: [Int]
    let colours: [Color]

    var body: some View {
        Canvas { gc, size in
            let width = size.width / CGFloat(max(shown.count, 1))
            for (n, chip) in shown.enumerated() {
                draw(chip: chip, in: CGRect(x: CGFloat(n) * width, y: 0, width: width, height: size.height), gc: gc)
            }
        }
    }

    private func draw(chip index: Int, in area: CGRect, gc: GraphicsContext) {
        let chips = frames.compactMap { $0.chips.indices.contains(index) ? $0.chips[index] : nil }
        guard let latest = chips.last else { return }
        let beside = shown.count > 1
        let margin: CGFloat = 14
        let width = area.width - margin * 2
        let gateHeight: CGFloat = 76
        let heading: CGFloat = beside ? 22 : 0
        let laneHeight = max((area.height - gateHeight - 16 - heading) / 2, 40)
        if beside {
            label("SID \(index + 1)", at: CGPoint(x: area.minX + margin, y: 16), colour: .white, bold: true, in: gc)
        }

        // The first voice on a pulse wave: a pulse width means nothing to the others.
        let voice = latest.voices.firstIndex { $0.waveform & 0x4 != 0 }
        let shown = voice ?? 0
        let width12 = latest.voices[shown].pulseWidth
        var lane = CGRect(x: area.minX + margin, y: 8 + heading, width: width, height: laneHeight)
        let pulseName = switch (voice == nil, beside) {
        case (false, false): String(format: "PULSE WIDTH V%d  %03X", shown + 1, width12)
        case (true, false): "PULSE WIDTH  no voice on a pulse wave now"
        case (false, true): String(format: "PULSE V%d  %03X", shown + 1, width12)
        case (true, true): "PULSE  none"
        }
        label(pulseName, at: CGPoint(x: lane.minX, y: lane.minY + 8), colour: colours[shown], bold: true, in: gc)
        plot(chips.map { Double($0.voices[shown].pulseWidth) / 4095 }, in: lane.insetBy(dx: 0, dy: 16), colour: colours[shown], in: gc)

        lane.origin.y += laneHeight
        label(String(format: beside ? "CUTOFF %03X  RES %X" : "FILTER CUTOFF  %03X   RESONANCE  %X", latest.cutoff, latest.resonance),
              at: CGPoint(x: lane.minX, y: lane.minY + 8), colour: violetColour, bold: true, in: gc)
        let inner = lane.insetBy(dx: 0, dy: 16)
        plot(chips.map { Double($0.cutoff) / 2047 }, in: inner, colour: violetColour, in: gc)
        plot(chips.map { Double($0.resonance) / 15 }, in: inner, colour: violetColour.opacity(0.5), dash: [4, 4], in: gc)

        lane.origin.y += laneHeight
        label("GATES", at: CGPoint(x: lane.minX, y: lane.minY + 8), colour: dimColour, bold: true, in: gc)
        let step = width / CGFloat(max(chips.count - 1, 1))
        for v in 0..<3 {
            let y = lane.minY + 26 + CGFloat(v) * 16
            label("V\(v + 1)", at: CGPoint(x: lane.minX, y: y), colour: colours[v], in: gc)
            var from: Int?
            for (i, chip) in chips.enumerated() {
                if chip.voices[v].gate, from == nil { from = i }
                let ends = !chip.voices[v].gate || i == chips.count - 1
                if ends, let start = from {
                    let x = lane.minX + 26 + CGFloat(start) * step * (width - 26) / width
                    let end = lane.minX + 26 + CGFloat(i) * step * (width - 26) / width
                    gc.fill(Path(roundedRect: CGRect(x: x, y: y - 4, width: max(end - x, 1.5), height: 8), cornerRadius: 2), with: .color(colours[v]))
                    from = nil
                }
            }
        }
    }

    private func plot(_ values: [Double], in rect: CGRect, colour: Color, dash: [CGFloat] = [], in gc: GraphicsContext) {
        guard values.count > 1 else { return }
        var path = Path()
        for (i, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1),
                                y: rect.maxY - rect.height * CGFloat(min(max(value, 0), 1)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        gc.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: dash))
    }
}

// MARK: Pitch trail

/// Each chip shown in a band of its own.
struct PitchCanvas: View {
    let frames: [VizSidFrame]
    let shown: [Int]
    let colours: [Color]

    private static let low = 24.0
    private static let high = 96.0

    var body: some View {
        Canvas { gc, size in
            let height = size.height / CGFloat(max(shown.count, 1))
            for (n, chip) in shown.enumerated() {
                draw(chip: chip, in: CGRect(x: 0, y: CGFloat(n) * height, width: size.width, height: height), gc: gc)
            }
        }
    }

    private func draw(chip index: Int, in area: CGRect, gc: GraphicsContext) {
        let chips = frames.compactMap { $0.chips.indices.contains(index) ? $0.chips[index] : nil }
        let beside = shown.count > 1
        let left: CGFloat = 40
        let right = area.width - 90
        let top = area.minY + 10
        let bottom = area.maxY - 10
        let y = { (midi: Double) -> CGFloat in
            bottom - (bottom - top) * CGFloat((midi - Self.low) / (Self.high - Self.low))
        }
        // Every octave only where the labels won't run into each other.
        for octave in stride(from: Self.low, through: Self.high, by: bottom - top < 110 ? 24 : 12) {
            label("C\(Int(octave) / 12 - 1)", at: CGPoint(x: 14, y: y(octave)), colour: dimColour, in: gc)
            gc.stroke(Path { $0.move(to: CGPoint(x: left, y: y(octave))); $0.addLine(to: CGPoint(x: right, y: y(octave))) },
                      with: .color(.white.opacity(0.07)), lineWidth: 1)
        }
        guard chips.count > 1 else { return }
        let x = { (i: Int) -> CGFloat in left + (right - left) * CGFloat(i) / CGFloat(chips.count - 1) }
        for voice in 0..<3 {
            var path = Path()
            var drawing = false
            for (i, chip) in chips.enumerated() {
                let sound = chip.voices[voice]
                guard sound.gate, sound.midi >= Self.low, sound.midi <= Self.high else {
                    drawing = false
                    continue
                }
                let point = CGPoint(x: x(i), y: y(sound.midi))
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
            }
            gc.stroke(path, with: .color(colours[voice]), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        if beside {
            label("SID \(index + 1)", at: CGPoint(x: right + 12, y: top + 4), colour: .white, bold: true, in: gc)
        }
        if let latest = chips.last {
            let first = beside ? top + 24 : top + 10
            let spacing = min(40, (bottom - first) / 3)
            for voice in 0..<3 {
                let sound = latest.voices[voice]
                let row = first + CGFloat(voice) * spacing
                label("V\(voice + 1) \(sound.gate ? (sound.note ?? "—") : "—")", at: CGPoint(x: right + 12, y: row), colour: colours[voice], bold: true, in: gc)
                if spacing >= 32 {
                    label(sound.waveformName.isEmpty ? "—" : sound.waveformName, at: CGPoint(x: right + 12, y: row + 16), colour: dimColour, in: gc)
                }
            }
        }
    }
}
