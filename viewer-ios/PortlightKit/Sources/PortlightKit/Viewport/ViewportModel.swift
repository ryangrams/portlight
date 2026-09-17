import Foundation

/// The session's local camera over the compact desktop: persistent Fit mode, zoom and pan.
///
/// Units: `layout` is compact-desktop logical points; `drawableSize`, `usableRect` and every gesture
/// argument are drawable pixels; `transform.scale` is drawable pixels per desktop point; `contentScale`
/// is drawable pixels per UI point. Only gestures, Fit/zoom commands, geometry (rotation, safe area,
/// keyboard) and explicit layout changes move the view. Stream resolution is image detail, so there is
/// deliberately no API taking a frame, canvas or resolution: receiving pixels cannot move the picture.
///
/// A value type with no clock, randomness or dictionary-order dependence: replaying the same calls
/// yields bit-identical transforms, and read-only calls never change state. The owner (one serial
/// context, e.g. the gesture surface on the main actor) publishes copies to the renderer.
public struct ViewportModel: Equatable, Sendable {
    /// Display frames in compact-desktop points (usually `DesktopLayout.arrange(…, compact: true)`).
    public private(set) var layout: [DisplayID: LogicalRect] = [:]
    /// Host native pixels per logical point, used only for the absolute zoom ceiling.
    public private(set) var hostScales: [DisplayID: Double] = [:]
    public private(set) var drawableSize = PixelSize(width: 0, height: 0)
    /// Safe-area (and keyboard-free) part of the drawable the picture is fitted into. Content still
    /// draws full-bleed and may be panned under the insets.
    public private(set) var usableRect = DrawableRect(x: 0, y: 0, width: 0, height: 0)
    /// Drawable pixels per UI point; view points = drawable pixels / contentScale.
    public private(set) var contentScale: Double = 1
    public private(set) var transform = ViewportTransform.identity
    /// Persistent Fit mode: while true, every geometry or layout change refits.
    public private(set) var isFit = true
    /// Anchor captured when geometry or layout became unusable, restored when it is usable again.
    private var suspendedAnchor: Anchor?

    /// Zoom ceiling terms: the whole drawable, UI points and host pixel density — never stream resolution
    /// or the usable rect, so neither a resolution change nor the keyboard can move the clamp.
    static let maxFitMultiple = 8.0
    static let maxActualSizeMultiple = 4.0
    static let maxHostPixelMultiple = 2.0
    /// Zoom In / Zoom Out command step (about 10%).
    public static let zoomStep = 1.1
    /// Content exceeding the usable extent by less than this relative amount counts as fitting, so
    /// rounding in `extent × (usable / extent)` never turns a no-op pan into a move.
    static let fitSlack = 1e-12

    public init() {}

    /// A model already given its layout and geometry (fitted). `usableRect` defaults to the drawable.
    public init(layout: [DisplayID: LogicalRect], hostScales: [DisplayID: Double] = [:], drawableSize: PixelSize,
                usableRect: DrawableRect? = nil, contentScale: Double) {
        setLayout(layout, hostScales: hostScales)
        setGeometry(drawableSize: drawableSize, usableRect: usableRect ?? DrawableRect(size: drawableSize),
                    contentScale: contentScale)
    }

    // MARK: - Derived geometry

