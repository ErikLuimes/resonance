import Foundation
import Observation
import PhosphorCore
import QuartzCore

// The picture on the 1084S (MonitorView.swift): a C64 boot, then a 40×25
// player drawn from PlayerStore and the visualizer feed, in two colors.
// design/crt-monitor/README.md has the layout and the reasons.

/// Our own 8×8 glyphs in the spirit of the C64's upper-case set, eight row
/// bytes each, MSB left. The Commodore character ROM isn't ours to ship.
nonisolated enum C64Font {
    private static let table: [(Character, String)] = [
        (" ", "0000000000000000"), ("!", "1818181800001800"), ("\"", "6666660000000000"), ("#", "6666FF66FF666600"),
        ("$", "183E603C067C1800"), ("%", "62660C1830664600"), ("&", "3C663C3867663F00"), ("'", "060C180000000000"),
        ("(", "0C18303030180C00"), (")", "30180C0C0C183000"), ("*", "00663CFF3C660000"), ("+", "0018187E18180000"),
        (",", "0000000000181830"), ("-", "0000007E00000000"), (".", "0000000000181800"), ("/", "0003060C18306000"),
        ("0", "3C666E7666663C00"), ("1", "1818381818187E00"), ("2", "3C66060C30607E00"), ("3", "3C66061C06663C00"),
        ("4", "060E1E667F060600"), ("5", "7E607C0606663C00"), ("6", "3C66607C66663C00"), ("7", "7E660C1818181800"),
        ("8", "3C66663C66663C00"), ("9", "3C66663E06663C00"), (":", "0000181800181800"), (";", "0000181800181830"),
        ("<", "0E18306030180E00"), ("=", "00007E007E000000"), (">", "70180C060C187000"), ("?", "3C66060C18001800"),
        ("@", "3C666E6E60623C00"), ("A", "183C667E66666600"), ("B", "7C66667C66667C00"), ("C", "3C66606060663C00"),
        ("D", "786C6666666C7800"), ("E", "7E60607860607E00"), ("F", "7E60607860606000"), ("G", "3C66606E66663C00"),
        ("H", "6666667E66666600"), ("I", "3C18181818183C00"), ("J", "1E0C0C0C0C6C3800"), ("K", "666C7870786C6600"),
        ("L", "6060606060607E00"), ("M", "63777F6B63636300"), ("N", "66767E7E6E666600"), ("O", "3C66666666663C00"),
        ("P", "7C66667C60606000"), ("Q", "3C666666663C0E00"), ("R", "7C66667C786C6600"), ("S", "3C66603C06663C00"),
        ("T", "7E18181818181800"), ("U", "6666666666663C00"), ("V", "66666666663C1800"), ("W", "6363636B7F776300"),
        ("X", "66663C183C666600"), ("Y", "666666663C181800"), ("Z", "7E060C1830607E00"), ("[", "3C30303030303C00"),
        ("]", "3C0C0C0C0C0C3C00"), ("^", "00183C7E18181800"), ("_", "00000000000000FF"),
        // Graphics.
        ("█", "FFFFFFFFFFFFFFFF"), ("▒", "AA55AA55AA55AA55"), ("▄", "00000000FFFFFFFF"), ("▀", "FFFFFFFF00000000"),
        ("─", "000000FFFF000000"), ("■", "007E7E7E7E7E7E00"), ("□", "007E424242427E00"), ("▶", "0060787E7E786000"),
        ("‖", "0066666666666600"), ("♥", "367F7F7F3E1C0800"), ("•", "00003C3C3C3C0000"), ("│", "1818181818181818"),
        ("←", "0010307F7F301000"),
        // Extra graphics for the startup disk's directory art.
        ("🮏", "00000000AA55AA55"), ("🮂", "FFFF000000000000"), ("🮌", "A050A050A050A050"),
        ("▔", "FF00000000000000"), ("▁", "00000000000000FF"), ("▂", "000000000000FFFF"),
        ("▕", "0101010101010101"), ("▏", "8080808080808080"), ("▌", "F0F0F0F0F0F0F0F0"),
        ("▝", "0F0F0F0F00000000"), ("▘", "F0F0F0F000000000"), ("╲", "8040201008040201"),
        ("╭", "000000071F3C3030"), ("╰", "30303C1F07000000"), ("╯", "0C0C3CF8E0000000"),
    ]

    /// Every glyph's eight rows, in the table's order.
    static let rows: [UInt8] = table.flatMap { entry in
        (0..<8).map { row in UInt8(entry.1.dropFirst(row * 2).prefix(2), radix: 16) ?? 0 }
    }

    private static let index: [Character: Int] = Dictionary(uniqueKeysWithValues: table.enumerated().map { ($1.0, $0) })
    static let space = index[" "]!
    private static let unknown = index["?"]!

    /// Lower case comes out upper, accents are dropped, and anything else is ?.
    static func glyph(_ character: Character) -> Int {
        if let found = index[character] { return found }
        let plain = String(character).folding(options: .diacriticInsensitive, locale: nil).uppercased()
        if let first = plain.first, let found = index[first] { return found }
        return unknown
    }
}

