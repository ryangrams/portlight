import Foundation

// The touch state machine behind `GestureInterpreter`. Every function runs on the main thread with
// `now` already set to the event or tick time.
extension GestureInterpreter {
    var currentStyle: Style {
        guard remoteEnabled else { return .local }
        switch mode {
        case .trackpad: return .trackpad
        case .direct: return .direct
        case .pan: return .local
        }
    }

    /// Stores new locations of known touches; true when any location changed. A non-finite location is
    /// ignored, so the touch keeps its last real one.
    func update(_ points: [TouchPoint]) -> Bool {
        var changed = false
        for point in points where point.x.isFinite && point.y.isFinite {
            guard let old = touches[point.id] else { continue }
            let new = Point(x: point.x, y: point.y)
            if new != old { touches[point.id] = new; changed = true }
        }
        return changed
    }

    // MARK: Began

    func touchesBegan(_ points: [TouchPoint], mapping: any PointerMapping, into out: inout [InputEffect]) {
        switch phase {
        case .idle:
            if touches.count == 1, let point = points.first {
                beginOne(point, mapping: mapping, into: &out)
            } else if touches.count == 2 {
                beginTwo(startTime: now, tapEligible: true)
            } else {
                phase = .finishing
            }
        case .one(let one):
            if touches.count == 2 {
                let quick = now - one.startTime <= configuration.twoFingerArrival
                // A finger left over from a pinch is local, and a second finger continues that same gesture,
                // so it stays local too ("once pinch wins, cancel remote scrolling for that gesture").
                beginTwo(startTime: one.startTime, tapEligible: quick && !one.beyondSlop, local: one.style == .local)
            } else {
                phase = .finishing
            }
        case .two:
            phase = .finishing // a third finger: nothing essential uses it; a scroll ends without inertia
        case .drag, .finishing:
            break // extra fingers never interrupt a held drag
        }
    }

    func beginOne(_ touch: TouchPoint, mapping: any PointerMapping, into out: inout [InputEffect]) {
        let point = Point(x: touch.x, y: touch.y)
        var one = One(id: touch.id, style: currentStyle, start: point, startTime: now, last: point, lastTime: now, applied: point)
        let previousTap = lastTap
        lastTap = nil
        switch one.style {
        case .trackpad:
            if let tap = previousTap, latchedButtons.isEmpty, now - tap.time <= configuration.doubleTapWindow,
               Self.distance(tap.point, point) <= configuration.doubleTapRadius {
                one.secondTap = true
            }
            seedCursor(at: point, mapping: mapping, into: &out)
        case .direct:
            // An armed latch presses where the next touch lands. While controls are hidden that touch may be
            // the tap that only reveals them, so the latch waits: it presses at the long press, or next time.
            if !controlsHidden, let button = armedButton, let target = target(at: point, mapping) {
                armedButton = nil
                predictDirect(target, into: &out)
                emit(.press(button, target), into: &out)
                out.append(.feedback(.dragBegan))
                phase = .drag(Drag(id: touch.id, style: .direct, button: button, last: point, lastTime: now, target: target, armed: true))
                return
            }
        case .local:
            break
        }
        phase = .one(one)
    }

    /// `local` keeps the whole two-finger gesture on the viewport (the rest of a pinch); Pan mode and
    /// remote-disabled gestures are local regardless.
    func beginTwo(startTime: Double, tapEligible: Bool, local: Bool = false) {
        let ids = touches.keys.sorted()
        guard ids.count == 2, let a = touches[ids[0]], let b = touches[ids[1]] else { phase = .finishing; return }
        let centroid = Self.centroid(a, b), span = Self.distance(a, b)
        phase = .two(Two(a: ids[0], b: ids[1], local: local || currentStyle == .local, startTime: startTime, startA: a, startB: b,
                         startCentroid: centroid, startSpan: span, prevCentroid: centroid, prevSpan: span,
                         tapEligible: tapEligible, samples: [(now, centroid)]))
    }

    // MARK: Moved

