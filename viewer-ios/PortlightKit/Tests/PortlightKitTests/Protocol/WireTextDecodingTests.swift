import Testing
@testable import PortlightKit

@Suite("Wire: text control messages")
struct WireTextDecodingTests {
    private typealias F = WireFixtures

    private static func decodeWelcome(_ text: String) throws -> WelcomeMessage {
        let message = try PortlightWire.decodeText(text)
        guard case .welcome(let welcome) = message else { throw UnexpectedWireMessage(message: message) }
        return welcome
    }

    private static func decodeSubscribed(_ text: String) throws -> SubscribedMessage {
        let message = try PortlightWire.decodeText(text)
        guard case .subscribed(let subscribed) = message else { throw UnexpectedWireMessage(message: message) }
        return subscribed
    }

    // MARK: - Framing and JSON shape

    @Test func controlMessagesAreCappedAt64KiB() throws {
        let body = #"{"type":"stats"}"#
        let padded = body + String(repeating: " ", count: PortlightProtocol.maxControlBytes - body.utf8.count)
        #expect(try PortlightWire.decodeText(padded) == .stats(StatsMessage()))
        #expect(try PortlightWire.decodeText(F.Bytes(padded.utf8)) == .stats(StatsMessage()))
        F.expectText(.controlMessageTooLarge(65_537), padded + " ")
        F.expectText(.controlMessageTooLarge(65_537), bytes: F.Bytes((padded + " ").utf8))
        // Measured in UTF-8 bytes, not characters: 32 769 × "é" is 65 538 bytes.
        F.expectText(.controlMessageTooLarge(65_538), String(repeating: "é", count: 32_769))
    }

    @Test func truncatedJSONIsInvalid() {
        let full = F.fixtureWelcomeJSON
        for cut in [1, 2, 20, full.utf8.count / 2, full.utf8.count - 1] {
            F.expectText(.invalidJSON, String(full.prefix(cut)), "cut at \(cut)")
        }
    }

    @Test func nonObjectJSONIsRejected() {
        for literal in ["[]", #"[{"type":"welcome"}]"#, "42", #""welcome""#, "null", "true"] {
            F.expectText(.notAnObject, literal, "\(literal)")
        }
        F.expectText(.invalidJSON, "")
        F.expectText(.invalidJSON, "  \n ")
    }

