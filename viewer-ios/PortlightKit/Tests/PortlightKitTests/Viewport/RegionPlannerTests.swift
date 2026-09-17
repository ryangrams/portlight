import Testing
@testable import PortlightKit

@Suite("Viewport · RegionPlanner")
struct ViewportRegionPlannerTests {
    /// Displays 1 and 3 compacted side by side.
    private let layout: [DisplayID: LogicalRect] = [
        "1": LogicalRect(x: 0, y: 0, width: 1920, height: 1080),
        "3": LogicalRect(x: 1920, y: 0, width: 1920, height: 1080),
    ]
    private let middle = LogicalRect(x: 480, y: 270, width: 960, height: 540)

    private func exact(_ visible: LogicalRect) -> [DisplayID: NormalizedRect] {
        RegionPlanner.regions(layout: layout, visibleDesktop: visible, marginFraction: 0, grid: 0)
    }

    private func planned(_ visible: LogicalRect) -> [DisplayID: NormalizedRect] {
        RegionPlanner.regions(layout: layout, visibleDesktop: visible)
    }

    private func refine(_ current: [DisplayID: NormalizedRect], _ visible: LogicalRect) -> Bool {
        let explicit = RegionPlanner.needsRefinement(current: current, visibleNow: exact(visible), planned: planned(visible))
        #expect(explicit == RegionPlanner.needsRefinement(current: current, layout: layout, visibleDesktop: visible))
        return explicit
    }

    @Test func fullyVisibleDisplaysAreFull() {
        #expect(planned(LogicalRect(x: -100, y: -100, width: 4040, height: 1280)) == ["1": .full, "3": .full])
        #expect(exact(LogicalRect(x: 0, y: 0, width: 3840, height: 1080)) == ["1": .full, "3": .full])
    }

    @Test func marginIsAddedAndSnappedOutward() {
        #expect(exact(middle)["1"] == NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        // 10% of 960×540 each side → 0.2…0.8, snapped outward to 1/64 → 12/64…52/64.
        #expect(planned(middle)["1"] == NormalizedRect(x: 0.1875, y: 0.1875, width: 0.625, height: 0.625))
        #expect(planned(middle)["3"] == .zero)
    }

    @Test func marginReachesIntoTheNeighbour() {
        let nearEdge = LogicalRect(x: 1000, y: 270, width: 900, height: 540)
        #expect(exact(nearEdge)["3"] == .zero)
        // Grown rect ends at 1990: 70 pt into display 3 → 0.036, snapped up to 3/64.
        #expect(planned(nearEdge)["3"] == NormalizedRect(x: 0, y: 0.1875, width: 3.0 / 64, height: 0.625))
    }

    @Test func regionsAreClampedAtTheFarEdges() throws {
        let corner = LogicalRect(x: 3700, y: 1000, width: 400, height: 300)
        let region = try #require(planned(corner)["3"])
        #expect(region.isValid && region.x + region.width == 1 && region.y + region.height == 1)
        // A non-dyadic grid must still honour x+w ≤ 1 exactly.
        for grid in [0.1, 0.3, 1.0 / 3, 0.07] {
            for (_, rect) in RegionPlanner.regions(layout: layout, visibleDesktop: corner, grid: grid) {
                #expect(rect.isValid && rect.x + rect.width <= 1 && rect.y + rect.height <= 1, "grid \(grid): \(rect)")
            }
        }
    }

    @Test func unusableVisibleRectNeverHidesPixels() {
        #expect(planned(LogicalRect(x: .nan, y: 0, width: 10, height: 10)) == ["1": .full, "3": .full])
        #expect(planned(LogicalRect(x: 0, y: 0, width: 0, height: 10)) == ["1": .full, "3": .full])
    }

