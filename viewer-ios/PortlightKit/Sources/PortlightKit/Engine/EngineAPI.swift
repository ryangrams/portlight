import Foundation

// Public surface of the session engine: the seams it needs injected, its configuration and the
// callbacks it delivers. The engine owns ordering, generations and flow control; it never owns
// pixels, sound, trust decisions or the user's desired state.

/// Decodes one PNG/JPEG patch into memory obtained from `allocate` (the framebuffer's staging pool).
/// Called on the engine's serial decode queue, never concurrently with itself.
public protocol TileDecoding: Sendable {
    /// Throws on corrupt data, a decoded size different from `header.rect`, or when `allocate` returns nil.
    func decode(_ header: FrameHeader, payload: Data, allocate: (Int) -> PatchBuffer?) throws -> DecodedPatch
}

/// Chooses revision 1 right after `welcome`. The engine assigns revisions; the planner's value is ignored.
public protocol SubscriptionPlanner: Sendable {
    /// `previousSelection` nil = deliberate fresh connection: select every valid display (at most 16).
    /// Non-nil = transient reconnect: keep the previously selected IDs that still exist.
    func initialSubscription(for welcome: WelcomeMessage, previousSelection: [DisplayID]?) -> SubscriptionRequest
}

/// One privacy-safe line per control message in or out ("→ subscribe {…}", "← subscribed {…}").
/// Never contains the password, typed text, printable keysyms or pixels. Called on the engine queue.
public protocol TranscriptSink: Sendable {
    func record(_ line: String)
}

/// Engine timing and resource limits. Defaults are the handoff's starting points; tune with evidence.
public struct EngineConfiguration: Equatable, Sendable {
    /// connect → `.opened`. Trust prompts end the attempt, so a user's decision time never counts.
    public var connectDeadline: TimeInterval
    /// Without identity or open by then, the phase turns `.connecting(patient: true)`.
    public var patienceDelay: TimeInterval
    /// `.opened` → `welcome`.
    public var welcomeDeadline: TimeInterval
    public var pingInterval: TimeInterval
    /// The host sends `stats` every second once authenticated, so this much silence means a half-open socket.
    public var readDeadline: TimeInterval
    public var maxDecodeJobs: Int
    public var maxDecodeBytes: Int
    /// Image-failure bursts allowed within `recoveryWindow`; one more fails the session.
    public var recoveryLimit: Int
    public var recoveryWindow: TimeInterval
    public var diagnosticsInterval: TimeInterval
    /// Aggregate canvas budget (four UHD canvases); larger acknowledgements are never allocated.
    public var maxTotalCanvasPixels: Int
    /// The host encoder's hard limit per side.
    public var maxCanvasSide: Int

    public init(connectDeadline: TimeInterval = 10, patienceDelay: TimeInterval = 3, welcomeDeadline: TimeInterval = 10,
                pingInterval: TimeInterval = 2, readDeadline: TimeInterval = 6, maxDecodeJobs: Int = 48,
                maxDecodeBytes: Int = 64 * 1024 * 1024, recoveryLimit: Int = 3, recoveryWindow: TimeInterval = 10,
                diagnosticsInterval: TimeInterval = 0.5, maxTotalCanvasPixels: Int = 33_177_600, maxCanvasSide: Int = 7680) {
        self.connectDeadline = connectDeadline; self.patienceDelay = patienceDelay; self.welcomeDeadline = welcomeDeadline
        self.pingInterval = pingInterval; self.readDeadline = readDeadline; self.maxDecodeJobs = maxDecodeJobs
        self.maxDecodeBytes = maxDecodeBytes; self.recoveryLimit = recoveryLimit; self.recoveryWindow = recoveryWindow
        self.diagnosticsInterval = diagnosticsInterval; self.maxTotalCanvasPixels = maxTotalCanvasPixels
        self.maxCanvasSide = maxCanvasSide
    }
}

/// Everything one connection attempt needs. The password is copied into the attempt, sent once in
/// `hello` after trusted open, then dropped. Descriptions and mirrors never reveal it.
public struct ConnectRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var endpoint: HostEndpoint
    /// nil = first use: any certificate ends the attempt with `.awaitingTrust`.
    public var pin: CertificateFingerprint?
    public var password: String
    public var planner: any SubscriptionPlanner
    /// nil = deliberate fresh connection (all displays); non-nil = transient reconnect.
    public var previousSelection: [DisplayID]?

    public init(endpoint: HostEndpoint, pin: CertificateFingerprint?, password: String, planner: any SubscriptionPlanner,
                previousSelection: [DisplayID]? = nil) {
        self.endpoint = endpoint; self.pin = pin; self.password = password; self.planner = planner
        self.previousSelection = previousSelection
    }
    public var description: String {
        "ConnectRequest(\(endpoint), pinned: \(pin != nil), password: <redacted>, reconnect: \(previousSelection != nil))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["endpoint": endpoint, "pinned": pin != nil, "password": "<redacted>",
                                "previousSelection": previousSelection as Any], displayStyle: .struct)
    }
}

