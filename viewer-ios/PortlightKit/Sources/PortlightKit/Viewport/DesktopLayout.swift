import Foundation

/// Places host displays in the viewer's desktop space: host logical points, union origin at (0, 0).
///
/// A faithful port of the Mac viewer's `displayLayout(_:compact:)` (viewer-macos DisplayLayout.swift),
/// so both viewers agree on geometry. Layout depends only on logical frames — pixel resolution is
/// image detail — which is why a 5K Retina and a 1080p display with the same logical size draw at the
/// same size. Compaction changes only the viewer's arrangement, never the host's.
public enum DesktopLayout {
    /// Frames for the `selected` displays, in `displays` order.
    ///
    /// - `compact: false` keeps the real arrangement (the display selector map; pass every ID).
    /// - `compact: true` removes empty horizontal then vertical bands between the selected displays
    ///   (content layout), so 1+3 without 2 become adjacent and a drag crosses without a dead zone.
    ///
    /// Unknown selected IDs are ignored, the first of any duplicate display ID wins, and a display
    /// whose logical frame is non-finite or has no area is left out rather than poisoning the union.
    public static func arrange(_ displays: [HostDisplay], selected: [DisplayID], compact: Bool) -> [DisplayID: LogicalRect] {
        let wanted = Set(selected)
        var seen = Set<DisplayID>()
        var ids: [DisplayID] = []
        var frames: [LogicalRect] = []
        for display in displays where wanted.contains(display.id) && seen.insert(display.id).inserted {
            let frame = display.logicalFrame
            guard frame.x.isFinite, frame.y.isFinite, frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0 else { continue }
            ids.append(display.id)
            frames.append(frame)
        }
        guard let first = frames.first else { return [:] }
        if compact {
            let horizontal = gaps(frames.map { Interval(start: $0.minX, end: $0.maxX) })
            let vertical = gaps(frames.map { Interval(start: $0.minY, end: $0.maxY) })
            frames = frames.map { rect in
                rect.offsetBy(dx: -removedLength(horizontal, before: rect.minX),
                              dy: -removedLength(vertical, before: rect.minY))
            }
        }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        var result: [DisplayID: LogicalRect] = [:]
        for (id, frame) in zip(ids, frames) {
            result[id] = frame.offsetBy(dx: -union.minX, dy: -union.minY)
        }
        return result
    }

    struct Interval: Equatable {
        var start: Double
        var end: Double
    }

    /// Empty bands between merged intervals. A gap exists only where the next start lies beyond
    /// everything seen so far, so touching or overlapping bands are never gaps.
    static func gaps(_ intervals: [Interval]) -> [Interval] {
        // Sorting on (start, end) makes the result independent of input order.
        let sorted = intervals.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        guard var end = sorted.first?.end else { return [] }
        var result: [Interval] = []
        for interval in sorted.dropFirst() {
            if interval.start > end { result.append(Interval(start: end, end: interval.start)) }
            end = max(end, interval.end)
        }
        return result
    }

    /// Total length of the gaps lying wholly before `coordinate` (the shift a rect starting there gets).
    static func removedLength(_ gaps: [Interval], before coordinate: Double) -> Double {
        var total = 0.0
        for gap in gaps where gap.end <= coordinate { total += gap.end - gap.start }
        return total
    }
}
