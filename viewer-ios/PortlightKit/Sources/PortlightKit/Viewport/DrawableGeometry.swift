import Foundation

// Drawable pixels: the session surface's Metal drawable grid, top-left origin, y down. Kept as their
// own types so a drawable pixel can never be passed where a host logical point or stream pixel is
// expected. View points (UIKit) become drawable pixels exactly once: `viewPoint × contentScale`.

/// A point in drawable pixels of the session surface.
public struct DrawablePoint: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    var isFinite: Bool { x.isFinite && y.isFinite }
}

/// A rectangle in drawable pixels, e.g. the safe-area rect the picture is fitted into.
public struct DrawableRect: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    /// The whole drawable (negative sizes treated as empty).
    public init(size: PixelSize) {
        self.init(x: 0, y: 0, width: Double(max(0, size.width)), height: Double(max(0, size.height)))
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: DrawablePoint { DrawablePoint(x: midX, y: midY) }
    public var isEmpty: Bool { !(width > 0 && height > 0) }

    var isFinite: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite }

    func intersection(_ other: DrawableRect) -> DrawableRect? {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return DrawableRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
