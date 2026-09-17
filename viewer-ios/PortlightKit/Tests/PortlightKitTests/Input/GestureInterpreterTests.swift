import Testing
@testable import PortlightKit

@Suite("Gesture interpreter")
struct GestureInterpreterTests {
    let m = InputTestMapping()

    private func make(_ mode: InputMode) -> GestureInterpreter {
        let interpreter = GestureInterpreter(mode: mode)
        interpreter.setCursor(LogicalPoint(x: 400, y: 400))
        return interpreter
    }

    /// Two fingers moving down 10 pt every 10 ms (1000 pt/s), lifting 5 ms after the last move.
    private var fling: [InputStep] {
        var steps: [InputStep] = [.began([tp(1, 200, 300), tp(2, 260, 300)], 0)]
        for k in 1...8 {
            let y = 300 + 10 * Double(k)
            steps.append(.moved([tp(1, 200, y), tp(2, 260, y)], 0.01 * Double(k)))
        }
        steps.append(.ended([tp(1, 200, 380), tp(2, 260, 380)], 0.085))
        return steps
    }

    // MARK: Hidden controls

    @Test func hiddenControlsTapOnlyRevealsThenTapsClickAgain() {
        for mode in [InputMode.trackpad, .direct] {
            let interpreter = make(mode)
            interpreter.controlsHidden = true
            let first = drive(interpreter, [.began([tp(1, 200, 300)], 0), .ended([tp(1, 200, 300)], 0.1)], mapping: m)
            #expect(first == [.revealControls], "\(mode)")
            #expect(!interpreter.controlsHidden)
            let second = drive(interpreter, [.began([tp(2, 200, 300)], 1), .ended([tp(2, 200, 300)], 1.1)], mapping: m)
            #expect(second.inputPresses.count == 1, "\(mode)")
        }
    }

    @Test func hiddenControlsTwoFingerTapOnlyReveals() {
        let interpreter = make(.trackpad)
        interpreter.controlsHidden = true
        #expect(drive(interpreter, InputConformance.script(.twoFingerTap, mode: .trackpad), mapping: m) == [.revealControls])
    }

    // MARK: No speculative presses

    @Test func directLongPressNeverPressesEarly() {
        let interpreter = make(.direct)
        let waiting = drive(interpreter, [.began([tp(1, 200, 300)], 0), .tick(0.1), .tick(0.3), .tick(0.49),
                                          .moved([tp(1, 204, 303)], 0.495)], mapping: m)
        #expect(!waiting.reachesRemote)
        let held = drive(interpreter, [.tick(0.5)], mapping: m)
        #expect(held.inputPresses == [.press(.left, m.at(408, 406))])
        #expect(held.last == .feedback(.dragBegan))
        #expect(drive(interpreter, [.ended([tp(1, 204, 303)], 0.6)], mapping: m) == [.remote(.release(.left, m.at(408, 406)))])
    }

    @Test func directSlowTapNeitherClicksNorPresses() {
        #expect(drive(make(.direct), [.began([tp(1, 200, 300)], 0), .tick(0.3), .ended([tp(1, 200, 300)], 0.4)], mapping: m).isEmpty)
    }

    @Test func trackpadTapAndHoldPressesOnlyAtTheHoldDeadline() {
        let interpreter = make(.trackpad)
        let t = m.at(400, 400)
        #expect(drive(interpreter, [.began([tp(1, 200, 300)], 0), .ended([tp(1, 200, 300)], 0.1)], mapping: m).inputPresses.count == 1)
        let waiting = drive(interpreter, [.began([tp(2, 200, 300)], 0.2), .tick(0.3), .tick(0.44)], mapping: m)
        #expect(waiting.inputPresses.isEmpty)
        #expect(drive(interpreter, [.tick(0.45)], mapping: m) == [.remote(.move(t)), .remote(.press(.left, t)), .feedback(.dragBegan)])
        #expect(drive(interpreter, [.ended([tp(2, 200, 300)], 0.6)], mapping: m) == [.remote(.release(.left, t))])
    }

    @Test func twoFingersNeverPressBeforeLifting() {
        #expect(drive(make(.direct), [.began([tp(1, 200, 300), tp(2, 260, 300)], 0), .tick(0.05), .tick(0.2), .tick(0.6)], mapping: m).isEmpty)
    }

    @Test func lateSecondFingerIsNotATwoFingerTap() {
        let late = drive(make(.direct), [.began([tp(1, 200, 300)], 0), .began([tp(2, 260, 300)], 0.1),
                                         .ended([tp(1, 200, 300), tp(2, 260, 300)], 0.2)], mapping: m)
        #expect(late.isEmpty)
    }