/// Counters for the optional diagnostics view. Reset by every `connect`.
public struct EngineDiagnostics: Equatable, Sendable {
    public var generation: ConnectionGeneration = .none
    /// Binary payload bytes (image and audio). The transport doesn't report wire sizes of text messages.
    public var bytesReceived = 0
    public var textMessages = 0
    public var binaryMessages = 0
    public var framesReceived = 0
    public var framesDecoded = 0
    public var framesCommitted = 0
    /// Old-revision frames (ACKed, never decoded) plus patches the framebuffer discarded as stale.
    public var framesStale = 0
    public var framesRejected = 0
    /// Frames for a revision not yet accepted (ACKed and dropped).
    public var framesUnexpected = 0
    public var acksSent = 0
    public var decodeJobsInFlight = 0
    public var decodeJobsPeak = 0
    public var decodeBytesInFlight = 0
    public var decodeBytesPeak = 0
    public var audioPackets = 0
    public var inputMessagesSent = 0
    public var inputMessagesDropped = 0
    public var subscriptionsSent = 0
    /// `subscribed` for a revision that isn't outstanding (ignored).
    public var subscriptionAcksIgnored = 0
    public var ignoredMessages = 0
    public var lastRTTMilliseconds: Double?
    /// Seconds since the last committed patch; nil before the first.
    public var lastPatchAge: TimeInterval?
    public var recoveries = 0
    /// Host-reported `stats` (the host's `fps` is summed over displays).
    public var hostFPS: Double?
    public var hostInFlightFrames: Int?
    public var hostPendingImageBytes: Int?
    public init() {}
}

/// Session callbacks, delivered on the engine's `delegateQueue` in engine order. A callback is dropped,
/// even when already queued, once a later `connect`, `disconnect` or `cancel` has been called: a retired
/// generation never publishes state. Every method has an empty default. Set `delegate` on that queue.
public protocol SessionEngineDelegate: AnyObject {
    func engine(_ engine: SessionEngine, phaseDidChange phase: ConnectionPhase)
    /// First `welcome` (topologyChange false) or a later `displays` message (true: the host has cleared
    /// its subscription and released input; resubmit the intersected selection).
    func engine(_ engine: SessionEngine, didReceiveWelcome welcome: WelcomeMessage, topologyChange: Bool)
    func engine(_ engine: SessionEngine, didSend request: SubscriptionRequest)
    /// The host released held input when it processed the subscribe, before sending this acknowledgement. It
    /// handles messages in arrival order, so input sent after the subscribe is still held.
    func engine(_ engine: SessionEngine, didAccept ack: SubscribedMessage, for request: SubscriptionRequest)
    /// Non-fatal host errors: topology, capture, subscription, message, other.
    func engine(_ engine: SessionEngine, hostReported error: HostErrorMessage)
    func engine(_ engine: SessionEngine, cursor: CursorMessage)
    func engine(_ engine: SessionEngine, stats: StatsMessage)
    func engine(_ engine: SessionEngine, diagnostics: EngineDiagnostics)
    /// Resubmit the current desired state with `force: true` at a safe input boundary.
    func engine(_ engine: SessionEngine, needsRecoverySubscription reason: String)
    /// Nothing was allocated; the engine already resent the same request paused. Lower the resolution or selection.
    /// The host applied the refused revision and then the paused resend, releasing held input as it processed each.
    func engine(_ engine: SessionEngine, canvasBudgetExceeded ack: SubscribedMessage)
}

public extension SessionEngineDelegate {
    func engine(_ engine: SessionEngine, phaseDidChange phase: ConnectionPhase) {}
    func engine(_ engine: SessionEngine, didReceiveWelcome welcome: WelcomeMessage, topologyChange: Bool) {}
    func engine(_ engine: SessionEngine, didSend request: SubscriptionRequest) {}
    func engine(_ engine: SessionEngine, didAccept ack: SubscribedMessage, for request: SubscriptionRequest) {}
    func engine(_ engine: SessionEngine, hostReported error: HostErrorMessage) {}
    func engine(_ engine: SessionEngine, cursor: CursorMessage) {}
    func engine(_ engine: SessionEngine, stats: StatsMessage) {}
    func engine(_ engine: SessionEngine, diagnostics: EngineDiagnostics) {}
    func engine(_ engine: SessionEngine, needsRecoverySubscription reason: String) {}
    func engine(_ engine: SessionEngine, canvasBudgetExceeded ack: SubscribedMessage) {}
}
