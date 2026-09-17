import Testing
@testable import PortlightKit

/// Layout vectors shared with the Mac and Windows viewers (host.md §6.A, viewer-macos main.swift).
@Suite("Viewport · DesktopLayout")
struct ViewportDesktopLayoutTests {
    private typealias Spec = (id: DisplayID, x: Double, y: Double, w: Double, h: Double)

    private func displays(_ specs: [Spec]) -> [HostDisplay] {
        specs.enumerated().map { ViewportFixtures.display($1.id, $1.x, $1.y, $1.w, $1.h, number: $0 + 1) }
    }

    private func arrange(_ specs: [Spec], compact: Bool) -> [DisplayID: LogicalRect] {
        let list = displays(specs)
        return DesktopLayout.arrange(list, selected: list.map(\.id), compact: compact)
    }

    private func bounds(_ layout: [DisplayID: LogicalRect]) -> LogicalRect? {
        guard let first = layout.values.first else { return nil }
        return layout.values.reduce(first) { $0.union($1) }
    }

    private let row: [Spec] = [("1", 0, 0, 1920, 1080), ("2", 1920, 0, 1920, 1080), ("3", 3840, 0, 1920, 1080)]

    @Test func threeHorizontalDisplaysSpanTheirFullWidth() {
        let layout = arrange(row, compact: true)
        #expect(bounds(layout)?.width == 5760)
        #expect(layout["2"]?.x == 1920 && layout["3"]?.x == 3840)
    }

    @Test func onePlusThreeCompactsThreeBesideOne() {
        let layout = arrange([row[0], row[2]], compact: true)
        #expect(layout["3"]?.x == 1920)
        #expect(bounds(layout)?.width == 3840)
        #expect(layout["1"]?.maxX == layout["3"]?.minX)
    }

    @Test func realArrangementKeepsTheHiddenDisplaysGap() {
        let layout = arrange([row[0], row[2]], compact: false)
        #expect(layout["3"]?.x == 3840)
        #expect(bounds(layout)?.width == 5760)
    }

    @Test func negativeOriginsAndPortraitDisplay() {
        let layout = arrange([("retina", -1440, 0, 1440, 900), ("portrait", 0, -300, 1080, 1920)], compact: true)
        #expect(layout["retina"] == LogicalRect(x: 0, y: 300, width: 1440, height: 900))
        #expect(layout["portrait"]?.x == 1440 && layout["portrait"]?.y == 0)
        #expect(bounds(layout) == LogicalRect(x: 0, y: 0, width: 2520, height: 1920))
    }

    @Test func verticalStackRemovesTheEmptyBand() {
        let layout = arrange([("top", 0, -2160, 1920, 1080), ("bottom", 0, 0, 1920, 1080)], compact: true)
        #expect(layout["top"]?.y == 0)
        #expect(layout["bottom"]?.y == 1080)
    }

    @Test func touchingOrOverlappingBandsAreNotGaps() {
        let layout = arrange([("a", 0, 0, 1920, 1080), ("b", 1800, 1080, 1920, 1080)], compact: true)
        #expect(layout["b"]?.x == 1800)
        #expect(layout["b"]?.y == 1080)
    }

    @Test func emptyInputAndEmptySelectionGiveEmptyLayouts() {
        #expect(DesktopLayout.arrange([], selected: [], compact: true).isEmpty)
        #expect(DesktopLayout.arrange(displays(row), selected: [], compact: false).isEmpty)
    }

    @Test func macViewerSelfTestVectors() {
        var monitors: [HostDisplay] = []
        for i in 0..<3 {
            let x = Double(i * 1920 - 1920)
            let scale: Double = i == 1 ? 1 : 2
            monitors.append(ViewportFixtures.display(String(i), x, 0, 1920, 1080, scale: scale, number: i + 1))
        }
        let full = DesktopLayout.arrange(monitors, selected: ["0", "1", "2"], compact: false)
        let compact = DesktopLayout.arrange(monitors, selected: ["0", "2"], compact: true)
        #expect(full["0"]?.width == full["1"]?.width, "Mixed Retina and standard displays use equal logical sizes")
        #expect(full["2"]?.minX == 3840 && compact["2"]?.minX == 1920, "Hidden middle display removed only from the viewing layout")
        #expect(compact["0"]?.maxX == compact["2"]?.minX, "Compacted screens meet without a dead drag zone")
        let stacked = ViewportFixtures.display("stack", 0, -1920, 1080, 1920, scale: 2, number: 4)
        let topology = DesktopLayout.arrange([monitors[1], stacked], selected: ["1", "stack"], compact: false)
        #expect(topology["stack"]?.minY == 0, "Negative vertical arrangement preserves the host topology")
        #expect(topology["1"]?.minY == 1920)
    }

