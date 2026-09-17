import Foundation

// Seams between modules. Each protocol has one production implementation and at least one test fake.

// MARK: - Rendering

/// Memory a decoder writes one patch into: BGRA8, premultiplied alpha, top-left origin.
/// Production buffers are Metal staging memory from a bounded pool; tests use heap memory.
/// A buffer has a single owner at a time (decoder, then the sink), so it may cross queues.
public protocol PatchBuffer: AnyObject, Sendable {
    var contents: UnsafeMutableRawPointer { get }
    var byteCount: Int { get }
}

/// A decoded rectangle ready to commit to a display surface in stream order.
public struct DecodedPatch {
    public var header: FrameHeader
    public var buffer: PatchBuffer
    /// Bytes per row in `buffer` (≥ header.rect.width × 4).
    public var bytesPerRow: Int
    public init(header: FrameHeader, buffer: PatchBuffer, bytesPerRow: Int) {
        self.header = header; self.buffer = buffer; self.bytesPerRow = bytesPerRow
    }
}

public enum PatchCommitResult: Equatable, Sendable {
    /// Committed to ordered framebuffer state; the sequence may be acknowledged.
    case committed
    /// No longer matches the accepted revision/canvas (e.g. a newer `subscribed` replaced it). Discarded; still acknowledge.
    case stale
    /// Lost for a local reason (staging memory, GPU resource, malformed patch). Acknowledge to free host
    /// capacity, but the picture is now incomplete: the session must recover with a fresh subscription.
    case failed
}

/// Owner of the per-display pixel surfaces. Implementations must be internally synchronized: the engine
/// calls `acceptRevision` on its engine queue while `makePatchBuffer`/`commit` run on its decode queue, so a
/// commit can race a newer `acceptRevision` (that race is exactly what `.stale` reports). A revision that
/// does not increase marks a new connection: surfaces are kept as the frozen frame but all pixels are invalid
/// until repainted. Call `removeAll()` before connecting to a different computer.
public protocol FramebufferSink: AnyObject, Sendable {
    /// A `subscribed` revision was accepted (called in stream order, before any of its frames).
    /// Keeps a display's surface when its canvas size is unchanged; otherwise prepares a replacement that
    /// becomes visible once the requested region is covered. Displays absent from `canvases` are released.
    func acceptRevision(_ revision: Int, canvases: [DisplayID: PixelSize], requestedRegions: [DisplayID: NormalizedRect])
    /// Staging memory for one decoded patch, or nil when the resource budget is exhausted.
    func makePatchBuffer(byteCount: Int) -> PatchBuffer?
    /// Commit one decoded patch in arrival order. Later patches overwrite earlier ones; untouched pixels persist.
    func commit(_ patch: DecodedPatch) -> PatchCommitResult
    /// True when the display's current picture has valid pixels at the normalized point (input gate).
    func hasValidPixels(display: DisplayID, x: Double, y: Double) -> Bool
    /// Forget every surface (new host or explicit disconnect without frozen-frame retention).
    func removeAll()
}

// MARK: - Audio

/// Audio configuration acknowledged by the host in `subscribed` (nil = audio off).
public struct AudioConfiguration: Equatable, Sendable {
    public var codec: AudioCodec
    public var bitrate: Int
    public init(codec: AudioCodec, bitrate: Int) { self.codec = codec; self.bitrate = bitrate }
}

/// Receives validated audio in stream order from the session pipeline. Owns epochs, decode and playback.
/// The engine calls every method on its engine queue. `audioConfigurationAcknowledged` is called for every
/// `subscribed` the host accepted (even when the phone declines that revision's canvases) and before any
/// packet of that revision. `stopAudio()` is called repeatedly (connect, disconnect, cancel, every terminal
/// failure) and must be idempotent.
public protocol AudioPacketSink: AnyObject, Sendable {
    /// Called in stream order for every accepted `subscribed`. A changed configuration starts a new epoch:
    /// packets stamped with an earlier revision than the epoch start are rejected.
    func audioConfigurationAcknowledged(_ configuration: AudioConfiguration?, revision: Int)
    /// One audio packet that passed wire validation.
    func submit(_ header: AudioHeader, payload: Data)
    /// Stop immediately and discard queued audio (disable, pause, background, disconnect).
    func stopAudio()
}

// MARK: - Persistence

/// Device-local secret storage (Keychain in production). Reads happen only when connecting.
public protocol SecretStore: Sendable {
    func password(for account: String) throws -> String?
    func setPassword(_ password: String, for account: String) throws
    func deletePassword(for account: String) throws
}

