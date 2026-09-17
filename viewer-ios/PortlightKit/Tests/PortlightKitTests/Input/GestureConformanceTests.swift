import Testing
@testable import PortlightKit

// One row per gesture × mode with the exact effect sequence (URC's GestureConformance design). The
// completeness test fails when a gesture or mode has no row.

enum InputConformanceGesture: String, CaseIterable, Sendable {
    case oneFingerMove, singleTap, doubleTap, twoFingerTap, twoFingerPan, pinch, drag, threeFingerTouch, tapInLetterbox
    /// The plan's explicit mouse-control rows: left-button latch drag, right-button latch drag, middle click.
    case latchDrag, rightDrag, middleClick
}

struct InputConformanceRow: Sendable {
    let gesture: InputConformanceGesture
    let mode: InputMode
    let expected: [InputEffect]
}

enum InputConformance {
    /// zoom 0.5, letterbox above view y 100: view (200, 300) is desktop (400, 400) on display L.
    static let mapping = InputTestMapping()
    static let startCursor = LogicalPoint(x: 400, y: 400)

    static func script(_ gesture: InputConformanceGesture, mode: InputMode) -> [InputStep] {
        switch gesture {
        case .oneFingerMove:
            return [.began([tp(1, 200, 300)], 0), .moved([tp(1, 206, 300)], 0.1), .moved([tp(1, 212, 300)], 0.2),
                    .moved([tp(1, 218, 300)], 0.3), .ended([tp(1, 218, 300)], 0.4)]
        case .singleTap:
            return [.began([tp(1, 200, 300)], 0), .ended([tp(1, 200, 300)], 0.1)]
        case .doubleTap:
            return [.began([tp(1, 200, 300)], 0), .ended([tp(1, 200, 300)], 0.1),
                    .began([tp(2, 202, 301)], 0.2), .ended([tp(2, 202, 301)], 0.3)]
        case .twoFingerTap:
            return [.began([tp(1, 200, 300), tp(2, 260, 300)], 0), .ended([tp(1, 200, 300), tp(2, 260, 300)], 0.1)]
        case .twoFingerPan:
            return [.began([tp(1, 200, 300), tp(2, 260, 300)], 0), .moved([tp(1, 200, 312), tp(2, 260, 312)], 0.1),
                    .moved([tp(1, 200, 318), tp(2, 260, 318)], 0.2), .ended([tp(1, 200, 318), tp(2, 260, 318)], 0.3)]
        case .pinch:
            return [.began([tp(1, 200, 300), tp(2, 260, 300)], 0), .moved([tp(1, 190, 300), tp(2, 270, 300)], 0.1),
                    .moved([tp(1, 180, 306), tp(2, 280, 306)], 0.2), .ended([tp(1, 180, 306), tp(2, 280, 306)], 0.3)]
        case .drag:
            if mode == .trackpad { // tap, then touch again and move
                return [.began([tp(1, 200, 300)], 0), .ended([tp(1, 200, 300)], 0.1), .began([tp(2, 200, 300)], 0.2),
                        .moved([tp(2, 212, 300)], 0.3), .moved([tp(2, 218, 300)], 0.4), .ended([tp(2, 218, 300)], 0.5)]
            }
            return [.began([tp(1, 200, 300)], 0), .tick(0.3), .tick(0.5), .moved([tp(1, 212, 300)], 0.6), .ended([tp(1, 212, 300)], 0.7)]
        case .threeFingerTouch:
            return [.began([tp(1, 200, 300), tp(2, 260, 300), tp(3, 320, 300)], 0),
                    .moved([tp(1, 200, 330), tp(2, 260, 330), tp(3, 320, 330)], 0.1),
                    .ended([tp(1, 200, 330), tp(2, 260, 330), tp(3, 320, 330)], 0.2)]
        case .tapInLetterbox:
            return [.began([tp(1, 200, 50)], 0), .ended([tp(1, 200, 50)], 0.1)]
        case .latchDrag, .rightDrag: // the explicit button latch, one stroke, then the latch control again
            let button: MouseButtons = gesture == .latchDrag ? .left : .right
            return [.pressLatched(button), .began([tp(1, 200, 300)], 0), .moved([tp(1, 212, 300)], 0.1), .moved([tp(1, 218, 300)], 0.2),
                    .ended([tp(1, 218, 300)], 0.3), .releaseLatched]
        case .middleClick:
            return [.click(.middle)]
        }
    }

