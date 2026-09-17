import Foundation
import CoreGraphics
import CoreText
import os
import PortlightKit

/// The gallery's remote picture: a real `MetalRenderer` whose display textures hold a generated, desktop-like
/// test pattern, and a lock-protected viewport that the display link reads. This is the production shape: the
/// render loop never reads SwiftUI state.
final class GalleryDemoScene: Sendable {
    static let shared = GalleryDemoScene()

    /// nil when Metal is unavailable.
    let renderer: MetalRenderer?
    private let state = OSAllocatedUnfairLock(initialState: SceneState())

    private struct SceneState: Sendable {
        var viewport = ViewportModel()
        var selection: [DisplayID] = GalleryDemo.displays.map(\.id)
        var cursor: LogicalPoint?
        var dimmed = false
        var zoomIntoFirstDisplay = false
        var zoomApplied = false
        var surface: SurfaceGeometry?
        var chromeInsets = ChromeInsets.zero
    }

    private init() {
        renderer = try? MetalRenderer()
        if let renderer { GalleryTestPattern.fill(renderer.framebuffers) }
        state.withLock { Self.reconcile(&$0) }
    }

    /// The scene for one display-link tick; an empty selection draws only the letterbox.
    var sceneProvider: @Sendable () -> RenderScene? {
        let state = self.state
        return { state.withLock { $0.viewport.scene(cursor: $0.cursor, dimmed: $0.dimmed) } }
    }

    func configure(selection: [DisplayID], cursor: LogicalPoint?, dimmed: Bool, zoomIntoFirstDisplay: Bool) {
        state.withLock { scene in
            scene.selection = selection
            scene.cursor = cursor
            scene.dimmed = dimmed
            scene.zoomIntoFirstDisplay = zoomIntoFirstDisplay
            scene.zoomApplied = false
            scene.viewport = ViewportModel()
            Self.reconcile(&scene)
        }
    }

    func setSelection(_ selection: [DisplayID]) {
        state.withLock { scene in
            scene.selection = selection
            Self.reconcile(&scene)
        }
    }

    func setDimmed(_ dimmed: Bool) {
        state.withLock { $0.dimmed = dimmed }
    }

    func setSurface(_ surface: SurfaceGeometry) {
        state.withLock { scene in
            scene.surface = surface
            Self.reconcile(&scene)
        }
    }

    func setChromeInsets(_ insets: ChromeInsets) {
        state.withLock { scene in
            scene.chromeInsets = insets
            Self.reconcile(&scene)
        }
    }

    func fit() { state.withLock { $0.viewport.fit() } }
    func actualSize() { state.withLock { $0.viewport.actualSize() } }
    func zoom(stepIn: Bool) { state.withLock { $0.viewport.zoom(stepIn: stepIn) } }

    /// Layout from the selection (compacted), then the usable rect: the safe area minus visible chrome.
    private static func reconcile(_ scene: inout SceneState) {
        let layout = DesktopLayout.arrange(GalleryDemo.displays, selected: scene.selection, compact: true)
        var scales: [DisplayID: Double] = [:]
        for display in GalleryDemo.displays where layout[display.id] != nil { scales[display.id] = display.scale }
        scene.viewport.setLayout(layout, hostScales: scales)
        if let surface = scene.surface {
            let scale = surface.contentScale
            let insets = scene.chromeInsets
            let safe = surface.usableRect
            let left = Double(insets.leading) * scale, right = Double(insets.trailing) * scale
            let top = Double(insets.top) * scale, bottom = Double(insets.bottom) * scale
            let usable = DrawableRect(x: safe.x + left, y: safe.y + top,
                                      width: max(1, safe.width - left - right), height: max(1, safe.height - top - bottom))
            scene.viewport.setGeometry(drawableSize: surface.drawableSize, usableRect: usable, contentScale: scale)
        }
        if scene.zoomIntoFirstDisplay, !scene.zoomApplied, scene.viewport.isReady,
           let first = scene.selection.first, let frame = scene.viewport.layout[first] {
            // Zoom until the first display spans the usable width, anchored at its leading edge.
            let usable = scene.viewport.usableRect
            scene.viewport.pinch(factor: usable.width / (frame.width * scene.viewport.transform.scale),
                                 centroid: DrawablePoint(x: usable.minX, y: usable.midY))
            scene.zoomApplied = true
        }
    }
}

/// Draws a desktop-like picture into each display's framebuffer (BGRA premultiplied, top-left origin), the same
/// format the tile decoder produces, then commits it as one full-canvas patch per display.
enum GalleryTestPattern {
    static let canvas = PixelSize(width: 1280, height: 720)

