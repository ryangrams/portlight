import Foundation

// Named conversions: view point → drawable pixel → (inverse transform) compact desktop point →
// display under it (half-open) → normalized full-display coordinate in [0, 1).

extension ViewportModel: PointerMapping {
    /// Keeps clamped points strictly inside a display so they normalize below 1.
    static let edgeInset = 1e-6

    public var viewPointsPerDesktopPoint: Double { transform.scale / contentScale }

    public func desktopPoint(atViewPoint x: Double, _ y: Double) -> LogicalPoint? {
        guard isReady, x.isFinite, y.isFinite else { return nil }
        return transform.toDesktop(x: x * contentScale, y: y * contentScale)
    }

    public func viewPoint(atDesktop point: LogicalPoint) -> (x: Double, y: Double) {
        let drawable = transform.toDrawable(point)
        return (drawable.x / contentScale, drawable.y / contentScale)
    }

    public func target(atDesktop point: LogicalPoint) -> PointerTarget? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        for (id, rect) in layout.sorted(by: { $0.key < $1.key }) where rect.contains(point) {
            return PointerTarget(display: id, x: Self.normalized(point.x - rect.minX, over: rect.width),
                                 y: Self.normalized(point.y - rect.minY, over: rect.height), desktop: point)
        }
        return nil
    }

    /// The point itself when it is on a display; otherwise the nearest point inside any display, inset
    /// by `edgeInset` from the far edges so it maps into [0, 1). A non-finite point maps to the center
    /// of the lowest-ID display; with nothing laid out the point is returned unchanged.
    public func clampToDisplays(_ point: LogicalPoint) -> LogicalPoint {
        let rects = layout.sorted(by: { $0.key < $1.key }).map(\.value)
        guard let first = rects.first else { return point }
        guard point.x.isFinite, point.y.isFinite else { return first.center }
        if target(atDesktop: point) != nil { return point }
        var best: (point: LogicalPoint, distance: Double)?
        for rect in rects {
            let x = min(max(point.x, rect.minX), max(rect.minX, rect.maxX - Self.edgeInset))
            let y = min(max(point.y, rect.minY), max(rect.minY, rect.maxY - Self.edgeInset))
            let distance = (x - point.x) * (x - point.x) + (y - point.y) * (y - point.y)
            if best == nil || distance < best!.distance { best = (LogicalPoint(x: x, y: y), distance) }
        }
        return best?.point ?? point
    }

    static func normalized(_ offset: Double, over extent: Double) -> Double {
        min(max(offset / extent, 0), 1.0.nextDown)
    }
}

extension ViewportModel {
    /// A UI point on the session surface in drawable pixels (gesture centroids, pan deltas).
    public func drawablePoint(atViewPoint x: Double, _ y: Double) -> DrawablePoint {
        DrawablePoint(x: x * contentScale, y: y * contentScale)
    }

    /// The remote target under a drawable pixel; nil in gaps, letterbox, or without geometry.
    public func target(atDrawable point: DrawablePoint) -> PointerTarget? {
        guard isReady, point.isFinite, let desktop = transform.toDesktop(x: point.x, y: point.y) else { return nil }
        return target(atDesktop: desktop)
    }

    /// The whole drawable (content is drawn full-bleed, under the insets too) in desktop points;
    /// the input to `RegionPlanner`. Nil without usable geometry.
    public var visibleDesktopRect: LogicalRect? {
        guard isReady,
              let topLeft = transform.toDesktop(x: 0, y: 0),
              let bottomRight = transform.toDesktop(x: Double(drawableSize.width), y: Double(drawableSize.height))
        else { return nil }
        return LogicalRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }

    /// Everything the renderer needs for one presentation; quads in display-ID order.
    public func scene(cursor: LogicalPoint? = nil, dimmed: Bool = false) -> RenderScene {
        RenderScene(transform: transform, drawableSize: drawableSize,
                    quads: layout.sorted(by: { $0.key < $1.key }).map { RenderScene.Quad(display: $0.key, frame: $0.value) },
                    cursor: cursor, dimmed: dimmed)
    }
}