    @Test func refinementDecisions() {
        // Fresh subscription streams everything; zooming into display 1 is worth refining.
        #expect(refine([:], middle))
        let adopted = planned(middle)
        #expect(!refine(adopted, middle))
        // A pan inside the margin keeps the subscription; one past it refines.
        #expect(!refine(adopted, middle.offsetBy(dx: 48, dy: 27)))
        #expect(refine(adopted, middle.offsetBy(dx: 144, dy: 0)))
        // A small zoom-in stays; a 2× zoom-in over-covers by more than 2.5× in area.
        #expect(!refine(adopted, LogicalRect(x: 576, y: 324, width: 768, height: 432)))
        #expect(refine(adopted, LogicalRect(x: 720, y: 405, width: 480, height: 270)))
        // Zooming out past the margin escapes.
        #expect(refine(adopted, LogicalRect(x: 240, y: 135, width: 1440, height: 810)))
        // A hidden display still streamed in full refines; an explicit zero does not.
        #expect(refine(["1": adopted["1"]!], middle))
        #expect(!refine(["1": adopted["1"]!, "3": .zero], middle))
        // A visible display whose current region is zero refines.
        #expect(refine(["1": .zero, "3": .zero], middle))
    }

    @Test func randomPlansAreValidCoverTheViewAndNeverLoop() {
        var rng = ViewportSplitMix64(seed: 2026_09_10)
        for run in 0..<2_000 {
            var displays: [HostDisplay] = []
            let count = 1 + rng.below(4)
            for i in 0..<count {
                let x = Double(rng.below(8_000) - 4_000)
                let y = Double(rng.below(4_000) - 2_000)
                let w = Double(400 + rng.below(3_000))
                let h = Double(300 + rng.below(2_000))
                displays.append(ViewportFixtures.display("d\(i)", x, y, w, h))
            }
            let layout = DesktopLayout.arrange(displays, selected: displays.map(\.id), compact: true)
            let vx = Double(rng.below(9_000) - 1_500)
            let vy = Double(rng.below(5_000) - 1_000)
            let vw = Double(20 + rng.below(4_000))
            let vh = Double(20 + rng.below(3_000))
            let visible = LogicalRect(x: vx, y: vy, width: vw, height: vh)
            let need = RegionPlanner.regions(layout: layout, visibleDesktop: visible, marginFraction: 0, grid: 0)
            let plan = RegionPlanner.regions(layout: layout, visibleDesktop: visible)
            for (id, region) in plan {
                let exactRegion = need[id]!
                if !(region.isValid && exactRegion.isValid) { Issue.record("run \(run) invalid \(id): \(region) / \(exactRegion)"); return }
                if !exactRegion.isZero && !RegionPlanner.contains(region, exactRegion) {
                    Issue.record("run \(run): plan \(region) misses visible \(exactRegion)"); return
                }
            }
            if RegionPlanner.needsRefinement(current: plan, visibleNow: need, planned: plan) {
                Issue.record("run \(run): adopting the plan still asks for refinement"); return
            }
        }
    }

    @Test func settledViewportScenario() throws {
        var model = ViewportFixtures.model(ViewportFixtures.row, selected: ["1", "3"])
        model.pinch(factor: 3 / model.transform.scale, centroid: model.usableRect.center)
        let visible = try #require(model.visibleDesktopRect)
        #expect(RegionPlanner.needsRefinement(current: [:], layout: model.layout, visibleDesktop: visible))
        let current = RegionPlanner.regions(layout: model.layout, visibleDesktop: visible)
        #expect(current["1"]?.isZero == false && current["3"]?.isZero == false)  // centered on the 1|3 boundary
        model.pan(dx: 30, dy: -20)  // 10 × 7 pt: well inside the margin
        #expect(!RegionPlanner.needsRefinement(current: current, layout: model.layout, visibleDesktop: try #require(model.visibleDesktopRect)))
        model.pan(dx: -600, dy: 0)  // 200 pt: past the margin
        #expect(RegionPlanner.needsRefinement(current: current, layout: model.layout, visibleDesktop: try #require(model.visibleDesktopRect)))
    }
}
