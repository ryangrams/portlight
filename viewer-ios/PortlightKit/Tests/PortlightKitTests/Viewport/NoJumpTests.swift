import Testing
@testable import PortlightKit

/// URC-style no-jump determinism (adapted from URC NoJumpTests.swift's scripted trajectory): the view
/// is a pure function of the gesture/geometry call sequence, bit for bit, and the desktop point under
/// the pinch centroid never slides — including when a pinch runs into the zoom limits.
@Suite("Viewport · no-jump determinism")
struct ViewportNoJumpTests {
    /// A 1920×1080 pt display at 2×, B at 1×, C 1440×900 pt offset down; A+C selected so B's band is compacted away.
    static let displays = [
        ViewportFixtures.display("A", 0, 0, 1920, 1080, scale: 2, number: 1),
        ViewportFixtures.display("B", 1920, 0, 1920, 1080, scale: 1, number: 2),
        ViewportFixtures.display("C", 3840, 180, 1440, 900, scale: 1, number: 3),
    ]
    static let contentScale = 3.0

    enum Step {
        case pinch(Double, DrawablePoint)
        case pan(Double, Double)
        case gesture(DrawablePoint, DrawablePoint, Double)
        case geometry(PixelSize, DrawableRect)
        case sameLayout
    }

    struct Sample: Equatable {
        var bits: [UInt64]
        var isFit: Bool
        var atMin: Bool
        var atMax: Bool
    }

    static func start() -> ViewportModel { ViewportFixtures.model(displays, selected: ["A", "C"]) }

    /// 240 steps. Zooms in for 40 steps, out for 40, repeatedly; 1.25/0.8 per pinch reaches both limits
    /// in every phase. Rotation and keyboard changes and redundant layout re-sends are mixed in.
    static func script() -> [Step] {
        (0..<240).map { i in
            let drift = Double(i % 37 - 18)
            let zoomingIn = (i / 40) % 2 == 0
            let factor = zoomingIn ? 1.25 : 0.8
            let cx: Double = (195 + 8 * drift) * contentScale
            let cy: Double = (422 - 16 * drift) * contentScale
            let centroid = DrawablePoint(x: cx, y: cy)
            switch i {
            case 100: return .geometry(ViewportFixtures.landscapeSize, ViewportFixtures.landscapeUsable)
            case 170: return .geometry(ViewportFixtures.portraitSize, ViewportFixtures.portraitUsable)
            case 200: return .geometry(ViewportFixtures.portraitSize, DrawableRect(x: 0, y: 141, width: 1170, height: 1100))
            case 215: return .geometry(ViewportFixtures.portraitSize, ViewportFixtures.portraitUsable)
            default: break
            }
            if i % 10 == 5 { return .sameLayout }
            switch i % 4 {
            case 0: return .pinch(factor, centroid)
            case 1: return .pan(2 * drift * contentScale, -drift * contentScale)
            case 2: return .gesture(centroid, DrawablePoint(x: centroid.x + drift * contentScale, y: centroid.y - drift * 1.5), factor)
            default: return .pan(-drift * contentScale, 3 * drift * contentScale)
            }
        }
    }

    static func apply(_ step: Step, to model: inout ViewportModel) {
        switch step {
        case let .pinch(factor, centroid): model.pinch(factor: factor, centroid: centroid)
        case let .pan(dx, dy): model.pan(dx: dx, dy: dy)
        case let .gesture(from, to, factor): model.gesture(from: from, to: to, factor: factor)
        case let .geometry(size, usable): model.setGeometry(drawableSize: size, usableRect: usable, contentScale: contentScale)
        case .sameLayout: model.setLayout(model.layout, hostScales: model.hostScales)
        }
    }

    static func sample(_ model: ViewportModel) -> Sample {
        Sample(bits: model.transform.viewportBits, isFit: model.isFit,
               atMin: model.transform.scale == model.minScale, atMax: model.transform.scale == model.maxScale)
    }

    static func run(interleaved: Bool) -> [Sample] {
        var model = start()
        var samples: [Sample] = []
        for step in script() {
            if interleaved { exerciseReadOnly(model) }
            apply(step, to: &model)
            if interleaved { exerciseReadOnly(model) }
            samples.append(sample(model))
        }
        return samples
    }

    /// Every read-only API, plus mutations of a copy. None of it may reach `model`.
    static func exerciseReadOnly(_ model: ViewportModel) {
        _ = model.target(atDrawable: DrawablePoint(x: 585, y: 1266))
        _ = model.desktopPoint(atViewPoint: 10, 20)
        _ = model.viewPoint(atDesktop: LogicalPoint(x: 100, y: 100))
        _ = model.clampToDisplays(LogicalPoint(x: -500, y: 9000))
        _ = model.scene(cursor: LogicalPoint(x: 1, y: 1), dimmed: true)
        _ = (model.fitScale, model.maxScale, model.desktopBounds, model.viewPointsPerDesktopPoint)
        if let visible = model.visibleDesktopRect {
            let planned = RegionPlanner.regions(layout: model.layout, visibleDesktop: visible)
            _ = RegionPlanner.needsRefinement(current: planned, layout: model.layout, visibleDesktop: visible)
        }
        var copy = model
        copy.pinch(factor: 1.7, centroid: DrawablePoint(x: 3, y: 4))
        copy.fit()
        copy.setLayout([:], hostScales: [:])
    }

