import Foundation

extension PortlightWire {
    /// Encodes one outbound control message as compact UTF-8 JSON with sorted keys and unescaped slashes.
    /// Integers stay JSON integers and booleans stay `true`/`false`, matching the host's `as? Int` and
    /// `as? Bool` reads (Server.swift `handle`, `applySubscription`, `handleInput`). A value the host would
    /// reject or misread throws `ProtocolError.outboundInvalid(field)` instead of reaching the wire; callers
    /// clamp pointer coordinates and choose valid settings.
    public static func encode(_ message: OutboundMessage) throws -> String {
        let object: [String: Any]
        switch message {
        case .hello(let password):
            guard password.utf8.count <= Limits.maxPasswordBytes else { throw ProtocolError.outboundInvalid("password") }
            object = ["type": "hello", "version": integer(PortlightProtocol.version), "password": password,
                      "codecs": PortlightProtocol.offeredCodecs]
        case .subscribe(let request):
            object = try subscription(request)
        case .frameAck(let sequence):
            guard sequence >= 0 else { throw ProtocolError.outboundInvalid("sequence") }
            object = ["type": "frameAck", "sequence": integer(sequence)]
        case .ping(let time):
            guard time.isFinite else { throw ProtocolError.outboundInvalid("time") }
            object = ["type": "ping", "time": number(time)]
        case let .pointer(display, x, y, buttons):
            var fields = try pointerTarget(display: display, x: x, y: y)
            guard Limits.buttonMaskRange.contains(buttons.rawValue) else { throw ProtocolError.outboundInvalid("buttons") }
            fields["type"] = "pointer"
            fields["buttons"] = integer(buttons.rawValue)
            object = fields
        case let .wheel(display, x, y, dx, dy):
            var fields = try pointerTarget(display: display, x: x, y: y)
            fields["type"] = "wheel"
            fields["dx"] = try wheelLines(dx, field: "dx")
            fields["dy"] = try wheelLines(dy, field: "dy")
            object = fields
        case let .key(keysym, down):
            object = ["type": "key", "key": integer(Int(keysym)), "down": boolean(down)]
        case .text(let text):
            guard !text.isEmpty, text.utf8.count <= PortlightProtocol.maxTextInputBytes else { throw ProtocolError.outboundInvalid("text") }
            object = ["type": "text", "text": text]
        }
        return try serialize(object)
    }

    /// The complete desired state; every field is always present so the host never falls back to its defaults.
    private static func subscription(_ request: SubscriptionRequest) throws -> [String: Any] {
        guard request.revision >= 0 else { throw ProtocolError.outboundInvalid("revision") }
        let selected = Set(request.displays)
        guard request.displays.count <= PortlightProtocol.maxSubscribedDisplays, selected.count == request.displays.count,
              request.displays.allSatisfy(isValidDisplayID) else { throw ProtocolError.outboundInvalid("displays") }
        guard Limits.fpsRange.contains(request.fps) else { throw ProtocolError.outboundInvalid("fps") }
        guard request.bandwidthKbps == 0 || Limits.bandwidthKbpsRange.contains(request.bandwidthKbps) else {
            throw ProtocolError.outboundInvalid("bandwidthKbps")
        }
        var regions: [String: Any] = [:]
        // Sorted so the reported field is deterministic when several entries are invalid.
        for (display, region) in request.regions.sorted(by: { $0.key < $1.key }) {
            guard selected.contains(display), region.isValid else { throw ProtocolError.outboundInvalid("regions.\(diagnostic(display))") }
            // The host reads an omitted display as the entire display; `.zero` must stay explicit.
            if region.isFull { continue }
            regions[display] = ["x": number(region.x), "y": number(region.y), "width": number(region.width), "height": number(region.height)]
        }
        let box = request.resolution.box
        return [
            "type": "subscribe",
            "revision": integer(request.revision),
            "displays": request.displays,
            "maxWidth": integer(box.width),
            "maxHeight": integer(box.height),
            "color": request.color.rawValue,
            "quality": request.quality.rawValue,
            "fps": integer(request.fps),
            "bandwidthKbps": integer(request.bandwidthKbps),
            "paused": boolean(request.paused),
            "audio": boolean(request.audio),
            "audioCodec": request.audioCodec.rawValue,
            "audioBitrate": integer(request.audioBitrate.rawValue),
            "viewOnly": boolean(request.viewOnly),
            "regions": regions,
            "dither": boolean(request.dither),
        ]
    }

    /// Normalized full-display coordinates use the half-open range [0, 1) (the host also takes 1, but
    /// that point lies outside the display on every other client).
    private static func pointerTarget(display: DisplayID, x: Double, y: Double) throws -> [String: Any] {
        guard isValidDisplayID(display) else { throw ProtocolError.outboundInvalid("display") }
        guard x.isFinite, (0..<1).contains(x) else { throw ProtocolError.outboundInvalid("x") }
        guard y.isFinite, (0..<1).contains(y) else { throw ProtocolError.outboundInvalid("y") }
        return ["display": display, "x": number(x), "y": number(y)]
    }

    private static func wheelLines(_ lines: Double, field: String) throws -> NSNumber {
        guard lines.isFinite else { throw ProtocolError.outboundInvalid(field) }
        return number(min(Limits.maxWheelLines, max(-Limits.maxWheelLines, lines)))
    }

    /// Explicit NSNumber kinds so JSONSerialization writes `1`, never `1.0` or `true`.
    private static func integer(_ value: Int) -> NSNumber { NSNumber(value: value) }
    private static func boolean(_ value: Bool) -> NSNumber { NSNumber(value: value) }
    /// Negative zero is normalized so the output never contains `-0`.
    private static func number(_ value: Double) -> NSNumber { NSNumber(value: value == 0 ? 0 : value) }

    private static func serialize(_ object: [String: Any]) throws -> String {
        // JSONSerialization raises an Objective-C exception, not a Swift error, for NaN or unsupported values.
        guard JSONSerialization.isValidJSONObject(object) else { throw ProtocolError.outboundInvalid("json") }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw ProtocolError.outboundInvalid("json")
        }
        guard data.count <= PortlightProtocol.maxControlBytes else { throw ProtocolError.outboundInvalid("size") }
        return String(decoding: data, as: UTF8.self)
    }
}
