import Foundation

// Vocabulary between the app's touch surface, the gesture interpreter, the viewport and the input
// ledger. Touches and viewport effects are in VIEW points (UIKit points of the session surface);
// the cursor and pointer targets are in compact-desktop logical points.

/// One touch as UIKit reports it: a stable identity for the touch's lifetime and its location.
public struct TouchPoint: Equatable, Sendable {
    public var id: Int
    public var x: Double
    public var y: Double
    public init(id: Int, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}

/// Raw touch phases forwarded unfiltered from `touchesBegan/Moved/Ended/Cancelled`. Each case lists
/// only the touches in that phase, with their current locations.
public enum TouchEvent: Equatable, Sendable {
    case began([TouchPoint])
    case moved([TouchPoint])
    case ended([TouchPoint])
    /// The system took the touches (edge gesture, alert, interruption). Ends everything they drove.
    case cancelled
}

/// A purely local viewport change. Never reaches the network.
public enum ViewportEffect: Equatable, Sendable {
    /// A location on the session surface, in view points.
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    /// Move the content by this many view points (content follows the finger).
    case pan(dx: Double, dy: Double)
    /// One combined pinch step: scale by `factor` about `from`, then move `from` to `to`. Carrying the
    /// centroid motion here (and nowhere else) is what keeps pinch + translation from being counted twice.
    case gesture(from: Point, to: Point, factor: Double)
}

/// A remote pointer action for `InputLedger.apply`. The ledger adds the held button mask and modifiers.
public enum RemoteAction: Equatable, Sendable {
    case move(PointerTarget)
    case press(MouseButtons, PointerTarget)
    case release(MouseButtons, PointerTarget)
    /// Logical lines; positive dy scrolls up (fingers moving down), positive dx scrolls left (fingers moving right).
    case scroll(PointerTarget, dx: Double, dy: Double)
}

/// Haptic/visual acknowledgements the app may render. Never required for correctness.
public enum FeedbackKind: Equatable, Sendable {
    /// A held press started (long press, tap-and-hold, or an armed button latch).
    case dragBegan
    /// A two-finger tap produced a right click.
    case secondaryClick
    /// A tap was ignored because remote control is off (View Only, paused, reconnecting, nothing selected).
    case inputBlocked
}

/// Everything the gesture interpreter asks the app/session to do, in order.
public enum InputEffect: Equatable, Sendable {
    case viewport(ViewportEffect)
    case remote(RemoteAction)
    /// The predicted remote cursor moved (compact-desktop points). Draw it in the same frame.
    case cursorMoved(LogicalPoint)
    /// The canvas tap that must show hidden controls. It never also clicks the Mac.
    case revealControls
    case feedback(FeedbackKind)
}
