import Foundation

/// Privacy-safe transcript lines. The password is always redacted; typed text is reduced to its byte
/// count and printable keysyms to a placeholder (they spell what the user typed); frames and audio are
/// summarized, never their bytes; the host's name and session ID are omitted (private host details).
enum EngineTranscript {
    static func line(_ message: OutboundMessage) -> String {
        switch message {
        case .hello:
            return "→ hello {version:\(PortlightProtocol.version) password:<redacted> codecs:[\(PortlightProtocol.offeredCodecs.joined(separator: ","))]}"
        case .subscribe(let request):
            return "→ subscribe " + describe(request)
        case .frameAck(let sequence):
            return "→ frameAck {sequence:\(sequence)}"
        case .ping(let time):
            return "→ ping {time:\(number(time))}"
        case .pointer(let display, let x, let y, let buttons):
            return "→ pointer {display:\(display) x:\(number(x)) y:\(number(y)) buttons:\(buttons.rawValue)}"
        case .wheel(let display, let x, let y, let dx, let dy):
            return "→ wheel {display:\(display) x:\(number(x)) y:\(number(y)) dx:\(number(dx)) dy:\(number(dy))}"
        case .key(let keysym, let down):
            return "→ key {key:\(keysymLabel(keysym)) down:\(down)}"
        case .text(let text):
            return "→ text {utf8Bytes:\(text.utf8.count)}"
        }
    }

    static func line(_ message: InboundMessage) -> String {
        switch message {
        case .welcome(let welcome):
            return "← welcome " + describe(welcome)
        case .displays(let welcome):
            return "← displays " + describe(welcome)
        case .subscribed(let ack):
            let canvases = ack.canvases.map { "\($0.display) \($0.size)" }.joined(separator: ",")
            var fields = ["revision:\(ack.revision)", "canvases:[\(canvases)]", "paused:\(ack.paused)", "audio:\(ack.audio)"]
            if let codec = ack.audioCodec { fields.append("audioCodec:\(codec.rawValue)") }
            if let bitrate = ack.audioBitrate { fields.append("audioBitrate:\(bitrate)") }
            if let resolution = ack.resolution { fields.append("resolution:\(describe(resolution))") }
            if let notice = ack.notice { fields.append("notice:\"\(notice)\"") }
            return "← subscribed {\(fields.joined(separator: " "))}"
        case .frame(let header, let payload):
            return "← frame {revision:\(header.revision) display:\(header.display) rect:\(header.rect) canvas:\(header.canvas) codec:\(header.codec.rawValue) sequence:\(header.sequence) bytes:\(payload.count)}"
        case .audio(let header, let payload):
            return "← audio {revision:\(header.revision) codec:\(header.codec.rawValue) sequence:\(header.sequence) bytes:\(payload.count)}"
        case .cursor(let cursor):
            return "← cursor {display:\(cursor.display) x:\(number(cursor.x)) y:\(number(cursor.y))}"
        case .stats(let stats):
            var fields: [String] = []
            if let fps = stats.fps { fields.append("fps:\(number(fps))") }
            if let bytes = stats.bytesSent { fields.append("bytesSent:\(bytes)") }
            if let frames = stats.inFlightFrames { fields.append("inFlightFrames:\(frames)") }
            if let pending = stats.pendingImageBytes { fields.append("pendingImageBytes:\(pending)") }
            if let skipped = stats.framesSkippedBackpressure { fields.append("skipped:\(skipped)") }
            if let resolution = stats.resolution { fields.append("resolution:\(resolution)") }
            return "← stats {\(fields.joined(separator: " "))}"
        case .pong(let time):
            return "← pong {time:\(number(time))}"
        case .error(let error):
            return "← error {code:\(describe(error.code)) message:\"\(error.message)\"}"
        case .ignored(let type):
            return "← \(type) {ignored}"
        }
    }

    static func describe(_ request: SubscriptionRequest) -> String {
        let regions = request.regions.sorted { $0.key < $1.key }
            .map { "\($0.key):(\(number($0.value.x)),\(number($0.value.y)) \(number($0.value.width))×\(number($0.value.height)))" }
            .joined(separator: ",")
        let fields = [
            "revision:\(request.revision)", "displays:[\(request.displays.joined(separator: ","))]",
            "resolution:\(request.resolution.rawValue)", "color:\(request.color.rawValue)", "quality:\(request.quality.rawValue)",
            "fps:\(request.fps)", "bandwidthKbps:\(request.bandwidthKbps)", "paused:\(request.paused)", "audio:\(request.audio)",
            "audioCodec:\(request.audioCodec.rawValue)", "audioBitrate:\(request.audioBitrate.rawValue)",
            "viewOnly:\(request.viewOnly)", "dither:\(request.dither)", "regions:{\(regions)}",
        ]
        return "{\(fields.joined(separator: " "))}"
    }

    private static func describe(_ welcome: WelcomeMessage) -> String {
        let displays = welcome.displays.map { "\($0.id) \($0.nativeSize)" }.joined(separator: ",")
        let caps = welcome.capabilities
        var fields = ["version:\(welcome.version)", "displays:[\(displays)]", "codecs:[\(caps.imageCodecs.joined(separator: ","))]",
                      "audio:[\(caps.audioCodecs.map(\.rawValue).joined(separator: ","))]"]
        if let maxViewers = caps.maxViewers { fields.append("maxViewers:\(maxViewers)") }
        return "{\(fields.joined(separator: " "))}"
    }

    private static func describe(_ resolution: EffectiveResolution) -> String {
        switch resolution { case .native: return "native"; case .preset(let preset): return preset.rawValue }
    }

    private static func describe(_ code: HostErrorCode) -> String {
        switch code {
        case .authentication: return "authentication"; case .busy: return "busy"; case .topology: return "topology"
        case .capture: return "capture"; case .subscription: return "subscription"; case .timeout: return "timeout"
        case .message: return "message"; case .other(let raw): return raw
        }
    }

    /// Function/navigation/modifier keysyms (0xff00–0xffff) are safe to log; anything printable is not.
    private static func keysymLabel(_ keysym: UInt32) -> String {
        (0xff00...0xffff).contains(keysym) ? String(format: "0x%04x", keysym) : "<redacted>"
    }

    private static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.4f", value) : "\(value)"
    }
}
