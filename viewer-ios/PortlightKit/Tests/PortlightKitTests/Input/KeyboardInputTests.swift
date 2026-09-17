import Testing
@testable import PortlightKit

@Suite("Modifier latches")
struct ModifierLatchesTests {
    @Test func tapLatchesImmediatelyAndASlowSecondTapClears() {
        var latches = ModifierLatches()
        latches.tap(.command, at: 0)
        #expect(latches[.command] == .latched)
        latches.tap(.command, at: 1)
        #expect(latches[.command] == .off)
    }

    @Test func doubleTapLocksAndTheNextTapUnlocks() {
        var latches = ModifierLatches()
        latches.tap(.shift, at: 10)
        latches.tap(.shift, at: 10.35)
        #expect(latches[.shift] == .locked)
        latches.tap(.shift, at: 10.4)
        #expect(latches[.shift] == .off)
        latches.tap(.shift, at: 10.45)
        #expect(latches[.shift] == .latched) // a fresh first tap, not a lock
    }

    @Test func consumeClearsLatchedButNeverLocked() {
        var latches = ModifierLatches()
        latches.tap(.command, at: 0)
        latches.tap(.shift, at: 0)
        latches.tap(.shift, at: 0.1)
        latches.consumeAfterAction()
        #expect(latches[.command] == .off)
        #expect(latches[.shift] == .locked)
        latches.tap(.command, at: 5) // consumed latch starts over as a first tap
        #expect(latches[.command] == .latched)
    }

    @Test func clearAllTurnsEverythingOff() {
        var latches = ModifierLatches()
        for key in ModifierKey.allCases { latches.tap(key, at: 0) }
        latches.tap(.option, at: 0.1)
        latches.clearAll()
        #expect(latches.isEmpty)
        #expect(ModifierKey.allCases.allSatisfy { latches[$0] == .off })
    }

    @Test func effectiveIsASetUnionNeverACount() {
        var latches = ModifierLatches()
        latches.tap(.command, at: 0)
        latches.tap(.shift, at: 0)
        latches.tap(.shift, at: 0.2)
        #expect(latches.latched == [.command] && latches.locked == [.shift])
        #expect(latches.effective(hardwareHeld: [.command, .option]) == [.command, .shift, .option])
        #expect(latches.effective() == [.command, .shift])
    }
}

