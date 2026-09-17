import Testing
@testable import PortlightKit

/// VIEW-01: Fit follows rotation and available space; other zoom keeps its anchor across geometry changes.
@Suite("Viewport · VIEW-01 viewport model")
struct ViewportModelTests {
    typealias F = ViewportFixtures
    private let keyboardUsable = DrawableRect(x: 0, y: 141, width: 1170, height: 1100)
    // Fitted content top edges (content height 219.375 px in portrait, 421.875 px in landscape). All exact binary.
    private static let portraitTop: Double = 1175.8125   // 141 + (2289 − 219.375) / 2
    private static let landscapeTop: Double = 342.5625   // (1107 − 421.875) / 2
    private static let keyboardTop: Double = 581.3125    // 141 + (1100 − 219.375) / 2
    private static let noInsetTop: Double = 1156.3125    // (2532 − 219.375) / 2

    /// Three 1920×1080 displays (5760×1080 union) on a 390×844 pt, 3× phone.
    private func phone() -> ViewportModel { F.model(F.row) }

    private func centerDesktop(_ m: ViewportModel) -> LogicalPoint {
        m.transform.toDesktop(x: m.usableRect.midX, y: m.usableRect.midY)!
    }

    /// Zoomed to `scale` about the usable center, then panned so desktop `x` sits at the usable center.
    private func zoomed(_ m: ViewportModel, scale: Double, centerX: Double? = nil) -> ViewportModel {
        var m = m
        // Actual Size lands on contentScale exactly; a pinch factor of scale/s may be an ulp off.
        if scale == m.contentScale { m.actualSize() } else { m.pinch(factor: scale / m.transform.scale, centroid: m.usableRect.center) }
        if let centerX { m.pan(dx: (centerDesktop(m).x - centerX) * m.transform.scale, dy: 0) }
        return m
    }

    @Test func startsFittedAndCenteredInTheSafeArea() {
        let m = phone()
        #expect(m.isFit && m.isReady)
        #expect(m.transform == ViewportTransform(scale: 0.203125, tx: 0, ty: Self.portraitTop))
        #expect(m.minScale == m.fitScale && m.fitScale == 0.203125)
        #expect(m.maxScale == 12)  // 4 × Actual Size beats 8 × Fit (1.625) and 2 × host density (4)
    }

    @Test func fitFollowsRotationPersistently() {
        var m = phone()
        let portraitBits = m.transform.viewportBits
        m.setGeometry(drawableSize: F.landscapeSize, usableRect: F.landscapeUsable, contentScale: 3)
        #expect(m.isFit)
        #expect(m.transform == ViewportTransform(scale: 0.390625, tx: 141, ty: Self.landscapeTop))
        m.setGeometry(drawableSize: F.portraitSize, usableRect: F.portraitUsable, contentScale: 3)
        #expect(m.isFit && m.transform.viewportBits == portraitBits)
    }

    @Test func fitFollowsSafeAreaKeyboardAndHiddenControls() {
        var m = phone()
        let original = m.transform.viewportBits
        m.setGeometry(drawableSize: F.portraitSize, usableRect: keyboardUsable, contentScale: 3)
        #expect(m.isFit && m.transform.ty == Self.keyboardTop)
        m.setGeometry(drawableSize: F.portraitSize, usableRect: DrawableRect(size: F.portraitSize), contentScale: 3)
        #expect(m.isFit && m.transform.ty == Self.noInsetTop)
        m.setGeometry(drawableSize: F.portraitSize, usableRect: F.portraitUsable, contentScale: 3)
        #expect(m.isFit && m.transform.viewportBits == original)
    }