    static func rows() -> [InputConformanceRow] {
        let m = mapping
        let cursor = m.at(400, 400)
        let centroid = m.at(460, 400) // view (230, 300)
        func click(_ button: MouseButtons, _ t: PointerTarget) -> [InputEffect] {
            [.remote(.move(t)), .remote(.press(button, t)), .remote(.release(button, t))]
        }
        func direct(_ button: MouseButtons, _ t: PointerTarget) -> [InputEffect] { [.cursorMoved(t.desktop)] + click(button, t) }
        func cursorStep(_ x: Double) -> [InputEffect] { [.cursorMoved(LogicalPoint(x: x, y: 400)), .remote(.move(m.at(x, 400)))] }
        func seq(_ parts: [InputEffect]...) -> [InputEffect] { parts.flatMap { $0 } }
        typealias P = ViewportEffect.Point
        let pinch: [InputEffect] = [
            .viewport(.gesture(from: P(x: 230, y: 300), to: P(x: 230, y: 300), factor: 80.0 / 60.0)),
            .viewport(.gesture(from: P(x: 230, y: 300), to: P(x: 230, y: 306), factor: 100.0 / 80.0)),
        ]
        let localPan: [InputEffect] = [.viewport(.pan(dx: 12, dy: 0)), .viewport(.pan(dx: 6, dy: 0))]
        var rows: [InputConformanceRow] = [
            .init(gesture: .oneFingerMove, mode: .trackpad, expected: cursorStep(412) + cursorStep(424) + cursorStep(436)),
            .init(gesture: .oneFingerMove, mode: .direct, expected: localPan),
            .init(gesture: .oneFingerMove, mode: .pan, expected: localPan),

            .init(gesture: .singleTap, mode: .trackpad, expected: click(.left, cursor)),
            .init(gesture: .singleTap, mode: .direct, expected: direct(.left, cursor)),
            .init(gesture: .singleTap, mode: .pan, expected: []),

            .init(gesture: .doubleTap, mode: .trackpad, expected: click(.left, cursor) + click(.left, cursor)),
            .init(gesture: .doubleTap, mode: .direct, expected: direct(.left, cursor) + direct(.left, m.at(404, 402))),
            .init(gesture: .doubleTap, mode: .pan, expected: []),

            .init(gesture: .twoFingerTap, mode: .trackpad, expected: seq(click(.right, cursor), [.feedback(.secondaryClick)])),
            .init(gesture: .twoFingerTap, mode: .direct, expected: seq(direct(.right, centroid), [.feedback(.secondaryClick)])),
            .init(gesture: .twoFingerTap, mode: .pan, expected: []),

            .init(gesture: .twoFingerPan, mode: .trackpad,
                  expected: [.remote(.scroll(cursor, dx: 0, dy: 2)), .remote(.scroll(cursor, dx: 0, dy: 1))]),
            .init(gesture: .twoFingerPan, mode: .direct,
                  expected: [.remote(.scroll(centroid, dx: 0, dy: 2)), .remote(.scroll(centroid, dx: 0, dy: 1))]),
            .init(gesture: .twoFingerPan, mode: .pan,
                  expected: [.viewport(.gesture(from: P(x: 230, y: 300), to: P(x: 230, y: 312), factor: 1)),
                             .viewport(.gesture(from: P(x: 230, y: 312), to: P(x: 230, y: 318), factor: 1))]),

            .init(gesture: .pinch, mode: .trackpad, expected: pinch),
            .init(gesture: .pinch, mode: .direct, expected: pinch),
            .init(gesture: .pinch, mode: .pan, expected: pinch),

            .init(gesture: .drag, mode: .trackpad,
                  expected: seq(click(.left, cursor), [.remote(.move(cursor)), .remote(.press(.left, cursor)), .feedback(.dragBegan)],
                                cursorStep(424), cursorStep(436), [.remote(.release(.left, m.at(436, 400)))])),
            .init(gesture: .drag, mode: .direct,
                  expected: [.cursorMoved(cursor.desktop), .remote(.move(cursor)), .remote(.press(.left, cursor)), .feedback(.dragBegan),
                             .cursorMoved(LogicalPoint(x: 424, y: 400)), .remote(.move(m.at(424, 400))),
                             .remote(.release(.left, m.at(424, 400)))]),
            .init(gesture: .drag, mode: .pan, expected: [.viewport(.pan(dx: 12, dy: 0))]),

            .init(gesture: .tapInLetterbox, mode: .trackpad, expected: click(.left, cursor)), // relative: clicks at the cursor
            .init(gesture: .tapInLetterbox, mode: .direct, expected: []),
            .init(gesture: .tapInLetterbox, mode: .pan, expected: []),
        ]
        for mode in InputMode.allCases { rows.append(.init(gesture: .threeFingerTouch, mode: mode, expected: [])) }
        // Trackpad: the latch presses at the cursor now and the stroke drags it. Direct: the latch arms the next
        // touch, which presses where it lands; lifting ends that drag. Pan: explicit mouse controls do nothing.
        for (gesture, button) in [(InputConformanceGesture.latchDrag, MouseButtons.left), (.rightDrag, .right)] {
            let stroke = seq(cursorStep(424), cursorStep(436), [.remote(.release(button, m.at(436, 400)))])
            rows.append(.init(gesture: gesture, mode: .trackpad,
                              expected: seq([.remote(.move(cursor)), .remote(.press(button, cursor)), .feedback(.dragBegan)], stroke)))
            rows.append(.init(gesture: gesture, mode: .direct,
                              expected: seq([.cursorMoved(cursor.desktop), .remote(.move(cursor)), .remote(.press(button, cursor)),
                                             .feedback(.dragBegan)], stroke)))
            rows.append(.init(gesture: gesture, mode: .pan, expected: localPan))
        }
        rows.append(.init(gesture: .middleClick, mode: .trackpad, expected: click(.middle, cursor)))
        rows.append(.init(gesture: .middleClick, mode: .direct, expected: click(.middle, cursor)))
        rows.append(.init(gesture: .middleClick, mode: .pan, expected: []))
        return rows
    }
}

