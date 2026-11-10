import AppKit
import Carbon.HIToolbox

/// The 66 keys of the C64 on the desk in About (MonitorDesk.swift). Each is
/// a node of the 3D model named `key_<rawValue>` (design/crt-monitor/blender/scene.py).
/// The Mac's keyboard presses them as an emulator would map it, and a click
/// presses one; what a key then does on the monitor is `action`.
nonisolated enum C64Key: String, CaseIterable, Sendable {
    case leftArrow = "LEFT_ARROW", digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4", digit5 = "5"
    case digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9", digit0 = "0"
    case plus = "PLUS", minus = "MINUS", pound = "POUND", clrHome = "CLR_HOME", instDel = "INST_DEL"
    case ctrl = "CTRL", q = "Q", w = "W", e = "E", r = "R", t = "T", y = "Y", u = "U", i = "I", o = "O", p = "P"
    case at = "AT", asterisk = "ASTERISK", upArrow = "UP_ARROW", restore = "RESTORE"
    case runStop = "RUN_STOP", shiftLock = "SHIFT_LOCK", a = "A", s = "S", d = "D", f = "F", g = "G", h = "H"
    case j = "J", k = "K", l = "L", colon = "COLON", semicolon = "SEMICOLON", equals = "EQUALS", `return` = "RETURN"
    case commodore = "COMMODORE", leftShift = "LEFT_SHIFT", z = "Z", x = "X", c = "C", v = "V", b = "B", n = "N", m = "M"
    case comma = "COMMA", period = "PERIOD", slash = "SLASH", rightShift = "RIGHT_SHIFT", crsrUpDown = "CRSR_UD", crsrLeftRight = "CRSR_LR"
    case f1 = "F1", f3 = "F3", f5 = "F5", f7 = "F7", space = "SPACE"

    var nodeName: String { "key_" + rawValue }

    init?(nodeName: String) {
        guard nodeName.hasPrefix("key_") else { return nil }
        self.init(rawValue: String(nodeName.dropFirst(4)))
    }

    /// The shifts and the other keys that only change another one.
    var isModifier: Bool { [.leftShift, .rightShift, .shiftLock, .ctrl, .commodore].contains(self) }

    // MARK: From the Mac's keyboard

    /// The C64 keys a Mac key presses, VICE-style: by the character it types,
    /// so `"` is SHIFT and 2 as on the C64, and by position for the keys with
    /// no character. The modifiers come from `modifierKeys`.
    static func keys(for event: NSEvent) -> [C64Key] {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return [.return]
        case kVK_Delete, kVK_ForwardDelete: return [.instDel]
        case kVK_Escape: return [.runStop]
        case kVK_Tab: return [.ctrl]
        case kVK_Home: return [.clrHome]
        case kVK_PageUp: return [.restore]
        case kVK_Space: return [.space]
        case kVK_DownArrow: return [.crsrUpDown]
        case kVK_UpArrow: return [.leftShift, .crsrUpDown]
        case kVK_RightArrow: return [.crsrLeftRight]
        case kVK_LeftArrow: return [.leftShift, .crsrLeftRight]
        case kVK_F1: return [.f1]
        case kVK_F2: return [.leftShift, .f1]
        case kVK_F3: return [.f3]
        case kVK_F4: return [.leftShift, .f3]
        case kVK_F5: return [.f5]
        case kVK_F6: return [.leftShift, .f5]
        case kVK_F7: return [.f7]
        case kVK_F8: return [.leftShift, .f7]
        default: break
        }
        // With ⌘, the plain character: ⌘R is the R key.
        let typed = event.modifierFlags.contains(.command) ? event.charactersIgnoringModifiers : event.characters
        guard let character = typed?.first else { return [] }
        return keys(for: character)
    }

    static func keys(for character: Character) -> [C64Key] {
        if let key = byCharacter[character] { return key }
        if let upper = character.uppercased().first, let key = C64Key(rawValue: String(upper)), upper.isLetter {
            return [key]
        }
        return []
    }

    private static let byCharacter: [Character: [C64Key]] = [
        "1": [.digit1], "2": [.digit2], "3": [.digit3], "4": [.digit4], "5": [.digit5],
        "6": [.digit6], "7": [.digit7], "8": [.digit8], "9": [.digit9], "0": [.digit0],
        "!": [.leftShift, .digit1], "\"": [.leftShift, .digit2], "#": [.leftShift, .digit3], "$": [.leftShift, .digit4],
        "%": [.leftShift, .digit5], "&": [.leftShift, .digit6], "'": [.leftShift, .digit7], "(": [.leftShift, .digit8],
        ")": [.leftShift, .digit9],
        "+": [.plus], "-": [.minus], "£": [.pound], "\\": [.pound], "@": [.at], "*": [.asterisk], "^": [.upArrow],
        ":": [.colon], ";": [.semicolon], "=": [.equals], ",": [.comma], ".": [.period], "/": [.slash],
        "<": [.leftShift, .comma], ">": [.leftShift, .period], "?": [.leftShift, .slash],
        "[": [.leftShift, .colon], "]": [.leftShift, .semicolon], "`": [.leftArrow], "_": [.leftArrow], "~": [.leftArrow],
        " ": [.space], "\n": [.return], "\r": [.return],
    ]

    /// The C64's modifier keys held down by the Mac's: each shift for its
    /// own side, Control for CTRL, Option for C=, Caps Lock for SHIFT LOCK,
    /// which latches as the C64's does.
    static func modifierKeys(_ flags: NSEvent.ModifierFlags) -> Set<C64Key> {
        // The device-dependent bits tell the left and right keys apart.
        let raw = flags.rawValue
        var keys = Set<C64Key>()
        if raw & 0x0002 != 0 { keys.insert(.leftShift) }
        if raw & 0x0004 != 0 { keys.insert(.rightShift) }
        if flags.contains(.control) { keys.insert(.ctrl) }
        if flags.contains(.option) { keys.insert(.commodore) }
        if flags.contains(.capsLock) { keys.insert(.shiftLock) }
        return keys
    }

    // MARK: On the monitor

    /// Printable characters on the on-screen keyboard, including shifted caps.
    func monitorCharacter(shifted: Bool) -> String? {
        if self == .leftArrow { return "_" }
        if shifted, let cap = Self.byCharacter.first(where: { $0.value == [.leftShift, self] })?.key {
            return String(cap)
        }
        if rawValue.count == 1 { return rawValue }
        return Self.byCharacter.first { $0.value == [self] && $0.key.isASCII }.map { String($0.key) }
    }

    /// What a clicked key does in the player, in the app's own terms: the
    /// breadbin mapping of design/crt-monitor/README.md. Space plays and
    /// pauses; CRSR down and right move and skip, with SHIFT up and back;
    /// RETURN plays the picked row; f1 and f2 change the subtune; + and −
    /// the volume; RUN/STOP stops; CLR/HOME goes to the top; S and R are
    /// shuffle and Surprise Me.
    func action(shifted: Bool) -> KeyAction? {
        switch self {
        case .space: .playPause
        case .return: .playSelected
        case .crsrUpDown: shifted ? .moveUp : .moveDown
        case .crsrLeftRight: shifted ? .previousTrack : .nextTrack
        case .f1: shifted ? .previousSubtune : .nextSubtune
        case .plus: .volumeUp
        case .minus: .volumeDown
        case .runStop: .stop
        case .clrHome: shifted ? .bottom : .top
        case .s: .shuffle
        case .r: .surpriseMe
        default: nil
        }
    }
}