    @Test func zoomedViewKeepsItsAnchorAcrossRotationAndKeyboard() {
        var m = phone()
        for _ in 0..<10 { m.zoom(stepIn: true) }
        m.pan(dx: 200, dy: 0)
        let scale = m.transform.scale, anchor = centerDesktop(m)
        #expect(!m.isFit && anchor.x > 2400 && anchor.x < 2600)
        m.setGeometry(drawableSize: F.landscapeSize, usableRect: F.landscapeUsable, contentScale: 3)
        var now = centerDesktop(m)
        #expect(!m.isFit && m.transform.scale == scale)
        #expect(viewportClose(now.x, anchor.x) && viewportClose(now.y, anchor.y))
        m.setGeometry(drawableSize: F.landscapeSize, usableRect: DrawableRect(x: 141, y: 0, width: 2250, height: 600), contentScale: 3)
        now = centerDesktop(m)
        #expect(m.transform.scale == scale && viewportClose(now.x, anchor.x) && viewportClose(now.y, anchor.y))
        m.setGeometry(drawableSize: F.portraitSize, usableRect: F.portraitUsable, contentScale: 3)
        now = centerDesktop(m)
        #expect(!m.isFit && m.transform.scale == scale && viewportClose(now.x, anchor.x) && viewportClose(now.y, anchor.y))
    }

    @Test func rotationReclampsAbsoluteScaleToTheNewLimits() {
        var m = phone()
        m.zoom(stepIn: true)  // 0.2234375: inside portrait limits, below the landscape floor 0.390625
        m.setGeometry(drawableSize: F.landscapeSize, usableRect: F.landscapeUsable, contentScale: 3)
        #expect(!m.isFit && m.transform.scale == 0.390625)
    }

    @Test func actualSizeIsOneHostPointPerUIPoint() {
        var m = phone()
        let before = centerDesktop(m)
        m.actualSize()
        #expect(!m.isFit && m.transform.scale == 3 && m.viewPointsPerDesktopPoint == 1)
        let after = centerDesktop(m)
        #expect(viewportClose(after.x, before.x) && viewportClose(after.y, before.y))
        m.setGeometry(drawableSize: F.landscapeSize, usableRect: F.landscapeUsable, contentScale: 3)
        #expect(m.transform.scale == 3)  // Actual Size survives rotation instead of refitting
    }

    /// The same 390×844 pt view moved to a 2× screen (an iPad window on an external display): the zoom is a
    /// UI-point quantity, so Actual Size stays Actual Size and a zoomed view keeps its zoom and anchor.
    @Test func aNewPixelDensityKeepsTheZoomInUIPoints() {
        let size2x = PixelSize(width: 780, height: 1688)
        let usable2x = DrawableRect(x: 0, y: 94, width: 780, height: 1526)
        var m = phone()
        m.actualSize()
        let anchor = centerDesktop(m)
        m.setGeometry(drawableSize: size2x, usableRect: usable2x, contentScale: 2)
        #expect(!m.isFit && m.transform.scale == 2 && m.viewPointsPerDesktopPoint == 1)
        let now = centerDesktop(m)
        #expect(viewportClose(now.x, anchor.x) && viewportClose(now.y, anchor.y))
        // The density can also change while nothing is laid out (the anchor is suspended meanwhile).
        var z = zoomed(phone(), scale: 4.5, centerX: 4800)
        let before = z.viewPointsPerDesktopPoint
        z.setLayout([:], hostScales: [:])
        z.setGeometry(drawableSize: size2x, usableRect: usable2x, contentScale: 2)
        z.setLayout(DesktopLayout.arrange(F.row, selected: ["1", "2", "3"], compact: true), hostScales: F.scales(F.row))
        #expect(!z.isFit && viewportClose(z.viewPointsPerDesktopPoint, before, 1e-12))
    }

    /// On a landscape iPad showing a small host display, 8 × Fit is the dominant ceiling term. Showing the
    /// keyboard shrinks the usable rect, but must not lower the ceiling and clamp the user's zoom for good.
    @Test func theKeyboardNeverLowersTheZoomCeiling() {
        let size = PixelSize(width: 2732, height: 2048)
        let usable = DrawableRect(x: 0, y: 48, width: 2732, height: 1960)
        let keyboard = DrawableRect(x: 0, y: 48, width: 2732, height: 1160)
        var m = F.model([F.display("air", 0, 0, 1440, 900, scale: 2)], size: size, usable: usable, contentScale: 2)
        m.pinch(factor: 1000, centroid: m.usableRect.center)
        let ceiling = m.transform.scale
        #expect(ceiling == m.maxScale && ceiling == 8 * (2732.0 / 1440))
        m.setGeometry(drawableSize: size, usableRect: keyboard, contentScale: 2)
        #expect(m.transform.scale == ceiling && m.maxScale == ceiling)
        m.setGeometry(drawableSize: size, usableRect: usable, contentScale: 2)
        #expect(m.transform.scale == ceiling)
    }