    func touchesMoved(mapping: any PointerMapping, into out: inout [InputEffect]) {
        switch phase {
        case .one(let one):
            if let point = touches[one.id], point != one.last { moveOne(one, to: point, mapping: mapping, into: &out) }
        case .two(let two):
            moveTwo(two, mapping: mapping, into: &out)
        case .drag(let drag):
            if let point = touches[drag.id], point != drag.last { moveDrag(drag, to: point, mapping: mapping, into: &out) }
        case .idle, .finishing:
            break
        }
    }

    func moveOne(_ one: One, to point: Point, mapping: any PointerMapping, into out: inout [InputEffect]) {
        var one = one
        if now > one.lastTime { one.speed = Self.distance(one.last, point) / (now - one.lastTime) }
        one.last = point
        one.lastTime = now
        if !one.beyondSlop, Self.distance(one.start, point) > configuration.tapSlop { one.beyondSlop = true }
        switch one.style {
        case .trackpad:
            if one.secondTap {
                phase = .one(one) // motion is withheld until tap-and-drag commits
                if one.beyondSlop { commitTapDrag(one, mapping: mapping, into: &out) }
                return
            }
            if !one.motionActive, one.beyondSlop || now - one.startTime >= configuration.twoFingerArrival { one.motionActive = true }
            if one.motionActive {
                moveCursor(by: Point(x: point.x - one.applied.x, y: point.y - one.applied.y), speed: one.speed, mapping: mapping, into: &out)
                one.applied = point
            }
        case .direct, .local:
            if one.beyondSlop {
                // Includes the slop distance, so content stays under the finger.
                let dx = point.x - one.applied.x, dy = point.y - one.applied.y
                if dx != 0 || dy != 0 { out.append(.viewport(.pan(dx: dx, dy: dy))) }
                one.applied = point
            }
        }
        phase = .one(one)
    }

    func moveTwo(_ two: Two, mapping: any PointerMapping, into out: inout [InputEffect]) {
        var two = two
        let slop = configuration.tapSlop
        // A tap needs every finger to stay within the slop, including one still down after the other lifted.
        for (id, start) in [(two.a, two.startA), (two.b, two.startB)] {
            if let point = touches[id], Self.distance(point, start) > slop { two.tapEligible = false }
        }
        guard two.lifted.isEmpty, let a = touches[two.a], let b = touches[two.b] else { phase = .two(two); return }
        let centroid = Self.centroid(a, b), span = Self.distance(a, b)
        two.samples.append((now, centroid))
        let horizon = now - 2 * configuration.velocityWindow
        two.samples.removeAll { $0.time < horizon }
        var from = two.prevCentroid, fromSpan = two.prevSpan
        if two.lock == .none {
            let scaleChange = two.startSpan > 0 ? span / two.startSpan - 1 : 0
            let drift = Self.distance(centroid, two.startCentroid)
            if abs(scaleChange) >= configuration.pinchLockScale || abs(span - two.startSpan) >= configuration.pinchLockSpan {
                two.lock = two.local ? .local : .pinch
            } else if drift >= configuration.scrollLockDistance, abs(scaleChange) < configuration.scrollLockMaxScale {
                two.lock = two.local ? .local : .scroll
                if two.lock == .scroll { two.scrollTarget = scrollTarget(for: two, mapping: mapping, into: &out) }
            } else {
                phase = .two(two) // unresolved: nothing leaves the reducer
                return
            }
            two.tapEligible = false
            // The locking step carries everything since the fingers landed, so content never lags them.
            from = two.startCentroid
            fromSpan = two.startSpan
        }
        switch two.lock {
        case .scroll:
            scroll(dx: centroid.x - from.x, dy: centroid.y - from.y, target: two.scrollTarget, mapping: mapping, into: &out)
        case .pinch, .local:
            let factor = fromSpan > 0 && span > 0 ? span / fromSpan : 1
            if from != centroid || factor != 1 { out.append(.viewport(.gesture(from: from, to: centroid, factor: factor))) }
        case .none:
            break
        }
        two.prevCentroid = centroid
        two.prevSpan = span
        phase = .two(two)
    }