    @Test func sequentialThreeFingerTouchIsIgnored() {
        let effects = drive(make(.trackpad), [.began([tp(1, 200, 300)], 0), .began([tp(2, 260, 300)], 0.02), .began([tp(3, 320, 300)], 0.04),
                                              .moved([tp(1, 200, 340), tp(2, 260, 340), tp(3, 320, 340)], 0.1),
                                              .ended([tp(1, 200, 340), tp(2, 260, 340), tp(3, 320, 340)], 0.15)], mapping: m)
        #expect(effects.isEmpty)
    }

    // MARK: Pinch versus scroll

    @Test func pinchLockPreventsScrollingForTheRestOfTheGesture() {
        let interpreter = make(.trackpad)
        let effects = drive(interpreter, [
            .began([tp(1, 200, 300), tp(2, 260, 300)], 0),
            .moved([tp(1, 192, 300), tp(2, 268, 300)], 0.05), // span 60 → 76: pinch wins
            .moved([tp(1, 192, 340), tp(2, 268, 340)], 0.10), // then a large two-finger translation
            .moved([tp(1, 192, 400), tp(2, 268, 400)], 0.15),
            .ended([tp(1, 192, 400), tp(2, 268, 400)], 0.2),
        ], mapping: m)
        #expect(!effects.reachesRemote)
        #expect(effects.count == 3)
        #expect(effects.allSatisfy { if case .viewport(.gesture) = $0 { return true } else { return false } })
        #expect(!interpreter.isInertiaActive)
    }

    @Test func scrollLockIgnoresLaterSpreading() {
        let effects = drive(make(.direct), [
            .began([tp(1, 200, 300), tp(2, 260, 300)], 0),
            .moved([tp(1, 200, 315), tp(2, 260, 315)], 0.1), // scroll wins
            .moved([tp(1, 150, 330), tp(2, 310, 330)], 0.2), // spreading afterwards never zooms
            .ended([tp(1, 150, 330), tp(2, 310, 330)], 0.3),
        ], mapping: m)
        #expect(effects.count == 2)
        #expect(effects.allSatisfy { if case .remote(.scroll) = $0 { return true } else { return false } })
    }

    @Test func pinchRemainderPansLocally() {
        let effects = drive(make(.direct), [
            .began([tp(1, 200, 300), tp(2, 260, 300)], 0), .moved([tp(1, 180, 300), tp(2, 280, 300)], 0.1),
            .ended([tp(2, 280, 300)], 0.2), .moved([tp(1, 200, 320)], 0.3), .ended([tp(1, 200, 320)], 0.4),
        ], mapping: m)
        #expect(!effects.reachesRemote)
        #expect(effects.last == .viewport(.pan(dx: 20, dy: 20)))
    }

    @Test func scrollFollowsTheFingersAtTheCurrentZoom() {
        let script: [InputStep] = [.began([tp(1, 200, 300), tp(2, 260, 300)], 0),
                                   .moved([tp(1, 212, 318), tp(2, 272, 318)], 0.1), .ended([tp(1, 212, 318), tp(2, 272, 318)], 0.15)]
        let half = drive(make(.trackpad), script, mapping: m).inputScrolls // 6 view points per line
        #expect(half.count == 1 && half[0].dx == 2 && half[0].dy == 3) // fingers down/right: positive
        var zoomed = m
        zoomed.zoom = 1
        let full = drive(make(.trackpad), script, mapping: zoomed).inputScrolls // 12 view points per line
        #expect(full.count == 1 && full[0].dx == 1 && full[0].dy == 1.5)
    }

    // MARK: Drags, cancellation, latches

    @Test func cancelMidDragReleasesTheButton() {
        let interpreter = make(.direct)
        let ledger = InputLedger()
        var latches = ModifierLatches()
        let pressed = drive(interpreter, [.began([tp(1, 200, 300)], 0), .tick(0.5), .moved([tp(1, 220, 300)], 0.6)], mapping: m)
        _ = wire(pressed, ledger: ledger, latches: &latches)
        #expect(ledger.buttons == .left)
        let cancelled = drive(interpreter, [.cancelled(0.7)], mapping: m)
        #expect(cancelled == [.remote(.release(.left, m.at(440, 400)))])
        #expect(wire(cancelled, ledger: ledger, latches: &latches) == [.inputPointer(m.at(440, 400), [])])
        #expect(!interpreter.hasActiveTouches && !interpreter.isDragging && !ledger.isHoldingInput)
        #expect(drive(interpreter, [.moved([tp(1, 240, 300)], 0.8), .ended([tp(1, 240, 300)], 0.9)], mapping: m).isEmpty)
    }

