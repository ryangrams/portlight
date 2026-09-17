import Testing
@testable import PortlightKit

@Suite("CoverageGrid")
struct CoverageGridTests {
    private let canvas = PixelSize(width: 1280, height: 720)

    /// The host's diff tiles: a 256 grid anchored at the canvas origin, clipped, row-major.
    private func hostTiles(_ canvas: PixelSize) -> [PixelRect] {
        stride(from: 0, to: canvas.height, by: 256).flatMap { y in
            stride(from: 0, to: canvas.width, by: 256).map { x in
                PixelRect(x: x, y: y, width: min(256, canvas.width - x), height: min(256, canvas.height - y))
            }
        }
    }

    @Test func freshGridHasNothingValid() {
        let grid = CoverageGrid(canvas: canvas)
        #expect(grid.requestedPixels == PixelRect(x: 0, y: 0, width: 1280, height: 720))
        #expect(grid.requestedCellCount == 80 * 45)
        #expect(grid.validCellCount == 0)
        #expect(!grid.isCovered)
        #expect(!grid.isValid(normalizedX: 0.5, y: 0.5))
    }

    @Test func partialFirstFrameIsNotCoveredUntilEveryTileArrives() {
        var grid = CoverageGrid(canvas: canvas)
        let tiles = hostTiles(canvas)
        for tile in tiles.dropLast() { grid.markPainted(tile) }
        #expect(!grid.isCovered)
        #expect(grid.isValid(normalizedX: 0.01, y: 0.01))
        #expect(!grid.isValid(normalizedX: 0.99, y: 0.99)) // last tile (1024,512) still missing
        grid.markPainted(tiles.last!)
        #expect(grid.isCovered)
        #expect(grid.validCellCount == grid.requestedCellCount)
    }

    @Test func aCellNeedsOnePatchCoveringItsWholeIntersection() {
        var grid = CoverageGrid(canvas: canvas)
        grid.markPainted(PixelRect(x: 0, y: 0, width: 15, height: 16))
        grid.markPainted(PixelRect(x: 8, y: 16, width: 16, height: 16)) // straddles two cells, covers neither
        #expect(grid.validCellCount == 0)
        grid.markPainted(PixelRect(x: 0, y: 0, width: 16, height: 16))
        #expect(grid.validCellCount == 1)
        #expect(grid.isValid(normalizedX: 15.5 / 1280, y: 15.5 / 720))
        #expect(!grid.isValid(normalizedX: 16.5 / 1280, y: 15.5 / 720))
    }

    @Test func requestedRegionFollowsHostRoundingAndBoundaryCellsCount() {
        var grid = CoverageGrid(canvas: canvas, requestedRegion: NormalizedRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25))
        #expect(grid.requestedPixels == PixelRect(x: 320, y: 180, width: 320, height: 180)) // host e2e step 8
        // y 180 and 360 are not multiples of 16: boundary cells only need their part inside the region.
        grid.markPainted(PixelRect(x: 320, y: 180, width: 320, height: 180))
        #expect(grid.isCovered)
        #expect(grid.isValid(normalizedX: 0.3, y: 0.3))
        #expect(!grid.isValid(normalizedX: 0.2499, y: 0.3)) // pixel 319: outside the region, not maintained
        #expect(!grid.isValid(normalizedX: 0.1, y: 0.1))

        let odd = CoverageGrid(canvas: PixelSize(width: 1000, height: 563), requestedRegion: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        #expect(odd.requestedPixels == PixelRect(x: 100, y: 56, width: 300, height: 170)) // floor 56.3, ceil 225.2
    }

    @Test func shrinkingKeepsValidCellsAndGrowingExposesInvalidOnes() {
        var grid = CoverageGrid(canvas: canvas)
        grid.markPainted(PixelRect(x: 0, y: 0, width: 640, height: 720))
        #expect(grid.validCellCount == 40 * 45)
        grid.setRequestedRegion(NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(grid.isCovered)
        grid.setRequestedRegion(.full)
        #expect(!grid.isCovered)
        #expect(grid.validCellCount == 40 * 45)
        #expect(!grid.isValid(normalizedX: 0.75, y: 0.5))
        // Cells that leave the region stop being maintained and do not come back valid.
        grid.setRequestedRegion(NormalizedRect(x: 0, y: 0, width: 0.25, height: 1))
        #expect(grid.validCellCount == 20 * 45)
        grid.setRequestedRegion(NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(grid.validCellCount == 20 * 45)
        #expect(!grid.isValid(normalizedX: 0.4, y: 0.5))
    }

    @Test func aBoundaryCellWhoseRequiredAreaGrowsBecomesInvalid() {
        var grid = CoverageGrid(canvas: PixelSize(width: 1000, height: 64), requestedRegion: NormalizedRect(x: 0, y: 0, width: 0.2, height: 1))
        grid.markPainted(PixelRect(x: 0, y: 0, width: 200, height: 64)) // cell column 12 spans 192..<208; only 192..<200 required
        #expect(grid.isCovered)
        grid.setRequestedRegion(NormalizedRect(x: 0, y: 0, width: 0.25, height: 1))
        #expect(!grid.isValid(normalizedX: 195.0 / 1000, y: 0.5)) // 200..<208 was never painted
        #expect(grid.isValid(normalizedX: 150.0 / 1000, y: 0.5))
    }

    @Test func zeroRegionIsNeverCoveredOrValid() {
        var grid = CoverageGrid(canvas: canvas, requestedRegion: .zero)
        grid.markPainted(PixelRect(x: 0, y: 0, width: 1280, height: 720))
        #expect(grid.requestedPixels == nil)
        #expect(grid.requestedCellCount == 0)
        #expect(grid.validCellCount == 0)
        #expect(!grid.isCovered)
        #expect(!grid.isValid(normalizedX: 0.5, y: 0.5))
    }

    @Test func pointsUseHalfOpenBounds() {
        var grid = CoverageGrid(canvas: canvas)
        grid.markPainted(PixelRect(x: 0, y: 0, width: 1280, height: 720))
        #expect(grid.isValid(normalizedX: 0, y: 0))
        #expect(grid.isValid(normalizedX: 0.999_999, y: 0.999_999))
        for (x, y) in [(1.0, 0.5), (0.5, 1.0), (-0.0001, 0.5), (Double.nan, 0.5), (0.5, Double.infinity)] {
            #expect(!grid.isValid(normalizedX: x, y: y))
        }
    }

    @Test func invalidateAllAndCanvasEdgesNotMultipleOfSixteen() {
        var grid = CoverageGrid(canvas: PixelSize(width: 1000, height: 563)) // 63 × 36 cells, partial last column/row
        #expect(grid.requestedCellCount == 63 * 36)
        for tile in hostTiles(PixelSize(width: 1000, height: 563)) { grid.markPainted(tile) }
        #expect(grid.isCovered)
        #expect(grid.isValid(normalizedX: 0.9995, y: 0.9995))
        grid.invalidateAll()
        #expect(grid.validCellCount == 0)
        #expect(!grid.isCovered)
        grid.markPainted(PixelRect(x: 992, y: 560, width: 8, height: 3)) // the whole last cell
        #expect(grid.validCellCount == 1)
    }
}