    func moveDrag(_ drag: Drag, to point: Point, speed: Double? = nil, mapping: any PointerMapping, into out: inout [InputEffect]) {
        var drag = drag
        switch drag.style {
        case .trackpad:
            let measured = now > drag.lastTime ? Self.distance(drag.last, point) / (now - drag.lastTime) : 0
            let delta = Point(x: point.x - drag.last.x, y: point.y - drag.last.y)
            if let target = moveCursor(by: delta, speed: speed ?? measured, mapping: mapping, into: &out) { drag.target = target }
        case .direct, .local:
            // Held drags clamp to the displays, so the release always has a real target.
            if let desktop = mapping.desktopPoint(atViewPoint: point.x, point.y),
               let target = mapping.target(atDesktop: mapping.clampToDisplays(desktop)), target != drag.target {
                predictDirect(target, into: &out)
                drag.target = target
            }
        }
        drag.last = point
        drag.lastTime = now
        phase = .drag(drag)
    }

    // MARK: Ended

    func touchesEnded(_ ids: [Int], mapping: any PointerMapping, into out: inout [InputEffect]) {
        guard !ids.isEmpty else { return }
        switch phase {
        case .one(let one):
            if ids.contains(one.id) { liftOne(one, mapping: mapping, into: &out) }
        case .two(let two):
            liftTwo(two, ids: ids, mapping: mapping, into: &out)
        case .drag(let drag):
            if ids.contains(drag.id) {
                emit(.release(drag.button, drag.target), into: &out)
                phase = .finishing
            }
        case .idle, .finishing:
            break
        }
    }

    func liftOne(_ one: One, mapping: any PointerMapping, into out: inout [InputEffect]) {
        phase = .finishing
        guard !one.beyondSlop, now - one.startTime <= configuration.tapMaxDuration else { return }
        if controlsHidden {
            controlsHidden = false
            out.append(.revealControls)
            return
        }
        switch one.style {
        case .local:
            if !remoteEnabled && mode != .pan { out.append(.feedback(.inputBlocked)) }
        case .trackpad:
            guard latchedButtons.isEmpty, let target = cursorTarget(mapping) else { return }
            sendClick(.left, at: target, into: &out) // immediately: a double tap never delays the first click
            lastTap = (now, one.start)
        case .direct:
            guard let target = target(at: one.start, mapping) else { return } // gap or letterbox: nothing
            predictDirect(target, into: &out)
            emit(.press(.left, target), into: &out)
            emit(.release(.left, target), into: &out)
        }
    }

    func liftTwo(_ two: Two, ids: [Int], mapping: any PointerMapping, into out: inout [InputEffect]) {
        var two = two
        let lifting = ids.filter { $0 == two.a || $0 == two.b }
        guard !lifting.isEmpty else { return }
        switch two.lock {
        case .scroll:
            if let velocity = velocity(two.samples), hypot(velocity.x, velocity.y) > configuration.inertiaMinSpeed,
               let target = two.scrollTarget {
                inertia = Inertia(vx: velocity.x, vy: velocity.y, time: now, target: target)
            }
            phase = .finishing
        case .pinch, .local:
            // The rest of a pinch stays local: a remaining finger keeps panning the viewport.
            if let id = [two.a, two.b].first(where: { !lifting.contains($0) }), let point = touches[id] {
                phase = .one(One(id: id, style: .local, start: point, startTime: now, last: point, lastTime: now, applied: point, beyondSlop: true))
            } else {
                phase = .finishing
            }
        case .none:
            two.lifted.formUnion(lifting)
            guard two.lifted.count == 2 else { phase = .two(two); return }
            phase = .finishing
            if two.tapEligible, now - two.startTime <= configuration.tapMaxDuration { twoFingerTap(two, mapping: mapping, into: &out) }
        }
    }