    @Test func trackpadButtonLatchDragsAcrossStrokesAndIgnoresTaps() {
        let interpreter = make(.trackpad)
        let ledger = InputLedger()
        var latches = ModifierLatches()
        let start = m.at(400, 400)
        var effects = interpreter.pressLatched(.left, mapping: m)
        #expect(effects == [.remote(.move(start)), .remote(.press(.left, start)), .feedback(.dragBegan)])
        effects += drive(interpreter, [.began([tp(1, 200, 300)], 0), .moved([tp(1, 210, 300)], 0.1), .moved([tp(1, 220, 300)], 0.2),
                                       .ended([tp(1, 220, 300)], 0.3), .began([tp(2, 200, 300)], 1), .ended([tp(2, 200, 300)], 1.05)], mapping: m)
        #expect(effects.inputPresses.count == 1)
        #expect(interpreter.isDragging)
        effects += interpreter.releaseLatched(mapping: m)
        #expect(effects.last == .remote(.release(.left, m.at(440, 400))))
        let messages = wire(effects, ledger: ledger, latches: &latches)
        #expect(messages.dropFirst().dropLast().allSatisfy { if case .pointer(_, _, _, let buttons) = $0 { return buttons == .left } else { return false } })
        #expect(messages.last == .inputPointer(m.at(440, 400), []))
        #expect(!ledger.isHoldingInput && interpreter.latchedButtons.isEmpty)
    }