    @Test func unknownDuplicateAndInvalidEntriesAreIgnored() {
        var list = displays(row)
        list.append(ViewportFixtures.display("1", 9000, 9000, 10, 10))                 // duplicate ID: first wins
        list.append(ViewportFixtures.display("nan", .nan, 0, 1920, 1080))              // non-finite frame
        list.append(ViewportFixtures.display("flat", 0, 0, 0, 1080))                   // no area
        let layout = DesktopLayout.arrange(list, selected: ["1", "3", "ghost", "3", "nan", "flat"], compact: true)
        #expect(Set(layout.keys) == ["1", "3"])
        #expect(layout["1"] == LogicalRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(layout["3"] == LogicalRect(x: 1920, y: 0, width: 1920, height: 1080))
    }

    /// host.md §6.A vector 8: 10,000 random layouts of six displays, x ∈ [−6000, 6000), y ∈ [−4000, 4000),
    /// w ∈ 400 + [0, 3000), h ∈ 300 + [0, 2000). Ten fixed-seed chunks of 1,000 run in parallel; plain checks
    /// (not a per-iteration #expect) keep the unoptimized test build fast.
    @Test(arguments: 0..<10)
    func tenThousandRandomLayoutsKeepInvariants(chunk: Int) {
        var rng = ViewportSplitMix64(seed: 472 &+ UInt64(chunk))
        let ids = (0..<6).map { String($0) }
        var frames = [LogicalRect](repeating: LogicalRect(x: 0, y: 0, width: 1, height: 1), count: 6)
        for run in 0..<1_000 {
            var list: [HostDisplay] = []
            list.reserveCapacity(6)
            for i in 0..<6 {
                let x = Double(rng.below(12_000) - 6_000)
                let y = Double(rng.below(8_000) - 4_000)
                let w = Double(400 + rng.below(3_000))
                let h = Double(300 + rng.below(2_000))
                frames[i] = LogicalRect(x: x, y: y, width: w, height: h)
                list.append(HostDisplay(id: ids[i], name: ids[i], number: i + 1, nativeSize: PixelSize(width: Int(w), height: Int(h)),
                                        logicalFrame: frames[i], scale: 1, isPrimary: i == 0))
            }
            let compact = DesktopLayout.arrange(list, selected: ids, compact: true)
            let real = DesktopLayout.arrange(list, selected: ids, compact: false)
            if let problem = Self.layoutProblem(frames: frames, ids: ids, compact: compact, real: real) {
                Issue.record("chunk \(chunk) run \(run): \(problem) — \(frames)")
                return
            }
        }
    }

    /// The first violated layout invariant, or nil.
    private static func layoutProblem(frames: [LogicalRect], ids: [DisplayID],
                                      compact: [DisplayID: LogicalRect], real: [DisplayID: LogicalRect]) -> String? {
        var originX = Double.infinity, originY = Double.infinity
        for frame in frames { originX = min(originX, frame.x); originY = min(originY, frame.y) }
        var placed: [LogicalRect] = []
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var realMaxX = -Double.infinity, realMaxY = -Double.infinity
        for (i, id) in ids.enumerated() {
            guard let r = compact[id], let m = real[id] else { return "missing \(id)" }
            if r.width != frames[i].width || r.height != frames[i].height { return "size changed for \(id)" }
            if m != frames[i].offsetBy(dx: -originX, dy: -originY) { return "real arrangement is not a translation for \(id)" }
            placed.append(r)
            minX = min(minX, r.minX); minY = min(minY, r.minY); maxX = max(maxX, r.maxX); maxY = max(maxY, r.maxY)
            realMaxX = max(realMaxX, m.maxX); realMaxY = max(realMaxY, m.maxY)
        }
        // Union origin at (0, 0) means every rect lies within [0, bounds].
        if minX != 0 || minY != 0 { return "compact union origin is not (0, 0)" }
        if maxX > realMaxX || maxY > realMaxY { return "compaction grew the desktop" }
        if !DesktopLayout.gaps(placed.map { .init(start: $0.minX, end: $0.maxX) }).isEmpty { return "horizontal gap left" }
        if !DesktopLayout.gaps(placed.map { .init(start: $0.minY, end: $0.maxY) }).isEmpty { return "vertical gap left" }
        for a in 0..<frames.count {
            for b in 0..<frames.count {
                if frames[a].x < frames[b].x && placed[a].x > placed[b].x { return "horizontal order changed" }
                if frames[a].y < frames[b].y && placed[a].y > placed[b].y { return "vertical order changed" }
            }
        }
        return nil
    }
}
