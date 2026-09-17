import Foundation

// Value types and seams the session controller shares with the app. Everything injectable lives in
// `SessionDependencies`, so tests swap the network, clock, pixels, sound and storage for fakes.

/// Adapts `ImageTileDecoder` (ImageIO, BGRA8) to the engine's `TileDecoding` seam.
public struct ImageTileDecoding: TileDecoding {
    public init() {}
    public func decode(_ header: FrameHeader, payload: Data, allocate: (Int) -> PatchBuffer?) throws -> DecodedPatch {
        try ImageTileDecoder.decode(header: header, payload: payload, allocate: allocate)
    }
}

/// Read-only framebuffer bookkeeping for diagnostics and time-to-fresh-region. Both framebuffers conform;
/// a sink that doesn't simply contributes no counters.
public protocol FramebufferInspecting: AnyObject {
    var counters: FramebufferCounters { get }
    /// Bumped whenever the shown pictures may have changed.
    var contentGeneration: UInt64 { get }
    /// Coverage of the shown surface of a display (nil when it has none).
    func coverage(display: DisplayID) -> CoverageGrid?
}

extension SoftwareFramebuffer: FramebufferInspecting {}
extension MetalFramebufferStore: FramebufferInspecting {}

/// The platform audio session (AVAudioSession on iOS) as the controller sees it. All calls and the
/// `onStateChange` callback happen on the main actor.
@MainActor
public protocol SessionAudioControl: AnyObject {
    /// True while the user wants remote audio, the session isn't paused, and the app is in the foreground.
    func setAudioEnabled(_ enabled: Bool)
    /// The user tapped Resume after an interruption or route change.
    func resume()
    var state: AudioSessionState { get }
    /// Set by the controller; called whenever `state` changes.
    var onStateChange: ((AudioSessionState) -> Void)? { get set }
}

/// Everything a `SessionController` needs from outside. Production wires WebSocketTransport, the Metal
/// framebuffer, ImageIO, AudioPipeline, Keychain and files; tests wire fakes and in-memory stores.
public struct SessionDependencies {
    /// One transport per connection attempt.
    public var transportFactory: () -> PortlightTransport
    public var clock: SessionClock
    public var framebuffer: FramebufferSink
    public var decoder: TileDecoding
    public var audio: AudioPacketSink
    /// iOS: `SystemAudioSessionControl` around the pipeline. nil = no platform audio session to manage.
    public var audioControl: SessionAudioControl?
    /// Audio diagnostics (`AudioPipeline.metrics`); read at most twice a second.
    public var audioMetrics: (@Sendable () -> AudioMetrics)?
    /// The renderer's presentation counters (`MetalRenderer.presentation`), for diagnostics.
    public var presentation: PresentationState?
    public var secrets: SecretStore
    public var trust: TrustStore
    /// Where connection preferences are saved; nil disables preference persistence.
    public var profiles: ProfileStore?
    /// Total stream pixels allowed on this device (`RenderBudget.devicePixelBudget`).
    public var pixelBudget: Int
    /// Uniform in [0, 1) for reconnect jitter.
    public var random: @Sendable () -> Double
    public var reconnectPolicy: ReconnectPolicy
    /// Its `maxTotalCanvasPixels` is lowered to `pixelBudget` when larger.
    public var engineConfiguration: EngineConfiguration
    public var gestureConfiguration: GestureConfiguration
    public var transcript: TranscriptSink?
    /// Wall-clock time for `lastConnectedAt`.
    public var wallClock: @Sendable () -> Date

    public init(transportFactory: @escaping () -> PortlightTransport, clock: SessionClock = SystemSessionClock(),
                framebuffer: FramebufferSink, decoder: TileDecoding = ImageTileDecoding(), audio: AudioPacketSink,
                audioControl: SessionAudioControl? = nil, audioMetrics: (@Sendable () -> AudioMetrics)? = nil,
                presentation: PresentationState? = nil, secrets: SecretStore, trust: TrustStore, profiles: ProfileStore? = nil,
                pixelBudget: Int = RenderBudget.devicePixelBudget, random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
                reconnectPolicy: ReconnectPolicy = .standard, engineConfiguration: EngineConfiguration = .init(),
                gestureConfiguration: GestureConfiguration = .standard, transcript: TranscriptSink? = nil,
                wallClock: @escaping @Sendable () -> Date = { Date() }) {
        self.transportFactory = transportFactory; self.clock = clock; self.framebuffer = framebuffer; self.decoder = decoder
        self.audio = audio; self.audioControl = audioControl; self.audioMetrics = audioMetrics; self.presentation = presentation
        self.secrets = secrets; self.trust = trust; self.profiles = profiles; self.pixelBudget = pixelBudget; self.random = random
        self.reconnectPolicy = reconnectPolicy; self.engineConfiguration = engineConfiguration
        self.gestureConfiguration = gestureConfiguration; self.transcript = transcript; self.wallClock = wallClock
    }
}

