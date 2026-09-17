import Foundation

// Typed Portlight v1 messages. Decoding/encoding lives in Protocol/ (`PortlightWire`); these types
// are the contract every other module programs against.

/// `welcome` and the later `displays` topology message share this shape.
public struct WelcomeMessage: Equatable, Sendable {
    public var version: Int
    public var serverName: String
    public var sessionID: String
    public var displays: [HostDisplay]
    public var capabilities: HostCapabilities
    public init(version: Int, serverName: String, sessionID: String, displays: [HostDisplay], capabilities: HostCapabilities) {
        self.version = version; self.serverName = serverName; self.sessionID = sessionID
        self.displays = displays; self.capabilities = capabilities
    }
}

/// Host acknowledgement of a subscription revision, with the actual full-canvas size per display.
public struct SubscribedMessage: Equatable, Sendable {
    public struct Canvas: Equatable, Sendable {
        public var display: DisplayID
        public var size: PixelSize
        public init(display: DisplayID, size: PixelSize) { self.display = display; self.size = size }
    }
    public var revision: Int
    public var canvases: [Canvas]
    public var paused: Bool
    public var audio: Bool
    public var audioCodec: AudioCodec?
    public var audioBitrate: Int?
    public var resolution: EffectiveResolution?
    public var notice: String?
    public init(revision: Int, canvases: [Canvas], paused: Bool, audio: Bool, audioCodec: AudioCodec?, audioBitrate: Int?, resolution: EffectiveResolution?, notice: String?) {
        self.revision = revision; self.canvases = canvases; self.paused = paused; self.audio = audio
        self.audioCodec = audioCodec; self.audioBitrate = audioBitrate; self.resolution = resolution; self.notice = notice
    }
}

/// Binary `frame` header. `rect` is in full-canvas coordinates; the payload is a PNG or JPEG of `rect`'s size.
public struct FrameHeader: Equatable, Sendable {
    public var revision: Int
    public var display: DisplayID
    public var rect: PixelRect
    public var canvas: PixelSize
    public var codec: ImageCodec
    /// Session-wide sequence shared with audio; gaps are normal.
    public var sequence: Int
    public init(revision: Int, display: DisplayID, rect: PixelRect, canvas: PixelSize, codec: ImageCodec, sequence: Int) {
        self.revision = revision; self.display = display; self.rect = rect; self.canvas = canvas; self.codec = codec; self.sequence = sequence
    }
}

/// Binary `audio` header. Audio packets are never acknowledged.
public struct AudioHeader: Equatable, Sendable {
    public var revision: Int
    public var codec: AudioCodec
    public var sampleRate: Int
    public var channels: Int
    public var samples: Int
    public var sequence: Int
    public var bitrate: Int?
    /// Decoded AAC magic cookie (≤ 4096 bytes); nil for μ-law.
    public var cookie: Data?
    public init(revision: Int, codec: AudioCodec, sampleRate: Int, channels: Int, samples: Int, sequence: Int, bitrate: Int?, cookie: Data?) {
        self.revision = revision; self.codec = codec; self.sampleRate = sampleRate; self.channels = channels
        self.samples = samples; self.sequence = sequence; self.bitrate = bitrate; self.cookie = cookie
    }
}

/// Host cursor position, normalized full-display coordinates.
public struct CursorMessage: Equatable, Sendable {
    public var display: DisplayID
    public var x: Double
    public var y: Double
    public init(display: DisplayID, x: Double, y: Double) { self.display = display; self.x = x; self.y = y }
}

/// Host `stats` (about once per second). Every field is optional for forward compatibility.
public struct StatsMessage: Equatable, Sendable {
    public var bytesSent: Int?
    /// Images encoded with at least one tile in the last interval, summed over displays.
    public var fps: Double?
    public var streamingDisplays: [DisplayID]?
    public var audio: Bool?
    public var resolution: String?
    public var pendingImageBytes: Int?
    public var inFlightFrames: Int?
    public var framesSkippedBackpressure: Int?
    public var meanEncodeMs: Double?
    public init(bytesSent: Int? = nil, fps: Double? = nil, streamingDisplays: [DisplayID]? = nil, audio: Bool? = nil, resolution: String? = nil,
                pendingImageBytes: Int? = nil, inFlightFrames: Int? = nil, framesSkippedBackpressure: Int? = nil, meanEncodeMs: Double? = nil) {
        self.bytesSent = bytesSent; self.fps = fps; self.streamingDisplays = streamingDisplays; self.audio = audio; self.resolution = resolution
        self.pendingImageBytes = pendingImageBytes; self.inFlightFrames = inFlightFrames
        self.framesSkippedBackpressure = framesSkippedBackpressure; self.meanEncodeMs = meanEncodeMs
    }
}