    @Test func directButtonLatchArmsTheNextTouch() {
        let interpreter = make(.direct)
        #expect(interpreter.pressLatched(.right, mapping: m).isEmpty)
        #expect(interpreter.armedButton == .right)
        let effects = drive(interpreter, [.began([tp(1, 300, 300)], 0), .moved([tp(1, 310, 300)], 0.05), .ended([tp(1, 310, 300)], 0.1)], mapping: m)
        #expect(effects == [.cursorMoved(LogicalPoint(x: 600, y: 400)), .remote(.move(m.at(600, 400))), .remote(.press(.right, m.at(600, 400))),
                            .feedback(.dragBegan), .cursorMoved(LogicalPoint(x: 620, y: 400)), .remote(.move(m.at(620, 400))),
                            .remote(.release(.right, m.at(620, 400)))])
        #expect(interpreter.armedButton == nil)
    }

    @Test func explicitClicksRespectModeAndControl() {
        let interpreter = make(.trackpad)
        let t = m.at(400, 400)
        #expect(interpreter.click(.middle, mapping: m) == [.remote(.move(t)), .remote(.press(.middle, t)), .remote(.release(.middle, t))])
        interpreter.mode = .pan
        #expect(interpreter.click(.middle, mapping: m).isEmpty)
        interpreter.mode = .direct
        interpreter.remoteEnabled = false
        #expect(interpreter.click(.right, mapping: m).isEmpty)
    }

    @Test func directExplicitClickUsesTheLastTouchedLocation() {
        let interpreter = GestureInterpreter(mode: .direct)
        _ = drive(interpreter, [.began([tp(1, 300, 300)], 0), .ended([tp(1, 300, 300)], 0.1)], mapping: m)
        let t = m.at(600, 400)
        #expect(interpreter.click(.middle, mapping: m).inputRemote == [.move(t), .press(.middle, t), .release(.middle, t)])
    }

    @Test func modeChangeAbandonsARemoteGestureSilently() {
        let interpreter = make(.direct)
        _ = drive(interpreter, [.began([tp(1, 200, 300)], 0), .tick(0.5)], mapping: m)
        #expect(interpreter.isDragging)
        interpreter.mode = .trackpad // the session sends InputLedger.releaseAll() for the host
        #expect(!interpreter.isDragging)
        #expect(drive(interpreter, [.moved([tp(1, 260, 300)], 0.6), .ended([tp(1, 260, 300)], 0.7)], mapping: m).isEmpty)
    }

    @Test func turningRemoteOffKeepsALocalPinchGoing() {
        let interpreter = make(.trackpad)
        _ = drive(interpreter, [.began([tp(1, 200, 300), tp(2, 260, 300)], 0), .moved([tp(1, 190, 300), tp(2, 270, 300)], 0.1)], mapping: m)
        interpreter.remoteEnabled = false
        let effects = drive(interpreter, [.moved([tp(1, 180, 300), tp(2, 280, 300)], 0.2)], mapping: m)
        #expect(effects.count == 1 && !effects.reachesRemote)
    }

    // MARK: Cursor

    @Test func trackpadGainCurve() {
        let configuration = GestureConfiguration.standard
        #expect(configuration.trackpadGain(speed: 0) == 1)
        #expect(configuration.trackpadGain(speed: 150) == 1)
        #expect(configuration.trackpadGain(speed: 675) == 1.75)
        #expect(configuration.trackpadGain(speed: 1200) == 2.5)
        #expect(configuration.trackpadGain(speed: 5000) == 2.5)
        #expect(configuration.trackpadGain(speed: .nan) == 1)
    }

    @Test func fastTrackpadMotionIsAccelerated() {
        let interpreter = make(.trackpad)
        _ = drive(interpreter, [.began([tp(1, 200, 300)], 0), .moved([tp(1, 206, 300)], 0.09)], mapping: m)
        #expect(interpreter.cursor == LogicalPoint(x: 412, y: 400)) // slow: gain 1, 6 pt ÷ zoom 0.5
        _ = drive(interpreter, [.moved([tp(1, 218, 300)], 0.1)], mapping: m) // 12 pt in 10 ms ≈ 1200 pt/s: gain ≈ 2.5
        #expect(abs(interpreter.cursor!.x - 472) < 1e-6)
    }

    @Test func trackpadCursorStaysOnTheDisplays() {
        let interpreter = GestureInterpreter(mode: .trackpad)
        interpreter.setCursor(LogicalPoint(x: 3800, y: 1000))
        _ = drive(interpreter, [.began([tp(1, 200, 300)], 0), .moved([tp(1, 300, 400)], 0.5), .moved([tp(1, 400, 500)], 1.0)], mapping: m)
        #expect(interpreter.cursor == LogicalPoint(x: 3839.5, y: 1079.5))
    }

    @Test func trackpadSeedsTheCursorFromTheFirstTouch() {
        let effects = drive(GestureInterpreter(mode: .trackpad), [.began([tp(1, 200, 300)], 0)], mapping: m)
        #expect(effects == [.cursorMoved(LogicalPoint(x: 400, y: 400))])
    }

    @Test func hostCursorReportsWaitForTheLocalPrediction() {
        let interpreter = make(.trackpad)
        _ = drive(interpreter, [.began([tp(1, 200, 300)], 0), .moved([tp(1, 220, 300)], 0.1), .ended([tp(1, 220, 300)], 0.2)], mapping: m)
        let host = LogicalPoint(x: 10, y: 10)
        #expect(interpreter.reconcileCursor(hostPoint: host, at: 0.3).isEmpty)
        #expect(interpreter.reconcileCursor(hostPoint: host, at: 0.7) == [.cursorMoved(host)])
        #expect(interpreter.cursor == host)
    }

    // MARK: Inertia

    @Test func inertiaDecaysAndStops() {
        let interpreter = make(.direct)
        let lifted = drive(interpreter, fling, mapping: m)
        #expect(lifted.inputScrolls.count == 8)
        #expect(interpreter.isInertiaActive)
        var dys: [Double] = []
        var t = 0.085
        while interpreter.isInertiaActive && t < 5 {
            t += 1.0 / 60
            dys += drive(interpreter, [.tick(t)], mapping: m).inputScrolls.map { $0.dy }
        }
        #expect(!interpreter.isInertiaActive)
        #expect(t < 3)
        #expect(dys.count > 10)
        #expect(zip(dys, dys.dropFirst()).allSatisfy { $0 > $1 && $1 > 0 })
        let travelled = dys.reduce(0, +) * 6 // lines × view points per line at zoom 0.5
        #expect(travelled > (1000 - 15) / 2.002 - 1 && travelled < 1000 / 2.002)
        #expect(drive(interpreter, [.tick(t + 1)], mapping: m).isEmpty)
    }

    @Test func inertiaStopsOnTouchDown() {
        let interpreter = make(.trackpad)
        _ = drive(interpreter, fling, mapping: m)
        #expect(interpreter.isInertiaActive)
        #expect(!drive(interpreter, [.tick(0.1)], mapping: m).inputScrolls.isEmpty)
        let touch = drive(interpreter, [.began([tp(9, 500, 500)], 0.11)], mapping: m)
        #expect(touch.inputScrolls.isEmpty && !interpreter.isInertiaActive)
        #expect(drive(interpreter, [.tick(0.2)], mapping: m).inputScrolls.isEmpty)
    }
}
