import Foundation
@testable import PortlightKit

// Foundation-typed helpers for the Session tests (test files import only Testing; see CLAUDE.md).
// Names carry a `Session` prefix because every module's tests share one target.

/// The platform audio session as a recorder: what the controller asked for, plus scripted state changes.
@MainActor
final class SessionFakeAudioControl: SessionAudioControl {
    private(set) var enabledCalls: [Bool] = []
    private(set) var resumeCount = 0
    var state: AudioSessionState = .off
    var onStateChange: ((AudioSessionState) -> Void)?

    func setAudioEnabled(_ enabled: Bool) {
        enabledCalls.append(enabled)
        state = enabled ? .active : .off
    }
    func resume() { resumeCount += 1 }
    /// The last request (false before any).
    var isEnabled: Bool { enabledCalls.last ?? false }
    /// The system changed the audio route (call, headphones unplugged).
    func simulate(_ next: AudioSessionState) {
        state = next
        onStateChange?(next)
    }
}

/// Real PNG payloads built the way the host encodes them, cached by size and color.
enum SessionPNG {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Data] = [:]

    /// A PNG of one solid color (`shade` picks it), exactly `width`×`height`.
    static func solid(width: Int, height: Int, shade: Int = 0) -> Data {
        let key = "\(width)x\(height)#\(shade)"
        if let hit = lock.withLock({ cache[key] }) { return hit }
        let value = UInt8(truncatingIfNeeded: 40 + shade * 37)
        let data = HostTileEncoder.rgbPNG(width: width, height: height) { _, _ in (value, UInt8(255 &- value), 128) }
        lock.withLock { cache[key] = data }
        return data
    }
}

/// A temporary directory for file-backed stores, removed by `remove()`.
struct SessionTempDirectory {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portlight-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
    var path: String { url.path }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// A saved-connection library with one profile, written to a temporary directory.
struct SessionProfileFixture {
    static let profileID = UUID(uuidString: "5E55A0E1-0000-4000-8000-000000000001")!
    static let otherID = UUID(uuidString: "5E55A0E1-0000-4000-8000-000000000002")!

    let directory = SessionTempDirectory()
    let store: ProfileStore

    init(profile: ConnectionProfile) {
        store = ProfileStore(directory: directory.url, now: { Date(timeIntervalSinceReferenceDate: 800_000_000) })
        var library = store.load().library
        library.add(profile)
        library.add(ConnectionProfile(id: Self.otherID, name: "Other", host: "other.local", createdAt: Date(timeIntervalSinceReferenceDate: 0)))
        try? store.save(library)
    }

    /// What is on disk now, read through a separate store instance.
    func stored(_ id: UUID = SessionProfileFixture.profileID) -> ConnectionProfile? {
        ProfileStore(directory: directory.url).load().library.profile(id: id)
    }
    var storedProfileCount: Int { ProfileStore(directory: directory.url).load().library.profiles.count }
}

/// A render loop on its own thread: reads the lock-protected stores and counts presentations the way
/// `MetalRenderer.encodeIfNeeded` does (changed scene or framebuffer content → one draw).
final class SessionRenderProbe: @unchecked Sendable {
    // Invariant for @unchecked Sendable: `samples` is only touched on `queue`; everything else is immutable.
    let presentation: PresentationState
    private let queue = DispatchQueue(label: "test.session.render")
    private var samples: [[UInt64]] = []

    init(framebuffer: SoftwareFramebuffer) {
        presentation = PresentationState { framebuffer.contentGeneration }
    }

    /// One display-link tick, on the render thread.
    func tick(transform: TransformStore, cursor: CursorStore) {
        queue.sync {
            let scene = transform.scene(cursor: cursor)
            let key = PresentationState.Key(scene: scene, generation: presentation.dirtyGeneration,
                                            targetSize: scene.drawableSize, cursorHeight: 36)
            _ = presentation.admit(key)
            samples.append([scene.transform.scale.bitPattern, scene.transform.tx.bitPattern, scene.transform.ty.bitPattern])
        }
    }

    /// The transform bits the render thread saw, one entry per tick.
    var transformBits: [[UInt64]] { queue.sync { samples } }
}

extension SessionTempDirectory {
    /// Text of a file (nil when missing).
    func read(_ name: String) -> String? { try? String(contentsOf: file(name), encoding: .utf8) }
}

/// A `SoftwareFramebuffer` that runs a hook right after `removeAll()`: late traffic of an older connection lands at
/// exactly that point, to prove whether anything of it can still reach the pixels.
final class SessionHookedFramebuffer: FramebufferSink, FramebufferInspecting, @unchecked Sendable {
    // Invariant for @unchecked Sendable: `hook` is only touched while holding `lock`; `base` is itself thread-safe.
    let base = SoftwareFramebuffer()
    private let lock = NSLock()
    private var hook: (@Sendable () -> Void)?

    /// Runs once, after the next `removeAll()`.
    func afterNextRemoveAll(_ body: @escaping @Sendable () -> Void) { lock.withLock { hook = body } }

    func acceptRevision(_ revision: Int, canvases: [DisplayID: PixelSize], requestedRegions: [DisplayID: NormalizedRect]) {
        base.acceptRevision(revision, canvases: canvases, requestedRegions: requestedRegions)
    }
    func makePatchBuffer(byteCount: Int) -> PatchBuffer? { base.makePatchBuffer(byteCount: byteCount) }
    func commit(_ patch: DecodedPatch) -> PatchCommitResult { base.commit(patch) }
    func hasValidPixels(display: DisplayID, x: Double, y: Double) -> Bool { base.hasValidPixels(display: display, x: x, y: y) }
    func removeAll() {
        base.removeAll()
        let pending = lock.withLock { () -> (@Sendable () -> Void)? in defer { hook = nil }; return hook }
        pending?()
    }
    var counters: FramebufferCounters { base.counters }
    var contentGeneration: UInt64 { base.contentGeneration }
    func coverage(display: DisplayID) -> CoverageGrid? { base.coverage(display: display) }
}