    @Test func invalidUTF8IsRejectedBeforeParsing() {
        let prefix = Array(#"{"type":"stats","resolution":""#.utf8)
        let suffix = Array(#""}"#.utf8)
        let samples: [[UInt8]] = [[0xFF], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xE2, 0x82], [0xF4, 0x90, 0x80, 0x80]]
        for bad in samples {
            F.expectText(.invalidUTF8, bytes: F.Bytes(prefix + bad + suffix), "\(bad)")
        }
        // A UTF-16 byte-order mark is not UTF-8.
        let byteOrderMark: [UInt8] = [0xFE, 0xFF]
        F.expectText(.invalidUTF8, bytes: F.Bytes(byteOrderMark + Array(#"{"type":"stats"}"#.utf8)))
    }

    @Test func nestingBombsAreRejected() throws {
        F.expectText(.nestingTooDeep, String(repeating: "[", count: 60_000))
        F.expectText(.nestingTooDeep, #"{"type":"stats","a":"# + String(repeating: "[", count: 16) + String(repeating: "]", count: 16) + "}")
        let deepest = #"{"type":"stats","a":"# + String(repeating: "[", count: 15) + String(repeating: "]", count: 15) + "}"
        #expect(try PortlightWire.decodeText(deepest) == .stats(StatsMessage()))
    }

    @Test func typeMustBeAString() {
        for literal in ["{}", #"{"type":3}"#, #"{"type":null}"#, #"{"type":true}"#, #"{"type":["welcome"]}"#, #"{"Type":"welcome"}"#] {
            F.expectText(.missingType, literal, "\(literal)")
        }
    }

    @Test func unknownTextTypesAreIgnored() throws {
        #expect(try PortlightWire.decodeText(#"{"type":"clipboard","text":"hi"}"#) == .ignored(type: "clipboard"))
        // Binary-only and client-only types carry nothing this client acts on as text.
        #expect(try PortlightWire.decodeText(#"{"type":"frame","sequence":1}"#) == .ignored(type: "frame"))
        #expect(try PortlightWire.decodeText(#"{"type":"hello","version":1}"#) == .ignored(type: "hello"))
        #expect(try PortlightWire.decodeText(#"{"type":""}"#) == .ignored(type: ""))
        // The reported type is bounded for diagnostics.
        let long = String(repeating: "x", count: 500)
        #expect(try PortlightWire.decodeText(#"{"type":"\#(long)"}"#) == .ignored(type: String(repeating: "x", count: 64)))
    }

    // MARK: - welcome / displays

    @Test func fixtureWelcomeLiteral() throws {
        #expect(try PortlightWire.decodeText(F.fixtureWelcomeJSON) == .welcome(F.fixtureWelcome))
    }

    @Test func fixtureWelcomeAsTheHostSerializesIt() throws {
        #expect(try PortlightWire.decodeText(F.hostFixtureWelcome()) == .welcome(F.fixtureWelcome))
        // A topology change reuses the welcome shape.
        #expect(try PortlightWire.decodeText(F.hostFixtureWelcome(type: "displays")) == .displays(F.fixtureWelcome))
    }

    @Test func realHostWelcomeWithMixedDisplays() throws {
        // Retina built-in, a portrait display at a negative origin, and a 1.5× display; real hosts offer both audio codecs.
        let text = #"{"capabilities":{"audio":["mulaw","aac"],"codecs":["png","jpeg"],"colorModes":["gray16","color256","rgb565","full"],"maxViewers":1},"displays":[{"height":1964,"id":"37D8832A-2D66-02CA-B9F7-8F30A301B230","index":1,"logicalHeight":982,"logicalWidth":1512,"name":"Built-in Retina Display","primary":true,"scale":2,"width":3024,"x":0,"y":0},{"height":3840,"id":"display-3","index":2,"logicalHeight":1920,"logicalWidth":1080,"name":"LG UltraFine","primary":false,"scale":2,"width":2160,"x":-1080,"y":-938},{"height":1620,"id":"6E1F4A0B-93C2-4D55-8E7A-1B2C3D4E5F60","index":3,"logicalHeight":1080,"logicalWidth":1920,"name":"Studio Display","primary":false,"scale":1.5,"width":2880,"x":1512,"y":0}],"serverName":"Studio Mac","sessionId":"0B6D3C9E-2F41-4A8B-9C7D-5E6F7A8B9C0D","type":"welcome","version":1}"#
        let retina = HostDisplay(id: "37D8832A-2D66-02CA-B9F7-8F30A301B230", name: "Built-in Retina Display", number: 1,
                                 nativeSize: PixelSize(width: 3024, height: 1964), logicalFrame: LogicalRect(x: 0, y: 0, width: 1512, height: 982),
                                 scale: 2, isPrimary: true)
        let portrait = HostDisplay(id: "display-3", name: "LG UltraFine", number: 2, nativeSize: PixelSize(width: 2160, height: 3840),
                                   logicalFrame: LogicalRect(x: -1080, y: -938, width: 1080, height: 1920), scale: 2, isPrimary: false)
        let studio = HostDisplay(id: "6E1F4A0B-93C2-4D55-8E7A-1B2C3D4E5F60", name: "Studio Display", number: 3,
                                 nativeSize: PixelSize(width: 2880, height: 1620), logicalFrame: LogicalRect(x: 1512, y: 0, width: 1920, height: 1080),
                                 scale: 1.5, isPrimary: false)
        let capabilities = HostCapabilities(imageCodecs: ["png", "jpeg"], audioCodecs: [.mulaw, .aac],
                                            colorModes: ["gray16", "color256", "rgb565", "full"], maxViewers: 1)
        let expected = WelcomeMessage(version: 1, serverName: "Studio Mac", sessionID: "0B6D3C9E-2F41-4A8B-9C7D-5E6F7A8B9C0D",
                                      displays: [retina, portrait, studio], capabilities: capabilities)
        let welcome = try Self.decodeWelcome(text)
        #expect(welcome == expected)
        #expect(welcome.capabilities.preferredAudioCodec == .aac)
    }

    @Test func capabilityAudioListKeepsKnownCodecsOnce() throws {
        let text = F.welcomeText { $0["capabilities"] = ["audio": ["opus", "aac", "mulaw", "aac"], "futureCapability": true] as [String: Any] }
        let welcome = try Self.decodeWelcome(text)
        #expect(welcome.capabilities == HostCapabilities(imageCodecs: [], audioCodecs: [.aac, .mulaw], colorModes: [], maxViewers: nil))
    }

    @Test func welcomeDefaultsAndLogicalRowFallback() throws {
        // No origins, names, primary flags, serverName, sessionId or capabilities.
        let text = F.welcomeText(rows: [
            F.displayRow("retina", width: 3840, height: 2160, ["scale": 2]),
            F.displayRow("hd", width: 1920, height: 1080),
            F.displayRow("scaled", width: 2560, height: 1440, ["logicalWidth": 1280, "logicalHeight": 720]),
        ])
        let retina = HostDisplay(id: "retina", name: "Display 1", number: 1, nativeSize: PixelSize(width: 3840, height: 2160),
                                 logicalFrame: LogicalRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2, isPrimary: false)
        // Placed after row 1's LOGICAL width (1920), not its native width (3840) as the Mac viewer did.
        let hd = HostDisplay(id: "hd", name: "Display 2", number: 2, nativeSize: PixelSize(width: 1920, height: 1080),
                             logicalFrame: LogicalRect(x: 1920, y: 0, width: 1920, height: 1080), scale: 1, isPrimary: false)
        let scaled = HostDisplay(id: "scaled", name: "Display 3", number: 3, nativeSize: PixelSize(width: 2560, height: 1440),
                                 logicalFrame: LogicalRect(x: 3840, y: 0, width: 1280, height: 720), scale: 2, isPrimary: false)
        let expected = WelcomeMessage(version: 1, serverName: "Mac", sessionID: "", displays: [retina, hd, scaled],
                                      capabilities: HostCapabilities(imageCodecs: [], audioCodecs: [], colorModes: [], maxViewers: nil))
        #expect(try Self.decodeWelcome(text) == expected)
    }

    @Test func partialOriginsAndEmptyNames() throws {
        let text = F.welcomeText(rows: [
            F.displayRow("a", width: 1920, height: 1080, ["x": 100, "name": ""]), // missing y is 0
            F.displayRow("b", width: 1920, height: 1080, ["y": 540]),             // missing x continues the row
        ], extra: ["serverName": ""])
        let welcome = try Self.decodeWelcome(text)
        #expect(welcome.serverName == "Mac")
        #expect(welcome.displays.map(\.name) == ["Display 1", "Display 2"])
        #expect(welcome.displays.map(\.logicalFrame) == [LogicalRect(x: 100, y: 0, width: 1920, height: 1080),
                                                         LogicalRect(x: 1920, y: 540, width: 1920, height: 1080)])
    }

    @Test func scaleAndLogicalSizeDerivation() throws {
        /// Decodes one 3840×2160 display row carrying `extra` and checks the derived scale and logical size.
        func expectGeometry(_ name: Comment, _ extra: [String: Any], scale: Double, width: Double, height: Double) throws {
            let welcome = try Self.decodeWelcome(F.welcomeText(rows: [F.displayRow("d", width: 3840, height: 2160, extra)]))
            let display = try #require(welcome.displays.first, name)
            #expect(display.scale == scale, name)
            #expect(display.logicalFrame.width == width, name)
            #expect(display.logicalFrame.height == height, name)
        }
        try expectGeometry("scale from logical size", ["logicalWidth": 1920, "logicalHeight": 1080], scale: 2, width: 1920, height: 1080)
        try expectGeometry("out-of-range scale re-derived", ["scale": 0.1, "logicalWidth": 1920, "logicalHeight": 1080], scale: 2, width: 1920, height: 1080)
        try expectGeometry("out-of-range scale, no logical size", ["scale": 10], scale: 1, width: 3840, height: 2160)
        try expectGeometry("derived scale clamped to 8", ["logicalWidth": 100, "logicalHeight": 56.25], scale: 8, width: 100, height: 56.25)
        try expectGeometry("logical height only", ["logicalHeight": 1080], scale: 2, width: 1920, height: 1080)
        try expectGeometry("invalid logical sizes fall back", ["scale": 2, "logicalWidth": 0, "logicalHeight": 200_000], scale: 2, width: 1920, height: 1080)
        try expectGeometry("negative logical width falls back", ["scale": 4, "logicalWidth": -1920], scale: 4, width: 960, height: 540)
        try expectGeometry("fractional scale", ["scale": 1.5], scale: 1.5, width: 2560, height: 1440)
        try expectGeometry("minimum scale", ["scale": 0.25], scale: 0.25, width: 15_360, height: 8_640)
        // 1000 native pixels over 8000 points is 0.125, clamped up to 0.25.
        let small = try Self.decodeWelcome(F.welcomeText(rows: [F.displayRow("s", width: 1000, height: 1000, ["logicalWidth": 8000])]))
        #expect(small.displays.first?.scale == 0.25)
        #expect(small.displays.first?.logicalFrame == LogicalRect(x: 0, y: 0, width: 8000, height: 4000))
    }

    @Test func welcomeBoundariesAreAccepted() throws {
        let sixtyFour = (1...64).map { F.displayRow("d\($0)", width: 1920, height: 1080) }
        let welcome = try Self.decodeWelcome(F.welcomeText(rows: sixtyFour))
        #expect(welcome.displays.count == 64)
        #expect(welcome.displays.last?.number == 64)
        // Logical widths accumulate left to right when rows omit x (63 displays of 1920 points precede the last).
        #expect(welcome.displays.last?.logicalFrame.x == Double(63 * 1920))
        // A 256-byte ID, the largest native side, and origins at ±131072.
        let edges = F.welcomeText(rows: [F.displayRow(String(repeating: "é", count: 128), width: 32_768, height: 1, ["x": -131_072, "y": 131_072])])
        let edge = try Self.decodeWelcome(edges)
        #expect(edge.displays.first?.logicalFrame.origin == LogicalPoint(x: -131_072, y: 131_072))
    }

    @Test func welcomeVersionAndListFailures() {
        F.expectText(.invalidField("version"), F.welcomeText { $0["version"] = 2 })
        F.expectText(.invalidField("version"), F.welcomeText { $0["version"] = true })
        F.expectText(.invalidField("version"), F.welcomeText { $0["version"] = "1" })
        F.expectText(.invalidField("version"), F.replacing(F.fixtureWelcomeJSON, #""version":1"#, with: #""version":1.0"#))
        F.expectText(.missingField("version"), F.welcomeText { $0["version"] = nil })
        F.expectText(.missingField("displays"), F.welcomeText { $0["displays"] = nil })
        F.expectText(.invalidField("displays"), F.welcomeText { $0["displays"] = ["fixture-1": 1] })
        F.expectText(.invalidField("displays"), F.welcomeText { $0["displays"] = [Any]() })
        F.expectText(.tooManyDisplays(65), F.welcomeText(rows: (1...65).map { F.displayRow("d\($0)", width: 1920, height: 1080) }))
        let notAnObject: [Any] = [F.displayRow("a", width: 1, height: 1), "fixture-2"]
        F.expectText(.invalidField("displays[1]"), F.welcomeText { $0["displays"] = notAnObject })
        F.expectText(.duplicateDisplayID("fixture-1"), F.welcomeText(row: 2) { $0["id"] = "fixture-1" })
    }

    @Test func welcomeRowFailures() {
        F.expectText(.missingField("displays[0].id"), F.welcomeText(row: 0) { $0["id"] = nil })
        F.expectText(.invalidField("displays[0].id"), F.welcomeText(row: 0) { $0["id"] = "" })
        F.expectText(.invalidField("displays[0].id"), F.welcomeText(row: 0) { $0["id"] = String(repeating: "x", count: 257) })
        F.expectText(.invalidField("displays[0].id"), F.welcomeText(row: 0) { $0["id"] = 1 })
        F.expectText(.missingField("displays[0].width"), F.welcomeText(row: 0) { $0["width"] = nil })
        F.expectText(.invalidField("displays[0].width"), F.welcomeText(row: 0) { $0["width"] = 1.5 })
        F.expectText(.invalidField("displays[0].width"), F.welcomeText(row: 0) { $0["width"] = "3" })
        F.expectText(.invalidField("displays[0].width"), F.welcomeText(row: 0) { $0["width"] = true })
        F.expectText(.invalidField("displays[0].width"), F.welcomeText(row: 0) { $0["width"] = 0 })
        F.expectText(.invalidField("displays[0].width"), F.welcomeText(row: 0) { $0["width"] = 32_769 })
        F.expectText(.invalidField("displays[2].height"), F.welcomeText(row: 2) { $0["height"] = -2160 })
        F.expectText(.missingField("displays[1].height"), F.welcomeText(row: 1) { $0["height"] = nil })
        F.expectText(.invalidField("displays[0].x"), F.welcomeText(row: 0) { $0["x"] = 131_073 })
        F.expectText(.invalidField("displays[0].y"), F.welcomeText(row: 0) { $0["y"] = -131_073 })
        F.expectText(.invalidField("displays[0].x"), F.welcomeText(row: 0) { $0["x"] = "0" })
        F.expectText(.invalidField("displays[0].x"), F.welcomeText(row: 0) { $0["x"] = false })
        F.expectText(.invalidField("displays[0].logicalWidth"), F.welcomeText(row: 0) { $0["logicalWidth"] = "1920" })
        F.expectText(.invalidField("displays[0].scale"), F.welcomeText(row: 0) { $0["scale"] = true })
        F.expectText(.invalidField("displays[0].primary"), F.welcomeText(row: 0) { $0["primary"] = 1 })
        F.expectText(.invalidField("displays[0].name"), F.welcomeText(row: 0) { $0["name"] = 7 })
    }

    @Test func welcomeHeaderAndCapabilityFailures() {
        F.expectText(.invalidField("serverName"), F.welcomeText { $0["serverName"] = 7 })
        F.expectText(.invalidField("sessionId"), F.welcomeText { $0["sessionId"] = false })
        F.expectText(.invalidField("capabilities"), F.welcomeText { $0["capabilities"] = ["aac"] })
        F.expectText(.invalidField("capabilities.codecs"), F.welcomeText { $0["capabilities"] = ["codecs": "png"] })
        let mixedAudio: [String: Any] = ["audio": ["aac", 2] as [Any]]
        F.expectText(.invalidField("capabilities.audio[1]"), F.welcomeText { $0["capabilities"] = mixedAudio })
        F.expectText(.invalidField("capabilities.maxViewers"), F.welcomeText { $0["capabilities"] = ["maxViewers": 1.5] })
    }

    // MARK: - subscribed

    @Test func subscribedFromTheFixtureHost() throws {
        let canvases = ["fixture-1", "fixture-2", "fixture-3"].map { SubscribedMessage.Canvas(display: $0, size: PixelSize(width: 1280, height: 720)) }
        let expected = SubscribedMessage(revision: 1, canvases: canvases, paused: false, audio: false, audioCodec: .aac,
                                         audioBitrate: 96_000, resolution: .preset(.hd), notice: nil)
        #expect(try PortlightWire.decodeText(F.subscribedJSON) == .subscribed(expected))
    }

    @Test func subscribedWithResolutionNotice() throws {
        // The fixture caps any selection that includes fixture-2 at FHD and says so (Server.swift applySubscription).
        let text = #"{"type":"subscribed","revision":7,"displays":[{"id":"fixture-1","width":1920,"height":1080},{"id":"fixture-2","width":1920,"height":1080}],"paused":false,"audio":false,"audioCodec":"aac","audioBitrate":96000,"resolution":"fhd","notice":"Resolution limited to FHD by the selected displays."}"#
        let canvases = ["fixture-1", "fixture-2"].map { SubscribedMessage.Canvas(display: $0, size: PixelSize(width: 1920, height: 1080)) }
        let expected = SubscribedMessage(revision: 7, canvases: canvases, paused: false, audio: false, audioCodec: .aac, audioBitrate: 96_000,
                                         resolution: .preset(.fhd), notice: "Resolution limited to FHD by the selected displays.")
        #expect(try PortlightWire.decodeText(text) == .subscribed(expected))
    }

    @Test func subscribedWithMuLawAudioWhilePaused() throws {
        // μ-law acknowledgements report 192 kbps whatever bitrate was requested; an empty selection is valid.
        let text = #"{"type":"subscribed","revision":12,"displays":[],"paused":true,"audio":true,"audioCodec":"mulaw","audioBitrate":192000,"resolution":"native"}"#
        let expected = SubscribedMessage(revision: 12, canvases: [], paused: true, audio: true, audioCodec: .mulaw, audioBitrate: 192_000,
                                         resolution: .native, notice: nil)
        #expect(try PortlightWire.decodeText(text) == .subscribed(expected))
    }

    @Test func subscribedOptionalFieldsAndBounds() throws {
        let minimal = SubscribedMessage(revision: 0, canvases: [], paused: false, audio: false, audioCodec: nil, audioBitrate: nil, resolution: nil, notice: nil)
        #expect(try PortlightWire.decodeText(#"{"type":"subscribed","revision":0,"displays":[]}"#) == .subscribed(minimal))
        // Unknown enumerations become nil rather than failing the acknowledgement.
        var unknown = minimal
        unknown.revision = 2
        #expect(try PortlightWire.decodeText(#"{"type":"subscribed","revision":2,"displays":[],"audioCodec":"opus","resolution":"8k"}"#) == .subscribed(unknown))
        // Long notices are cut to 512 characters.
        let noticed = try Self.decodeSubscribed(F.subscribedText { $0["notice"] = String(repeating: "é", count: 600) })
        #expect(noticed.notice == String(repeating: "é", count: 512))
        // Sixteen canvases at the 7680-pixel encoder limit.
        let sixteen = (1...16).map { ["id": "d\($0)", "width": 7_680, "height": 7_680] as [String: Any] }
        let large = try Self.decodeSubscribed(F.subscribedText { $0["displays"] = sixteen })
        #expect(large.canvases.count == 16)
        #expect(large.canvases.allSatisfy { $0.size == PixelSize(width: 7_680, height: 7_680) })
    }

    @Test func subscribedValidationFailures() {
        F.expectText(.invalidField("revision"), F.subscribedText { $0["revision"] = true })
        F.expectText(.invalidField("revision"), F.subscribedText { $0["revision"] = -1 })
        F.expectText(.invalidField("revision"), F.subscribedText { $0["revision"] = 1.5 })
        F.expectText(.missingField("revision"), F.subscribedText { $0["revision"] = nil })
        F.expectText(.missingField("displays"), F.subscribedText { $0["displays"] = nil })
        F.expectText(.invalidField("displays"), F.subscribedText { $0["displays"] = "fixture-1" })
        F.expectText(.invalidField("displays[0]"), F.subscribedText { $0["displays"] = ["fixture-1"] })
        F.expectText(.missingField("displays[0].id"), F.subscribedText(row: 0) { $0["id"] = nil })
        F.expectText(.invalidField("displays[0].id"), F.subscribedText(row: 0) { $0["id"] = "" })
        F.expectText(.duplicateDisplayID("fixture-1"), F.subscribedText(row: 1) { $0["id"] = "fixture-1" })
        F.expectText(.invalidField("displays[0].width"), F.subscribedText(row: 0) { $0["width"] = 7_681 })
        F.expectText(.invalidField("displays[0].width"), F.subscribedText(row: 0) { $0["width"] = 0 })
        F.expectText(.invalidField("displays[0].width"), F.subscribedText(row: 0) { $0["width"] = true })
        F.expectText(.invalidField("displays[1].height"), F.subscribedText(row: 1) { $0["height"] = 7_681 })
        F.expectText(.missingField("displays[2].height"), F.subscribedText(row: 2) { $0["height"] = nil })
        let seventeen = (1...17).map { ["id": "d\($0)", "width": 64, "height": 64] as [String: Any] }
        F.expectText(.tooManyDisplays(17), F.subscribedText { $0["displays"] = seventeen })
        F.expectText(.invalidField("paused"), F.subscribedText { $0["paused"] = "no" })
        F.expectText(.invalidField("audio"), F.subscribedText { $0["audio"] = 1 })
        F.expectText(.invalidField("audioCodec"), F.subscribedText { $0["audioCodec"] = 1 })
        F.expectText(.invalidField("audioBitrate"), F.subscribedText { $0["audioBitrate"] = 96_000.5 })
        F.expectText(.invalidField("resolution"), F.subscribedText { $0["resolution"] = 720 })
        F.expectText(.invalidField("notice"), F.subscribedText { $0["notice"] = ["too", "long"] })
    }

    // MARK: - cursor

    @Test func cursorMessages() throws {
        #expect(try PortlightWire.decodeText(#"{"type":"cursor","display":"fixture-1","x":0.25,"y":0.75}"#)
                == .cursor(CursorMessage(display: "fixture-1", x: 0.25, y: 0.75)))
        #expect(try PortlightWire.decodeText(#"{"type":"cursor","display":"d","x":0,"y":1}"#) == .cursor(CursorMessage(display: "d", x: 0, y: 1)))
        F.expectText(.invalidField("x"), #"{"type":"cursor","display":"d","x":1.5,"y":0}"#)
        F.expectText(.invalidField("y"), #"{"type":"cursor","display":"d","x":0,"y":-0.5}"#)
        F.expectText(.invalidField("x"), #"{"type":"cursor","display":"d","x":"0.5","y":0}"#)
        F.expectText(.invalidField("x"), #"{"type":"cursor","display":"d","x":true,"y":0}"#)
        F.expectText(.missingField("y"), #"{"type":"cursor","display":"d","x":0}"#)
        F.expectText(.missingField("display"), #"{"type":"cursor","x":0,"y":0}"#)
        F.expectText(.invalidField("display"), #"{"type":"cursor","display":"","x":0,"y":0}"#)
        F.expectText(.invalidField("display"), #"{"type":"cursor","display":3,"x":0,"y":0}"#)
    }

    // MARK: - stats

    @Test func statsFromTheHost() throws {
        // Every field RemoteSession.tick sends; the ones StatsMessage doesn't carry are ignored.
        let text = #"{"type":"stats","bytesSent":48213377,"fps":37,"streamingDisplays":["fixture-1","fixture-3"],"audio":false,"quality":"auto","resolution":"hd","encodedInputs":37,"framesSkippedBackpressure":4,"pendingImageBytes":131072,"inFlightFrames":3,"meanEncodeMs":6.5,"meanRasterMs":1.25,"meanQuantizeMs":0.5,"meanDiffMs":0.75,"meanCodecMs":4}"#
        let expected = StatsMessage(bytesSent: 48_213_377, fps: 37, streamingDisplays: ["fixture-1", "fixture-3"], audio: false, resolution: "hd",
                                    pendingImageBytes: 131_072, inFlightFrames: 3, framesSkippedBackpressure: 4, meanEncodeMs: 6.5)
        #expect(try PortlightWire.decodeText(text) == .stats(expected))
    }

    @Test func mistypedStatsFieldsAreDroppedOneByOne() throws {
        let allWrong = #"{"type":"stats","bytesSent":"lots","fps":true,"streamingDisplays":["fixture-1",2],"audio":1,"resolution":5,"pendingImageBytes":1.5,"inFlightFrames":null,"framesSkippedBackpressure":[],"meanEncodeMs":"4"}"#
        #expect(try PortlightWire.decodeText(allWrong) == .stats(StatsMessage()))
        let mixed = #"{"type":"stats","bytesSent":1024,"fps":"fast","streamingDisplays":"fixture-1","audio":true,"meanEncodeMs":2.5}"#
        #expect(try PortlightWire.decodeText(mixed) == .stats(StatsMessage(bytesSent: 1024, audio: true, meanEncodeMs: 2.5)))
    }

    // MARK: - pong

    @Test func pongEchoesTime() throws {
        #expect(try PortlightWire.decodeText(#"{"type":"pong","time":1757540000.125}"#) == .pong(time: 1_757_540_000.125))
        #expect(try PortlightWire.decodeText(#"{"type":"pong","time":12345}"#) == .pong(time: 12_345))
        // The host echoes `object["time"] ?? 0`.
        #expect(try PortlightWire.decodeText(#"{"type":"pong"}"#) == .pong(time: 0))
        F.expectText(.invalidField("time"), #"{"type":"pong","time":"now"}"#)
        F.expectText(.invalidField("time"), #"{"type":"pong","time":true}"#)
    }

    // MARK: - error

    @Test(arguments: zip(
        ["authentication", "busy", "topology", "capture", "subscription", "timeout", "message", "quota"],
        [HostErrorCode.authentication, .busy, .topology, .capture, .subscription, .timeout, .message, .other("quota")]))
    func errorCodeMapping(wire: String, code: HostErrorCode) throws {
        let text = F.jsonText(["type": "error", "code": wire, "message": "Detail for \(wire)"])
        #expect(try PortlightWire.decodeText(text) == .error(HostErrorMessage(code: code, message: "Detail for \(wire)")))
    }

    @Test func hostErrorMessagesVerbatim() throws {
        #expect(try PortlightWire.decodeText(#"{"type":"error","code":"authentication","message":"Incorrect password or incompatible protocol"}"#)
                == .error(HostErrorMessage(code: .authentication, message: "Incorrect password or incompatible protocol")))
        #expect(try PortlightWire.decodeText(#"{"code":"busy","message":"Another viewer is connected. Disconnect it before connecting here.","type":"error"}"#)
                == .error(HostErrorMessage(code: .busy, message: "Another viewer is connected. Disconnect it before connecting here.")))
        #expect(try PortlightWire.decodeText(#"{"type":"error","code":"topology","message":"Displays changed. Select displays again."}"#)
                == .error(HostErrorMessage(code: .topology, message: "Displays changed. Select displays again.")))
        #expect(try PortlightWire.decodeText(#"{"type":"error","code":"timeout","message":"Viewer stopped acknowledging image updates"}"#)
                == .error(HostErrorMessage(code: .timeout, message: "Viewer stopped acknowledging image updates")))
        #expect(try PortlightWire.decodeText(#"{"type":"error","code":"message"}"#) == .error(HostErrorMessage(code: .message, message: "")))
        F.expectText(.missingField("code"), #"{"type":"error","message":"no code"}"#)
        F.expectText(.invalidField("code"), #"{"type":"error","code":42}"#)
        F.expectText(.invalidField("message"), #"{"type":"error","code":"busy","message":42}"#)
        // Unknown codes keep a bounded copy for diagnostics.
        let long = F.jsonText(["type": "error", "code": String(repeating: "q", count: 300)])
        #expect(try PortlightWire.decodeText(long) == .error(HostErrorMessage(code: .other(String(repeating: "q", count: 64)), message: "")))
    }
}
