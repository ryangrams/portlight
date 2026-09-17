import SwiftUI
import UIKit
import QuartzCore
import Metal
import PortlightKit

/// The surface's geometry, reported on every layout change that alters it.
struct SurfaceGeometry: Equatable, Sendable {
    /// The Metal drawable, in pixels (bounds × the window screen's native scale).
    var drawableSize: PixelSize
    /// The safe-area part of the surface in drawable pixels. The session subtracts visible chrome from it.
    var usableRect: DrawableRect
    /// Drawable pixels per UI point.
    var contentScale: Double
}

/// The remote picture (UI-SPEC §5): a `UIViewRepresentable` built once, with an empty `updateUIView`, so SwiftUI
/// never pushes state into the render loop. Each display-link tick asks `sceneProvider` for the scene; the
/// provider reads lock-protected stores, never the view tree. Raw touches go to `onTouch` as `TouchEvent`s in
/// view points with UIKit timestamps (the same clock as `SystemSessionClock`).
struct SessionSurfaceView: UIViewRepresentable {
    private let renderer: MetalRenderer?
    private let sceneProvider: @Sendable () -> RenderScene?
    private let onTouch: @MainActor (TouchEvent, TimeInterval) -> Void
    private let onGeometry: @MainActor (SurfaceGeometry) -> Void
    private let onFirstFrame: (@MainActor () -> Void)?
    private let onTick: (@MainActor (TimeInterval) -> Void)?

    /// - Parameters:
    ///   - renderer: nil when Metal is unavailable; the surface then shows only the letterbox colour.
    ///   - sceneProvider: called on the main thread once per display-link tick; nil skips the tick.
    ///   - onFirstFrame: called once, after the first drawable is presented.
    ///   - onTick: called on the main thread at the start of every display-link tick, before the scene is read,
    ///     with `ProcessInfo.systemUptime` (the clock base of touch timestamps and `SystemSessionClock`).
    init(renderer: MetalRenderer?, sceneProvider: @escaping @Sendable () -> RenderScene?,
         onTouch: @escaping @MainActor (TouchEvent, TimeInterval) -> Void,
         onGeometry: @escaping @MainActor (SurfaceGeometry) -> Void,
         onFirstFrame: (@MainActor () -> Void)? = nil,
         onTick: (@MainActor (TimeInterval) -> Void)? = nil) {
        self.renderer = renderer
        self.sceneProvider = sceneProvider
        self.onTouch = onTouch
        self.onGeometry = onGeometry
        self.onFirstFrame = onFirstFrame
        self.onTick = onTick
    }

    func makeUIView(context: Context) -> SessionSurfaceUIView {
        SessionSurfaceUIView(renderer: renderer, sceneProvider: sceneProvider, onTouch: onTouch,
                             onGeometry: onGeometry, onFirstFrame: onFirstFrame, onTick: onTick)
    }

    func updateUIView(_ uiView: SessionSurfaceUIView, context: Context) {}
}