/// 40×25 cells over a 384×272 picture: the C64's 320×200 with its border.
/// Reverse video is the only emphasis. `render` writes BGRA pixels.
nonisolated struct C64Frame: Equatable {
    static let width = 384, height = 272, columns = 40, rows = 25, originX = 32, originY = 36
    /// The two colors, from the reference screenshot (BGRA8 as little-endian words).
    static let background: UInt32 = 0xFF65_4DB6
    static let foreground: UInt32 = 0xFF9E_8BE1

    var cells = [UInt16](repeating: UInt16(C64Font.space), count: columns * rows)
    var reversed = [Bool](repeating: false, count: columns * rows)

    mutating func clear() {
        cells = [UInt16](repeating: UInt16(C64Font.space), count: Self.columns * Self.rows)
        reversed = [Bool](repeating: false, count: Self.columns * Self.rows)
    }

    mutating func put(_ x: Int, _ y: Int, _ text: String, reversed flag: Bool = false) {
        guard y >= 0, y < Self.rows else { return }
        var column = x
        for character in text {
            if column >= Self.columns { break }
            if column >= 0 {
                cells[y * Self.columns + column] = UInt16(C64Font.glyph(character))
                reversed[y * Self.columns + column] = flag
            }
            column += 1
        }
    }

    /// A whole row: `text` cut or padded to 40.
    mutating func line(_ y: Int, _ text: String, reversed flag: Bool = false) {
        let padded = String(text.prefix(Self.columns)) + String(repeating: " ", count: max(0, Self.columns - text.count))
        put(0, y, padded, reversed: flag)
    }

    /// Scrolls everything up a row, as the C64 does when the cursor leaves the bottom.
    mutating func scroll() {
        cells.removeFirst(Self.columns)
        cells.append(contentsOf: [UInt16](repeating: UInt16(C64Font.space), count: Self.columns))
        reversed.removeFirst(Self.columns)
        reversed.append(contentsOf: [Bool](repeating: false, count: Self.columns))
    }

    func render(into pixels: inout [UInt32], cursor: (x: Int, y: Int)?) {
        pixels.withUnsafeMutableBufferPointer { out in
            for i in out.indices { out[i] = Self.foreground }
            C64Font.rows.withUnsafeBufferPointer { font in
                for y in 0..<Self.rows {
                    for x in 0..<Self.columns {
                        let cell = y * Self.columns + x
                        var flag = reversed[cell]
                        if let cursor, cursor.x == x, cursor.y == y { flag.toggle() }
                        let glyph = Int(cells[cell]) * 8
                        let left = Self.originX + x * 8
                        for row in 0..<8 {
                            let bits = font[glyph + row]
                            let base = (Self.originY + y * 8 + row) * Self.width + left
                            for bit in 0..<8 {
                                let on = (bits >> UInt8(7 - bit)) & 1 == 1
                                out[base + bit] = on != flag ? Self.foreground : Self.background
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The startup disk's simulated LIST output. Each zero-block entry supplies
/// one 16-character row of the skull; the PRG is the only loadable entry.
private nonisolated enum C64StartupDirectory {
    private static let art = [
        "    .🮏🮏🮏🮏🮏🮏.    ",
        "   🮏▒*🮂▔▔🮂*▒🮏   ",
        "  ╭▒▔ ▁▁▁▁ ▔*│  ",
        " ▕▒▔ 🮏▒▒▒▒▒▁.▒▏ ",
        " │🮌 ▒▒▒▒▒▒▒▒ ▕│ ",
        " ▒▏▕▒▒▒▒▒▒▒▒🮌▕▒ ",
        " │🮏🮏▒*▒▒▒▒*─▒🮏▒ ",
        "▕▒▌ ▒  ▒▒  ▒ ▕▒▏",
        "▕▒▌ ▕  ▒▒  ▏ ▕▒▏",
        "▕▒▌ ▝▂▂▒│▂▂▘ ▕▒▏",
        "▕▒▌  ▒▒▏▕▒▒  ▕▒▏",
        " ▔▔   ▒▒▒▒   ▔▔╲",
        "     ▕▂▂▂▂▏    ╲",
        "     ▕▌▌▌▌▏    ╯",
        "      ╰▂▂╯ ───╯ ",
        " .            + ",
        "STILL LISTENING "
    ]

    static let frame: C64Frame = {
        var frame = C64Frame()
        frame.put(0, 0, "LIST")
        frame.put(0, 2, "0 ")
        frame.put(2, 2, "\"RESONANCE       \" RS 2A", reversed: true)
        for (index, name) in art.enumerated() {
            frame.put(0, 3 + index, "0    \"\(name)\"")
            frame.put(24, 3 + index, "DEL")
        }
        let programRow = 3 + art.count
        frame.put(0, programRow, "38   \"RESONANCE\"")
        frame.put(24, programRow, "PRG")
        frame.put(0, programRow + 1, "626 BLOCKS FREE.")
        frame.put(0, programRow + 3, "READY.")
        return frame
    }()
}

/// What the tube is doing, for the shader: the power animation's parameters.
nonisolated struct MonitorPicture {
    var bright: Float = 0
    var scaleX: Float = 1
    var scaleY: Float = 1
    var focus: Float = 0.4
    var wobble: Float = 0
    var ambient: Float = 1
    var collapse: Float = 0
}

/// The monitor's state: off, warming up and booting, or showing the player.
/// One for the app, shown in About Resonance.
@MainActor @Observable
final class MonitorModel {
    static let shared = MonitorModel()

    enum Power { case off, on, dying }
    enum Mode { case off, boot, player, frozen }

    private(set) var power: Power = .off
    @ObservationIgnored private(set) var mode: Mode = .off
    @ObservationIgnored private(set) var frame = C64Frame()
    @ObservationIgnored private(set) var cursor: (x: Int, y: Int)?
    /// The list row the arrows have picked.
    @ObservationIgnored private(set) var selected = 0

    @ObservationIgnored private var onAt = 0.0
    @ObservationIgnored private var offAt = 0.0
    @ObservationIgnored private var term = (x: 0, y: 0)
    @ObservationIgnored private var script: [Step] = []
    @ObservationIgnored private var scriptAt = 0
    @ObservationIgnored private var peaks: [Float] = [0, 0, 0]
    @ObservationIgnored private var lastTick = 0.0
    @ObservationIgnored private var tuneCount: UInt32?
    @ObservationIgnored private var freezer: SIDFreezeMonitor?

    private struct Step {
        var at: Double = 0
        let delay: Double
        let run: @MainActor (MonitorModel) -> Void
    }

    static let heaterTime = 1.0

    var isOn: Bool { power == .on }

    /// About is animating its window until then: the power button waits. A
    /// deadline rather than a flag, so a window animation that never
    /// reports its end (About closed under it) can't lock the button.
    @ObservationIgnored var busyUntil: Double = 0
    var busy: Bool { CACurrentMediaTime() < busyUntil }
    /// About has grown for the monitor. At its small size the monitor can
    /// only be off: `tick` switches it off if it isn't.
    @ObservationIgnored var hostGrown = false
    @ObservationIgnored private var hostFullscreen = false
    @ObservationIgnored var holdsCameraForWindowResize = false

    static let pictureCollapseDuration = 0.45

    /// Fullscreen resizing can interrupt drawing without closing About.
    func setHostFullscreen(_ enabled: Bool) {
        hostFullscreen = enabled
        lastDraw = CACurrentMediaTime()
    }
    /// Counts the clean starts: the renderer draws only while About is on
    /// screen, so a gap in its drawing means About was closed, and the
    /// monitor starts over, whatever SwiftUI did with the window. About
    /// watches this and puts its window back.
    private(set) var resets = 0
    @ObservationIgnored private var lastDraw = 0.0
    /// Each character the boot types, as it types it, and its Returns: the
    /// desk in About presses the C64's keys with it.
    @ObservationIgnored var typed: ((Character) -> Void)?

    /// The power button: on from off, off from on. Nothing while the picture
    /// is still collapsing or About's window is on the move: pressing in
    /// those moments left the monitor on at its small size.
    func pressPower(store: PlayerStore?) {
        guard !busy else { return }
        switch power {
        case .off: powerOn(store: store)
        case .on: powerOff()
        case .dying: break
        }
    }

    func powerOn(store: PlayerStore?) {
        guard power == .off else { return }
        tuneCount = store?.hvscInfo?.totalTunes
        power = .on
        onAt = CACurrentMediaTime()
        boot()
    }

    /// Off, nothing running, nothing on the screen, the list from the top,
    /// as a monitor just unpacked. About calls it whenever its window goes,
    /// and `tick` when it finds About was gone.
    func startOver() {
        powerOff(animated: false)
        frame.clear()
        cursor = nil
        peaks = [0, 0, 0]
        selected = 0
        hostGrown = false
        hostFullscreen = false
        holdsCameraForWindowResize = false
        busyUntil = 0
        resets += 1
    }

    /// Starts the collapse. `now: false` is the window closing: off at once.
    func powerOff(animated: Bool = true) {
        if power == .off { return }
        if animated, power == .on {
            power = .dying
            offAt = CACurrentMediaTime()
        } else {
            power = .off
        }
        freezer?.close()
        freezer = nil
        mode = .off
        script = []
        cursor = nil
    }

    // MARK: The boot

    /// The cartridge resets the C64 while its monitor stays on.
    func resetComputer() {
        guard isOn else { return }
        freezer?.close()
        freezer = nil
        selected = 0
        peaks = [0, 0, 0]
        boot()
    }

    private func boot() {
        frame.clear()
        term = (0, 0)
        cursor = nil
        mode = .boot
        let count = tuneCount.map(String.init) ?? "63165"
        var steps: [Step] = [
            Step(delay: 0.05) { m in
                m.print("\n    **** RESONANCE 64 SID PLAYER ****\n\n 64K RAM SYSTEM  \(count) SID TUNES FREE\n\nREADY.\n")
                m.showCursor(true)
            },
            Step(delay: 1.1) { _ in },
        ]
        steps += typing("LOAD\"$\",8")
        steps += [
            submit(after: 0.35),
            Step(delay: 0.18) { m in m.print("\nSEARCHING FOR $\n") },
            Step(delay: 0.20) { m in m.print("LOADING\n") },
            Step(delay: 0.35) { m in m.print("\nREADY.\n"); m.showCursor(true) },
            Step(delay: 0.25) { _ in },
        ]
        steps += typing("LIST")
        steps += [
            submit(after: 0.24),
            Step(delay: 0.10) { m in
                m.frame = C64StartupDirectory.frame
                m.term = (0, C64Frame.rows - 1)
                m.showCursor(true)
            },
            Step(delay: 2) { _ in },
        ]
        steps += typing("LOAD\"RESONANCE\",8,1")
        steps += [
            submit(after: 0.35),
            Step(delay: 0.4) { m in m.print("\nSEARCHING FOR RESONANCE\n") },
            Step(delay: 1.0) { m in m.print("LOADING\n") },
            Step(delay: 1.7) { m in m.print("READY.\n"); m.showCursor(true) },
            Step(delay: 0.8) { _ in },
        ]
        steps += typing("RUN")
        steps += [
            submit(after: 0.3),
            Step(delay: 0.35) { m in m.startPlayer() },
        ]
        // A warm CRT can show a reboot right away.
        var at = max(CACurrentMediaTime(), onAt + Self.heaterTime + 0.3)
        for i in steps.indices {
            at += steps[i].delay
            steps[i].at = at
        }
        script = steps
        scriptAt = 0
    }

    private func submit(after delay: Double) -> Step {
        Step(delay: delay) { m in
            m.showCursor(false)
            m.newline()
            m.typed?("\n")
        }
    }

    private func typing(_ text: String) -> [Step] {
        text.map { character in
            Step(delay: Double.random(in: 0.06...0.16)) { m in
                m.print(String(character))
                m.showCursor(true)
                m.typed?(character)
            }
        }
    }

    /// For previews: on and warm, straight at the player.
    func showPlayer(store: PlayerStore?) {
        tuneCount = store?.hvscInfo?.totalTunes
        power = .on
        onAt = CACurrentMediaTime() - 10
        startPlayer()
    }

    /// Any key during the boot: straight to the player.
    func skipBoot() {
        guard mode == .boot else { return }
        startPlayer()
    }

    // MARK: The freeze cartridge

    /// C64 F6/F8 are Shift+F5/F7 on the modeled keyboard.
    func handleFreezeKey(_ key: C64Key, shifted: Bool, character: String? = nil, store: PlayerStore) -> Bool {
        guard isOn else { return false }
        if let freezer {
            if freezer.key(key, shifted: shifted, character: character) {
                startPlayer()
            }
            return true
        }
        guard shifted, key == .f5 || key == .f7 else { return false }
        if mode == .boot {
            startPlayer()
            compose(store, dt: 0)
        }
        guard mode == .player else { return false }
        freezer = SIDFreezeMonitor(store: store, frozenFrame: frame, direct: key == .f7)
        mode = .frozen
        return true
    }

    func pasteIntoFreezeMonitor(_ text: String) {
        freezer?.paste(text)
    }

    private func startPlayer() {
        freezer?.close()
        freezer = nil
        mode = .player
        script = []
        cursor = nil
        frame.clear()
    }

    private func print(_ text: String) {
        for character in text {
            if character == "\n" { newline(); continue }
            frame.put(term.x, term.y, String(character))
            term.x += 1
            if term.x >= C64Frame.columns { newline() }
        }
    }

    private func newline() {
        term.x = 0
        term.y += 1
        if term.y >= C64Frame.rows {
            frame.scroll()
            term.y = C64Frame.rows - 1
        }
    }

    private func showCursor(_ shown: Bool) {
        cursor = shown ? (term.x, term.y) : nil
    }

    // MARK: Each frame

    /// Advances the boot, redraws the player from the store, and says what
    /// the tube is doing. Called once per display frame by the renderer.
    func tick(store: PlayerStore?, now: Double = CACurrentMediaTime()) -> MonitorPicture {
        // A gap in the drawing: About was away. Everything starts over.
        if !hostFullscreen, lastDraw > 0, now - lastDraw > 0.5, power != .off || mode != .off {
            startOver()
        }
        lastDraw = now
        // Small means off. About grows within a frame of the power press;
        // half a second of grace covers that, and nothing else.
        if !hostGrown, power != .off, now - onAt > 0.5 { powerOff(animated: false) }
        let dt = lastTick == 0 ? 0 : min(0.1, now - lastTick)
        lastTick = now
        if mode == .boot {
            while scriptAt < script.count, script[scriptAt].at <= now {
                script[scriptAt].run(self)
                scriptAt += 1
            }
        }
        if mode == .player, let store {
            compose(store, dt: dt)
        } else if let freezer {
            freezer.syncVolume()
            frame = freezer.frame
            cursor = freezer.cursor
        }
        return picture(at: now)
    }

    private func picture(at now: Double) -> MonitorPicture {
        var p = MonitorPicture()
        switch power {
        case .off:
            p.bright = 0
        case .on:
            let t = now - onAt
            if t > Self.heaterTime {
                let a = t - Self.heaterTime
                let u = min(1, a / 0.7), e = 1 - pow(1 - u, 3)
                p.scaleY = Float(0.03 + 0.97 * e)
                p.scaleX = Float(0.9 + 0.1 * e)
                let u2 = min(1, a / 1.8)
                p.bright = Float((0.15 + 0.85 * min(1, a / 0.45)) * (1 + 0.22 * sin(.pi * u2) * (1 - u2)))
                p.focus = Float(0.4 + 0.55 * max(0, 1 - a / 1.4))
                p.wobble = Float(0.012 * exp(-a * 2.5))
                p.ambient = Float(0.04 + 0.96 * max(0, 1 - a / 1.5))
            } else {
                p.bright = 0
            }
        case .dying:
            let t = now - offAt
            p.ambient = Float(0.04 + 0.96 * min(1, t / 1.5))
            if t < 0.12 {
                let u = t / 0.12
                p.scaleY = Float(1 - (1 - 0.004) * u * u)
                p.bright = Float(1 + 1.4 * u)
            } else if t < Self.pictureCollapseDuration {
                let u = (t - 0.12) / (Self.pictureCollapseDuration - 0.12)
                p.collapse = 1
                p.scaleY = 0.004
                p.scaleX = Float(1 - (1 - 0.006) * u * u * u)
                p.bright = Float(2.4 - 1.0 * u)
            } else {
                p.collapse = 1
                p.scaleY = 0.004
                p.scaleX = 0.006
                p.bright = Float(1.4 * exp(-(t - Self.pictureCollapseDuration) / 0.55))
                if p.bright < 0.01 {
                    power = .off
                    p.bright = 0
                    p.ambient = 1
                }
            }
        }
        return p
    }

    // MARK: The player screen

    private struct Listed {
        let name: String
        let tunes: [QueuedTune]
        let playing: Int?
    }

    /// The list playing: the library queue, or the playlist.
    private func listed(_ store: PlayerStore) -> Listed {
        if store.queueActive {
            let playing = store.queue.firstIndex { $0.path == store.nowPlaying?.path }
            return Listed(name: store.queueSource?.name ?? "QUEUE", tunes: store.queue, playing: playing)
        }
        let tunes = store.rows.map { QueuedTune(path: $0.id, title: $0.title, author: $0.author) }
        return Listed(name: "PLAYLIST", tunes: tunes, playing: store.currentIndex)
    }

    private func compose(_ store: PlayerStore, dt: Double) {
        let list = listed(store)
        selected = max(0, min(selected, max(0, list.tunes.count - 1)))
        var f = C64Frame()
        f.line(0, " RESONANCE 64".padding(toLength: 29, withPad: " ", startingAt: 0) + "SID PLAYER ", reversed: true)
        let count = "\(list.tunes.count) TUNES"
        f.line(2, (" " + list.name.uppercased()).padding(toLength: max(0, 39 - count.count), withPad: " ", startingAt: 0) + " " + count)
        let first = max(0, min(selected - 4, list.tunes.count - 10))
        for row in 0..<10 {
            let i = first + row
            guard i < list.tunes.count else { break }
            let number = String(i + 1)
            let text = (i == selected ? ">" : " ") + String(repeating: " ", count: max(0, 2 - number.count)) + number + ". " + list.tunes[i].title
            f.line(3 + row, text, reversed: i == list.playing)
        }
        if let tune = store.nowPlaying {
            f.line(14, " PLAYING: " + tune.title)
            f.line(15, " BY:      " + tune.author)
            f.line(16, " YEAR:    " + tune.released)
            let song = " SONG:    \(tune.currentSong) OF \(tune.songs)"
            let time = "TIME: " + Self.clock(store.elapsed) + " / " + (store.duration.map(Self.clock) ?? "--:--")
            f.line(17, song.padding(toLength: 20, withPad: " ", startingAt: 0) + time)
            let share = store.duration.map { $0 > 0 ? min(1, store.elapsed / $0) : 0 } ?? 0
            let filled = Int((36 * share).rounded())
            f.line(18, " [" + String(repeating: "█", count: filled) + String(repeating: "▒", count: 36 - filled) + "]")
        } else {
            f.line(14, " NOTHING PLAYING")
            f.line(18, " [" + String(repeating: "▒", count: 36) + "]")
        }
        let voices = store.visualizer.latest()?.chips.first?.voices ?? []
        for v in 0..<3 {
            let voice = v < voices.count ? voices[v] : nil
            let level = max(0, min(1, voice?.envLevel ?? 0))
            peaks[v] = max(level, peaks[v] - Float(dt) * 1.2)
            let lit = Int((level * 30).rounded()), peak = Int((peaks[v] * 30).rounded())
            var bar = ""
            for cell in 0..<30 {
                bar += cell < lit ? "■" : (cell == peak - 1 && peak > lit ? "□" : ".")
            }
            let name = (voice?.waveformName.prefix(3)).map(String.init) ?? "   "
            f.line(20 + v, " V\(v + 1) " + name.padding(toLength: 3, withPad: " ", startingAt: 0) + " " + bar)
        }
        let status = switch store.state {
        case .playing: "PLAYING"
        case .paused: "PAUSED "
        case .stopped: "STOPPED"
        }
        let volume = max(0, min(10, Int((store.volume * 10).rounded())))
        let percent = String(volume * 10)
        f.line(23, " F6 FREEZE              F8 CODE MONITOR")
        f.line(24, " " + status + "  VOL " + String(repeating: "■", count: volume) + String(repeating: ".", count: 10 - volume)
               + String(repeating: " ", count: max(1, 4 - percent.count)) + percent + "%" + (store.shuffle ? "  SHUFFLE" : ""))
        frame = f
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Keys

    /// The list keys, on the monitor's own list. True when handled.
    func handle(_ action: KeyAction, store: PlayerStore) -> Bool {
        guard mode == .player else { return true }
        let list = listed(store)
        switch action {
        case .moveDown: selected = min(list.tunes.count - 1, selected + 1)
        case .moveUp: selected = max(0, selected - 1)
        case .top: selected = 0
        case .bottom: selected = list.tunes.count - 1
        case .playSelected:
            guard selected < list.tunes.count else { return true }
            let tune = list.tunes[selected]
            if store.queueActive {
                store.playQueue(store.queue.map { URL(filePath: $0.path) }, startAt: URL(filePath: tune.path),
                                from: store.queueSource ?? .myPlaylist, tunes: store.queue)
            } else {
                store.play(index: selected)
            }
        case .remove: break   // Not from here.
        default: return false
        }
        selected = max(0, selected)
        return true
    }
}