    @Test func scriptedTrajectoryReplaysBitIdentically() {
        let reference = Self.run(interleaved: false)
        let replay = Self.run(interleaved: false)
        let interleaved = Self.run(interleaved: true)
        #expect(reference.count == 240)
        #expect(reference == replay)
        #expect(reference == interleaved)
        // Guards that the trajectory is worth comparing: it moves a lot and reaches both limits.
        #expect(reference.contains { $0.atMin } && reference.contains { $0.atMax })
        #expect(Set(reference.map { $0.bits[0] }).count > 20)
        #expect(Set(reference.map { $0.bits[1] }).count > 20)
        #expect(!reference.last!.isFit)
    }

    @Test func redundantLayoutResendsNeverMoveTheView() {
        var model = Self.start()
        var checked = 0
        for step in Self.script() {
            let before = model.transform.viewportBits
            Self.apply(step, to: &model)
            if case .sameLayout = step {
                #expect(model.transform.viewportBits == before)
                checked += 1
            }
        }
        #expect(checked > 20)
    }

    /// Whether an axis is free of the pan limits: content overflows the usable rect and its edge lies
    /// strictly inside the allowed range. Only then must the anchor be exact on that axis.
    static func freeAxes(_ m: ViewportModel) -> (x: Bool, y: Bool) {
        guard let b = m.desktopBounds else { return (false, false) }
        let s = m.transform.scale, u = m.usableRect
        let left = b.minX * s + m.transform.tx, top = b.minY * s + m.transform.ty
        let width = b.width * s, height = b.height * s
        let overflowX = width > u.width * (1 + 1e-9), overflowY = height > u.height * (1 + 1e-9)
        let insideX = left > u.maxX - width && left < u.minX
        let insideY = top > u.maxY - height && top < u.minY
        return (overflowX && insideX, overflowY && insideY)
    }

    @Test func pointUnderTheCentroidStaysPutThroughTheTrajectory() {
        var model = Self.start()
        var exact = 0, partialAtMax = 0, beyondMax = 0, beyondMin = 0
        for step in Self.script() {
            let before = model
            Self.apply(step, to: &model)
            let anchors: (DrawablePoint, DrawablePoint, Double)
            switch step {
            case let .pinch(factor, centroid): anchors = (centroid, centroid, factor)
            case let .gesture(from, to, factor): anchors = (from, to, factor)
            default: continue
            }
            let (start, end, factor) = anchors
            let was = before.transform.toDesktop(x: start.x, y: start.y)!
            let now = model.transform.toDesktop(x: end.x, y: end.y)!
            let free = Self.freeAxes(model)
            if free.x { #expect(viewportClose(now.x, was.x), "x drifted: \(was.x) → \(now.x)"); exact += 1 }
            if free.y { #expect(viewportClose(now.y, was.y), "y drifted: \(was.y) → \(now.y)"); exact += 1 }
            let atMax = model.transform.scale == model.maxScale
            if atMax && before.transform.scale < model.maxScale && (free.x || free.y) { partialAtMax += 1 }
            if case .pinch = step {
                if before.transform.scale == before.maxScale && factor > 1 {
                    #expect(model.transform.viewportBits == before.transform.viewportBits); beyondMax += 1
                }
                if before.transform.scale == before.minScale && factor < 1 {
                    #expect(model.transform.viewportBits == before.transform.viewportBits); beyondMin += 1
                }
            }
        }
        #expect(exact > 50 && partialAtMax > 0 && beyondMax > 0 && beyondMin > 0)
    }

    @Test func anchorHoldsWhenAPinchCrossesIntoEitherLimit() {
        var m = Self.start()
        let center = m.usableRect.center
        // Up to just below the ceiling, then a pinch whose raw factor overshoots it.
        m.pinch(factor: (m.maxScale / 1.1) / m.transform.scale, centroid: center)
        let a = DrawablePoint(x: center.x + 30, y: center.y - 40)
        let under = m.transform.toDesktop(x: a.x, y: a.y)!
        let previous = m.transform
        m.pinch(factor: 1.5, centroid: a)
        #expect(m.transform.scale == m.maxScale)
        let held = m.transform.toDesktop(x: a.x, y: a.y)!
        #expect(viewportClose(held.x, under.x) && viewportClose(held.y, under.y))
        // URC's raw-factor translation at the clamp would have slid the content by (a − t)(f − f_eff)/s.
        let naiveTx = a.x - (a.x - previous.tx) * 1.5
        #expect(abs((a.x - naiveTx) / m.maxScale - under.x) > 1)
        // From a centered view to just above the floor about the center, then a pinch that overshoots it.
        // (At the floor the content is centered, so only a centered anchor can be held there.)
        m.fit()
        m.pinch(factor: 1.05, centroid: center)
        let centered = m.transform.toDesktop(x: center.x, y: center.y)!
        m.pinch(factor: 0.5, centroid: center)
        #expect(m.transform.scale == m.minScale)
        let floor = m.transform.toDesktop(x: center.x, y: center.y)!
        #expect(viewportClose(floor.x, centered.x) && viewportClose(floor.y, centered.y))
    }

    @Test func bitComparisonIsStricterThanAnEpsilon() {
        let t = Self.start().transform
        let nudged = ViewportTransform(scale: t.scale.nextUp, tx: t.tx, ty: t.ty)
        #expect(viewportClose(nudged.scale, t.scale))
        #expect(nudged.viewportBits != t.viewportBits)
    }
}
