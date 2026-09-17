import Foundation

extension PortlightWire {
    /// Decodes one text WebSocket message (`URLSessionWebSocketTask.Message.string`).
    public static func decodeText(_ text: String) throws -> InboundMessage {
        let byteCount = text.utf8.count
        guard byteCount <= PortlightProtocol.maxControlBytes else { throw ProtocolError.controlMessageTooLarge(byteCount) }
        return try decodeText(Data(text.utf8))
    }

    /// Decodes one text control message from its UTF-8 bytes. Any failure is a `ProtocolError`; a
    /// well-formed message of a type this client doesn't use becomes `.ignored` for forward compatibility.
    public static func decodeText(_ data: Data) throws -> InboundMessage {
        guard data.count <= PortlightProtocol.maxControlBytes else { throw ProtocolError.controlMessageTooLarge(data.count) }
        let object = try StrictJSON.parseObject(data)
        guard let type = object.value("type").flatMap(JSONScalar.string) else { throw ProtocolError.missingType }
        switch type {
        case "welcome": return .welcome(try decodeWelcome(object))
        case "displays": return .displays(try decodeWelcome(object))
        case "subscribed": return .subscribed(try decodeSubscribed(object))
        case "cursor": return .cursor(try decodeCursor(object))
        case "stats": return .stats(decodeStats(object))
        case "pong": return .pong(time: try object.optionalDouble("time") ?? 0)
        case "error": return .error(try decodeError(object))
        default: return .ignored(type: diagnostic(type))
        }
    }

