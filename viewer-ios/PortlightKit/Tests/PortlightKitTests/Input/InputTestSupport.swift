import Foundation
@testable import PortlightKit

// Shared fixtures for the Input tests. Names carry an `Input` prefix because every module's tests share
// one test target.

/// Two 1920×1080 displays side by side in the compact desktop ("L" at x 0, "R" at x 1920), drawn at
/// `zoom` view points per desktop point with the desktop origin at view (`offsetX`, `offsetY`). View
/// y below `offsetY` is letterbox.
struct InputTestMapping: PointerMapping {
    var zoom: Double = 0.5
    var offsetX: Double = 0
    var offsetY: Double = 100
    var frames: [(id: DisplayID, frame: LogicalRect)] = [
        ("L", LogicalRect(x: 0, y: 0, width: 1920, height: 1080)),
        ("R", LogicalRect(x: 1920, y: 0, width: 1920, height: 1080)),
    ]

    var viewPointsPerDesktopPoint: Double { zoom }

    func desktopPoint(atViewPoint x: Double, _ y: Double) -> LogicalPoint? {
        LogicalPoint(x: (x - offsetX) / zoom, y: (y - offsetY) / zoom)
    }

    func viewPoint(atDesktop point: LogicalPoint) -> (x: Double, y: Double) {
        (point.x * zoom + offsetX, point.y * zoom + offsetY)
    }

    func target(atDesktop point: LogicalPoint) -> PointerTarget? {
        guard let hit = frames.first(where: { $0.frame.contains(point) }) else { return nil }
        return PointerTarget(display: hit.id, x: (point.x - hit.frame.x) / hit.frame.width,
                             y: (point.y - hit.frame.y) / hit.frame.height, desktop: point)
    }

    /// Nearest point inside any display; the max edges stay half a point inside the half-open bounds.
    func clampToDisplays(_ point: LogicalPoint) -> LogicalPoint {
        var best = point
        var bestDistance = Double.infinity
        for entry in frames {
            let f = entry.frame
            let clamped = LogicalPoint(x: min(max(point.x, f.minX), f.maxX - 0.5), y: min(max(point.y, f.minY), f.maxY - 0.5))
            let distance = hypot(clamped.x - point.x, clamped.y - point.y)
            if distance < bestDistance { best = clamped; bestDistance = distance }
        }
        return best
    }

    /// Expected target for a desktop point that is known to be on a display.
    func at(_ x: Double, _ y: Double) -> PointerTarget { target(atDesktop: LogicalPoint(x: x, y: y))! }
}

/// One timed step of a touch script, or an explicit mouse control from the accessory palette.
enum InputStep {
    case began([TouchPoint], Double)
    case moved([TouchPoint], Double)
    case ended([TouchPoint], Double)
    case cancelled(Double)
    case tick(Double)
    case pressLatched(MouseButtons)
    case releaseLatched
    case click(MouseButtons)
}

func tp(_ id: Int, _ x: Double, _ y: Double) -> TouchPoint { TouchPoint(id: id, x: x, y: y) }

/// Runs a script and returns every effect in order.
func drive(_ interpreter: GestureInterpreter, _ steps: [InputStep], mapping: any PointerMapping) -> [InputEffect] {
    var effects: [InputEffect] = []
    for step in steps {
        switch step {
        case .began(let points, let t): effects += interpreter.handle(.began(points), at: t, mapping: mapping)
        case .moved(let points, let t): effects += interpreter.handle(.moved(points), at: t, mapping: mapping)
        case .ended(let points, let t): effects += interpreter.handle(.ended(points), at: t, mapping: mapping)
        case .cancelled(let t): effects += interpreter.handle(.cancelled, at: t, mapping: mapping)
        case .tick(let t): effects += interpreter.tick(at: t, mapping: mapping)
        case .pressLatched(let button): effects += interpreter.pressLatched(button, mapping: mapping)
        case .releaseLatched: effects += interpreter.releaseLatched(mapping: mapping)
        case .click(let button): effects += interpreter.click(button, mapping: mapping)
        }
    }
    return effects
}

/// Feeds the remote effects through a ledger, as the session engine does, and returns the wire messages.
func wire(_ effects: [InputEffect], ledger: InputLedger, latches: inout ModifierLatches) -> [OutboundMessage] {
    var messages: [OutboundMessage] = []
    for effect in effects {
        if case .remote(let action) = effect { messages += ledger.apply(action, modifiers: &latches) }
    }
    return messages
}

extension Array where Element == InputEffect {
    var inputRemote: [RemoteAction] {
        compactMap { if case .remote(let action) = $0 { return action } else { return nil } }
    }
    /// Anything that reaches or predicts the remote Mac.
    var reachesRemote: Bool {
        contains { effect in
            switch effect {
            case .remote, .cursorMoved: return true
            case .viewport, .revealControls, .feedback: return false
            }
        }
    }
    var inputPresses: [RemoteAction] {
        inputRemote.filter { if case .press = $0 { return true } else { return false } }
    }
    var inputScrolls: [(dx: Double, dy: Double)] {
        inputRemote.compactMap { if case .scroll(_, let dx, let dy) = $0 { return (dx, dy) } else { return nil } }
    }
}

extension OutboundMessage {
    static func inputDown(_ keysym: UInt32) -> OutboundMessage { .key(keysym: keysym, down: true) }
    static func inputUp(_ keysym: UInt32) -> OutboundMessage { .key(keysym: keysym, down: false) }
    static func inputPointer(_ target: PointerTarget, _ buttons: MouseButtons) -> OutboundMessage {
        .pointer(display: target.display, x: target.x, y: target.y, buttons: buttons)
    }
}