    @Test func zoomCommandsStepByTenPercentAboutTheUsableCenter() {
        var m = phone()
        let center = centerDesktop(m)
        m.zoom(stepIn: true)
        #expect(m.transform.scale == 0.203125 * 1.1 && !m.isFit)
        m.zoom(stepIn: true)
        #expect(m.transform.scale == 0.203125 * 1.1 * 1.1)
        m.zoom(stepIn: false)
        #expect(viewportClose(m.transform.scale, 0.203125 * 1.1, 1e-15))
        let after = centerDesktop(m)
        #expect(viewportClose(after.x, center.x) && viewportClose(after.y, center.y))
    }

    @Test func zoomOutAtFitStaysInFitSoRotationStillRefits() {
        var m = phone()
        let bits = m.transform.viewportBits
        m.zoom(stepIn: false)
        #expect(m.isFit && m.transform.viewportBits == bits)
        m.setGeometry(drawableSize: F.landscapeSize, usableRect: F.landscapeUsable, contentScale: 3)
        #expect(m.isFit && m.transform.scale == 0.390625)
    }

    @Test func zoomLimitsAreAbsolute() {
        var m = phone()
        m.pinch(factor: 1000, centroid: DrawablePoint(x: 300, y: 900))
        #expect(m.transform.scale == 12)
        m.pinch(factor: 1e-6, centroid: DrawablePoint(x: 900, y: 300))
        #expect(m.transform.scale == m.fitScale)
        // The densest laid-out display raises the ceiling; a display that is not laid out does not.
        m.setLayout(m.layout, hostScales: ["1": 8, "zzz": 100])
        #expect(m.maxScale == 16)
        m.setLayout(m.layout, hostScales: ["zzz": 100])
        #expect(m.maxScale == 12)
        // A small display on a large surface: 8 × Fit dominates.
        let big = F.model([F.display("s", 0, 0, 800, 600)], size: PixelSize(width: 2048, height: 2732), usable: nil, contentScale: 2)
        #expect(big.fitScale == 2.56 && big.maxScale == 8 * 2.56)
    }

    @Test func invalidPinchInputIsIgnored() {
        var m = zoomed(phone(), scale: 1)
        let bits = m.transform.viewportBits
        for factor in [0, -1, Double.nan, .infinity, -.infinity] {
            m.pinch(factor: factor, centroid: DrawablePoint(x: 500, y: 500))
            m.gesture(from: DrawablePoint(x: 1, y: 1), to: DrawablePoint(x: 9, y: 9), factor: factor)
        }
        m.pinch(factor: 1.5, centroid: DrawablePoint(x: .nan, y: 5))
        m.gesture(from: DrawablePoint(x: .infinity, y: 1), to: DrawablePoint(x: 2, y: 2), factor: 1.2)
        m.pan(dx: .nan, dy: 3)
        #expect(m.transform.viewportBits == bits)
        var fitted = phone()
        fitted.pinch(factor: .nan, centroid: DrawablePoint(x: 1, y: 1))
        #expect(fitted.isFit)
    }

    @Test func pinchBeyondTheLimitsNeverSlides() {
        var m = phone()
        m.pinch(factor: 1000, centroid: DrawablePoint(x: 300, y: 900))
        let atMax = m.transform.viewportBits
        m.pinch(factor: 1.5, centroid: DrawablePoint(x: 100, y: 2000))
        m.zoom(stepIn: true)
        #expect(m.transform.viewportBits == atMax)
        var fitted = phone()
        let atMin = fitted.transform.viewportBits
        fitted.pinch(factor: 0.5, centroid: DrawablePoint(x: 100, y: 400))
        #expect(fitted.isFit && fitted.transform.viewportBits == atMin)
    }

