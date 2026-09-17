import Testing
@testable import PortlightKit

@Suite("Input ledger")
struct InputLedgerTests {
    let m = InputTestMapping()
    let command: UInt32 = 0xffeb
    let shift: UInt32 = 0xffe1
    let control: UInt32 = 0xffe3

    private func run(_ actions: [RemoteAction], _ ledger: InputLedger, _ latches: inout ModifierLatches) -> [OutboundMessage] {
        var out: [OutboundMessage] = []
        for action in actions { out += ledger.apply(action, modifiers: &latches) }
        return out
    }

    private func click(_ t: PointerTarget, _ button: MouseButtons = .left) -> [RemoteAction] {
        [.move(t), .press(button, t), .release(button, t)]
    }

    @Test func latchedCommandWrapsOneTapThenReleases() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        latches.tap(.command, at: 0)
        let interpreter = GestureInterpreter(mode: .direct)
        let effects = drive(interpreter, [.began([tp(1, 200, 300)], 1), .ended([tp(1, 200, 300)], 1.1)], mapping: m)
        let t = m.at(400, 400)
        #expect(wire(effects, ledger: ledger, latches: &latches) ==
                [.inputDown(command), .inputPointer(t, []), .inputPointer(t, .left), .inputPointer(t, []), .inputUp(command)])
        #expect(latches[.command] == .off)
        #expect(ledger.modifiersDown.isEmpty && !ledger.isHoldingInput)
    }

    @Test func lockedShiftStaysDownAcrossClicksAndIsReassertedAfterHostRelease() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        latches.tap(.shift, at: 0)
        latches.tap(.shift, at: 0.2)
        #expect(latches[.shift] == .locked)
        let t = m.at(400, 400)
        let pointerClick: [OutboundMessage] = [.inputPointer(t, []), .inputPointer(t, .left), .inputPointer(t, [])]
        #expect(run(click(t), ledger, &latches) == [.inputDown(shift)] + pointerClick)
        #expect(run(click(t), ledger, &latches) == pointerClick)
        #expect(ledger.modifiersDown == [.shift])
        ledger.hostDidReleaseInput()
        #expect(ledger.modifiersDown.isEmpty)
        #expect(run(click(t), ledger, &latches) == [.inputDown(shift)] + pointerClick)
        #expect(latches[.shift] == .locked)
    }

    @Test func releaseAllOrdersButtonsKeysThenModifiersInReverse() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        latches.tap(.command, at: 0)
        latches.tap(.control, at: 1)
        let t = m.at(2000, 500)
        #expect(ledger.apply(.press(.left, t), modifiers: &latches) == [.inputDown(control), .inputDown(command), .inputPointer(t, .left)])
        _ = ledger.key(keysym: 0x61, down: true, modifiers: &latches)
        _ = ledger.key(keysym: 0x62, down: true, modifiers: &latches)
        #expect(ledger.isHoldingInput)
        #expect(ledger.releaseAll() == [.inputPointer(t, []), .inputUp(0x62), .inputUp(0x61), .inputUp(command), .inputUp(control)])
        #expect(!ledger.isHoldingInput && ledger.buttons.isEmpty && ledger.keysDown.isEmpty && ledger.modifiersDown.isEmpty)
        #expect(ledger.releaseAll().isEmpty)
    }

    @Test func pointerMessagesAlwaysCarryTheFullMask() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        let a = m.at(100, 100), b = m.at(200, 100)
        let out = run([.press(.left, a), .press(.right, a), .move(b), .release(.right, b), .move(a), .release(.left, a)], ledger, &latches)
        #expect(out == [.inputPointer(a, .left), .inputPointer(a, [.left, .right]), .inputPointer(b, [.left, .right]),
                        .inputPointer(b, .left), .inputPointer(a, .left), .inputPointer(a, [])])
    }

    @Test func releasingAButtonThatIsNotHeldSendsNothing() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        #expect(ledger.apply(.release(.left, m.at(10, 10)), modifiers: &latches).isEmpty)
    }

    @Test func hostReleaseIsNeverReplayed() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        let t = m.at(300, 300)
        _ = ledger.apply(.press(.left, t), modifiers: &latches)
        ledger.hostDidReleaseInput()
        #expect(!ledger.isHoldingInput)
        #expect(ledger.apply(.move(t), modifiers: &latches) == [.inputPointer(t, [])])
        #expect(ledger.apply(.release(.left, t), modifiers: &latches).isEmpty)
    }

    @Test func scrollUsesModifiersWithoutConsumingTheLatch() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        latches.tap(.command, at: 0)
        let t = m.at(500, 500)
        #expect(ledger.apply(.scroll(t, dx: 0, dy: 1.5), modifiers: &latches) ==
                [.inputDown(command), .wheel(display: t.display, x: t.x, y: t.y, dx: 0, dy: 1.5)])
        #expect(latches[.command] == .latched)
        #expect(ledger.apply(.scroll(t, dx: 0, dy: 0), modifiers: &latches).isEmpty)
        #expect(run(click(t), ledger, &latches) == [.inputPointer(t, []), .inputPointer(t, .left), .inputPointer(t, []), .inputUp(command)])
        #expect(latches[.command] == .off)
    }

    @Test func textReleasesModifiersFirstAndNeverCarriesThem() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        latches.tap(.shift, at: 0)
        latches.tap(.shift, at: 0.1)
        let t = m.at(400, 400)
        _ = run(click(t), ledger, &latches)
        #expect(ledger.text("hé\nx") == [.inputUp(shift), .text("hé"), .inputDown(0xff0d), .inputUp(0xff0d), .text("x")])
        #expect(ledger.text("").isEmpty)
        #expect(run(click(t), ledger, &latches).first == .inputDown(shift))
    }

    @Test func committedCharacterBecomesAChordOnlyWithModifiers() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        #expect(ledger.typeCommitted("c", modifiers: &latches) == [.text("c")])
        latches.tap(.command, at: 0)
        #expect(ledger.typeCommitted("c", modifiers: &latches) == [.inputDown(command), .inputDown(0x63), .inputUp(0x63), .inputUp(command)])
        #expect(latches[.command] == .off)
        latches.tap(.command, at: 1)
        #expect(ledger.typeCommitted("\n", modifiers: &latches) == [.inputDown(command), .inputDown(0xff0d), .inputUp(0xff0d), .inputUp(command)])
        latches.tap(.command, at: 2)
        #expect(ledger.typeCommitted("hi", modifiers: &latches) == [.text("hi")]) // text never carries modifiers
        #expect(latches[.command] == .latched)
    }

    @Test func softKeyChordCompletesOnKeyUp() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        latches.tap(.control, at: 0)
        #expect(ledger.pressKey(keysym: SoftKey.tab.keysym, modifiers: &latches) ==
                [.inputDown(control), .inputDown(0xff09), .inputUp(0xff09), .inputUp(control)])
        #expect(ledger.pressKey(keysym: SoftKey.escape.keysym, modifiers: &latches) == [.inputDown(0xff1b), .inputUp(0xff1b)])
    }

    @Test func hardwareAndStickyCommandAreOneCommand() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        #expect(ledger.key(keysym: command, down: true, modifiers: &latches) == [.inputDown(command)])
        #expect(ledger.hardwareModifiers == [.command] && ledger.isHoldingInput)
        latches.tap(.command, at: 0)
        let t = m.at(400, 400)
        #expect(run(click(t), ledger, &latches) == [.inputPointer(t, []), .inputPointer(t, .left), .inputPointer(t, [])])
        #expect(latches[.command] == .off)
        #expect(ledger.modifiersDown == [.command]) // still physically held
        #expect(ledger.key(keysym: command, down: false, modifiers: &latches) == [.inputUp(command)])
        #expect(!ledger.isHoldingInput)
    }

    @Test func rightHandHardwareModifierKeepsItsKeysym() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        #expect(ledger.key(keysym: 0xffe2, down: true, modifiers: &latches) == [.inputDown(0xffe2)])
        #expect(ledger.key(keysym: 0x61, down: true, modifiers: &latches) == [.inputDown(0x61)])
        #expect(ledger.key(keysym: 0x61, down: false, modifiers: &latches) == [.inputUp(0x61)])
        #expect(ledger.key(keysym: 0xffe2, down: false, modifiers: &latches) == [.inputUp(0xffe2)])
    }

    @Test func untoggledLatchIsReleasedMidDrag() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        latches.tap(.option, at: 0)
        let t = m.at(400, 400)
        #expect(ledger.apply(.press(.left, t), modifiers: &latches) == [.inputDown(0xffe9), .inputPointer(t, .left)])
        latches.tap(.option, at: 2) // slow second tap: Off
        #expect(ledger.modifiersChanged(latches) == [.inputUp(0xffe9)])
        #expect(ledger.apply(.release(.left, t), modifiers: &latches) == [.inputPointer(t, [])])
    }

    @Test func keyUpForAKeyThatIsNotDownSendsNothing() {
        let ledger = InputLedger()
        var latches = ModifierLatches()
        #expect(ledger.key(keysym: 0x61, down: false, modifiers: &latches).isEmpty)
        #expect(ledger.key(keysym: command, down: false, modifiers: &latches).isEmpty)
    }

    @Test func crossDisplayDragKeepsTheMaskAndSwitchesDisplays() {
        let interpreter = GestureInterpreter(mode: .direct)
        let ledger = InputLedger()
        var latches = ModifierLatches()
        // View (900, 300) is desktop (1800, 400) on L; view 980 and 1000 are on R.
        let effects = drive(interpreter, [
            .began([tp(1, 900, 300)], 0), .tick(0.5),
            .moved([tp(1, 980, 300)], 0.6), .moved([tp(1, 1000, 20)], 0.7), // into the letterbox: clamped, still held
            .ended([tp(1, 1000, 20)], 0.8),
        ], mapping: m)
        let messages = wire(effects, ledger: ledger, latches: &latches)
        let pointers = messages.compactMap { message -> (DisplayID, MouseButtons)? in
            if case .pointer(let display, _, _, let buttons) = message { return (display, buttons) } else { return nil }
        }
        let expectedButtons: [MouseButtons] = [[], .left, .left, .left, []]
        #expect(pointers.map { $0.0 } == ["L", "L", "R", "R", "R"])
        #expect(pointers.map { $0.1 } == expectedButtons)
        #expect(messages.last == .inputPointer(m.at(2000, 0), []))
        #expect(!ledger.isHoldingInput)
    }
}
