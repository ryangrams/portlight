import Foundation

/// Deterministic touch arbitration for the session surface: one raw-touch reducer instead of stacked
/// UIKit recognizers, so which gesture wins is a pure function of the touch trace and testable.
///
/// | Gesture | Trackpad | Direct | Pan mode / remote disabled |
/// |---|---|---|---|
/// | One-finger move | predicted cursor (gain, clamped) + remote move | local pan | local pan |
/// | Tap | left click at cursor | left click where touched | nothing |
/// | Double tap | two clicks, first not delayed | two clicks | nothing |
/// | Two-finger tap | right click at cursor | right click at centroid | nothing |
/// | Two-finger pan | remote scroll (+ inertia) | remote scroll (+ inertia) | local pan/zoom |
/// | Pinch | local zoom + pan until every finger lifts (a re-grip too), never scroll | same | local |
/// | Drag | tap, then touch again and hold/move | long press, then move | nothing |
/// | Three fingers | ignored | ignored | ignored |
///
/// A remote press is never sent while its gesture is unresolved: taps resolve on lift, drags on the
/// long-press/hold deadline or movement. Taps in gaps/letterbox send nothing (Direct). When controls
/// are hidden, the first tap only reveals them; an armed Direct latch then waits for a long press.
///
/// Confinement: main thread only. Create it, set its properties and call every method from the main
/// thread (UIKit touch delivery and the display link that drives `tick`). Not Sendable. Remote effects
/// go to `InputLedger.apply` in order; viewport effects go to the viewport model.
public final class GestureInterpreter {
    typealias Point = ViewportEffect.Point

    enum Style: Equatable { case trackpad, direct, local }

    /// A single touch whose meaning isn't a held drag.
    struct One {
        var id: Int
        var style: Style
        var start: Point
        var startTime: Double
        var last: Point
        var lastTime: Double
        /// Finger position up to which motion was applied (cursor or pan).
        var applied: Point
        /// Trackpad: began soon after, and near, a tap — may become tap-and-drag.
        var secondTap = false
        var beyondSlop = false
        /// Trackpad: the cursor follows this finger (after `twoFingerArrival` or slop).
        var motionActive = false
        /// Direct: the long-press deadline passed over a gap; it can no longer press.
        var longPressSpent = false
        var speed = 0.0
    }

    enum Lock: Equatable { case none, pinch, scroll, local }

    struct Two {
        var a: Int
        var b: Int
        /// Pan mode or remote disabled when the gesture began, or a finger added to the rest of a pinch:
        /// everything stays local.
        var local: Bool
        var startTime: Double
        var startA: Point
        var startB: Point
        var startCentroid: Point
        var startSpan: Double
        var prevCentroid: Point
        var prevSpan: Double
        var tapEligible: Bool
        var samples: [(time: Double, point: Point)]
        var lock: Lock = .none
        var scrollTarget: PointerTarget?
        var lifted: Set<Int> = []
    }

    /// A held button driven by one touch.
    struct Drag {
        var id: Int
        var style: Style
        var button: MouseButtons
        var last: Point
        var lastTime: Double
        var target: PointerTarget
        /// Started from a Direct button latch; `releaseLatched` ends it.
        var armed: Bool
    }

    enum Phase {
        case idle
        case one(One)
        case two(Two)
        case drag(Drag)
        /// Gesture over (or abandoned) while fingers remain; ignore them until all lift.
        case finishing
    }

    struct Inertia {
        var vx: Double
        var vy: Double
        var time: Double
        var target: PointerTarget
    }

    public let configuration: GestureConfiguration
    /// Changing mode abandons any remote gesture silently; call `InputLedger.releaseAll()` first.
    public var mode: InputMode { didSet { if mode != oldValue { reset() } } }
    /// False when View Only, paused, reconnecting, or nothing is selected (`SessionSettings.allowsRemoteInput`
    /// and a live selection): only local viewport effects. Turning it off abandons remote gestures silently;
    /// the ledger's `releaseAll()` releases the host.
    public var remoteEnabled: Bool { didSet { if remoteEnabled != oldValue { reset() } } }
    /// While true the first tap only emits `.revealControls` (then clears this), never a click.
    public var controlsHidden = false
    /// Predicted remote cursor in compact-desktop points; nil until seeded by a touch, a host report or `setCursor`.
    public internal(set) var cursor: LogicalPoint?
    /// Trackpad button latch currently held on the host by this interpreter.
    public internal(set) var latchedButtons: MouseButtons = []
    /// Direct button latch waiting for the next one-finger touch.
    public internal(set) var armedButton: MouseButtons?

    var touches: [Int: Point] = [:]
    var phase: Phase = .idle
    var lastTap: (time: Double, point: Point)?
    var inertia: Inertia?
    var lastSentTarget: PointerTarget?
    var lastPredictionTime = -Double.infinity
    var now: Double = 0

    public init(configuration: GestureConfiguration = .standard, mode: InputMode = .trackpad, remoteEnabled: Bool = true) {
        self.configuration = configuration
        self.mode = mode
        self.remoteEnabled = remoteEnabled
    }

    public var isInertiaActive: Bool { inertia != nil }
    public var hasActiveTouches: Bool { !touches.isEmpty }
    /// A touch drag or trackpad latch is holding a button.
    public var isDragging: Bool {
        if case .drag = phase { return true }
        return !latchedButtons.isEmpty
    }

    // MARK: Events