/// Exact certificate pins bound to `HostEndpoint.canonicalKey`.
public protocol TrustStore: Sendable {
    func pinnedFingerprint(for endpoint: HostEndpoint) -> CertificateFingerprint?
    func pin(_ fingerprint: CertificateFingerprint, for endpoint: HostEndpoint) throws
    func removePin(for endpoint: HostEndpoint) throws
}

// MARK: - Viewport ↔ rendering

/// Maps compact-desktop logical points to drawable pixels: pixel = point × scale + translation.
public struct ViewportTransform: Equatable, Sendable {
    /// Drawable pixels per desktop point.
    public var scale: Double
    public var tx: Double
    public var ty: Double
    public init(scale: Double, tx: Double, ty: Double) { self.scale = scale; self.tx = tx; self.ty = ty }
    public static let identity = ViewportTransform(scale: 1, tx: 0, ty: 0)
    public func toDrawable(_ point: LogicalPoint) -> (x: Double, y: Double) { (point.x * scale + tx, point.y * scale + ty) }
    /// Inverse mapping; nil when the scale is not usable.
    public func toDesktop(x: Double, y: Double) -> LogicalPoint? {
        guard scale.isFinite, scale > 0 else { return nil }
        return LogicalPoint(x: (x - tx) / scale, y: (y - ty) / scale)
    }
}

/// Everything the renderer needs for one presentation. Built from the viewport model; frames never touch it.
public struct RenderScene: Equatable, Sendable {
    public struct Quad: Equatable, Sendable {
        public var display: DisplayID
        /// Placement in compact-desktop logical points.
        public var frame: LogicalRect
        public init(display: DisplayID, frame: LogicalRect) { self.display = display; self.frame = frame }
    }
    public var transform: ViewportTransform
    public var drawableSize: PixelSize
    public var quads: [Quad]
    /// Local (predicted or host-reported) cursor in compact-desktop points.
    public var cursor: LogicalPoint?
    /// Paused / reconnecting treatment: retained picture drawn dimmed.
    public var dimmed: Bool
    public init(transform: ViewportTransform, drawableSize: PixelSize, quads: [Quad], cursor: LogicalPoint? = nil, dimmed: Bool = false) {
        self.transform = transform; self.drawableSize = drawableSize; self.quads = quads; self.cursor = cursor; self.dimmed = dimmed
    }
}

// MARK: - Input

/// A remote pointer location: normalized full-display coordinates in [0, 1) and the compact-desktop point.
public struct PointerTarget: Equatable, Sendable {
    public var display: DisplayID
    public var x: Double
    public var y: Double
    public var desktop: LogicalPoint
    public init(display: DisplayID, x: Double, y: Double, desktop: LogicalPoint) {
        self.display = display; self.x = x; self.y = y; self.desktop = desktop
    }
}

/// Geometry the input layer needs from the viewport. View points are UIKit points of the session surface.
public protocol PointerMapping {
    /// View points per compact-desktop point at the current zoom (trackpad gain, scroll scaling).
    var viewPointsPerDesktopPoint: Double { get }
    /// Inverse viewport transform; nil when the viewport has no usable geometry.
    func desktopPoint(atViewPoint x: Double, _ y: Double) -> LogicalPoint?
    /// Forward transform for drawing a local cursor or anchoring feedback.
    func viewPoint(atDesktop point: LogicalPoint) -> (x: Double, y: Double)
    /// The selected display under a desktop point (half-open bounds); nil in gaps and letterbox.
    func target(atDesktop point: LogicalPoint) -> PointerTarget?
    /// Nearest point inside any selected display (cursor containment; held drags never leave the desktop).
    func clampToDisplays(_ point: LogicalPoint) -> LogicalPoint
}

public enum InputMode: String, CaseIterable, Sendable, Codable {
    /// Relative cursor movement; taps click at the cursor.
    case trackpad
    /// Taps click where touched; long press then move drags.
    case direct
    /// Local viewport navigation only; remote input suppressed.
    case pan
}

public enum ModifierKey: String, CaseIterable, Sendable, Codable {
    case command, option, shift, control
    /// Left-hand keysym sent to the host.
    public var keysym: UInt32 {
        switch self { case .command: return 0xffeb; case .option: return 0xffe9; case .shift: return 0xffe1; case .control: return 0xffe3 }
    }
    public var symbol: String {
        switch self { case .command: return "⌘"; case .option: return "⌥"; case .shift: return "⇧"; case .control: return "⌃" }
    }
}

/// Sticky modifier state: Off; Latched for the next complete click/drag/key chord; Locked until toggled.
public enum ModifierLatch: String, Sendable, Codable {
    case off, latched, locked
}