public enum HostErrorCode: Equatable, Sendable {
    case authentication, busy, topology, capture, subscription, timeout, message
    case other(String)
    public init(wire: String) {
        switch wire {
        case "authentication": self = .authentication
        case "busy": self = .busy
        case "topology": self = .topology
        case "capture": self = .capture
        case "subscription": self = .subscription
        case "timeout": self = .timeout
        case "message": self = .message
        default: self = .other(wire)
        }
    }
}

public struct HostErrorMessage: Equatable, Sendable {
    public var code: HostErrorCode
    public var message: String
    public init(code: HostErrorCode, message: String) { self.code = code; self.message = message }
}

public enum InboundMessage: Equatable, Sendable {
    case welcome(WelcomeMessage)
    /// Topology change; same shape as welcome. The host has already cleared its subscription.
    case displays(WelcomeMessage)
    case subscribed(SubscribedMessage)
    case frame(FrameHeader, payload: Data)
    case audio(AudioHeader, payload: Data)
    case cursor(CursorMessage)
    case stats(StatsMessage)
    case pong(time: Double)
    case error(HostErrorMessage)
    /// A well-formed text message of a type this client does not use (forward compatibility).
    case ignored(type: String)
}

/// The complete desired state for one `subscribe`. Every change resends the whole state at a new revision.
public struct SubscriptionRequest: Equatable, Sendable {
    public var revision: Int
    public var displays: [DisplayID]
    public var resolution: ResolutionPreset
    public var color: ColorMode
    public var quality: ContentPriority
    /// Wire field 1...60; the UI never exposes it.
    public var fps: Int
    /// 0 = automatic, otherwise 100...100000.
    public var bandwidthKbps: Int
    public var paused: Bool
    public var audio: Bool
    public var audioCodec: AudioCodec
    public var audioBitrate: AudioQuality
    public var viewOnly: Bool
    /// Omitted display = the entire display. A hidden selected display needs `.zero`.
    public var regions: [DisplayID: NormalizedRect]
    public var dither: Bool
    public init(revision: Int, displays: [DisplayID], resolution: ResolutionPreset, color: ColorMode, quality: ContentPriority,
                fps: Int = 60, bandwidthKbps: Int = 0, paused: Bool = false, audio: Bool = false, audioCodec: AudioCodec = .aac,
                audioBitrate: AudioQuality = .stereo96, viewOnly: Bool = false, regions: [DisplayID: NormalizedRect] = [:], dither: Bool = false) {
        self.revision = revision; self.displays = displays; self.resolution = resolution; self.color = color; self.quality = quality
        self.fps = fps; self.bandwidthKbps = bandwidthKbps; self.paused = paused; self.audio = audio; self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate; self.viewOnly = viewOnly; self.regions = regions; self.dither = dither
    }
    /// Same desired state apart from the revision number. Regions equal to `.full` are treated as omitted.
    public func isEquivalent(to other: SubscriptionRequest) -> Bool {
        var a = self, b = other
        a.revision = 0; b.revision = 0
        a.regions = a.regions.filter { !$0.value.isFull }
        b.regions = b.regions.filter { !$0.value.isFull }
        return a == b
    }
}

public enum OutboundMessage: Equatable, Sendable {
    case hello(password: String)
    case subscribe(SubscriptionRequest)
    case frameAck(sequence: Int)
    case ping(time: Double)
    /// x/y normalized full-display coordinates in [0, 1). The full current button mask on every event.
    case pointer(display: DisplayID, x: Double, y: Double, buttons: MouseButtons)
    /// dx/dy in logical lines; positive dy scrolls up.
    case wheel(display: DisplayID, x: Double, y: Double, dx: Double, dy: Double)
    /// X11/RFB keysym.
    case key(keysym: UInt32, down: Bool)
    /// Committed Unicode text, ≤ 4096 UTF-8 bytes per message.
    case text(String)

    /// Remote-control input (never sent while view-only or paused).
    public var isInput: Bool {
        switch self {
        case .pointer, .wheel, .key, .text: return true
        case .hello, .subscribe, .frameAck, .ping: return false
        }
    }
}

public enum ProtocolError: Error, Equatable, Sendable {
    case controlMessageTooLarge(Int)
    case invalidUTF8
    case invalidJSON
    case nestingTooDeep
    case notAnObject
    case missingType
    case binaryTooShort(Int)
    case binaryTooLarge(Int)
    case invalidHeaderLength(Int)
    case unexpectedBinaryType(String)
    case missingField(String)
    case invalidField(String)
    case unsupportedCodec(String)
    case invalidRectangle
    case duplicateDisplayID(String)
    case tooManyDisplays(Int)
    case outboundInvalid(String)
}

/// Namespace for wire encoding/decoding. Implemented in Protocol/.
public enum PortlightWire {}
