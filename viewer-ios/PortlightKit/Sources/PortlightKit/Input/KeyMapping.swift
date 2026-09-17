import Foundation

/// Hardware and soft keys → X11/RFB keysyms (Portlight's key contract; never HID usages or Mac keycodes).
///
/// Non-printing keys come from a HID-usage table. Printing keys use the keysym of the character the
/// key produces without modifiers, so ⌃C sends `c` with Control held and the host's layout resolves it.
/// Keypad keys map to plain ASCII keysyms because the host types unmapped keypad keysyms
/// (0xffb0…) as U+FFxx text. A key that maps to nothing is dropped, never typed.
public enum KeyMapping {
    /// UIKeyboardHIDUsage raw value → keysym for keys that don't produce text.
    static let nonPrinting: [Int: UInt32] = {
        var table: [Int: UInt32] = [
            0x28: 0xff0d, // Return
            0x29: 0xff1b, // Escape
            0x2A: 0xff08, // Backspace (Mac "Delete")
            0x2B: 0xff09, // Tab
            0x39: 0xffe5, // Caps Lock
            0x49: 0xff63, // Insert (host: Help)
            0x4A: 0xff50, // Home
            0x4B: 0xff55, // Page Up
            0x4C: 0xffff, // Forward Delete
            0x4D: 0xff57, // End
            0x4E: 0xff56, // Page Down
            0x4F: 0xff53, // Right
            0x50: 0xff51, // Left
            0x51: 0xff54, // Down
            0x52: 0xff52, // Up
            0x58: 0xff0d, // Keypad Enter (host has no KP_Enter)
            0xE0: 0xffe3, // Left Control
            0xE1: 0xffe1, // Left Shift
            0xE2: 0xffe9, // Left Option
            0xE3: 0xffeb, // Left Command
            0xE4: 0xffe4, // Right Control
            0xE5: 0xffe2, // Right Shift
            0xE6: 0xffea, // Right Option
            0xE7: 0xffec, // Right Command
        ]
        for n in 0..<12 { table[0x3A + n] = 0xffbe + UInt32(n) } // F1–F12
        for n in 0..<8 { table[0x68 + n] = 0xffca + UInt32(n) }  // F13–F20
        return table
    }()

    /// Keypad digits and operators → ASCII keysyms.
    static let keypad: [Int: UInt32] = {
        var table: [Int: UInt32] = [
            0x54: 0x2f, // /
            0x55: 0x2a, // *
            0x56: 0x2d, // -
            0x57: 0x2b, // +
            0x62: 0x30, // 0
            0x63: 0x2e, // .
            0x67: 0x3d, // =
            0x85: 0x2c, // ,
            0x86: 0x3d, // = (AS/400)
        ]
        for n in 0..<9 { table[0x59 + n] = 0x31 + UInt32(n) } // 1–9
        return table
    }()

    /// Keysym for a key that doesn't depend on the produced character (non-printing or keypad), else nil.
    public static func keysym(forHIDUsage usage: Int) -> UInt32? {
        nonPrinting[usage] ?? keypad[usage]
    }

    /// Full hardware-key resolution: HID tables first, then the unmodified character. Nil means drop the key.
    public static func keysym(forHIDUsage usage: Int, charactersIgnoringModifiers: String) -> UInt32? {
        keysym(forHIDUsage: usage) ?? keysym(forCharacter: charactersIgnoringModifiers)
    }

    /// Keysym of a typed character that is exactly one Unicode scalar (letters lowercased: the host adds
    /// Shift itself for uppercase). Latin-1 is its codepoint, other Unicode 0x01000000 | codepoint.
    /// Multi-scalar characters ("e\u{301}", flags, emoji with a variation selector) map to nil, because their
    /// first scalar alone is a different character; so do multi-character strings (such as UIKit's named key
    /// constants), controls and private-use characters.
    public static func keysym(forCharacter text: String) -> UInt32? {
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first, scalars.index(after: scalars.startIndex) == scalars.endIndex else { return nil }
        return keysym(for: scalar)
    }

    static func keysym(for scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.properties.generalCategory {
        case .control, .privateUse, .surrogate, .unassigned: return nil
        default: break
        }
        var chosen = scalar
        let lower = String(scalar).lowercased().unicodeScalars
        if lower.count == 1, let only = lower.first { chosen = only }
        return chosen.value <= 0xff ? chosen.value : 0x0100_0000 | chosen.value
    }

    /// The sticky modifier a modifier keysym (left or right hand) belongs to.
    public static func modifierKey(forKeysym keysym: UInt32) -> ModifierKey? {
        switch keysym {
        case 0xffe1, 0xffe2: return .shift
        case 0xffe3, 0xffe4: return .control
        case 0xffe9, 0xffea: return .option
        case 0xffeb, 0xffec: return .command
        default: return nil
        }
    }
}

/// Keys offered in the expandable accessory palette, including soft equivalents of shortcuts iOS reserves.
public enum SoftKey: String, CaseIterable, Sendable, Codable {
    case escape, tab, left, right, up, down, home, end, pageUp, pageDown, forwardDelete, backspace, returnKey
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    public var keysym: UInt32 {
        switch self {
        case .escape: return 0xff1b
        case .tab: return 0xff09
        case .left: return 0xff51
        case .right: return 0xff53
        case .up: return 0xff52
        case .down: return 0xff54
        case .home: return 0xff50
        case .end: return 0xff57
        case .pageUp: return 0xff55
        case .pageDown: return 0xff56
        case .forwardDelete: return 0xffff
        case .backspace: return 0xff08
        case .returnKey: return 0xff0d
        default: return 0xffbe + UInt32(functionNumber! - 1)
        }
    }

    /// 1…12 for F-keys, else nil.
    public var functionNumber: Int? {
        switch self {
        case .f1: return 1
        case .f2: return 2
        case .f3: return 3
        case .f4: return 4
        case .f5: return 5
        case .f6: return 6
        case .f7: return 7
        case .f8: return 8
        case .f9: return 9
        case .f10: return 10
        case .f11: return 11
        case .f12: return 12
        default: return nil
        }
    }

    /// Short key-cap text.
    public var label: String {
        switch self {
        case .escape: return "esc"
        case .tab: return "tab"
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pg up"
        case .pageDown: return "pg dn"
        case .forwardDelete: return "⌦"
        case .backspace: return "⌫"
        case .returnKey: return "return"
        default: return "F\(functionNumber!)"
        }
    }

    /// VoiceOver name, using the Mac's key names.
    public var accessibilityLabel: String {
        switch self {
        case .escape: return "Escape"
        case .tab: return "Tab"
        case .left: return "Left Arrow"
        case .right: return "Right Arrow"
        case .up: return "Up Arrow"
        case .down: return "Down Arrow"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .forwardDelete: return "Forward Delete"
        case .backspace: return "Delete"
        case .returnKey: return "Return"
        default: return "F\(functionNumber!)"
        }
    }

    /// SF Symbol name where a standard one exists; nil means show `label`.
    public var systemImage: String? {
        switch self {
        case .escape: return "escape"
        case .tab: return "arrow.right.to.line"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .home: return "arrow.up.left"
        case .end: return "arrow.down.right"
        case .forwardDelete: return "delete.right"
        case .backspace: return "delete.left"
        case .returnKey: return "return"
        default: return nil
        }
    }

    public static let functionKeys: [SoftKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
}
