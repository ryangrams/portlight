import Testing
@testable import PortlightKit

/// Regressions for defects found in the Input review (2026-09-11). Each test failed on the code before its fix.
@Suite("Input review regressions")
struct InputReviewRegressionTests {
    let m = InputTestMapping()
    typealias P = ViewportEffect.Point

    private func make(_ mode: InputMode) -> GestureInterpreter {
        let interpreter = GestureInterpreter(mode: mode)
        interpreter.setCursor(LogicalPoint(x: 400, y: 400))
        return interpreter
    }

    // MARK: Gestures

    /// EXECUTION-PLAN §2: "once pinch wins, cancel remote scrolling for that gesture." Lifting one finger and
    /// putting another down (a re-grip) continues that gesture, so it stays a local pan/zoom.
    @Test func pinchRegripNeverBecomesARemoteScroll() {
        for mode in [InputMode.trackpad, .direct] {
            let interpreter = make(mode)
            let effects = drive(interpreter, [
                .began([tp(1, 200, 300), tp(2, 260, 300)], 0),
                .moved([tp(1, 180, 300), tp(2, 280, 300)], 0.05), // span 60 → 100: pinch wins
                .ended([tp(2, 280, 300)], 0.10),
                .began([tp(3, 280, 300)], 0.15),                  // re-grip; finger 1 never lifted
                .moved([tp(1, 180, 330), tp(3, 280, 330)], 0.20), // parallel motion: a scroll lock if remote
                .moved([tp(1, 180, 360), tp(3, 280, 360)], 0.25),
                .ended([tp(1, 180, 360), tp(3, 280, 360)], 0.30),
            ], mapping: m)
            #expect(effects == [
                .viewport(.gesture(from: P(x: 230, y: 300), to: P(x: 230, y: 300), factor: 100.0 / 60.0)),
                .viewport(.gesture(from: P(x: 230, y: 300), to: P(x: 230, y: 330), factor: 1)),
                .viewport(.gesture(from: P(x: 230, y: 330), to: P(x: 230, y: 360), factor: 1)),
            ], "\(mode)")
            #expect(!interpreter.isInertiaActive && !interpreter.hasActiveTouches)
        }
    }

    /// A tap needs every finger to stay within the slop, including the one still down after the other lifted.
    @Test func twoFingerTapFailsWhenTheRemainingFingerSlides() {
        for mode in [InputMode.trackpad, .direct] {
            let effects = drive(make(mode), [
                .began([tp(1, 200, 300), tp(2, 260, 300)], 0),
                .ended([tp(1, 200, 300)], 0.05),
                .moved([tp(2, 320, 300)], 0.10), // 60 pt: far beyond the tap slop
                .ended([tp(2, 320, 300)], 0.15),
            ], mapping: m)
            #expect(effects.isEmpty, "\(mode)")
        }
        let still = drive(make(.direct), [
            .began([tp(1, 200, 300), tp(2, 260, 300)], 0),
            .ended([tp(1, 200, 300)], 0.05),
            .moved([tp(2, 265, 300)], 0.10), // within the slop: still a tap
            .ended([tp(2, 265, 300)], 0.15),
        ], mapping: m)
        #expect(still.inputPresses == [.press(.right, m.at(460, 400))])
    }

    /// EXECUTION-PLAN §2 and UI-SPEC §5: while controls are hidden a canvas tap only reveals them. An armed
    /// Direct latch pressed at touch-down, so the reveal tap clicked the Mac.
    @Test func hiddenControlsRevealWithoutFiringAnArmedDirectLatch() {
        let interpreter = make(.direct)
        _ = interpreter.pressLatched(.right, mapping: m)
        interpreter.controlsHidden = true
        #expect(drive(interpreter, [.began([tp(1, 200, 300)], 0), .ended([tp(1, 200, 300)], 0.1)], mapping: m) == [.revealControls])
        #expect(interpreter.armedButton == .right) // still waiting for the next deliberate touch
        let t = m.at(600, 400)
        #expect(drive(interpreter, [.began([tp(2, 300, 300)], 1)], mapping: m) ==
                [.cursorMoved(t.desktop), .remote(.move(t)), .remote(.press(.right, t)), .feedback(.dragBegan)])
        #expect(drive(interpreter, [.ended([tp(2, 300, 300)], 1.1)], mapping: m) == [.remote(.release(.right, t))])
    }

    /// With controls hidden an armed latch waits for the long press (a deliberate drag), then presses its button.
    @Test func hiddenControlsLongPressUsesTheArmedButton() {
        let interpreter = make(.direct)
        _ = interpreter.pressLatched(.right, mapping: m)
        interpreter.controlsHidden = true
        let t = m.at(400, 400)
        #expect(!drive(interpreter, [.began([tp(1, 200, 300)], 0), .tick(0.3)], mapping: m).reachesRemote)
        #expect(drive(interpreter, [.tick(0.5)], mapping: m) ==
                [.cursorMoved(t.desktop), .remote(.move(t)), .remote(.press(.right, t)), .feedback(.dragBegan)])
        #expect(interpreter.armedButton == nil)
        #expect(drive(interpreter, [.ended([tp(1, 200, 300)], 0.6)], mapping: m) == [.remote(.release(.right, t))])
        #expect(interpreter.controlsHidden) // a long press is not the reveal tap
    }

    /// Non-finite locations are ignored at the entry, so they can't poison the predicted cursor (the viewport
    /// maps a non-finite point to a display centre) or the slop/speed math.
    @Test func nonFiniteTouchLocationsAreIgnored() {
        let interpreter = make(.trackpad)
        let t = m.at(400, 400)
        let effects = drive(interpreter, [
            .began([tp(1, 200, 300)], 0), .moved([tp(1, .nan, 300)], 0.1), .moved([tp(1, 206, .infinity)], 0.15),
            .began([tp(2, .nan, .nan)], 0.16), .ended([tp(1, 200, 300)], 0.2),
        ], mapping: m)
        #expect(interpreter.cursor == LogicalPoint(x: 400, y: 400))
        #expect(effects.inputRemote == [.move(t), .press(.left, t), .release(.left, t)])
        #expect(!interpreter.hasActiveTouches)
    }

    // MARK: Ledger

    /// PROTOCOL-IMPLEMENTATION-NOTES §6 and Server.swift:445: the host (and the encoder) clamp every wheel
    /// message to ±100 lines, so a larger step lost its remainder and the content stopped following the fingers.
    @Test func scrollStepsBeyondTheWireLimitAreSplitExactly() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        let t = m.at(400, 400)
        let out = ledger.apply(.scroll(t, dx: 50, dy: -250), modifiers: &latches)
        #expect(out.count == 3)
        var sumX = 0.0, sumY = 0.0
        for message in out {
            guard case .wheel(let display, let x, let y, let dx, let dy) = message else { Issue.record("not a wheel: \(message)"); continue }
            #expect(display == t.display && x == t.x && y == t.y)
            #expect(abs(dx) <= 100 && abs(dy) <= 100)
            sumX += dx
            sumY += dy
        }
        #expect(sumX == 50 && sumY == -250)
        #expect(ledger.apply(.scroll(t, dx: 0, dy: 100), modifiers: &latches) == [.wheel(display: t.display, x: t.x, y: t.y, dx: 0, dy: 100)])
        #expect(ledger.apply(.scroll(t, dx: 0, dy: 1e12), modifiers: &latches).count <= 16) // bounded, never a runaway burst
    }

    /// EXECUTION-PLAN §2: a Latched modifier is released after the next complete click/drag. One latched while a
    /// drag was held (and the finger didn't move again) was consumed without ever reaching the host.
    @Test func aModifierLatchedMidDragAppliesToTheDrop() {
        let interpreter = make(.direct)
        let ledger = InputLedger()
        var latches = ModifierLatches()
        let t = m.at(400, 400)
        let pressed = wire(drive(interpreter, [.began([tp(1, 200, 300)], 0), .tick(0.5)], mapping: m), ledger: ledger, latches: &latches)
        #expect(pressed == [.inputPointer(t, []), .inputPointer(t, .left)])
        latches.tap(.option, at: 1)
        #expect(ledger.modifiersChanged(latches).isEmpty) // latching sends nothing yet
        let drop = wire(drive(interpreter, [.ended([tp(1, 200, 300)], 1.1)], mapping: m), ledger: ledger, latches: &latches)
        #expect(drop == [.inputDown(0xffe9), .inputPointer(t, []), .inputUp(0xffe9)])
        #expect(latches[.option] == .off && ledger.modifiersDown.isEmpty)
    }

    // MARK: Keys and text

    /// Only a single-scalar character has one keysym. The first scalar of "e\u{301}", "❤️" or a flag is a
    /// different character, so the key is dropped rather than mistyped.
    @Test func multiScalarCharactersAreDroppedNotTruncated() {
        #expect(KeyMapping.keysym(forCharacter: "e\u{301}") == nil)
        #expect(KeyMapping.keysym(forCharacter: "🇺🇸") == nil)
        #expect(KeyMapping.keysym(forCharacter: "❤️") == nil)
        #expect(KeyMapping.keysym(forHIDUsage: 0x08, charactersIgnoringModifiers: "e\u{301}") == nil)
        #expect(KeyMapping.keysym(forCharacter: "é") == 0xe9)
        #expect(KeyMapping.keysym(forCharacter: "❤") == 0x0100_2764)
    }

    /// Display.swift:108-115 posts each `text` message as one CGEvent, and CGEventKeyboardSetUnicodeString keeps
    /// only 20 UTF-16 units per event (host-input.md #2), so longer chunks lost their tail on the current host.
    @Test func textChunksFitTheHostPerEventUnicodeLimit() {
        let text = String(repeating: "héllo wörld 👋🏽 👨‍👩‍👧‍👦 ", count: 50)
        let pieces = TextInput.pieces(for: text)
        let chunks = pieces.compactMap { piece -> String? in if case .text(let s) = piece { return s } else { return nil } }
        #expect(chunks.count == pieces.count && chunks.count > 50)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.utf16.count <= 20 && $0.utf8.count <= PortlightProtocol.maxTextInputBytes })
        #expect(chunks.joined() == text)
        #expect(chunks.map(\.count).reduce(0, +) == text.count) // no grapheme was split
        let family = "👨🏽‍👩🏽‍👧🏽‍👦🏽" // one grapheme, 19 UTF-16 units: stays whole, and "a" fills the chunk to 20
        #expect(TextInput.pieces(for: family + "ab") == [.text(family + "a"), .text("b")])
        let zalgo = "a" + String(repeating: "\u{301}", count: 30) // one grapheme, 31 units: split at scalars
        #expect(TextInput.pieces(for: zalgo) == [.text("a" + String(repeating: "\u{301}", count: 19)),
                                                 .text(String(repeating: "\u{301}", count: 11))])
    }

    // MARK: Host contract (coverage)

    /// Every non-printing keysym the viewer can emit is one Server.swift `inputKeysym` maps (its `special` table
    /// or F1–F20), and every special key the host maps is reachable from a hardware key. Keypad keys send ASCII.
    @Test func keysymsStayWithinTheHostTable() {
        let hostSpecial: Set<UInt32> = [0xff0d, 0xff1b, 0xff08, 0xff09, 0xff51, 0xff52, 0xff53, 0xff54, 0xffff, 0xff50, 0xff57, 0xff55,
                                        0xff56, 0xff63, 0xffe1, 0xffe2, 0xffe3, 0xffe4, 0xffe9, 0xffea, 0xffeb, 0xffec, 0xffe5]
        let hostFunction: ClosedRange<UInt32> = 0xffbe...0xffd1
        var reachable: Set<UInt32> = []
        for usage in 0..<0x100 {
            guard let keysym = KeyMapping.keysym(forHIDUsage: usage) else { continue }
            reachable.insert(keysym)
            if keysym >= 0xff00 {
                #expect(hostSpecial.contains(keysym) || hostFunction.contains(keysym), "HID \(usage)")
            } else {
                #expect((0x20..<0x7f).contains(keysym), "HID \(usage)")
            }
        }
        #expect(hostSpecial.isSubset(of: reachable))
        #expect(hostFunction.allSatisfy { reachable.contains($0) })
        for key in SoftKey.allCases { #expect(hostSpecial.contains(key.keysym) || hostFunction.contains(key.keysym), "\(key)") }
        for key in ModifierKey.allCases { #expect(hostSpecial.contains(key.keysym)) }
    }
}
