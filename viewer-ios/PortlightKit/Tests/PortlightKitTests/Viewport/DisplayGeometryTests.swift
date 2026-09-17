import Testing
@testable import PortlightKit

/// DISP-02: mixed DPI, negative origins, portrait and 1+3 compact selection map correctly.
@Suite("Viewport · DISP-02 display geometry")
struct ViewportDisplayGeometryTests {
    @Test func fiveKRetinaAndStandardDisplayOfEqualLogicalSizeDrawEqualQuads() throws {
        let fiveK = HostDisplay(id: "5k", name: "Studio Display", number: 1, nativeSize: PixelSize(width: 5120, height: 2880),
                                logicalFrame: LogicalRect(x: 0, y: 0, width: 1920, height: 1080), scale: 5120.0 / 1920, isPrimary: true)
        let hd = HostDisplay(id: "hd", name: "1080p", number: 2, nativeSize: PixelSize(width: 1920, height: 1080),
                             logicalFrame: LogicalRect(x: 1920, y: 0, width: 1920, height: 1080), scale: 1, isPrimary: false)
        // Their streams differ (image detail) but nothing about stream size reaches the viewport.
        #expect(ResolutionPreset.uhd.streamSize(forNative: fiveK.nativeSize) != ResolutionPreset.uhd.streamSize(forNative: hd.nativeSize))
        let model = ViewportFixtures.model([fiveK, hd])
        let quads = Dictionary(uniqueKeysWithValues: model.scene().quads.map { ($0.display, $0.frame) })
        let a = try #require(quads["5k"]), b = try #require(quads["hd"])
        #expect(a.width == b.width && a.height == b.height)
        #expect(a.width * model.transform.scale == b.width * model.transform.scale)
        #expect(a.maxX == b.minX)
    }

    @Test func negativeOriginsHitTestToNormalizedCoordinates() throws {
        let displays = [ViewportFixtures.display("retina", -1440, 0, 1440, 900, scale: 2, number: 1),
                        ViewportFixtures.display("portrait", 0, -300, 1080, 1920, scale: 1, number: 2)]
        let model = ViewportFixtures.model(displays)
        let retina = try #require(model.target(atDesktop: LogicalPoint(x: 720, y: 750)))
        #expect(retina.display == "retina" && retina.x == 0.5 && retina.y == 0.5)
        let portrait = try #require(model.target(atDesktop: LogicalPoint(x: 1980, y: 960)))
        #expect(portrait.display == "portrait" && portrait.x == 0.5 && portrait.y == 0.5)
        // The same points through the drawable, as a touch would arrive.
        let drawable = model.transform.toDrawable(LogicalPoint(x: 720, y: 750))
        let touched = try #require(model.target(atDrawable: DrawablePoint(x: drawable.x, y: drawable.y)))
        #expect(touched.display == "retina" && viewportClose(touched.x, 0.5) && viewportClose(touched.y, 0.5))
        // Above the Retina display and left of the portrait one is a gap in the arrangement.
        #expect(model.target(atDesktop: LogicalPoint(x: 100, y: 100)) == nil)
    }

    @Test func portraitDisplayDrawsPortraitAndMapsItsCorners() throws {
        let model = ViewportFixtures.model([ViewportFixtures.display("p", 0, 0, 1080, 1920, scale: 2)],
                                           size: ViewportFixtures.landscapeSize, usable: ViewportFixtures.landscapeUsable)
        let quad = try #require(model.scene().quads.first)
        #expect(quad.frame.height > quad.frame.width)
        #expect(model.fitScale == ViewportFixtures.landscapeUsable.height / 1920)
        let corner = try #require(model.target(atDesktop: LogicalPoint(x: 1080.0.nextDown, y: 1920.0.nextDown)))
        #expect(corner.x < 1 && corner.y < 1 && corner.x > 0.999_999)
        let origin = try #require(model.target(atDesktop: .zero))
        #expect(origin.x == 0 && origin.y == 0)
        #expect(model.target(atDesktop: LogicalPoint(x: 1080, y: 10)) == nil)  // half-open far edge
    }

