import Foundation

/// Chooses the per-display `regions` a subscription asks the host to stream, and decides when the
/// view has changed enough to be worth asking again.
///
/// Every accepted subscription restarts capture, resets encoders and releases held input on the
/// current host, so regions are planned with a margin and snapped outward to a coarse grid: small
/// pans stay inside what the host already sends and never cost a resubscribe. The scheduler (not
/// this type) decides *when* to send — after a gesture settles and never while input is held.
public enum RegionPlanner {
    public static let defaultMarginFraction = 0.1
    public static let defaultGrid = 1.0 / 64
    /// Current area may exceed the planned area by this factor before a zoom-in is worth a restart.
    static let overCoverageFactor = 2.5
    /// Slack for comparing normalized edges computed along different arithmetic paths.
    static let containmentTolerance = 1e-9

    /// Normalized full-display regions for every display in `layout`.
    ///
    /// Per display: (`visibleDesktop` grown by `marginFraction` × its size on every side) ∩ the
    /// display, normalized, snapped outward to `grid` and clamped so x+w ≤ 1 and y+h ≤ 1. A fully
    /// covered display gets `.full`; one the grown rect misses gets the explicit `.zero` the host
    /// needs for an offscreen selected display. `marginFraction: 0, grid: 0` gives the exact visible
    /// regions. An unusable `visibleDesktop` (non-finite or no area) yields `.full` everywhere: bad
    /// geometry must never hide pixels.
    public static func regions(layout: [DisplayID: LogicalRect], visibleDesktop visible: LogicalRect,
                               marginFraction: Double = defaultMarginFraction,
                               grid: Double = defaultGrid) -> [DisplayID: NormalizedRect] {
        let usable = [visible.x, visible.y, visible.width, visible.height].allSatisfy { $0.isFinite }
            && visible.width > 0 && visible.height > 0
        guard usable else { return layout.mapValues { _ in .full } }
        let margin = marginFraction.isFinite && marginFraction > 0 ? marginFraction : 0
        let cell = grid.isFinite && grid > 0 && grid <= 1 ? grid : 0
        let grown = LogicalRect(x: visible.x - margin * visible.width, y: visible.y - margin * visible.height,
                                width: visible.width * (1 + 2 * margin), height: visible.height * (1 + 2 * margin))
        return layout.mapValues { region(of: $0, within: grown, grid: cell) }
    }

    /// Whether the host's current regions no longer suit the view.
    ///
    /// - `current`: what the host is streaming (a missing key means the whole display).
    /// - `visibleNow`: exact visible regions (`regions(…, marginFraction: 0, grid: 0)`) for every
    ///   selected display.
    /// - `planned`: what `regions(…)` would request now.
    ///
    /// True when visible area escapes its current region, when a visible display's current region
    /// exceeds the planned one by more than 2.5× in area (a zoom-in), or when a hidden display is
    /// still streamed in full. Over-coverage is judged against `planned`, not the raw visible area,
    /// so the planner's own margin and snapping can never trigger a refinement: adopting `planned`
    /// always makes this false, and there is no resubscribe loop.
    public static func needsRefinement(current: [DisplayID: NormalizedRect],
                                       visibleNow: [DisplayID: NormalizedRect],
                                       planned: [DisplayID: NormalizedRect]) -> Bool {
        for (id, need) in visibleNow {
            let have = current[id] ?? .full
            let want = planned[id] ?? .full
            if need.isZero || need.width <= 0 || need.height <= 0 {
                // Hidden. A leftover margin strip is cheap; a display still streaming in full is not.
                if have.isFull && !want.isFull { return true }
                continue
            }
            if !contains(have, need) { return true }
            if area(have) > overCoverageFactor * area(want) { return true }
        }
        return false
    }

    /// Convenience: plans `visibleNow` and `planned` from the layout and visible desktop rect.
    public static func needsRefinement(current: [DisplayID: NormalizedRect], layout: [DisplayID: LogicalRect],
                                       visibleDesktop: LogicalRect,
                                       marginFraction: Double = defaultMarginFraction,
                                       grid: Double = defaultGrid) -> Bool {
        needsRefinement(current: current,
                        visibleNow: regions(layout: layout, visibleDesktop: visibleDesktop, marginFraction: 0, grid: 0),
                        planned: regions(layout: layout, visibleDesktop: visibleDesktop,
                                         marginFraction: marginFraction, grid: grid))
    }

    // MARK: - Internals

    static func region(of display: LogicalRect, within visible: LogicalRect, grid: Double) -> NormalizedRect {
        guard !display.isEmpty, let overlap = display.intersection(visible) else { return .zero }
        // Containment is tested on edges; the overlap's own width can differ from the display's by rounding.
        if visible.minX <= display.minX && visible.maxX >= display.maxX
            && visible.minY <= display.minY && visible.maxY >= display.maxY { return .full }
        let (x, width) = span(overlap.minX, overlap.maxX, origin: display.minX, extent: display.width, grid: grid)
        let (y, height) = span(overlap.minY, overlap.maxY, origin: display.minY, extent: display.height, grid: grid)
        // A sliver that rounds away on either axis is not visible; width and height must be zero together.
        guard width > 0, height > 0 else { return .zero }
        let rect = NormalizedRect(x: x, y: y, width: width, height: height)
        return rect.isFull ? .full : rect
    }

    /// One axis of a region: normalized, snapped outward to `grid` (0 = exact), within [0, 1].
    static func span(_ low: Double, _ high: Double, origin: Double, extent: Double, grid: Double) -> (Double, Double) {
        var start = (low - origin) / extent
        var end = (high - origin) / extent
        if grid > 0 {
            start = (start / grid).rounded(.down) * grid
            end = (end / grid).rounded(.up) * grid
        }
        start = min(max(start, 0), 1)
        end = min(max(end, start), 1)
        var length = end - start
        // Host contract is x+w ≤ 1 exactly; a non-dyadic grid can round the sum just past it.
        while length > 0 && start + length > 1 { length = length.nextDown }
        return (start, length)
    }

    static func contains(_ outer: NormalizedRect, _ inner: NormalizedRect) -> Bool {
        guard !outer.isZero else { return false }
        let slack = containmentTolerance
        return inner.x >= outer.x - slack && inner.y >= outer.y - slack
            && inner.x + inner.width <= outer.x + outer.width + slack
            && inner.y + inner.height <= outer.y + outer.height + slack
    }

    static func area(_ rect: NormalizedRect) -> Double { rect.width * rect.height }
}