    @Test func panRespectsFitAndTheUsableRect() {
        var m = phone()
        let fitted = m.transform.viewportBits
        m.pan(dx: 50, dy: -80)
        #expect(m.isFit && m.transform.viewportBits == fitted)  // a pan that cannot move keeps Fit

        m = zoomed(phone(), scale: 1)  // 5760 × 1080 px: wider than the usable rect, shorter than it
        let tx = m.transform.tx, ty = m.transform.ty
        m.pan(dx: 10, dy: 500)
        #expect(m.transform.tx == tx + 10 && m.transform.ty == ty)  // x is free; y stays centered
        m.pan(dx: 1e6, dy: 0)
        #expect(m.transform.tx == 0)                               // left edge at the usable edge
        m.pan(dx: -1e6, dy: 0)
        #expect(viewportClose(m.transform.tx + 5760 * m.transform.scale, 1170))

        m = zoomed(phone(), scale: 12)  // taller than the usable rect: may extend under the insets
        m.pan(dx: 0, dy: 1e7)
        #expect(m.transform.ty == F.portraitUsable.minY)          // no gap inside the usable rect
        m.pan(dx: 0, dy: -1e7)
        #expect(viewportClose(m.transform.ty + 1080 * 12, F.portraitUsable.maxY))
        #expect(m.transform.ty < 0)                                // content runs under the top inset
    }

    @Test func combinedGestureCountsTranslationOnce() {
        let base = zoomed(phone(), scale: 3)
        let c0 = DrawablePoint(x: 500, y: 1200), c1 = DrawablePoint(x: 530, y: 1180)
        let under = base.transform.toDesktop(x: c0.x, y: c0.y)!
        var combined = base
        combined.gesture(from: c0, to: c1, factor: 1.2)
        let after = combined.transform.toDesktop(x: c1.x, y: c1.y)!
        #expect(viewportClose(after.x, under.x) && viewportClose(after.y, under.y))
        #expect(!combined.isFit && viewportClose(combined.transform.scale, 3.6, 1e-12))
        var panThenPinch = base
        panThenPinch.pan(dx: 30, dy: -20)
        panThenPinch.pinch(factor: 1.2, centroid: c1)
        #expect(viewportClose(panThenPinch.transform.tx, combined.transform.tx) && viewportClose(panThenPinch.transform.ty, combined.transform.ty))
        var pinchThenPan = base  // magnify about the live centroid, then pan: off by δ(1 − f)
        pinchThenPan.pinch(factor: 1.2, centroid: c1)
        pinchThenPan.pan(dx: 30, dy: -20)
        let skew = pinchThenPan.transform.tx - combined.transform.tx
        #expect(viewportClose(skew, -6))  // δx(1 − f) = 30 × (1 − 1.2)
        // No movement and factor 1 is an exact no-op.
        var still = base
        still.gesture(from: c0, to: c0, factor: 1)
        #expect(still.transform.viewportBits == base.transform.viewportBits)
    }

    @Test func selectionChangeInFitFitsTheNewCollection() {
        var m = phone()
        m.setLayout(DesktopLayout.arrange(F.row, selected: ["1", "3"], compact: true), hostScales: F.scales(F.row))
        #expect(m.isFit && m.transform.scale == 1170.0 / 3840)
    }

    @Test func compactionShiftDoesNotJumpTheView() throws {
        var m = zoomed(phone(), scale: 3, centerX: 4800)  // centered on display 3 (display-local 0.5, 0.5)
        let before = try #require(m.target(atDrawable: m.usableRect.center))
        #expect(before.display == "3" && viewportClose(before.x, 0.5) && viewportClose(before.y, 0.5))
        m.setLayout(DesktopLayout.arrange(F.row, selected: ["1", "3"], compact: true), hostScales: F.scales(F.row))
        let after = try #require(m.target(atDrawable: m.usableRect.center))
        #expect(!m.isFit && m.transform.scale == 3)
        #expect(after.display == "3" && viewportClose(after.x, before.x) && viewportClose(after.y, before.y))
        #expect(viewportClose(after.desktop.x, 2880))  // display 3 moved 1920 points left; the view followed it
    }