    @Test func onePlusThreeHitTestingAcrossTheCompactedBoundary() throws {
        let model = ViewportFixtures.model(ViewportFixtures.row, selected: ["1", "3"])
        #expect(model.layout["3"]?.minX == 1920)
        #expect(DesktopLayout.arrange(ViewportFixtures.row, selected: ["1", "2", "3"], compact: false)["3"]?.minX == 3840)
        let left = try #require(model.target(atDesktop: LogicalPoint(x: 1919.5, y: 540)))
        #expect(left.display == "1" && left.x == 1919.5 / 1920 && left.y == 0.5)
        let edge = try #require(model.target(atDesktop: LogicalPoint(x: 1920, y: 540)))
        #expect(edge.display == "3" && edge.x == 0)
        let right = try #require(model.target(atDesktop: LogicalPoint(x: 1920.5, y: 540)))
        #expect(right.display == "3" && right.x == 0.5 / 1920)
        // A drag across the boundary in drawable pixels switches target once, 1 → 3, without a dead zone.
        let boundary = model.transform.toDrawable(LogicalPoint(x: 1920, y: 540))
        var seen: [DisplayID] = []
        for step in -20...20 {
            let point = DrawablePoint(x: boundary.x + Double(step) * 0.25, y: boundary.y)
            let target = try #require(model.target(atDrawable: point), "no target at step \(step)")
            #expect(target.x >= 0 && target.x < 1 && target.y >= 0 && target.y < 1)
            if seen.last != target.display { seen.append(target.display) }
        }
        #expect(seen == ["1", "3"])
    }

    @Test func gapsAndLetterboxReturnNil() throws {
        let displays = [ViewportFixtures.display("a", 0, 0, 1920, 1080), ViewportFixtures.display("b", 1800, 1080, 1920, 1080)]
        let model = ViewportFixtures.model(displays)
        #expect(model.target(atDesktop: LogicalPoint(x: 100, y: 1500)) == nil)   // below a, left of b
        #expect(model.target(atDesktop: LogicalPoint(x: 3000, y: 500)) == nil)   // right of a, above b
        #expect(model.target(atDesktop: LogicalPoint(x: -1, y: 10)) == nil)
        // Fitted in portrait, the band above the content is letterbox.
        #expect(model.target(atDrawable: DrawablePoint(x: 585, y: 150)) == nil)
        // Held drags are clamped into a display and still map into [0, 1).
        let clamped = model.clampToDisplays(LogicalPoint(x: 100, y: 1500))
        let target = try #require(model.target(atDesktop: clamped))
        #expect(target.display == "b" || target.display == "a")
        #expect(target.x >= 0 && target.x < 1 && target.y >= 0 && target.y < 1)
    }

    @Test func clampToDisplaysStaysInsideTheHalfOpenRange() throws {
        let model = ViewportFixtures.model(ViewportFixtures.row, selected: ["1", "3"])
        let farRight = try #require(model.target(atDesktop: model.clampToDisplays(LogicalPoint(x: 99_999, y: 99_999))))
        #expect(farRight.display == "3" && farRight.x < 1 && farRight.y < 1 && farRight.x > 0.999_999)
        let farLeft = try #require(model.target(atDesktop: model.clampToDisplays(LogicalPoint(x: -50, y: -50))))
        #expect(farLeft.display == "1" && farLeft.x == 0 && farLeft.y == 0)
        let inside = LogicalPoint(x: 2500, y: 300)
        #expect(model.clampToDisplays(inside) == inside)
        #expect(model.clampToDisplays(LogicalPoint(x: .nan, y: 3)) == LogicalPoint(x: 960, y: 540))
        #expect(ViewportModel().clampToDisplays(LogicalPoint(x: 7, y: 8)) == LogicalPoint(x: 7, y: 8))
    }

    @Test func viewPointsRoundTripThroughTheInverseTransform() throws {
        var model = ViewportFixtures.model(ViewportFixtures.row)
        model.zoom(stepIn: true)
        let desktop = try #require(model.desktopPoint(atViewPoint: 200, 400))
        let back = model.viewPoint(atDesktop: desktop)
        #expect(viewportClose(back.x, 200) && viewportClose(back.y, 400))
        #expect(model.viewPointsPerDesktopPoint == model.transform.scale / 3)
        #expect(model.drawablePoint(atViewPoint: 10, 20) == DrawablePoint(x: 30, y: 60))
        #expect(ViewportModel().desktopPoint(atViewPoint: 1, 1) == nil)
    }
}