@Suite("Gesture conformance")
struct GestureConformanceTests {
    @Test func everyGestureAndModeHasExactlyOneRow() {
        var seen: [String: Int] = [:]
        for row in InputConformance.rows() { seen["\(row.gesture.rawValue)/\(row.mode.rawValue)", default: 0] += 1 }
        for gesture in InputConformanceGesture.allCases {
            for mode in InputMode.allCases {
                #expect(seen["\(gesture.rawValue)/\(mode.rawValue)"] == 1, "\(gesture) × \(mode) needs exactly one row")
            }
        }
        #expect(seen.count == InputConformanceGesture.allCases.count * InputMode.allCases.count)
    }

    @Test func everyRowProducesExactlyItsEffects() {
        for row in InputConformance.rows() {
            let interpreter = GestureInterpreter(mode: row.mode)
            interpreter.setCursor(InputConformance.startCursor)
            let effects = drive(interpreter, InputConformance.script(row.gesture, mode: row.mode), mapping: InputConformance.mapping)
            #expect(effects == row.expected, "\(row.gesture) × \(row.mode)")
            #expect(!interpreter.hasActiveTouches && !interpreter.isDragging, "\(row.gesture) × \(row.mode) left state behind")
        }
    }

    @Test func remoteDisabledSendsNothingForAnyGesture() {
        for mode in InputMode.allCases {
            for gesture in InputConformanceGesture.allCases {
                let interpreter = GestureInterpreter(mode: mode, remoteEnabled: false)
                interpreter.setCursor(InputConformance.startCursor)
                let effects = drive(interpreter, InputConformance.script(gesture, mode: mode), mapping: InputConformance.mapping)
                #expect(!effects.reachesRemote, "\(gesture) × \(mode) reached the Mac while remote input is off")
                #expect(interpreter.cursor == InputConformance.startCursor)
            }
        }
    }

    @Test func remoteDisabledTapOnlyReportsBlocked() {
        let interpreter = GestureInterpreter(mode: .trackpad, remoteEnabled: false)
        let effects = drive(interpreter, InputConformance.script(.singleTap, mode: .trackpad), mapping: InputConformance.mapping)
        #expect(effects == [.feedback(.inputBlocked)])
    }

    @Test func remoteDisabledStillNavigatesLocally() {
        let interpreter = GestureInterpreter(mode: .direct, remoteEnabled: false)
        let pan = drive(interpreter, InputConformance.script(.oneFingerMove, mode: .direct), mapping: InputConformance.mapping)
        #expect(pan == [.viewport(.pan(dx: 12, dy: 0)), .viewport(.pan(dx: 6, dy: 0))])
        let pinch = drive(interpreter, InputConformance.script(.pinch, mode: .direct), mapping: InputConformance.mapping)
        #expect(pinch.count == 2 && !pinch.reachesRemote)
    }

    @Test func panModeSendsNothingRemoteForAnyGesture() {
        for gesture in InputConformanceGesture.allCases {
            let interpreter = GestureInterpreter(mode: .pan)
            interpreter.setCursor(InputConformance.startCursor)
            let effects = drive(interpreter, InputConformance.script(gesture, mode: .pan), mapping: InputConformance.mapping)
            #expect(!effects.reachesRemote, "\(gesture) in Pan mode reached the Mac")
        }
    }
}