    static func fill(_ store: MetalFramebufferStore) {
        let canvases = Dictionary(uniqueKeysWithValues: GalleryDemo.displays.map { ($0.id, canvas) })
        store.acceptRevision(1, canvases: canvases, requestedRegions: [:])
        let bytesPerRow = canvas.width * 4
        for (index, display) in GalleryDemo.displays.enumerated() {
            guard let buffer = store.makePatchBuffer(byteCount: bytesPerRow * canvas.height) else { continue }
            draw(display, into: buffer.contents, bytesPerRow: bytesPerRow)
            let header = FrameHeader(revision: 1, display: display.id,
                                     rect: PixelRect(x: 0, y: 0, width: canvas.width, height: canvas.height),
                                     canvas: canvas, codec: .png, sequence: index + 1)
            _ = store.commit(DecodedPatch(header: header, buffer: buffer, bytesPerRow: bytesPerRow))
        }
        store.flush()
    }

    private static func draw(_ display: HostDisplay, into data: UnsafeMutableRawPointer, bytesPerRow: Int) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: data, width: canvas.width, height: canvas.height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let size = CGSize(width: canvas.width, height: canvas.height)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1) // y down, like the canvas

        wallpaper(context, size: size, display: display, space: space)
        switch display.number {
        case 1:
            finderWindow(context)
            menuBar(context, width: size.width)
            dock(context, size: size)
        case 2:
            editorWindow(context)
        default:
            photoWindow(context, space: space)
            colorChecker(context, origin: CGPoint(x: 800, y: 120))
        }
        text("\(display.number)", at: CGPoint(x: size.width - 150, y: size.height - 40), size: 180,
             color: rgb(1, 1, 1, 0.22), weight: .bold, in: context)
        text("\(display.name) · \(Int(display.logicalFrame.width)) × \(Int(display.logicalFrame.height)) pt",
             at: CGPoint(x: 24, y: size.height - (display.isPrimary ? 90 : 26)), size: 18, color: rgb(1, 1, 1, 0.92), in: context)
    }

    // MARK: Scenes

    private static func wallpaper(_ context: CGContext, size: CGSize, display: HostDisplay, space: CGColorSpace) {
        let palettes: [[CGColor]] = [
            [rgb(0.10, 0.16, 0.42), rgb(0.45, 0.22, 0.58)],
            [rgb(0.03, 0.27, 0.34), rgb(0.12, 0.52, 0.40)],
            [rgb(0.62, 0.24, 0.12), rgb(0.50, 0.12, 0.40)],
        ]
        let colors = palettes[(display.number - 1) % palettes.count]
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        if let glow = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1]) {
            let center = CGPoint(x: size.width * 0.72, y: size.height * 0.25)
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 420, options: [])
        }
        // A faint 64-pixel grid, to judge sharpness when zoomed.
        context.setStrokeColor(rgb(1, 1, 1, 0.06))
        context.setLineWidth(1)
        for x in stride(from: 64.0, to: size.width, by: 64) {
            context.move(to: CGPoint(x: x + 0.5, y: 0)); context.addLine(to: CGPoint(x: x + 0.5, y: size.height))
        }
        for y in stride(from: 64.0, to: size.height, by: 64) {
            context.move(to: CGPoint(x: 0, y: y + 0.5)); context.addLine(to: CGPoint(x: size.width, y: y + 0.5))
        }
        context.strokePath()
    }

    private static func menuBar(_ context: CGContext, width: CGFloat) {
        context.setFillColor(rgb(0.97, 0.97, 0.98, 0.82))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 22))
        text("Finder     File     Edit     View     Go     Window     Help", at: CGPoint(x: 36, y: 16), size: 12,
             color: rgb(0.1, 0.1, 0.1), weight: .bold, in: context)
        text("Thu 9:41", at: CGPoint(x: width - 76, y: 16), size: 12, color: rgb(0.1, 0.1, 0.1), in: context)
        context.setFillColor(rgb(0.1, 0.1, 0.1))
        context.fillEllipse(in: CGRect(x: 14, y: 6, width: 10, height: 10))
    }

    private static func dock(_ context: CGContext, size: CGSize) {
        let rect = CGRect(x: size.width / 2 - 230, y: size.height - 66, width: 460, height: 56)
        roundedRect(rect, radius: 16, fill: rgb(1, 1, 1, 0.3), in: context)
        let colors = [rgb(0.2, 0.5, 0.95), rgb(0.95, 0.35, 0.3), rgb(0.3, 0.8, 0.4), rgb(0.98, 0.75, 0.2),
                      rgb(0.6, 0.4, 0.9), rgb(0.2, 0.75, 0.85), rgb(0.95, 0.5, 0.7), rgb(0.35, 0.35, 0.4)]
        for (index, color) in colors.enumerated() {
            roundedRect(CGRect(x: rect.minX + 14 + CGFloat(index) * 55, y: rect.minY + 8, width: 40, height: 40),
                        radius: 9, fill: color, in: context)
        }
    }

    private static func finderWindow(_ context: CGContext) {
        let window = CGRect(x: 70, y: 70, width: 580, height: 380)
        windowFrame(window, title: "Portlight Gallery", dark: false, in: context)
        context.setFillColor(rgb(0.93, 0.93, 0.95))
        context.fill(CGRect(x: window.minX, y: window.minY + 30, width: 150, height: window.height - 30))
        for (index, item) in ["Favorites", "Desktop", "Documents", "Downloads", "Projects"].enumerated() {
            text(item, at: CGPoint(x: window.minX + 18, y: window.minY + 62 + CGFloat(index) * 28), size: 14,
                 color: index == 0 ? rgb(0.45, 0.45, 0.5) : rgb(0.15, 0.15, 0.2), weight: index == 0 ? .bold : .regular, in: context)
        }
        let files = ["Projects", "Renders", "Stills", "Audio", "Notes.txt", "Cut 03.mov"]
        for (index, name) in files.enumerated() {
            let column = CGFloat(index % 3), row = CGFloat(index / 3)
            let icon = CGRect(x: window.minX + 190 + column * 130, y: window.minY + 70 + row * 140, width: 76, height: 60)
            roundedRect(icon, radius: 8, fill: index < 4 ? rgb(0.35, 0.62, 0.98) : rgb(0.88, 0.88, 0.9), in: context)
            text(name, at: CGPoint(x: icon.minX - 4, y: icon.maxY + 26), size: 14, color: rgb(0.15, 0.15, 0.2), in: context)
        }
    }

    private static func editorWindow(_ context: CGContext) {
        let window = CGRect(x: 90, y: 80, width: 760, height: 430)
        windowFrame(window, title: "SessionController.swift", dark: true, in: context)
        let keyword = rgb(0.99, 0.37, 0.64), type = rgb(0.36, 0.85, 0.90), plain = rgb(0.90, 0.90, 0.92)
        let comment = rgb(0.47, 0.72, 0.42), number = rgb(0.55, 0.55, 0.6)
        let lines: [[(String, CGColor)]] = [
            [("// Every attempt is a new generation.", comment)],
            [("func ", keyword), ("connect", plain), ("(to host: ", plain), ("HostEndpoint", type), (") {", plain)],
            [("    let ", keyword), ("pin = trust.pinnedFingerprint(for: host)", plain)],
            [("    engine.connect(", plain), ("ConnectRequest", type), ("(endpoint: host,", plain)],
            [("                                  pin: pin,", plain)],
            [("                                  password: password,", plain)],
            [("                                  planner: planner))", plain)],
            [("}", plain)],
            [("", plain)],
            [("let ", keyword), ("presets: [", plain), ("ResolutionPreset", type), ("] = [.hd, .fhd, .qhd, .uhd]", plain)],
        ]
        for (index, segments) in lines.enumerated() {
            let y = window.minY + 70 + CGFloat(index) * 30
            text(String(index + 1), at: CGPoint(x: window.minX + 18, y: y), size: 15, color: number, weight: .mono, in: context)
            var x = window.minX + 60
            for (segment, color) in segments where !segment.isEmpty {
                x += text(segment, at: CGPoint(x: x, y: y), size: 15, color: color, weight: .mono, in: context)
            }
        }
    }

    private static func photoWindow(_ context: CGContext, space: CGColorSpace) {
        let window = CGRect(x: 70, y: 70, width: 660, height: 420)
        windowFrame(window, title: "Grade — Shot 12", dark: true, in: context)
        let photo = CGRect(x: window.minX + 16, y: window.minY + 46, width: window.width - 32, height: window.height - 62)
        context.saveGState()
        context.clip(to: photo)
        if let sky = CGGradient(colorsSpace: space, colors: [rgb(0.12, 0.2, 0.45), rgb(0.95, 0.55, 0.3), rgb(0.98, 0.85, 0.55)] as CFArray,
                                locations: [0, 0.65, 1]) {
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: photo.minY), end: CGPoint(x: 0, y: photo.maxY), options: [])
        }
        context.setFillColor(rgb(1, 0.93, 0.7))
        context.fillEllipse(in: CGRect(x: photo.midX - 50, y: photo.maxY - 150, width: 100, height: 100))
        context.setFillColor(rgb(0.08, 0.1, 0.16))
        context.move(to: CGPoint(x: photo.minX, y: photo.maxY))
        context.addLine(to: CGPoint(x: photo.minX + 180, y: photo.maxY - 110))
        context.addLine(to: CGPoint(x: photo.minX + 330, y: photo.maxY - 40))
        context.addLine(to: CGPoint(x: photo.minX + 480, y: photo.maxY - 140))
        context.addLine(to: CGPoint(x: photo.maxX, y: photo.maxY - 60))
        context.addLine(to: CGPoint(x: photo.maxX, y: photo.maxY))
        context.fillPath()
        context.restoreGState()
    }

    /// A 6 × 4 colour checker, plus a 16-step gray ramp under it.
    private static func colorChecker(_ context: CGContext, origin: CGPoint) {
        let patches: [CGColor] = [
            rgb(0.45, 0.32, 0.26), rgb(0.77, 0.58, 0.50), rgb(0.36, 0.48, 0.61), rgb(0.35, 0.42, 0.26), rgb(0.51, 0.50, 0.69), rgb(0.40, 0.74, 0.67),
            rgb(0.84, 0.49, 0.18), rgb(0.29, 0.36, 0.65), rgb(0.76, 0.33, 0.38), rgb(0.36, 0.24, 0.42), rgb(0.62, 0.74, 0.25), rgb(0.88, 0.63, 0.18),
            rgb(0.17, 0.24, 0.59), rgb(0.27, 0.58, 0.29), rgb(0.69, 0.19, 0.23), rgb(0.93, 0.78, 0.13), rgb(0.73, 0.33, 0.58), rgb(0.03, 0.52, 0.63),
            rgb(0.95, 0.95, 0.95), rgb(0.78, 0.78, 0.78), rgb(0.63, 0.63, 0.63), rgb(0.47, 0.47, 0.47), rgb(0.33, 0.33, 0.33), rgb(0.20, 0.20, 0.20),
        ]
        roundedRect(CGRect(x: origin.x - 12, y: origin.y - 12, width: 6 * 64 + 16, height: 4 * 64 + 16 + 56), radius: 12,
                    fill: rgb(0.08, 0.08, 0.1, 0.85), in: context)
        for (index, color) in patches.enumerated() {
            let rect = CGRect(x: origin.x + CGFloat(index % 6) * 64, y: origin.y + CGFloat(index / 6) * 64, width: 56, height: 56)
            roundedRect(rect, radius: 6, fill: color, in: context)
        }
        for step in 0..<16 {
            let level = CGFloat(step) / 15
            context.setFillColor(rgb(level, level, level))
            context.fill(CGRect(x: origin.x + CGFloat(step) * 23.5, y: origin.y + 4 * 64 + 8, width: 23.5, height: 36))
        }
    }

    // MARK: Drawing helpers

    private static func windowFrame(_ rect: CGRect, title: String, dark: Bool, in context: CGContext) {
        context.saveGState()
        // Shadows are in the unflipped base space: a negative height falls below the window.
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0, 0, 0, 0.45))
        roundedRect(rect, radius: 12, fill: dark ? rgb(0.13, 0.14, 0.16) : rgb(0.98, 0.98, 0.99), in: context)
        context.restoreGState()
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.clip()
        context.setFillColor(dark ? rgb(0.2, 0.21, 0.24) : rgb(0.91, 0.91, 0.93))
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 30))
        context.restoreGState()
        for (index, color) in [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.79, 0.25)].enumerated() {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: rect.minX + 14 + CGFloat(index) * 20, y: rect.minY + 9, width: 12, height: 12))
        }
        text(title, at: CGPoint(x: rect.midX - CGFloat(title.count) * 3.6, y: rect.minY + 20), size: 13,
             color: dark ? rgb(0.85, 0.85, 0.88) : rgb(0.25, 0.25, 0.3), weight: .bold, in: context)
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat, fill: CGColor, in context: CGContext) {
        context.setFillColor(fill)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    private enum Weight { case regular, bold, mono }

    /// Draws one line with its baseline at `point` (y down) and returns its advance width.
    @discardableResult
    private static func text(_ string: String, at point: CGPoint, size: CGFloat, color: CGColor, weight: Weight = .regular,
                             in context: CGContext) -> CGFloat {
        let font: CTFont
        switch weight {
        case .mono: font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        case .bold: font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        case .regular: font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.saveGState()
        // The context is flipped (y down); flip back around the baseline so the glyphs stand upright.
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