    func twoFingerTap(_ two: Two, mapping: any PointerMapping, into out: inout [InputEffect]) {
        if controlsHidden {
            controlsHidden = false
            out.append(.revealControls)
            return
        }
        if two.local {
            if !remoteEnabled && mode != .pan { out.append(.feedback(.inputBlocked)) }
            return
        }
        guard latchedButtons.isEmpty else { return }
        switch mode {
        case .trackpad:
            seedCursor(at: two.startCentroid, mapping: mapping, into: &out)
            guard let target = cursorTarget(mapping) else { return }
            sendClick(.right, at: target, into: &out)
        case .direct:
            guard let target = target(at: two.startCentroid, mapping) else { return }
            predictDirect(target, into: &out)
            emit(.press(.right, target), into: &out)
            emit(.release(.right, target), into: &out)
        case .pan:
            return
        }
        out.append(.feedback(.secondaryClick))
    }

    // MARK: Timers and inertia

    func advanceTimers(mapping: any PointerMapping, into out: inout [InputEffect]) {
        guard case .one(var one) = phase else { return }
        switch one.style {
        case .trackpad:
            if one.secondTap {
                if !one.beyondSlop, now - one.startTime >= configuration.tapMaxDuration { commitTapDrag(one, mapping: mapping, into: &out) }
            } else if !one.motionActive, now - one.startTime >= configuration.twoFingerArrival {
                one.motionActive = true
                moveCursor(by: Point(x: one.last.x - one.applied.x, y: one.last.y - one.applied.y), speed: one.speed, mapping: mapping, into: &out)
                one.applied = one.last
                phase = .one(one)
            }
        case .direct:
            guard !one.beyondSlop, !one.longPressSpent, now - one.startTime >= configuration.longPressDuration else { return }
            if let target = target(at: one.last, mapping) {
                // A latch still armed (its touch revealed hidden controls, or landed in a gap) is this drag's button.
                let button = armedButton ?? .left
                let armed = armedButton != nil
                armedButton = nil
                predictDirect(target, into: &out)
                emit(.press(button, target), into: &out)
                out.append(.feedback(.dragBegan))
                phase = .drag(Drag(id: one.id, style: .direct, button: button, last: one.last, lastTime: now, target: target, armed: armed))
            } else {
                one.longPressSpent = true
                phase = .one(one)
            }
        case .local:
            break
        }
    }

    func stepInertia(mapping: any PointerMapping, into out: inout [InputEffect]) {
        guard var fling = inertia else { return }
        let rate = configuration.inertiaDecayPerMillisecond
        guard remoteEnabled, rate > 0, rate < 1 else { inertia = nil; return }
        let milliseconds = (now - fling.time) * 1000
        guard milliseconds > 0 else { return }
        let decay = pow(rate, milliseconds)
        // Exact distance under v(t) = v0 · rate^ms over this step: v0 · (1 − decay) / (−1000 · ln rate).
        let seconds = (1 - decay) / (-1000 * log(rate))
        let dx = fling.vx * seconds, dy = fling.vy * seconds
        fling.vx *= decay
        fling.vy *= decay
        fling.time = now
        scroll(dx: dx, dy: dy, target: fling.target, mapping: mapping, into: &out)
        inertia = hypot(fling.vx, fling.vy) < configuration.inertiaStopSpeed ? nil : fling
    }

    /// Centroid velocity (view pt/s) over the trailing window; nil when the fingers rested before lifting.
    func velocity(_ samples: [(time: Double, point: Point)]) -> Point? {
        let window = configuration.velocityWindow
        guard let last = samples.last, now - last.time <= window,
              let first = samples.first(where: { last.time - $0.time <= window }), last.time > first.time else { return nil }
        let dt = last.time - first.time
        return Point(x: (last.point.x - first.point.x) / dt, y: (last.point.y - first.point.y) / dt)
    }

    // MARK: Helpers

    func commitTapDrag(_ one: One, mapping: any PointerMapping, into out: inout [InputEffect]) {
        guard let target = cursorTarget(mapping) else {
            var plain = one
            plain.secondTap = false
            phase = .one(plain)
            return
        }
        emit(.move(target), into: &out)
        emit(.press(.left, target), into: &out)
        out.append(.feedback(.dragBegan))
        let drag = Drag(id: one.id, style: .trackpad, button: .left, last: one.start, lastTime: one.startTime, target: target, armed: false)
        phase = .drag(drag)
        if one.last != one.start { moveDrag(drag, to: one.last, speed: one.speed, mapping: mapping, into: &out) }
    }

