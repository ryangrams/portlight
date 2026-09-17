import Foundation

/// Committed Unicode text → ordered `text` chunks and key presses.
///
/// Chunks hold at most `maxUTF16UnitsPerMessage` UTF-16 units and 4096 UTF-8 bytes, and split only at
/// grapheme boundaries; a single grapheme larger than that splits at scalar boundaries rather than being
/// dropped. Line breaks and tabs become Return/Tab key presses, because typed "\n" is not a Return key in
/// most Mac apps. Other control characters are dropped: they'd reach the Mac as invisible text.
public enum TextInput {
    public enum Piece: Equatable, Sendable {
        case text(String)
        /// Press and release this keysym (no modifiers; see `InputLedger.text`).
        case key(UInt32)
    }

    /// UTF-16 units per `text` message. The host posts each message as one CGEvent (Display.swift `text`), and
    /// CGEventKeyboardSetUnicodeString is reported to keep only the first 20 units of an event (host-input.md #2;
    /// URC's host posts at most 16 per event for the same reason), so a longer message would lose its tail.
    /// Smaller messages stay within the 4096-byte wire contract. Revisit once the host splits text itself.
    public static let maxUTF16UnitsPerMessage = 20

    static let returnKeysym: UInt32 = 0xff0d
    static let tabKeysym: UInt32 = 0xff09

    public static func pieces(for text: String, maxBytes: Int = PortlightProtocol.maxTextInputBytes,
                              maxUTF16Units: Int = maxUTF16UnitsPerMessage) -> [Piece] {
        let byteLimit = max(4, maxBytes)      // any scalar fits in 4 UTF-8 bytes
        let unitLimit = max(2, maxUTF16Units) // and in 2 UTF-16 units
        var result: [Piece] = []
        var chunk = ""
        var chunkBytes = 0
        var chunkUnits = 0
        func flush() {
            if !chunk.isEmpty { result.append(.text(chunk)) }
            chunk = ""; chunkBytes = 0; chunkUnits = 0
        }
        func fits(_ bytes: Int, _ units: Int) -> Bool { chunkBytes + bytes <= byteLimit && chunkUnits + units <= unitLimit }
        for character in text {
            if let keysym = keyPress(for: character) {
                flush(); result.append(.key(keysym)); continue
            }
            if isDroppedControl(character) { continue }
            let bytes = character.utf8.count, units = character.utf16.count
            if bytes > byteLimit || units > unitLimit {
                // One grapheme larger than a message: split it at scalar boundaries rather than drop it.
                flush()
                for scalar in character.unicodeScalars {
                    let size = UTF8.width(scalar), width = UTF16.width(scalar)
                    if !fits(size, width) { flush() }
                    chunk.unicodeScalars.append(scalar); chunkBytes += size; chunkUnits += width
                }
                flush()
                continue
            }
            if !fits(bytes, units) { flush() }
            chunk.append(character); chunkBytes += bytes; chunkUnits += units
        }
        flush()
        return result
    }

    /// Keysym for one committed character typed while modifiers are active (⌘ + "c", ⌘ + Return), so
    /// the chord goes through the key path instead of `text`, which never carries modifiers. Nil when the
    /// character isn't a single scalar with a keysym.
    public static func chordKeysym(for text: String) -> UInt32? {
        guard text.count == 1, let character = text.first else { return nil }
        if let keysym = keyPress(for: character) { return keysym }
        return KeyMapping.keysym(forCharacter: text)
    }

    private static func keyPress(for character: Character) -> UInt32? {
        switch character {
        case "\n", "\r\n", "\r": return returnKeysym
        case "\t": return tabKeysym
        default: return nil
        }
    }

    private static func isDroppedControl(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1
            && character.unicodeScalars.first!.properties.generalCategory == .control
    }
}