    @Test func removingTheAnchoredDisplayFitsTheNewSelection() throws {
        var m = zoomed(phone(), scale: 3, centerX: 2880)
        #expect(try #require(m.target(atDrawable: m.usableRect.center)).display == "2")
        m.setLayout(DesktopLayout.arrange(F.row, selected: ["1", "3"], compact: true), hostScales: F.scales(F.row))
        #expect(m.isFit && m.transform.scale == 1170.0 / 3840)
    }

    @Test func identicalLayoutOrGeometryNeverMovesTheView() {
        var m = zoomed(phone(), scale: 2.5, centerX: 1000)
        let bits = m.transform.viewportBits
        m.setLayout(m.layout, hostScales: m.hostScales)  // e.g. re-sent after a resolution-only revision
        m.setGeometry(drawableSize: m.drawableSize, usableRect: m.usableRect, contentScale: m.contentScale)
        #expect(m.transform.viewportBits == bits && !m.isFit)
    }

    @Test func emptySelectionSuspendsAndRestoresTheAnchor() throws {
        var m = zoomed(phone(), scale: 3, centerX: 4800)
        let bits = m.transform.viewportBits
        m.setLayout([:], hostScales: [:])
        #expect(!m.isReady && m.transform.viewportBits == bits)
        m.pinch(factor: 2, centroid: DrawablePoint(x: 10, y: 10))
        m.pan(dx: 40, dy: 40)
        m.zoom(stepIn: true)
        #expect(m.transform.viewportBits == bits && m.target(atDrawable: DrawablePoint(x: 585, y: 1285)) == nil)
        m.setLayout(DesktopLayout.arrange(F.row, selected: ["1", "3"], compact: true), hostScales: F.scales(F.row))
        let target = try #require(m.target(atDrawable: m.usableRect.center))
        #expect(!m.isFit && m.transform.scale == 3)
        #expect(target.display == "3" && viewportClose(target.x, 0.5) && viewportClose(target.y, 0.5))
    }

    @Test func sceneAndVisibleDesktopRect() throws {
        var m = phone()
        let scene = m.scene(cursor: LogicalPoint(x: 10, y: 20), dimmed: true)
        #expect(scene.quads.map(\.display) == ["1", "2", "3"] && scene.transform == m.transform)
        #expect(scene.drawableSize == F.portraitSize && scene.dimmed && scene.cursor == LogicalPoint(x: 10, y: 20))
        let fitted = try #require(m.visibleDesktopRect)
        #expect(fitted.minX == 0 && fitted.width == 5760 && fitted.minY < 0 && fitted.maxY > 1080)
        m = zoomed(m, scale: 3)
        let zoomedRect = try #require(m.visibleDesktopRect)
        #expect(viewportClose(zoomedRect.width, 390) && viewportClose(zoomedRect.height, 844))
        #expect(ViewportModel().visibleDesktopRect == nil)
    }

    @Test func geometryBeforeLayoutAndGesturesBeforeGeometry() {
        var m = ViewportModel()
        m.pinch(factor: 2, centroid: DrawablePoint(x: 1, y: 1))
        m.pan(dx: 5, dy: 5)
        m.zoom(stepIn: true)
        m.actualSize()
        #expect(m.isFit && m.transform == .identity && !m.isReady)
        m.setGeometry(drawableSize: F.portraitSize, usableRect: F.portraitUsable, contentScale: 3)
        #expect(!m.isReady)
        m.setLayout(DesktopLayout.arrange(F.row, selected: ["1", "2", "3"], compact: true), hostScales: F.scales(F.row))
        #expect(m.isFit && m.transform.viewportBits == phone().transform.viewportBits)
    }

    @Test func geometryInputIsSanitized() {
        var m = phone()
        m.setGeometry(drawableSize: F.portraitSize, usableRect: DrawableRect(x: 5000, y: 5000, width: 10, height: 10), contentScale: 0)
        #expect(m.contentScale == 1 && m.usableRect == DrawableRect(size: F.portraitSize) && m.isFit)
        m.setGeometry(drawableSize: F.portraitSize, usableRect: DrawableRect(x: -100, y: 100, width: 5000, height: .nan), contentScale: .nan)
        #expect(m.contentScale == 1 && m.usableRect == DrawableRect(size: F.portraitSize))
    }
}