    /// Trackpad motion: gain × finger delta ÷ zoom, clamped to the displays. Returns the new target.
    @discardableResult
    func moveCursor(by delta: Point, speed: Double, mapping: any PointerMapping, into out: inout [InputEffect]) -> PointerTarget? {
        guard delta.x != 0 || delta.y != 0, let current = cursor else { return nil }
        let scale = mapping.viewPointsPerDesktopPoint
        guard scale.isFinite, scale > 0 else { return nil }
        let gain = configuration.trackpadGain(speed: speed)
        let next = mapping.clampToDisplays(LogicalPoint(x: current.x + gain * delta.x / scale, y: current.y + gain * delta.y / scale))
        guard next != current else { return nil }
        cursor = next
        lastPredictionTime = now
        out.append(.cursorMoved(next))
        guard let target = mapping.target(atDesktop: next) else { return nil }
        emit(.move(target), into: &out)
        return target
    }

    func scroll(dx: Double, dy: Double, target: PointerTarget?, mapping: any PointerMapping, into out: inout [InputEffect]) {
        // Content follows the finger: view motion ÷ (zoom × host points per line) = lines, same sign.
        let viewPointsPerLine = mapping.viewPointsPerDesktopPoint * configuration.scrollPointsPerLine
        guard let target, dx != 0 || dy != 0, viewPointsPerLine.isFinite, viewPointsPerLine > 0 else { return }
        emit(.scroll(target, dx: dx / viewPointsPerLine, dy: dy / viewPointsPerLine), into: &out)
    }

    func scrollTarget(for two: Two, mapping: any PointerMapping, into out: inout [InputEffect]) -> PointerTarget? {
        if mode == .trackpad {
            seedCursor(at: two.startCentroid, mapping: mapping, into: &out)
            return cursorTarget(mapping)
        }
        return target(at: two.startCentroid, mapping)
    }

    func seedCursor(at point: Point, mapping: any PointerMapping, into out: inout [InputEffect]) {
        guard cursor == nil, let desktop = mapping.desktopPoint(atViewPoint: point.x, point.y) else { return }
        let seeded = mapping.clampToDisplays(desktop)
        cursor = seeded
        lastPredictionTime = now
        out.append(.cursorMoved(seeded))
    }

    /// Fallback for explicit controls before any touch: the nearest display point to the desktop origin.
    func ensureCursor(_ mapping: any PointerMapping, into out: inout [InputEffect]) {
        guard cursor == nil else { return }
        let seeded = mapping.clampToDisplays(.zero)
        cursor = seeded
        out.append(.cursorMoved(seeded))
    }

    func cursorTarget(_ mapping: any PointerMapping) -> PointerTarget? {
        cursor.flatMap { mapping.target(atDesktop: mapping.clampToDisplays($0)) }
    }

    func target(at point: Point, _ mapping: any PointerMapping) -> PointerTarget? {
        mapping.desktopPoint(atViewPoint: point.x, point.y).flatMap { mapping.target(atDesktop: $0) }
    }

    /// Direct mode: the remote cursor jumps to the touched target; keep the prediction in step.
    func predictDirect(_ target: PointerTarget, into out: inout [InputEffect]) {
        cursor = target.desktop
        lastPredictionTime = now
        out.append(.cursorMoved(target.desktop))
        emit(.move(target), into: &out)
    }

    func sendClick(_ button: MouseButtons, at target: PointerTarget, into out: inout [InputEffect]) {
        emit(.move(target), into: &out)
        emit(.press(button, target), into: &out)
        emit(.release(button, target), into: &out)
    }

    func emit(_ action: RemoteAction, into out: inout [InputEffect]) {
        switch action {
        case .move(let target), .press(_, let target), .release(_, let target), .scroll(let target, _, _):
            lastSentTarget = target
        }
        out.append(.remote(action))
    }

    static func centroid(_ a: Point, _ b: Point) -> Point { Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    static func distance(_ a: Point, _ b: Point) -> Double { hypot(b.x - a.x, b.y - a.y) }
}