    /// Decodes one binary WebSocket message: a 4-byte big-endian header length N, N bytes of JSON header,
    /// then the payload. Only `frame` and `audio` exist; the payload is returned as a standalone `Data`
    /// (startIndex 0) after the header and payload both validate.
    public static func decodeBinary(_ data: Data) throws -> InboundMessage {
        let count = data.count
        guard count >= 5 else { throw ProtocolError.binaryTooShort(count) }
        guard count <= PortlightProtocol.maxBinaryMessageBytes else { throw ProtocolError.binaryTooLarge(count) }
        let start = data.startIndex
        let headerLength = data[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        guard headerLength > 0, headerLength <= PortlightProtocol.maxBinaryHeaderBytes, headerLength <= count - 4 else {
            throw ProtocolError.invalidHeaderLength(headerLength)
        }
        let payloadStart = start + 4 + headerLength
        let header = try StrictJSON.parseObject(data[(start + 4)..<payloadStart])
        guard let type = header.value("type").flatMap(JSONScalar.string) else { throw ProtocolError.missingType }
        // Validated in place, copied once, so consumers never see a slice with a non-zero startIndex.
        let payload = data[payloadStart...]
        switch type {
        case "frame":
            let frame = try decodeFrameHeader(header, payload: payload)
            return .frame(frame, payload: data.subdata(in: payloadStart..<data.endIndex))
        case "audio":
            let audio = try decodeAudioHeader(header, payload: payload)
            return .audio(audio, payload: data.subdata(in: payloadStart..<data.endIndex))
        default:
            throw ProtocolError.unexpectedBinaryType(diagnostic(type))
        }
    }

    // MARK: - Text messages

    /// `welcome` and `displays` share one shape.
    private static func decodeWelcome(_ object: JSONFields) throws -> WelcomeMessage {
        guard try object.int("version") == PortlightProtocol.version else { throw ProtocolError.invalidField("version") }
        let serverName = try object.optionalString("serverName").flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
        let sessionID = try object.optionalString("sessionId") ?? ""
        let rows = try object.array("displays")
        guard rows.count <= Limits.maxAdvertisedDisplays else { throw ProtocolError.tooManyDisplays(rows.count) }
        guard !rows.isEmpty else { throw ProtocolError.invalidField("displays") }
        var displays: [HostDisplay] = []
        var seen = Set<DisplayID>()
        var nextRowX = 0.0
        for index in rows.indices {
            let row = try object.object(in: rows, at: index, of: "displays")
            let id = try row.displayID("id")
            guard seen.insert(id).inserted else { throw ProtocolError.duplicateDisplayID(id) }
            let display = try decodeHostDisplay(row, id: id, number: index + 1, fallbackX: nextRowX)
            displays.append(display)
            nextRowX += display.logicalFrame.width
        }
        let capabilities = try decodeCapabilities(object.optionalObject("capabilities"))
        return WelcomeMessage(version: PortlightProtocol.version, serverName: serverName, sessionID: sessionID,
                              displays: displays, capabilities: capabilities)
    }

    /// Host display geometry in logical points. Missing pieces are derived so native pixels, scale and
    /// logical size stay consistent. A row without `x` continues a left-to-right row using LOGICAL widths
    /// (the Mac viewer summed native pixels here, which mixes units on Retina displays); missing `y` is 0.
    private static func decodeHostDisplay(_ row: JSONFields, id: DisplayID, number: Int, fallbackX: Double) throws -> HostDisplay {
        let width = try row.int("width", in: Limits.nativeSideRange)
        let height = try row.int("height", in: Limits.nativeSideRange)
        let name = try row.optionalString("name").flatMap { $0.isEmpty ? nil : $0 } ?? "Display \(number)"
        let x = try row.logicalCoordinate("x") ?? fallbackX
        let y = try row.logicalCoordinate("y") ?? 0
        // Out-of-range logical sizes and scales fall back to derived values rather than failing the row.
        let logicalWidth = try row.optionalDouble("logicalWidth").flatMap(validLogicalLength)
        let logicalHeight = try row.optionalDouble("logicalHeight").flatMap(validLogicalLength)
        let scale: Double
        if let advertised = try row.optionalDouble("scale"), Limits.scaleRange.contains(advertised) {
            scale = advertised
        } else if let logicalWidth {
            scale = clampScale(Double(width) / logicalWidth)
        } else if let logicalHeight {
            scale = clampScale(Double(height) / logicalHeight)
        } else {
            scale = 1
        }
        let frame = LogicalRect(x: x, y: y, width: logicalWidth ?? Double(width) / scale, height: logicalHeight ?? Double(height) / scale)
        return HostDisplay(id: id, name: name, number: number, nativeSize: PixelSize(width: width, height: height),
                           logicalFrame: frame, scale: scale, isPrimary: try row.optionalBool("primary") ?? false)
    }

    private static func validLogicalLength(_ value: Double) -> Double? {
        value > 0 && value <= Limits.maxLogicalMagnitude ? value : nil
    }

    private static func clampScale(_ value: Double) -> Double {
        min(Limits.scaleRange.upperBound, max(Limits.scaleRange.lowerBound, value))
    }

    /// Absent capabilities advertise nothing, so a missing audio list never inherits a previous host's audio.
    private static func decodeCapabilities(_ object: JSONFields?) throws -> HostCapabilities {
        guard let object else { return HostCapabilities(imageCodecs: [], audioCodecs: [], colorModes: [], maxViewers: nil) }
        var audioCodecs: [AudioCodec] = []
        for name in try object.optionalStrings("audio") ?? [] {
            if let codec = AudioCodec(rawValue: name), !audioCodecs.contains(codec) { audioCodecs.append(codec) }
        }
        return try HostCapabilities(imageCodecs: object.optionalStrings("codecs") ?? [], audioCodecs: audioCodecs,
                                    colorModes: object.optionalStrings("colorModes") ?? [], maxViewers: object.optionalInt("maxViewers"))
    }

    /// Canvas sizes are validated here because the renderer allocates from them. More rows than the
    /// wire's subscription limit can't answer any request this client could have sent.
    private static func decodeSubscribed(_ object: JSONFields) throws -> SubscribedMessage {
        let revision = try object.nonNegativeInt("revision")
        let rows = try object.array("displays")
        guard rows.count <= PortlightProtocol.maxSubscribedDisplays else { throw ProtocolError.tooManyDisplays(rows.count) }
        var canvases: [SubscribedMessage.Canvas] = []
        var seen = Set<DisplayID>()
        for index in rows.indices {
            let row = try object.object(in: rows, at: index, of: "displays")
            let id = try row.displayID("id")
            guard seen.insert(id).inserted else { throw ProtocolError.duplicateDisplayID(id) }
            let size = try PixelSize(width: row.int("width", in: Limits.canvasSideRange), height: row.int("height", in: Limits.canvasSideRange))
            canvases.append(SubscribedMessage.Canvas(display: id, size: size))
        }
        return try SubscribedMessage(
            revision: revision, canvases: canvases,
            paused: object.optionalBool("paused") ?? false,
            audio: object.optionalBool("audio") ?? false,
            audioCodec: object.optionalString("audioCodec").flatMap(AudioCodec.init(rawValue:)),
            audioBitrate: object.optionalInt("audioBitrate"),
            resolution: object.optionalString("resolution").flatMap(EffectiveResolution.init(wire:)),
            notice: object.optionalString("notice").map { String($0.prefix(Limits.maxNoticeCharacters)) })
    }

    private static func decodeCursor(_ object: JSONFields) throws -> CursorMessage {
        try CursorMessage(display: object.displayID("display"), x: object.unitDouble("x"), y: object.unitDouble("y"))
    }

    /// Diagnostics only: every field is optional and a mistyped one is dropped, never fatal.
    private static func decodeStats(_ object: JSONFields) -> StatsMessage {
        StatsMessage(
            bytesSent: object.lenient("bytesSent", JSONScalar.int),
            fps: object.lenient("fps", JSONScalar.double),
            streamingDisplays: object.lenient("streamingDisplays") { raw -> [DisplayID]? in
                guard let items = raw as? [Any] else { return nil }
                let ids = items.compactMap(JSONScalar.string)
                return ids.count == items.count ? ids : nil
            },
            audio: object.lenient("audio", JSONScalar.bool),
            resolution: object.lenient("resolution", JSONScalar.string),
            pendingImageBytes: object.lenient("pendingImageBytes", JSONScalar.int),
            inFlightFrames: object.lenient("inFlightFrames", JSONScalar.int),
            framesSkippedBackpressure: object.lenient("framesSkippedBackpressure", JSONScalar.int),
            meanEncodeMs: object.lenient("meanEncodeMs", JSONScalar.double))
    }

    private static func decodeError(_ object: JSONFields) throws -> HostErrorMessage {
        try HostErrorMessage(code: HostErrorCode(wire: diagnostic(object.string("code"))), message: object.optionalString("message") ?? "")
    }

    // MARK: - Binary headers

    private static func decodeFrameHeader(_ header: JSONFields, payload: Data) throws -> FrameHeader {
        let revision = try header.nonNegativeInt("revision")
        let display = try header.displayID("display")
        let x = try header.nonNegativeInt("x")
        let y = try header.nonNegativeInt("y")
        let width = try header.int("width", in: 1...Int.max)
        let height = try header.int("height", in: 1...Int.max)
        let canvas = try PixelSize(width: header.int("canvasWidth", in: Limits.canvasSideRange),
                                   height: header.int("canvasHeight", in: Limits.canvasSideRange))
        let codecName = try header.string("codec")
        guard let codec = ImageCodec(rawValue: codecName) else { throw ProtocolError.unsupportedCodec(diagnostic(codecName)) }
        let sequence = try header.nonNegativeInt("sequence")
        let rect = PixelRect(x: x, y: y, width: width, height: height)
        guard rect.fits(in: canvas) else { throw ProtocolError.invalidRectangle }
        // A payload that isn't the declared format is corrupt framing, not something to hand ImageIO to sniff.
        guard (1...Limits.maxFramePayloadBytes).contains(payload.count), payload.starts(with: signature(of: codec)) else {
            throw ProtocolError.invalidField("payload")
        }
        return FrameHeader(revision: revision, display: display, rect: rect, canvas: canvas, codec: codec, sequence: sequence)
    }

    /// Leading bytes every payload of the declared codec starts with: the PNG signature, or JPEG SOI plus a marker.
    private static func signature(of codec: ImageCodec) -> [UInt8] {
        switch codec {
        case .png: return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        case .jpeg: return [0xFF, 0xD8, 0xFF]
        }
    }

    /// Only the formats the host produces are accepted: AAC-LC 48 kHz, 1024 samples, with its decoder cookie
    /// (shared/AAC.swift), or μ-law 24 kHz mono with one byte per sample.
    private static func decodeAudioHeader(_ header: JSONFields, payload: Data) throws -> AudioHeader {
        let revision = try header.nonNegativeInt("revision")
        let codecName = try header.string("codec")
        guard let codec = AudioCodec(rawValue: codecName) else { throw ProtocolError.unsupportedCodec(diagnostic(codecName)) }
        let sequence = try header.nonNegativeInt("sequence")
        let sampleRate = try header.int("sampleRate")
        let channels = try header.int("channels")
        let samples = try header.int("samples")
        let bitrate = try header.optionalInt("bitrate")
        switch codec {
        case .aac:
            guard sampleRate == Limits.aacSampleRate else { throw ProtocolError.invalidField("sampleRate") }
            guard channels == 1 || channels == 2 else { throw ProtocolError.invalidField("channels") }
            guard samples == Limits.aacSamplesPerPacket else { throw ProtocolError.invalidField("samples") }
            let encodedCookie = try header.string("cookie")
            guard encodedCookie.utf8.count <= Limits.maxCookieBase64Characters, let cookie = Data(base64Encoded: encodedCookie),
                  Limits.aacCookieBytes.contains(cookie.count) else { throw ProtocolError.invalidField("cookie") }
            guard Limits.aacPacketBytes.contains(payload.count) else { throw ProtocolError.invalidField("payload") }
            return AudioHeader(revision: revision, codec: .aac, sampleRate: sampleRate, channels: channels, samples: samples,
                               sequence: sequence, bitrate: bitrate, cookie: cookie)
        case .mulaw:
            guard sampleRate == Limits.muLawSampleRate else { throw ProtocolError.invalidField("sampleRate") }
            guard channels == 1 else { throw ProtocolError.invalidField("channels") }
            guard Limits.muLawPacketBytes.contains(payload.count) else { throw ProtocolError.invalidField("payload") }
            guard samples == payload.count else { throw ProtocolError.invalidField("samples") }
            return AudioHeader(revision: revision, codec: .mulaw, sampleRate: sampleRate, channels: channels, samples: samples,
                               sequence: sequence, bitrate: bitrate, cookie: nil)
        }
    }
}

private extension PortlightWire.JSONFields {
    func int(_ key: String, in range: ClosedRange<Int>) throws -> Int {
        let value = try int(key)
        guard range.contains(value) else { throw ProtocolError.invalidField(fieldPath(key)) }
        return value
    }

    func nonNegativeInt(_ key: String) throws -> Int {
        try int(key, in: 0...Int.max)
    }

    func displayID(_ key: String) throws -> DisplayID {
        let id = try string(key)
        guard PortlightWire.isValidDisplayID(id) else { throw ProtocolError.invalidField(fieldPath(key)) }
        return id
    }

    /// Normalized coordinate in the closed range 0...1.
    func unitDouble(_ key: String) throws -> Double {
        let value = try double(key)
        guard (0...1).contains(value) else { throw ProtocolError.invalidField(fieldPath(key)) }
        return value
    }

    /// Optional logical origin component bounded to ±131072 points.
    func logicalCoordinate(_ key: String) throws -> Double? {
        guard let value = try optionalDouble(key) else { return nil }
        guard abs(value) <= PortlightWire.Limits.maxLogicalMagnitude else { throw ProtocolError.invalidField(fieldPath(key)) }
        return value
    }
}