@Suite("Key mapping")
struct KeyMappingTests {
    @Test func nonPrintingTableMatchesTheHostContract() {
        let expected: [Int: UInt32] = [
            0x28: 0xff0d, 0x29: 0xff1b, 0x2A: 0xff08, 0x2B: 0xff09, 0x39: 0xffe5, 0x49: 0xff63, 0x4A: 0xff50, 0x4B: 0xff55,
            0x4C: 0xffff, 0x4D: 0xff57, 0x4E: 0xff56, 0x4F: 0xff53, 0x50: 0xff51, 0x51: 0xff54, 0x52: 0xff52, 0x58: 0xff0d,
            0xE0: 0xffe3, 0xE1: 0xffe1, 0xE2: 0xffe9, 0xE3: 0xffeb, 0xE4: 0xffe4, 0xE5: 0xffe2, 0xE6: 0xffea, 0xE7: 0xffec,
        ]
        for (usage, keysym) in expected { #expect(KeyMapping.keysym(forHIDUsage: usage) == keysym, "HID \(usage)") }
        for n in 0..<12 { #expect(KeyMapping.keysym(forHIDUsage: 0x3A + n) == 0xffbe + UInt32(n), "F\(n + 1)") }
        for n in 0..<8 { #expect(KeyMapping.keysym(forHIDUsage: 0x68 + n) == 0xffca + UInt32(n), "F\(n + 13)") }
        #expect(KeyMapping.keysym(forHIDUsage: 0x04) == nil) // "a" is a printing key: resolved from its character
    }

    @Test func keypadKeysUseAsciiKeysyms() {
        let expected: [Int: UInt32] = [0x54: 0x2f, 0x55: 0x2a, 0x56: 0x2d, 0x57: 0x2b, 0x59: 0x31, 0x5A: 0x32, 0x61: 0x39,
                                       0x62: 0x30, 0x63: 0x2e, 0x67: 0x3d]
        for (usage, keysym) in expected { #expect(KeyMapping.keysym(forHIDUsage: usage) == keysym, "HID \(usage)") }
        // Never the X11 keypad keysyms (0xffb0…), which the host would type as U+FFxx text.
        #expect(KeyMapping.keysym(forHIDUsage: 0x5A, charactersIgnoringModifiers: "\u{F702}") == 0x32)
    }

    @Test func printableKeysUseTheirUnmodifiedCharacter() {
        #expect(KeyMapping.keysym(forHIDUsage: 0x04, charactersIgnoringModifiers: "a") == 0x61)
        #expect(KeyMapping.keysym(forCharacter: "A") == 0x61)
        #expect(KeyMapping.keysym(forCharacter: "é") == 0xe9)
        #expect(KeyMapping.keysym(forCharacter: "É") == 0xe9)
        #expect(KeyMapping.keysym(forCharacter: " ") == 0x20)
        #expect(KeyMapping.keysym(forCharacter: "1") == 0x31)
        #expect(KeyMapping.keysym(forCharacter: "€") == 0x0100_20ac)
        #expect(KeyMapping.keysym(forCharacter: "😀") == 0x0101_f600)
    }

    @Test func unmappableKeysAreDroppedNeverTyped() {
        #expect(KeyMapping.keysym(forCharacter: "") == nil)
        #expect(KeyMapping.keysym(forCharacter: "ab") == nil)
        #expect(KeyMapping.keysym(forCharacter: "UIKeyInputEscape") == nil)
        #expect(KeyMapping.keysym(forCharacter: "\u{F704}") == nil) // private-use function-key character
        #expect(KeyMapping.keysym(forCharacter: "\u{7}") == nil)
        #expect(KeyMapping.keysym(forHIDUsage: 0x46, charactersIgnoringModifiers: "") == nil) // Print Screen
    }

    @Test func modifierKeysymsMapToStickyModifiers() {
        for key in ModifierKey.allCases { #expect(KeyMapping.modifierKey(forKeysym: key.keysym) == key) }
        #expect(KeyMapping.modifierKey(forKeysym: 0xffec) == .command)
        #expect(KeyMapping.modifierKey(forKeysym: 0xffe2) == .shift)
        #expect(KeyMapping.modifierKey(forKeysym: 0xffe5) == nil) // Caps Lock is a key, not a chord modifier
    }

    @Test func softKeysCoverThePalette() {
        #expect(SoftKey.allCases.count == 25)
        #expect(Set(SoftKey.allCases.map(\.keysym)).count == 25)
        let expected: [SoftKey: UInt32] = [.escape: 0xff1b, .tab: 0xff09, .left: 0xff51, .right: 0xff53, .up: 0xff52, .down: 0xff54,
                                           .home: 0xff50, .end: 0xff57, .pageUp: 0xff55, .pageDown: 0xff56, .forwardDelete: 0xffff,
                                           .backspace: 0xff08, .returnKey: 0xff0d]
        for (key, keysym) in expected { #expect(key.keysym == keysym, "\(key)") }
        #expect(SoftKey.functionKeys.map(\.keysym) == (0..<12).map { 0xffbe + UInt32($0) })
        #expect(SoftKey.f12.label == "F12" && SoftKey.backspace.accessibilityLabel == "Delete")
        #expect(SoftKey.left.systemImage == "arrow.left" && SoftKey.f1.systemImage == nil)
        for key in SoftKey.allCases { #expect(!key.label.isEmpty && !key.accessibilityLabel.isEmpty) }
    }
}

@Suite("Text input")
struct TextInputTests {
    @Test func emptyTextSendsNothing() {
        #expect(TextInput.pieces(for: "").isEmpty)
    }

    @Test func lineBreaksAndTabsBecomeKeyPressesInOrder() {
        #expect(TextInput.pieces(for: "a\nb\r\nc\td\re") == [.text("a"), .key(0xff0d), .text("b"), .key(0xff0d), .text("c"),
                                                           .key(0xff09), .text("d"), .key(0xff0d), .text("e")])
        #expect(TextInput.pieces(for: "\n\n") == [.key(0xff0d), .key(0xff0d)])
    }

    @Test func otherControlCharactersAreDropped() {
        #expect(TextInput.pieces(for: "a\u{7}b\u{1B}") == [.text("ab")])
    }

    @Test func chunksSplitOnlyAtGraphemeBoundaries() {
        let decomposed = "e\u{301}" // one grapheme, 3 bytes
        #expect(TextInput.pieces(for: decomposed + decomposed, maxBytes: 5) == [.text(decomposed), .text(decomposed)])
        let family = "👨\u{200D}👩\u{200D}👧" // one grapheme, 18 bytes
        #expect(TextInput.pieces(for: "ab" + family + "cd", maxBytes: 19) == [.text("ab"), .text(family + "c"), .text("d")])
    }

    @Test func oversizedGraphemeSplitsAtScalarBoundaries() {
        let family = "👨\u{200D}👩\u{200D}👧"
        #expect(TextInput.pieces(for: family, maxBytes: 10) == [.text("👨\u{200D}"), .text("👩\u{200D}"), .text("👧")])
    }

    @Test func longAccentedAndEmojiTextStaysWithinTheHostLimit() {
        let unit = "héllo wörld 👋🏽 👨‍👩‍👧‍👦 "
        let text = String(repeating: unit, count: 400)
        let pieces = TextInput.pieces(for: text)
        let chunks = pieces.compactMap { piece -> String? in if case .text(let s) = piece { return s } else { return nil } }
        #expect(chunks.count == pieces.count && chunks.count > 1)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.utf8.count <= PortlightProtocol.maxTextInputBytes })
        #expect(chunks.joined() == text)
        #expect(chunks.map(\.count).reduce(0, +) == text.count) // no grapheme was split across chunks
    }

    @Test func theWireByteLimitStillAppliesExactly() {
        let exact = String(repeating: "a", count: 4096)
        #expect(TextInput.pieces(for: exact, maxUTF16Units: .max) == [.text(exact)])
        #expect(TextInput.pieces(for: exact + "b", maxUTF16Units: .max) == [.text(exact), .text("b")])
        let almost = String(repeating: "a", count: 4095)
        #expect(TextInput.pieces(for: almost + "é", maxUTF16Units: .max) == [.text(almost), .text("é")]) // "é" is 2 bytes
        #expect(TextInput.pieces(for: exact + "\r\n" + "z", maxUTF16Units: .max) == [.text(exact), .key(0xff0d), .text("z")])
    }

    @Test func surrogatePairsNeverStraddleTheUnitLimit() {
        let nineteen = String(repeating: "a", count: 19)
        #expect(TextInput.pieces(for: nineteen + "😀" + "b") == [.text(nineteen), .text("😀b")])
        #expect(TextInput.pieces(for: nineteen + "a" + "a") == [.text(nineteen + "a"), .text("a")])
    }

    @Test func chordKeysymsForCommittedCharacters() {
        #expect(TextInput.chordKeysym(for: "c") == 0x63)
        #expect(TextInput.chordKeysym(for: "C") == 0x63)
        #expect(TextInput.chordKeysym(for: "\n") == 0xff0d)
        #expect(TextInput.chordKeysym(for: "\t") == 0xff09)
        #expect(TextInput.chordKeysym(for: "é") == 0xe9)
        #expect(TextInput.chordKeysym(for: "😀") == 0x0101_f600)
        #expect(TextInput.chordKeysym(for: "hi") == nil)
        #expect(TextInput.chordKeysym(for: "e\u{301}") == nil)
        #expect(TextInput.chordKeysym(for: "👨\u{200D}👩\u{200D}👧") == nil)
    }
}