    /// Feed one raw touch event. `time` is the event timestamp (monotonic seconds).
    public func handle(_ event: TouchEvent, at time: TimeInterval, mapping: any PointerMapping) -> [InputEffect] {
        now = time
        var out: [InputEffect] = []
        advanceTimers(mapping: mapping, into: &out)
        switch event {
        case .began(let points):
            inertia = nil // any touch-down stops a fling
            // Only finite locations are tracked. UIKit never reports others, and one would poison the slop,
            // speed and cursor math (the viewport maps a non-finite point to a display centre).
            let landed = points.filter { $0.x.isFinite && $0.y.isFinite }
            for point in landed { touches[point.id] = Point(x: point.x, y: point.y) }
            if !landed.isEmpty { touchesBegan(landed, mapping: mapping, into: &out) }
        case .moved(let points):
            if update(points) { touchesMoved(mapping: mapping, into: &out) }
        case .ended(let points):
            let ids = points.map(\.id).filter { touches[$0] != nil }
            if update(points) { touchesMoved(mapping: mapping, into: &out) }
            touchesEnded(ids, mapping: mapping, into: &out)
            for id in ids { touches[id] = nil }
            if touches.isEmpty {
                if case .drag(let drag) = phase { emit(.release(drag.button, drag.target), into: &out) }
                phase = .idle
            }
        case .cancelled:
            out += cancel(mapping: mapping)
        }
        return out
    }

    /// Display-link step: long-press/hold deadlines, trackpad motion start, and scroll inertia.
    public func tick(at time: TimeInterval, mapping: any PointerMapping) -> [InputEffect] {
        now = time
        var out: [InputEffect] = []
        advanceTimers(mapping: mapping, into: &out)
        stepInertia(mapping: mapping, into: &out)
        return out
    }

    /// Touches cancelled or an interruption: end drags and latches with releases, stop inertia, forget touches.
    public func cancel(mapping: any PointerMapping) -> [InputEffect] {
        var out: [InputEffect] = []
        if case .drag(let drag) = phase { emit(.release(drag.button, drag.target), into: &out) }
        if !latchedButtons.isEmpty, let target = cursorTarget(mapping) ?? lastSentTarget {
            emit(.release(latchedButtons, target), into: &out)
        }
        latchedButtons = []
        armedButton = nil
        inertia = nil
        lastTap = nil
        touches.removeAll()
        phase = .idle
        return out
    }

    /// Forget latches, inertia and any remote gesture without emitting anything — after the ledger
    /// released the host (`releaseAll`/`hostDidReleaseInput`). Purely local gestures keep running.
    public func reset() {
        latchedButtons = []
        armedButton = nil
        inertia = nil
        lastTap = nil
        switch phase {
        case .idle: return
        case .one(let one) where one.style == .local: return
        case .two(let two) where two.local || two.lock == .pinch: return
        default: phase = touches.isEmpty ? .idle : .finishing
        }
    }

    // MARK: Explicit controls

    /// Button latch fallback. Trackpad: press now at the cursor and hold until `releaseLatched`
    /// (one-finger movement drags). Direct: arm the next one-finger touch to press where it lands.
    public func pressLatched(_ button: MouseButtons, mapping: any PointerMapping) -> [InputEffect] {
        guard remoteEnabled, !button.isEmpty else { return [] }
        switch mode {
        case .pan:
            return []
        case .direct:
            armedButton = button
            return []
        case .trackpad:
            let adding = button.subtracting(latchedButtons)
            guard !adding.isEmpty else { return [] }
            var out: [InputEffect] = []
            ensureCursor(mapping, into: &out)
            guard let target = cursorTarget(mapping) else { return out }
            latchedButtons.formUnion(adding)
            lastTap = nil
            emit(.move(target), into: &out)
            emit(.press(adding, target), into: &out)
            out.append(.feedback(.dragBegan))
            return out
        }
    }

    /// Ends the button latch: releases trackpad-latched buttons at the cursor, ends an armed Direct
    /// drag in progress, or disarms an unused Direct latch.
    public func releaseLatched(mapping: any PointerMapping) -> [InputEffect] {
        var out: [InputEffect] = []
        armedButton = nil
        if case .drag(let drag) = phase, drag.armed {
            emit(.release(drag.button, drag.target), into: &out)
            phase = touches.isEmpty ? .idle : .finishing
        }
        if !latchedButtons.isEmpty {
            if let target = cursorTarget(mapping) ?? lastSentTarget { emit(.release(latchedButtons, target), into: &out) }
            latchedButtons = []
        }
        return out
    }

    /// Explicit click (right/middle from the mouse-actions control) at the cursor — which in Direct
    /// mode is the last touched location.
    public func click(_ button: MouseButtons, mapping: any PointerMapping) -> [InputEffect] {
        guard remoteEnabled, mode != .pan, !button.isEmpty else { return [] }
        var out: [InputEffect] = []
        ensureCursor(mapping, into: &out)
        guard let target = cursorTarget(mapping) else { return out }
        sendClick(button, at: target, into: &out)
        return out
    }

    // MARK: Cursor

    /// Place the predicted cursor without emitting (session start, selection change, mode switch).
    public func setCursor(_ point: LogicalPoint?) {
        cursor = point
    }

    /// Host `cursor` report converted to compact-desktop points. Ignored while touches are down or a
    /// local prediction is fresh, so a stale report can't yank the cursor back.
    public func reconcileCursor(hostPoint: LogicalPoint, at time: TimeInterval) -> [InputEffect] {
        guard touches.isEmpty, time - lastPredictionTime >= configuration.cursorReconcileGrace, hostPoint != cursor else { return [] }
        cursor = hostPoint
        return [.cursorMoved(hostPoint)]
    }
}
