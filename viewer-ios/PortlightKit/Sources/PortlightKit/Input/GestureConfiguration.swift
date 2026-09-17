import Foundation

/// Touch-feel constants. URC defines none of these; they are this viewer's starting values, tunable
/// after a real-phone review without changing the arbitration rules. Distances are view points.
public struct GestureConfiguration: Equatable, Sendable {
    /// Movement that turns a touch from a tap/long-press candidate into a move.
    public var tapSlop: Double = 10
    /// Longest touch that still counts as a tap.
    public var tapMaxDuration: TimeInterval = 0.25
    /// Direct mode: stationary hold that commits a left press for dragging.
    public var longPressDuration: TimeInterval = 0.5
    /// Trackpad: a new touch this soon after a tap, this close to it, may become tap-and-drag.
    public var doubleTapWindow: TimeInterval = 0.3
    public var doubleTapRadius: Double = 30
    /// A second finger arriving this soon after the first makes a two-finger gesture (tap eligible).
    public var twoFingerArrival: TimeInterval = 0.08
    /// Pinch wins when |scale − 1| or |Δspan| reaches these, before scroll locks.
    public var pinchLockScale: Double = 0.06
    public var pinchLockSpan: Double = 12
    /// Two-finger scroll wins when the centroid moves this far while the span stays nearly constant.
    public var scrollLockDistance: Double = 10
    public var scrollLockMaxScale: Double = 0.04
    /// Trackpad acceleration: gain 1 below `gainSlowSpeed`, rising linearly to `gainMax` at `gainFastSpeed` (pt/s).
    public var gainSlowSpeed: Double = 150
    public var gainFastSpeed: Double = 1200
    public var gainMax: Double = 2.5
    /// Host points per wheel line; with content following the finger this converts view motion to lines.
    public var scrollPointsPerLine: Double = 12
    /// Scroll inertia: starts above `inertiaMinSpeed` (pt/s), decays ×`inertiaDecayPerMillisecond` per ms
    /// (UIScrollView's normal rate), stops below `inertiaStopSpeed`.
    public var inertiaMinSpeed: Double = 250
    public var inertiaDecayPerMillisecond: Double = 0.998
    public var inertiaStopSpeed: Double = 15
    /// Velocity is measured over this trailing window; a finger resting longer than this before lifting flings nothing.
    public var velocityWindow: TimeInterval = 0.1
    /// Host cursor reports are ignored for this long after a local prediction, so a stale report can't yank the cursor back.
    public var cursorReconcileGrace: TimeInterval = 0.5

    public init() {}
    public static let standard = GestureConfiguration()

    /// Trackpad gain for a finger speed in view points per second.
    public func trackpadGain(speed: Double) -> Double {
        guard speed.isFinite, speed > gainSlowSpeed else { return 1 }
        guard speed < gainFastSpeed, gainFastSpeed > gainSlowSpeed else { return gainMax }
        return 1 + (gainMax - 1) * (speed - gainSlowSpeed) / (gainFastSpeed - gainSlowSpeed)
    }
}