/// What the host actually applied for the accepted revision (versus the desired `settings`).
public struct EffectiveState: Equatable, Sendable {
    public var revision: Int
    public var displays: [DisplayID]
    public var resolution: EffectiveResolution?
    /// Acknowledged full-canvas sizes; empty when the phone declined them (canvas budget).
    public var canvases: [DisplayID: PixelSize]
    public var paused: Bool
    public var viewOnly: Bool
    public var audioEnabled: Bool
    public var audioCodec: AudioCodec?
    public var audioBitrate: Int?
    public var regions: [DisplayID: NormalizedRect]
    /// The host's `notice` (e.g. why it chose a lower resolution).
    public var hostNotice: String?
    public init(revision: Int, displays: [DisplayID], resolution: EffectiveResolution?, canvases: [DisplayID: PixelSize],
                paused: Bool, viewOnly: Bool, audioEnabled: Bool, audioCodec: AudioCodec?, audioBitrate: Int?,
                regions: [DisplayID: NormalizedRect], hostNotice: String?) {
        self.revision = revision; self.displays = displays; self.resolution = resolution; self.canvases = canvases
        self.paused = paused; self.viewOnly = viewOnly; self.audioEnabled = audioEnabled; self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate; self.regions = regions; self.hostNotice = hostNotice
    }
}

/// Remote audio as the session UI shows it.
public enum SessionAudioState: Equatable, Sendable {
    case off
    /// Requested; waiting for the host's acknowledgement or the first played audio.
    case starting
    case playing
    /// The system took the audio route (call, route change); Resume is offered.
    case interrupted
}

/// Session conditions that Core's `SessionNotice` has no case for. `SessionController.alerts` queues them like
/// `notices` (show the first, then call `dismissAlert()`); show them the same way, with a Resume button when
/// `offersResume`.
public enum SessionAlert: Equatable, Sendable {
    /// The system wouldn't start the audio session. The payload is the system's reason, for diagnostics; the
    /// message doesn't quote it. Resume (`SessionController.resumeAudio()`) tries again.
    case audioFailed(String)
    /// Pasted or committed text was longer than `SessionController.maxTypedCharacters`: only its first
    /// `typedCharacters` characters were typed.
    case textTruncated(typedCharacters: Int)

    public var title: String {
        switch self {
        case .audioFailed: return "Audio Couldn’t Start"
        case .textTruncated: return "Text Shortened"
        }
    }

    public var message: String {
        switch self {
        case .audioFailed:
            return "This iPhone couldn’t start playing the Mac’s audio. Tap Resume to try again."
        case .textTruncated(let count):
            return "Only the first \(count.formatted()) characters were typed on the Mac."
        }
    }

    /// The banner offers Resume, which calls `SessionController.resumeAudio()`.
    public var offersResume: Bool {
        if case .audioFailed = self { return true }
        return false
    }
}

/// SwiftUI `ScenePhase` without SwiftUI.
public enum SessionScenePhase: Equatable, Sendable {
    case active, inactive, background
}

/// Why `connect(profile:typedPassword:)` could not start. Shown inline on the connection form.
public enum SessionConnectError: Error, Equatable, Sendable, LocalizedError {
    case invalidAddress
    /// No typed password and none saved for this computer.
    case passwordRequired
    /// The Keychain refused (its message is user-presentable).
    case keychain(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return ConnectionFailure.invalidAddress.message(for: nil)
        case .passwordRequired: return "Enter the password set in Portlight Host."
        case .keychain(let message): return message
        }
    }
}
