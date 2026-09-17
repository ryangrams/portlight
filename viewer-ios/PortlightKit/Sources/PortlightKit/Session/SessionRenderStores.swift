import Foundation

// High-frequency state for the render loop. The controller publishes on the main actor; a display link
// (or any thread) reads a consistent copy under a lock, never through the SwiftUI view tree.

/// The camera the renderer draws with: the viewport model plus the dimmed (paused/frozen) treatment.
public final class TransformStore: @unchecked Sendable {
    // Invariant for @unchecked Sendable: `current` is only read or written while holding `lock`.
    public struct Snapshot: Equatable, Sendable {
        public var viewport: ViewportModel
        public var dimmed: Bool
        /// Bumped by every published change.
        public var version: UInt64
    }

    private let lock = NSLock()
    private var current = Snapshot(viewport: ViewportModel(), dimmed: false, version: 0)

    public init() {}

    public var snapshot: Snapshot { lock.withLock { current } }
    public var transform: ViewportTransform { lock.withLock { current.viewport.transform } }

    /// Everything for one presentation; quads in display-ID order.
    public func scene(cursor: LogicalPoint?) -> RenderScene {
        let state = snapshot
        return state.viewport.scene(cursor: cursor, dimmed: state.dimmed)
    }

    public func scene(cursor: CursorStore) -> RenderScene { scene(cursor: cursor.visiblePoint) }

    /// Returns true when something changed (and the version was bumped).
    @discardableResult
    func publish(_ viewport: ViewportModel, dimmed: Bool) -> Bool {
        lock.withLock {
            guard viewport != current.viewport || dimmed != current.dimmed else { return false }
            current = Snapshot(viewport: viewport, dimmed: dimmed, version: current.version &+ 1)
            return true
        }
    }
}

/// The local (predicted or host-reported) cursor in compact-desktop points.
public final class CursorStore: @unchecked Sendable {
    // Invariant for @unchecked Sendable: `current` is only read or written while holding `lock`.
    public struct Snapshot: Equatable, Sendable {
        public var point: LogicalPoint?
        /// False in Pan mode, without a selection, or while not connected.
        public var isVisible: Bool
        public var version: UInt64
    }

    private let lock = NSLock()
    private var current = Snapshot(point: nil, isVisible: false, version: 0)

    public init() {}

    public var snapshot: Snapshot { lock.withLock { current } }
    /// The point to draw, or nil when the cursor is hidden or unknown.
    public var visiblePoint: LogicalPoint? {
        lock.withLock { current.isVisible ? current.point : nil }
    }

    func set(_ point: LogicalPoint?) {
        lock.withLock {
            guard point != current.point else { return }
            current.point = point
            current.version &+= 1
        }
    }

    func setVisible(_ visible: Bool) {
        lock.withLock {
            guard visible != current.isVisible else { return }
            current.isVisible = visible
            current.version &+= 1
        }
    }
}