/// A `UIView` backed by a `CAMetalLayer` (.bgra8Unorm, framebufferOnly) and driven by a `CAMetalDisplayLink`.
///
/// Every frame uses the drawable the link vends; `nextDrawable()` is never called while the link runs. The link
/// exists only while the view is in a window and is paused while its scene isn't the active foreground scene.
/// Frames are presented only when `MetalRenderer.encodeIfNeeded` reports a change.
final class SessionSurfaceUIView: UIView, CAMetalDisplayLinkDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    // Read on display-link ticks, which arrive on the main run loop but in a nonisolated method: both are
    // immutable and Sendable.
    private let renderer: MetalRenderer?
    private let sceneProvider: @Sendable () -> RenderScene?

    private let onTouch: @MainActor (TouchEvent, TimeInterval) -> Void
    private let onGeometry: @MainActor (SurfaceGeometry) -> Void
    private var onFirstFrame: (@MainActor () -> Void)?
    private let onTick: (@MainActor (TimeInterval) -> Void)?

    private var displayLink: CAMetalDisplayLink?
    private var isSceneActive = false
    private var lastGeometry: SurfaceGeometry?
    /// Small stable integers for UITouch identities, for the lifetime of each touch.
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 1

    init(renderer: MetalRenderer?, sceneProvider: @escaping @Sendable () -> RenderScene?,
         onTouch: @escaping @MainActor (TouchEvent, TimeInterval) -> Void,
         onGeometry: @escaping @MainActor (SurfaceGeometry) -> Void,
         onFirstFrame: (@MainActor () -> Void)?,
         onTick: (@MainActor (TimeInterval) -> Void)? = nil) {
        self.renderer = renderer
        self.sceneProvider = sceneProvider
        self.onTouch = onTouch
        self.onGeometry = onGeometry
        self.onFirstFrame = onFirstFrame
        self.onTick = onTick
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isOpaque = true
        let letterbox = MetalRenderer.letterbox
        backgroundColor = UIColor(red: CGFloat(letterbox.red) / 255, green: CGFloat(letterbox.green) / 255,
                                  blue: CGFloat(letterbox.blue) / 255, alpha: 1)
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.device = renderer?.device
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            metalLayer.isOpaque = true
        }
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidActivate(_:)),
                                               name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate(_:)),
                                               name: UIScene.willDeactivateNotification, object: nil)
    }

    required init?(coder: NSCoder) { return nil }

    // MARK: Display link lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            isSceneActive = window.windowScene?.activationState == .foregroundActive
            startLinkIfNeeded()
            setNeedsLayout()
        } else {
            // Invalidated rather than paused, so a removed view never leaves a link on the run loop.
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func startLinkIfNeeded() {
        guard displayLink == nil, renderer != nil, let metalLayer = layer as? CAMetalLayer else { return }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.delegate = self
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateLinkState()
    }

    private func updateLinkState() {
        guard let displayLink else { return }
        let run = window != nil && isSceneActive
        if run && displayLink.isPaused {
            // The layer may have been purged in the background: draw on the next tick even if nothing changed.
            renderer?.presentation.invalidate()
        }
        displayLink.isPaused = !run
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        isSceneActive = true
        updateLinkState()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        isSceneActive = false
        updateLinkState()
    }

    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // The link is on the main run loop, so this callback runs on the main thread. Input deadlines and
        // inertia advance first, so this frame already shows their effect.
        MainActor.assumeIsolated { self.onTick?(ProcessInfo.processInfo.systemUptime) }
        guard let renderer, let scene = sceneProvider(),
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Portlight present"
        let drawable = update.drawable
        guard renderer.encodeIfNeeded(scene: scene, into: drawable.texture, commandBuffer: commandBuffer) else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        // The link is on the main run loop, so this callback runs on the main thread.
        MainActor.assumeIsolated { self.didPresentFrame() }
    }

    private func didPresentFrame() {
        guard let onFirstFrame else { return }
        self.onFirstFrame = nil
        onFirstFrame()
    }

    // MARK: Geometry

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.windowScene?.screen.nativeScale ?? traitCollection.displayScale
        if contentScaleFactor != scale { contentScaleFactor = scale }
        let drawable = PixelSize(width: Int((bounds.width * scale).rounded()), height: Int((bounds.height * scale).rounded()))
        guard drawable.width > 0, drawable.height > 0 else { return }
        if let metalLayer = layer as? CAMetalLayer {
            let size = CGSize(width: drawable.width, height: drawable.height)
            if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        }
        let safe = bounds.inset(by: safeAreaInsets)
        let usable = DrawableRect(x: Double(safe.minX * scale), y: Double(safe.minY * scale),
                                  width: Double(max(0, safe.width) * scale), height: Double(max(0, safe.height) * scale))
        let geometry = SurfaceGeometry(drawableSize: drawable, usableRect: usable, contentScale: Double(scale))
        guard geometry != lastGeometry else { return }
        lastGeometry = geometry
        onGeometry(geometry)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    // MARK: Touches (raw, multi-touch, forwarded unfiltered)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        var points: [TouchPoint] = []
        for touch in touches {
            let id = nextTouchID
            nextTouchID += 1
            touchIDs[ObjectIdentifier(touch)] = id
            points.append(point(for: touch, id: id))
        }
        onTouch(.began(points.sorted { $0.id < $1.id }), timestamp(touches, event))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let points = touches.compactMap { touch in touchIDs[ObjectIdentifier(touch)].map { point(for: touch, id: $0) } }
        guard !points.isEmpty else { return }
        onTouch(.moved(points.sorted { $0.id < $1.id }), timestamp(touches, event))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        var points: [TouchPoint] = []
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            points.append(point(for: touch, id: id))
        }
        guard !points.isEmpty else { return }
        onTouch(.ended(points.sorted { $0.id < $1.id }), timestamp(touches, event))
    }

    /// The system took the touches (edge gesture, alert, interruption): everything they drove ends.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchIDs.removeAll()
        onTouch(.cancelled, timestamp(touches, event))
    }

    private func point(for touch: UITouch, id: Int) -> TouchPoint {
        let location = touch.location(in: self)
        return TouchPoint(id: id, x: Double(location.x), y: Double(location.y))
    }

    private func timestamp(_ touches: Set<UITouch>, _ event: UIEvent?) -> TimeInterval {
        event?.timestamp ?? touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
    }
}

extension View {
    /// The remote picture as one VoiceOver element (UI-SPEC §11): "Remote screen", its control state and input
    /// mode, with Fit, Actual Size, Displays and Pause/Resume as custom actions. Direct interaction lets
    /// VoiceOver users still use gestures on the picture.
    func remoteSurfaceAccessibility(controlEnabled: Bool, inputMode: InputMode, paused: Bool,
                                    identifier: String = "session.surface",
                                    fit: @escaping @MainActor () -> Void,
                                    actualSize: @escaping @MainActor () -> Void,
                                    displays: @escaping @MainActor () -> Void,
                                    togglePause: @escaping @MainActor () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel("Remote screen")
            .accessibilityValue(paused ? "Paused" : "\(ControlModeButton.title(isOn: controlEnabled)), \(inputMode.chromeTitle)")
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityAction(named: "Fit") { fit() }
            .accessibilityAction(named: "Actual Size") { actualSize() }
            .accessibilityAction(named: "Displays") { displays() }
            .accessibilityAction(named: paused ? "Resume" : "Pause") { togglePause() }
            .accessibilityIdentifier(identifier)
    }
}