    /// Union of the layout in desktop points; nil when nothing is laid out.
    public var desktopBounds: LogicalRect? {
        guard let first = layout.values.first else { return nil }
        // min/max are exact, so the result is independent of dictionary order.
        var x0 = first.minX, y0 = first.minY, x1 = first.maxX, y1 = first.maxY
        for rect in layout.values {
            x0 = min(x0, rect.minX); y0 = min(y0, rect.minY)
            x1 = max(x1, rect.maxX); y1 = max(y1, rect.maxY)
        }
        return LogicalRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// True when there is content and a usable surface to show it on. Gestures are ignored otherwise.
    public var isReady: Bool {
        guard let bounds = desktopBounds, bounds.width > 0, bounds.height > 0 else { return false }
        return drawableSize.width > 0 && drawableSize.height > 0 && !usableRect.isEmpty
    }

    /// Scale that shows the whole desktop inside `usableRect`; 0 when not ready.
    public var fitScale: Double {
        guard isReady, let bounds = desktopBounds else { return 0 }
        return min(usableRect.width / bounds.width, usableRect.height / bounds.height)
    }

    /// Zoom floor: Fit.
    public var minScale: Double { fitScale }

    /// Zoom ceiling: max(8 × the whole-drawable Fit, 4 × Actual Size, 2 × the densest laid-out display's
    /// native pixels). The Fit term uses the whole drawable, not `usableRect`, so showing the keyboard or
    /// controls never lowers the ceiling and clamps a zoom the user keeps after they hide again.
    public var maxScale: Double {
        let densest = layout.keys.compactMap { hostScales[$0] }.max() ?? 0
        return max(fitScale, Self.maxFitMultiple * drawableFitScale, Self.maxActualSizeMultiple * contentScale,
                   Self.maxHostPixelMultiple * densest)
    }

    /// Scale that would show the whole desktop in the whole drawable (≥ `fitScale`); 0 when not ready.
    var drawableFitScale: Double {
        guard isReady, let bounds = desktopBounds else { return 0 }
        return min(Double(drawableSize.width) / bounds.width, Double(drawableSize.height) / bounds.height)
    }

    // MARK: - Geometry and layout

    /// Adopts a new drawable, safe-area rect or pixel density (rotation, keyboard, controls shown).
    ///
    /// In Fit mode the picture refits. Otherwise the zoom is kept (re-clamped) and the desktop point that
    /// was at the old usable center moves to the new usable center. The zoom is kept in UI points: the
    /// absolute scale when `contentScale` is unchanged, rescaled when the view moves to a screen with another
    /// pixel density (so Actual Size stays Actual Size). `usableRect` is clipped to the drawable; an empty
    /// result means the whole drawable. Identical input is a no-op.
    public mutating func setGeometry(drawableSize: PixelSize, usableRect: DrawableRect, contentScale: Double) {
        let density = contentScale.isFinite && contentScale > 0 ? contentScale : 1
        let bounds = DrawableRect(size: drawableSize)
        let usable = (usableRect.isFinite ? usableRect.intersection(bounds) : nil) ?? bounds
        guard drawableSize != self.drawableSize || usable != self.usableRect || density != self.contentScale else { return }
        let before = captureAnchor()
        self.drawableSize = drawableSize
        self.usableRect = usable
        self.contentScale = density
        reconcile(from: before)
    }

    /// Adopts a new display layout (selection or topology change) and host scales.
    ///
    /// In Fit mode the new collection is fitted. Otherwise, if the display containing (or nearest to)
    /// the point at the usable center is still laid out, that display-local point stays at the usable
    /// center — compaction shifts caused by other displays never jump the view — at the same absolute
    /// scale (re-clamped). If that display is gone the new selection is fitted and Fit mode resumes.
    /// Rects that are non-finite or have no area, and non-positive scales, are dropped. Identical
    /// input is a no-op, so re-sending the same layout after a resolution change moves nothing.
    public mutating func setLayout(_ layout: [DisplayID: LogicalRect], hostScales: [DisplayID: Double]) {
        let rects = layout.filter { entry in
            let r = entry.value
            return [r.x, r.y, r.width, r.height].allSatisfy { $0.isFinite } && r.width > 0 && r.height > 0
        }
        let scales = hostScales.filter { $0.value.isFinite && $0.value > 0 }
        guard rects != self.layout || scales != self.hostScales else { return }
        let before = captureAnchor()
        self.layout = rects
        self.hostScales = scales
        reconcile(from: before)
    }

    // MARK: - Commands and gestures

    /// Enters Fit mode and shows the whole desktop, centered in the usable rect.
    public mutating func fit() {
        isFit = true
        if isReady { transform = fitted() }
    }

    /// Incremental pinch about `centroid` (drawable pixels, the centroid now).
    ///
    /// The factor is clamped first (`f_eff = clamp(s·f)/s`) and the translation uses `f_eff`, so the
    /// desktop point under the centroid never slides at the zoom limits (URC's clamp drift). A factor
    /// ≤ 0 or non-finite is ignored. Exits Fit unless the effective factor is 1.
    public mutating func pinch(factor: Double, centroid: DrawablePoint) {
        guard factor > 0, factor.isFinite else { return }
        magnify(toScale: transform.scale * factor, about: centroid)
    }

    /// One recognizer event of a combined pinch + two-finger pan, applied once: the desktop point that
    /// was under `start` ends under `end` at the new (clamped) scale, `t' = c1 − (c0 − t)·(s'/s)`.
    /// Applying pinch and pan separately would depend on UIKit's undefined callback order.
    public mutating func gesture(from start: DrawablePoint, to end: DrawablePoint, factor: Double) {
        guard isReady, factor > 0, factor.isFinite, start.isFinite, end.isFinite else { return }
        let scale = transform.scale
        let clamped = clampScale(scale * factor)
        guard clamped != scale else {
            pan(dx: end.x - start.x, dy: end.y - start.y)
            return
        }
        let k = clamped / scale
        commit(constrained(ViewportTransform(scale: clamped,
                                             tx: end.x - (start.x - transform.tx) * k,
                                             ty: end.y - (start.y - transform.ty) * k)))
    }

    /// Incremental pan in drawable pixels. A pan that cannot move the view (e.g. while fitted) keeps
    /// Fit mode; one that moves it exits Fit.
    public mutating func pan(dx: Double, dy: Double) {
        guard isReady, dx.isFinite, dy.isFinite else { return }
        commit(constrained(ViewportTransform(scale: transform.scale, tx: transform.tx + dx, ty: transform.ty + dy)))
    }

    /// Zoom In / Zoom Out by `zoomStep` about the usable center. Exits Fit unless already at the limit
    /// (a Zoom Out at Fit stays in Fit, so rotation keeps refitting).
    public mutating func zoom(stepIn: Bool) {
        guard isReady else { return }
        magnify(toScale: transform.scale * (stepIn ? Self.zoomStep : 1 / Self.zoomStep), about: usableRect.center)
    }

    /// Actual Size: one host logical point per UI point (`scale = contentScale`, within limits), about
    /// the usable center. Always leaves Fit mode, so rotation keeps Actual Size instead of refitting.
    public mutating func actualSize() {
        guard isReady else { return }
        magnify(toScale: contentScale, about: usableRect.center)
        isFit = false
    }

    // MARK: - Internals

    /// Scales to `target` (clamped) keeping the desktop point under `anchor` fixed.
    private mutating func magnify(toScale target: Double, about anchor: DrawablePoint) {
        guard isReady, anchor.isFinite else { return }
        let scale = transform.scale
        let clamped = clampScale(target)
        guard clamped != scale else { return }  // f_eff == 1: nothing moves, even at a limit.
        let k = clamped / scale
        // Adapted from URC ViewportGesture.swift (`magnified`): t' = a − (a − t)·f, here with f_eff.
        commit(constrained(ViewportTransform(scale: clamped,
                                             tx: anchor.x - (anchor.x - transform.tx) * k,
                                             ty: anchor.y - (anchor.y - transform.ty) * k)))
    }

    /// A user change: any actual movement leaves Fit mode.
    private mutating func commit(_ next: ViewportTransform) {
        guard next != transform else { return }
        transform = next
        isFit = false
    }

    func clampScale(_ scale: Double) -> Double {
        let low = minScale, high = max(low, maxScale)
        guard scale.isFinite else { return low }
        return min(max(scale, low), high)
    }

    /// The nearest allowed transform: scale into its limits, then each axis against `usableRect`.
    func constrained(_ proposal: ViewportTransform) -> ViewportTransform {
        guard isReady, let bounds = desktopBounds else { return proposal }
        let scale = clampScale(proposal.scale)
        let left = Self.constrainedOrigin(bounds.minX * scale + proposal.tx, content: bounds.width * scale,
                                          usableStart: usableRect.minX, usableExtent: usableRect.width)
        let top = Self.constrainedOrigin(bounds.minY * scale + proposal.ty, content: bounds.height * scale,
                                         usableStart: usableRect.minY, usableExtent: usableRect.height)
        return ViewportTransform(scale: scale, tx: left - bounds.minX * scale, ty: top - bounds.minY * scale)
    }

    /// Where the content's leading edge may sit on one axis: centered when it fits the usable extent,
    /// otherwise no gap inside the usable extent (it may extend under the insets). Hard limits.
    // Adapted from URC ViewportLimits.swift (`constrainedOrigin`), offset by the usable rect.
    static func constrainedOrigin(_ origin: Double, content: Double, usableStart: Double, usableExtent: Double) -> Double {
        guard content > usableExtent * (1 + fitSlack) else { return usableStart + (usableExtent - content) / 2 }
        guard origin.isFinite else { return usableStart + usableExtent - content }
        return min(max(origin, usableStart + usableExtent - content), usableStart)
    }

    func fitted() -> ViewportTransform {
        constrained(ViewportTransform(scale: fitScale, tx: 0, ty: 0))
    }

    /// Re-establishes the view after geometry or layout changed.
    private mutating func reconcile(from before: Anchor?) {
        guard isReady else {
            // Nothing to show yet; leave the transform alone and remember where the user was looking.
            if let before { suspendedAnchor = before }
            return
        }
        let anchor = before ?? suspendedAnchor
        suspendedAnchor = nil
        guard !isFit, let anchor, let point = anchor.resolve(in: layout) else {
            isFit = true
            transform = fitted()
            return
        }
        // Same density: the same absolute scale, bit for bit. Another density: the same zoom in UI points.
        let zoom = anchor.density == contentScale ? anchor.scale : anchor.scale / anchor.density * contentScale
        let scale = clampScale(zoom)
        let center = usableRect.center
        transform = constrained(ViewportTransform(scale: scale, tx: center.x - point.x * scale,
                                                  ty: center.y - point.y * scale))
    }

    /// The desktop point at the usable center, tied to the display containing (or nearest to) it.
    private func captureAnchor() -> Anchor? {
        guard isReady, let desktop = transform.toDesktop(x: usableRect.midX, y: usableRect.midY) else { return nil }
        var fraction = LogicalPoint.zero
        let display = displayID(containingOrNearest: desktop)
        if let display, let rect = layout[display] {
            fraction = LogicalPoint(x: (desktop.x - rect.minX) / rect.width, y: (desktop.y - rect.minY) / rect.height)
        }
        return Anchor(desktop: desktop, display: display, fraction: fraction, scale: transform.scale,
                      density: contentScale, layout: layout)
    }

    /// Half-open containment first, else the nearest display; ties go to the lowest ID.
    func displayID(containingOrNearest point: LogicalPoint) -> DisplayID? {
        var best: (id: DisplayID, distance: Double)?
        for (id, rect) in layout.sorted(by: { $0.key < $1.key }) {
            if rect.contains(point) { return id }
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance { best = (id, distance) }
        }
        return best?.id
    }

    /// What the user was looking at, in a form that survives layout changes.
    struct Anchor: Equatable, Sendable {
        var desktop: LogicalPoint
        var display: DisplayID?
        /// Position relative to `display`'s frame (0…1 inside; may lie outside when in a gap).
        var fraction: LogicalPoint
        var scale: Double
        /// `contentScale` when captured, so a new pixel density keeps the zoom in UI points.
        var density: Double
        /// Layout `desktop` refers to.
        var layout: [DisplayID: LogicalRect]

        /// The anchor's desktop point in `current`: unchanged for the same layout, else display-local.
        func resolve(in current: [DisplayID: LogicalRect]) -> LogicalPoint? {
            if current == layout { return desktop }
            guard let display, let rect = current[display] else { return nil }
            return LogicalPoint(x: rect.minX + fraction.x * rect.width, y: rect.minY + fraction.y * rect.height)
        }
    }
}
