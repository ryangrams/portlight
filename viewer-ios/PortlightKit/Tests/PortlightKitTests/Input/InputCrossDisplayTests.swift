import Testing
@testable import PortlightKit

@Suite("Input across displays")
struct InputCrossDisplayTests {
    let m = InputTestMapping()

    private func pointerTrace(_ effects: [InputEffect], _ ledger: InputLedger) -> [String] {
        var latches = ModifierLatches()
        return wire(effects, ledger: ledger, latches: &latches).compactMap { message -> String? in
            if case .pointer(let display, _, _, let buttons) = message { return "\(display)\(buttons.rawValue)" } else { return nil }
        }
    }

    @Test func trackpadTapDragCrossesTheCompactedBoundaryWithTheMaskHeld() {
        let interpreter = GestureInterpreter(mode: .trackpad)
        interpreter.setCursor(LogicalPoint(x: 1900, y: 400)) // 20 points left of the L|R boundary
        let ledger = InputLedger()
        let effects = drive(interpreter, [
            .began([tp(1, 200, 300)], 0), .ended([tp(1, 200, 300)], 0.1),
            .began([tp(2, 200, 300)], 0.2), .moved([tp(2, 212, 300)], 0.3), .moved([tp(2, 218, 300)], 0.4),
            .ended([tp(2, 218, 300)], 0.5),
        ], mapping: m)
        // click on L; then press on L, cross to R with the left button held, release on R.
        #expect(pointerTrace(effects, ledger) == ["L0", "L1", "L0", "L0", "L1", "R1", "R1", "R0"])
        #expect(interpreter.cursor == LogicalPoint(x: 1936, y: 400))
        #expect(!ledger.isHoldingInput)
    }

    @Test func directTouchesInAGapBetweenDisplaysSendNothing() {
        var gapped = m
        gapped.frames = [("L", LogicalRect(x: 0, y: 0, width: 1920, height: 1080)),
                         ("R", LogicalRect(x: 1920, y: 540, width: 1920, height: 1080))]
        let interpreter = GestureInterpreter(mode: .direct)
        // View (1000, 150) is desktop (2000, 100): right of L and above R.
        #expect(drive(interpreter, [.began([tp(1, 1000, 150)], 0), .ended([tp(1, 1000, 150)], 0.1)], mapping: gapped).isEmpty)
        #expect(drive(interpreter, [.began([tp(2, 1000, 150)], 1), .tick(1.6), .ended([tp(2, 1000, 150)], 1.7)], mapping: gapped).isEmpty)
        #expect(drive(interpreter, [.began([tp(3, 1000, 150), tp(4, 1010, 150)], 2), .ended([tp(3, 1000, 150), tp(4, 1010, 150)], 2.1)],
                      mapping: gapped).isEmpty)
    }
}
