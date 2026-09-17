import Foundation

/// Which parts of one display's stream canvas hold pixels the viewer can trust, in 16×16-pixel cells.
///
/// A `frame` is a rectangle, not a video frame: a revision's first patch need not cover the display, so
/// completeness is tracked per cell for the region the viewer actually requested. A cell becomes valid when
/// one patch covers all of its intersection with canvas ∩ requested region. Host diff tiles sit on a
/// 256-pixel grid (a multiple of 16) and keyframes cover the whole visible area, so no host cell is ever
/// split between two patches. The grid gates remote input (`hasValidPixels`) and decides when a
/// replacement surface may be shown.
public struct CoverageGrid: Equatable, Sendable {
    public static let cellSize = 16

    public let canvas: PixelSize
    public private(set) var requestedRegion: NormalizedRect
    /// The requested region in canvas pixels, computed like the host (floor origin, ceil far edge, clipped
    /// to the canvas). Nil when nothing is requested (zero region or empty canvas).
    public private(set) var requestedPixels: PixelRect?
    /// Valid cells. Always inside the requested region: cells outside it are no longer maintained.
    public private(set) var validCellCount = 0

    private let columns: Int
    private let rows: Int
    private var cells: [Bool]

    public init(canvas: PixelSize, requestedRegion: NormalizedRect = .full) {
        self.canvas = canvas
        let usable = canvas.width > 0 && canvas.height > 0
        columns = usable ? (canvas.width + Self.cellSize - 1) / Self.cellSize : 0
        rows = usable ? (canvas.height + Self.cellSize - 1) / Self.cellSize : 0
        cells = [Bool](repeating: false, count: columns * rows)
        self.requestedRegion = requestedRegion
        requestedPixels = Self.pixelRect(for: requestedRegion, canvas: canvas)
    }

    /// Cells that intersect the requested region.
    public var requestedCellCount: Int {
        guard let region = requestedPixels else { return 0 }
        let span = Self.cellSpan(of: region)
        return (span.columns.count) * (span.rows.count)
    }

    /// True when something is requested and every requested cell is valid. A zero region is never covered:
    /// nothing in it could be shown, so it must not trigger a surface swap.
    public var isCovered: Bool {
        let requested = requestedCellCount
        return requested > 0 && validCellCount == requested
    }

    /// Records a committed patch (canvas pixels). Cells it covers completely within the requested region become valid.
    public mutating func markPainted(_ rect: PixelRect) {
        guard let region = requestedPixels, let area = Self.intersect(rect, region) else { return }
        let span = Self.cellSpan(of: area)
        for row in span.rows {
            for column in span.columns {
                let index = row * columns + column
                guard !cells[index], let target = Self.intersect(cellRect(column: column, row: row), region) else { continue }
                if Self.contains(rect, target) {
                    cells[index] = true
                    validCellCount += 1
                }
            }
        }
    }

    /// Changes the maintained region. Cells outside it stop being maintained (invalid); a cell stays valid only
    /// if everything it must now show was already required, and painted, under the old region.
    public mutating func setRequestedRegion(_ region: NormalizedRect) {
        let old = requestedPixels
        requestedRegion = region
        requestedPixels = Self.pixelRect(for: region, canvas: canvas)
        guard validCellCount > 0, let old else { return }
        let span = Self.cellSpan(of: old)
        for row in span.rows {
            for column in span.columns {
                let index = row * columns + column
                guard cells[index] else { continue }
                let cell = cellRect(column: column, row: row)
                let keep: Bool
                if let now = requestedPixels, let newTarget = Self.intersect(cell, now), let oldTarget = Self.intersect(cell, old) {
                    keep = Self.contains(oldTarget, newTarget)
                } else {
                    keep = false
                }
                if !keep {
                    cells[index] = false
                    validCellCount -= 1
                }
            }
        }
    }

    /// Forgets every valid cell (pixels kept by a frozen frame are no longer trusted for input).
    public mutating func invalidateAll() {
        guard validCellCount > 0 else { return }
        cells = [Bool](repeating: false, count: cells.count)
        validCellCount = 0
    }

    /// Forgets every cell `rect` (canvas pixels) touches: a patch that should have repainted them was lost, so what
    /// they show is no longer what the host believes. They become valid again once a later patch repaints them.
    public mutating func invalidate(_ rect: PixelRect) {
        guard validCellCount > 0, rect.fits(in: canvas), let region = requestedPixels, let area = Self.intersect(rect, region) else { return }
        let span = Self.cellSpan(of: area)
        for row in span.rows {
            for column in span.columns where cells[row * columns + column] {
                cells[row * columns + column] = false
                validCellCount -= 1
            }
        }
    }

    /// Whether the pixel under a normalized full-display point is valid. Half-open [0, 1); points outside the
    /// requested region are not maintained and therefore not valid.
    public func isValid(normalizedX x: Double, y: Double) -> Bool {
        guard let region = requestedPixels, x.isFinite, y.isFinite, x >= 0, x < 1, y >= 0, y < 1 else { return false }
        let px = min(canvas.width - 1, Int(x * Double(canvas.width)))
        let py = min(canvas.height - 1, Int(y * Double(canvas.height)))
        guard px >= region.x, px < region.maxX, py >= region.y, py < region.maxY else { return false }
        return cells[(py / Self.cellSize) * columns + px / Self.cellSize]
    }

    // MARK: - Geometry (private so it can't collide with other modules' PixelRect helpers)

    /// Host rule (`Capture.swift`): `CGRect(x·w, y·h, w·w, h·h) ∩ canvas`, then `.integral`.
    static func pixelRect(for region: NormalizedRect, canvas: PixelSize) -> PixelRect? {
        guard canvas.width > 0, canvas.height > 0,
              [region.x, region.y, region.width, region.height].allSatisfy({ $0.isFinite }),
              region.width > 0, region.height > 0 else { return nil }
        let w = Double(canvas.width), h = Double(canvas.height)
        let x0 = max(0, floor(region.x * w)), y0 = max(0, floor(region.y * h))
        let x1 = min(w, ceil(region.x * w + region.width * w)), y1 = min(h, ceil(region.y * h + region.height * h))
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: Int(x0), y: Int(y0), width: Int(x1 - x0), height: Int(y1 - y0))
    }

    private func cellRect(column: Int, row: Int) -> PixelRect {
        let x = column * Self.cellSize, y = row * Self.cellSize
        return PixelRect(x: x, y: y, width: min(Self.cellSize, canvas.width - x), height: min(Self.cellSize, canvas.height - y))
    }

    private static func cellSpan(of rect: PixelRect) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        ((rect.x / cellSize)...((rect.maxX - 1) / cellSize), (rect.y / cellSize)...((rect.maxY - 1) / cellSize))
    }

    private static func intersect(_ a: PixelRect, _ b: PixelRect) -> PixelRect? {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y), x1 = min(a.maxX, b.maxX), y1 = min(a.maxY, b.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func contains(_ outer: PixelRect, _ inner: PixelRect) -> Bool {
        outer.x <= inner.x && outer.y <= inner.y && outer.maxX >= inner.maxX && outer.maxY >= inner.maxY
    }
}
