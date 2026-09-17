import Testing
@testable import PortlightKit

@Suite("Wire: outbound encoding")
struct WireEncodingTests {
    private typealias F = WireFixtures
    private typealias Scalar = PortlightWire.JSONScalar

    /// Encoder output read back through the strict parser, as the host receives it.
    private static func reparse(_ json: String) throws -> PortlightWire.JSONFields {
        try PortlightWire.StrictJSON.parseObject(F.Bytes(json.utf8))
    }

    /// Proves JSON typing after a JSONSerialization round trip: each integer key is a non-float, non-boolean
    /// NSNumber equal to its value (and what the host's `as? Int` reads), and each boolean key is a CFBoolean.
    private static func expectTyping(_ json: String, integers: [String: Int] = [:], booleans: [String: Bool] = [:],
                                     sourceLocation: SourceLocation = #_sourceLocation) throws {
        let fields = try reparse(json)
        for (key, value) in integers {
            let raw = try #require(fields.values[key], "\(key)", sourceLocation: sourceLocation)
            #expect(Scalar.int(raw) == value, "\(key)", sourceLocation: sourceLocation)
            #expect((raw as? Int) == value, "\(key)", sourceLocation: sourceLocation)
        }
        for (key, value) in booleans {
            let raw = try #require(fields.values[key], "\(key)", sourceLocation: sourceLocation)
            #expect(Scalar.bool(raw) == value, "\(key)", sourceLocation: sourceLocation)
        }
    }

    private static func subscription(_ edit: (inout SubscriptionRequest) -> Void) -> OutboundMessage {
        var request = SubscriptionRequest(revision: 3, displays: ["a", "b"], resolution: .hd, color: .full, quality: .automatic)
        edit(&request)
        return .subscribe(request)
    }

    // MARK: - hello

    @Test func hello() throws {
        let json = try PortlightWire.encode(.hello(password: "correct horse/battery é"))
        #expect(json == #"{"codecs":["png","jpeg"],"password":"correct horse/battery é","type":"hello","version":1}"#)
        try Self.expectTyping(json, integers: ["version": 1])
        // The host hashes the exact UTF-8 bytes, so the password must survive untouched.
        #expect(try Self.reparse(json).string("password") == "correct horse/battery é")
    }

    @Test func helloPasswordLimit() {
        #expect(throws: Never.self) { try PortlightWire.encode(.hello(password: String(repeating: "p", count: 1_024))) }
        #expect(throws: Never.self) { try PortlightWire.encode(.hello(password: String(repeating: "é", count: 512))) }
        F.expectEncode(.outboundInvalid("password"), .hello(password: String(repeating: "p", count: 1_025)))
        F.expectEncode(.outboundInvalid("password"), .hello(password: String(repeating: "é", count: 513)))
    }

    // MARK: - subscribe

    @Test func subscribeMatchesTheProtocolNotesExample() throws {
        let request = SubscriptionRequest(revision: 1, displays: ["fixture-1", "fixture-2", "fixture-3"], resolution: .hd, color: .full, quality: .automatic)
        let json = try PortlightWire.encode(.subscribe(request))
        #expect(json == #"{"audio":false,"audioBitrate":96000,"audioCodec":"aac","bandwidthKbps":0,"color":"full","displays":["fixture-1","fixture-2","fixture-3"],"dither":false,"fps":60,"maxHeight":720,"maxWidth":1280,"paused":false,"quality":"auto","regions":{},"revision":1,"type":"subscribe","viewOnly":false}"#)
        try Self.expectTyping(json, integers: ["revision": 1, "maxWidth": 1280, "maxHeight": 720, "fps": 60, "bandwidthKbps": 0, "audioBitrate": 96_000],
                              booleans: ["paused": false, "audio": false, "viewOnly": false, "dither": false])
    }

    @Test func subscribeWithEveryFieldAndRegions() throws {
        let partial = NormalizedRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let request = SubscriptionRequest(
            revision: 7, displays: ["fixture-1", "fixture-2", "fixture-3"], resolution: .fhd, color: .gray16, quality: .video,
            fps: 30, bandwidthKbps: 4_000, paused: false, audio: true, audioCodec: .mulaw, audioBitrate: .mono48, viewOnly: true,
            regions: ["fixture-1": .full, "fixture-2": .zero, "fixture-3": partial], dither: true)
        let json = try PortlightWire.encode(.subscribe(request))
        // Full regions are omitted (the host reads a missing entry as the whole display); zero regions stay explicit.
        #expect(json == #"{"audio":true,"audioBitrate":48000,"audioCodec":"mulaw","bandwidthKbps":4000,"color":"gray16","displays":["fixture-1","fixture-2","fixture-3"],"dither":true,"fps":30,"maxHeight":1080,"maxWidth":1920,"paused":false,"quality":"motion","regions":{"fixture-2":{"height":0,"width":0,"x":0,"y":0},"fixture-3":{"height":0.25,"width":0.5,"x":0.25,"y":0.5}},"revision":7,"type":"subscribe","viewOnly":true}"#)
        try Self.expectTyping(json, integers: ["revision": 7, "maxWidth": 1920, "maxHeight": 1080, "fps": 30, "bandwidthKbps": 4_000, "audioBitrate": 48_000],
                              booleans: ["paused": false, "audio": true, "viewOnly": true, "dither": true])
        // The host accepts regions only when they cast to [String: [String: Double]] (Server.swift applySubscription).
        let regions = try #require(try Self.reparse(json).optionalObject("regions"))
        let hostView = regions.values as? [String: [String: Double]]
        let expected: [String: [String: Double]] = ["fixture-2": ["x": 0, "y": 0, "width": 0, "height": 0],
                                                    "fixture-3": ["x": 0.25, "y": 0.5, "width": 0.5, "height": 0.25]]
        #expect(hostView == expected)
    }

    @Test func regionValuesRoundTripExactly() throws {
        let region = NormalizedRect(x: 0.1, y: 1.0 / 3.0, width: 0.7, height: 0.2)
        let request = SubscriptionRequest(revision: 2, displays: ["d"], resolution: .hd, color: .full, quality: .automatic, regions: ["d": region])
        let regions = try #require(try Self.reparse(PortlightWire.encode(.subscribe(request))).optionalObject("regions"))
        let fields = try #require(try regions.optionalObject("d"))
        let decoded = try NormalizedRect(x: fields.double("x"), y: fields.double("y"), width: fields.double("width"), height: fields.double("height"))
        #expect(decoded == region)
    }

    @Test(arguments: ResolutionPreset.allCases)
    func subscribeSendsTheResolutionBox(_ preset: ResolutionPreset) throws {
        let json = try PortlightWire.encode(.subscribe(SubscriptionRequest(revision: 1, displays: [], resolution: preset, color: .full, quality: .automatic)))
        try Self.expectTyping(json, integers: ["maxWidth": preset.box.width, "maxHeight": preset.box.height])
    }

    @Test func subscribeUsesTheHostsWireNames() throws {
        var colors: [String] = []
        for color in ColorMode.allCases {
            let json = try PortlightWire.encode(Self.subscription { $0.color = color })
            colors.append(try Self.reparse(json).string("color"))
        }
        #expect(colors == ["full", "color256", "gray16"])
        var qualities: [String] = []
        for quality in ContentPriority.allCases {
            let json = try PortlightWire.encode(Self.subscription { $0.quality = quality })
            qualities.append(try Self.reparse(json).string("quality"))
        }
        #expect(qualities == ["auto", "desktop", "motion"])
        for codec in AudioCodec.allCases {
            for quality in AudioQuality.allCases {
                let json = try PortlightWire.encode(Self.subscription { $0.audio = true; $0.audioCodec = codec; $0.audioBitrate = quality })
                try Self.expectTyping(json, integers: ["audioBitrate": quality.rawValue], booleans: ["audio": true])
                #expect(try Self.reparse(json).string("audioCodec") == codec.rawValue)
            }
        }
    }

    @Test func subscribeScalarValidation() {
        F.expectEncode(.outboundInvalid("revision"), Self.subscription { $0.revision = -1 })
        F.expectEncode(.outboundInvalid("displays"), Self.subscription { $0.displays = ["a", "a"] })
        F.expectEncode(.outboundInvalid("displays"), Self.subscription { $0.displays = (1...17).map { "d\($0)" } })
        F.expectEncode(.outboundInvalid("displays"), Self.subscription { $0.displays = [""] })
        F.expectEncode(.outboundInvalid("displays"), Self.subscription { $0.displays = [String(repeating: "x", count: 257)] })
        F.expectEncode(.outboundInvalid("fps"), Self.subscription { $0.fps = 0 })
        F.expectEncode(.outboundInvalid("fps"), Self.subscription { $0.fps = 61 })
        F.expectEncode(.outboundInvalid("bandwidthKbps"), Self.subscription { $0.bandwidthKbps = 99 })
        F.expectEncode(.outboundInvalid("bandwidthKbps"), Self.subscription { $0.bandwidthKbps = 100_001 })
        F.expectEncode(.outboundInvalid("bandwidthKbps"), Self.subscription { $0.bandwidthKbps = -1 })
    }

    @Test func subscribeRegionValidation() {
        F.expectEncode(.outboundInvalid("regions.c"), Self.subscription { $0.regions = ["c": .zero] })
        // Even a full region, which is omitted on the wire, must name a selected display.
        F.expectEncode(.outboundInvalid("regions.c"), Self.subscription { $0.regions = ["c": .full] })
        F.expectEncode(.outboundInvalid("regions.a"), Self.subscription { $0.regions = ["a": NormalizedRect(x: 0.5, y: 0, width: 0.6, height: 1)] })
        F.expectEncode(.outboundInvalid("regions.a"), Self.subscription { $0.regions = ["a": NormalizedRect(x: 0, y: 0, width: 0, height: 0.5)] })
        F.expectEncode(.outboundInvalid("regions.a"), Self.subscription { $0.regions = ["a": NormalizedRect(x: -0.1, y: 0, width: 0.5, height: 0.5)] })
        F.expectEncode(.outboundInvalid("regions.a"), Self.subscription { $0.regions = ["a": NormalizedRect(x: Double.nan, y: 0, width: 0.5, height: 0.5)] })
        // With several bad entries the first in sorted order is reported.
        F.expectEncode(.outboundInvalid("regions.a"), Self.subscription { $0.regions = ["b": .zero, "a": NormalizedRect(x: 0, y: 0, width: 2, height: 2)] })
    }

    @Test func subscribeBoundariesAreAccepted() {
        let sixteen = (1...16).map { "d\($0)" }
        let smallest = SubscriptionRequest(revision: 0, displays: [], resolution: .hd, color: .full, quality: .automatic, fps: 1, bandwidthKbps: 100)
        var largest = SubscriptionRequest(revision: Int.max, displays: sixteen, resolution: .uhd, color: .color256, quality: .text, fps: 60, bandwidthKbps: 100_000)
        largest.regions = Dictionary(uniqueKeysWithValues: sixteen.map { ($0, NormalizedRect.zero) })
        #expect(throws: Never.self) { try PortlightWire.encode(.subscribe(smallest)) }
        #expect(throws: Never.self) { try PortlightWire.encode(.subscribe(largest)) }
    }

    // MARK: - frameAck and ping

    @Test func frameAck() throws {
        let json = try PortlightWire.encode(.frameAck(sequence: 12))
        #expect(json == #"{"sequence":12,"type":"frameAck"}"#)
        try Self.expectTyping(json, integers: ["sequence": 12])
        #expect(try PortlightWire.encode(.frameAck(sequence: 0)) == #"{"sequence":0,"type":"frameAck"}"#)
        F.expectEncode(.outboundInvalid("sequence"), .frameAck(sequence: -1))
    }

    @Test func ping() throws {
        #expect(try PortlightWire.encode(.ping(time: 12_345.5)) == #"{"time":12345.5,"type":"ping"}"#)
        #expect(try PortlightWire.encode(.ping(time: 0)) == #"{"time":0,"type":"ping"}"#)
        // Wall-clock times survive the host's echo exactly, so latency math sees the value that was sent.
        let now = 1_757_540_000.123456
        let echoed = F.replacing(try PortlightWire.encode(.ping(time: now)), #""type":"ping""#, with: #""type":"pong""#)
        #expect(try PortlightWire.decodeText(echoed) == .pong(time: now))
        F.expectEncode(.outboundInvalid("time"), .ping(time: Double.nan))
        F.expectEncode(.outboundInvalid("time"), .ping(time: Double.infinity))
        F.expectEncode(.outboundInvalid("time"), .ping(time: -Double.infinity))
    }

    // MARK: - Input

    @Test func pointer() throws {
        let json = try PortlightWire.encode(.pointer(display: "fixture-1", x: 0.5, y: 0.25, buttons: .left))
        #expect(json == #"{"buttons":1,"display":"fixture-1","type":"pointer","x":0.5,"y":0.25}"#)
        try Self.expectTyping(json, integers: ["buttons": 1])
        let allButtons = try PortlightWire.encode(.pointer(display: "fixture-1", x: 0, y: 0, buttons: [.left, .right, .middle]))
        #expect(allButtons == #"{"buttons":7,"display":"fixture-1","type":"pointer","x":0,"y":0}"#)
        // Negative zero is normalized.
        let negativeZero = try PortlightWire.encode(.pointer(display: "fixture-1", x: -0.0, y: 0.75, buttons: []))
        #expect(negativeZero == #"{"buttons":0,"display":"fixture-1","type":"pointer","x":0,"y":0.75}"#)
        // The largest coordinate below 1 is inside the display and round-trips exactly.
        let edge = try Self.reparse(PortlightWire.encode(.pointer(display: "d", x: 1.0.nextDown, y: 0.999999, buttons: .right)))
        #expect(try edge.double("x") == 1.0.nextDown)
        #expect(try edge.double("y") == 0.999999)
    }

    @Test func pointerValidation() {
        F.expectEncode(.outboundInvalid("x"), .pointer(display: "d", x: 1, y: 0.5, buttons: []))
        F.expectEncode(.outboundInvalid("x"), .pointer(display: "d", x: -0.001, y: 0.5, buttons: []))
        F.expectEncode(.outboundInvalid("x"), .pointer(display: "d", x: Double.nan, y: 0.5, buttons: []))
        F.expectEncode(.outboundInvalid("y"), .pointer(display: "d", x: 0.5, y: Double.infinity, buttons: []))
        F.expectEncode(.outboundInvalid("y"), .pointer(display: "d", x: 0.5, y: 1.5, buttons: []))
        F.expectEncode(.outboundInvalid("buttons"), .pointer(display: "d", x: 0.5, y: 0.5, buttons: MouseButtons(rawValue: 8)))
        F.expectEncode(.outboundInvalid("buttons"), .pointer(display: "d", x: 0.5, y: 0.5, buttons: MouseButtons(rawValue: -1)))
        F.expectEncode(.outboundInvalid("display"), .pointer(display: "", x: 0.5, y: 0.5, buttons: []))
    }

    @Test func wheel() throws {
        let json = try PortlightWire.encode(.wheel(display: "fixture-1", x: 0.625, y: 0.5, dx: 0, dy: -1))
        #expect(json == #"{"display":"fixture-1","dx":0,"dy":-1,"type":"wheel","x":0.625,"y":0.5}"#)
        let fractional = try PortlightWire.encode(.wheel(display: "d", x: 0.5, y: 0.5, dx: 0.375, dy: -2.5))
        #expect(fractional == #"{"display":"d","dx":0.375,"dy":-2.5,"type":"wheel","x":0.5,"y":0.5}"#)
        // Clamped to the host's ±100 lines per message.
        let clamped = try PortlightWire.encode(.wheel(display: "fixture-1", x: 0, y: 0, dx: 250, dy: -1e9))
        #expect(clamped == #"{"display":"fixture-1","dx":100,"dy":-100,"type":"wheel","x":0,"y":0}"#)
    }

    @Test func wheelValidation() {
        F.expectEncode(.outboundInvalid("dx"), .wheel(display: "d", x: 0.5, y: 0.5, dx: Double.nan, dy: 0))
        F.expectEncode(.outboundInvalid("dy"), .wheel(display: "d", x: 0.5, y: 0.5, dx: 0, dy: -Double.infinity))
        F.expectEncode(.outboundInvalid("x"), .wheel(display: "d", x: 1, y: 0.5, dx: 0, dy: 1))
        F.expectEncode(.outboundInvalid("y"), .wheel(display: "d", x: 0.5, y: -1, dx: 0, dy: 1))
        F.expectEncode(.outboundInvalid("display"), .wheel(display: "", x: 0.5, y: 0.5, dx: 0, dy: 1))
    }

    @Test func key() throws {
        let down = try PortlightWire.encode(.key(keysym: 0xffeb, down: true))
        #expect(down == #"{"down":true,"key":65515,"type":"key"}"#)
        try Self.expectTyping(down, integers: ["key": 65_515], booleans: ["down": true])
        let up = try PortlightWire.encode(.key(keysym: 0xffeb, down: false))
        #expect(up == #"{"down":false,"key":65515,"type":"key"}"#)
        try Self.expectTyping(up, booleans: ["down": false])
        // Non-Latin-1 Unicode keysyms are 0x01000000 | scalar; even UInt32.max stays a JSON integer.
        try Self.expectTyping(PortlightWire.encode(.key(keysym: 0x0100_20AC, down: true)), integers: ["key": 0x0100_20AC])
        try Self.expectTyping(PortlightWire.encode(.key(keysym: UInt32.max, down: true)), integers: ["key": Int(UInt32.max)])
    }

    @Test func text() throws {
        #expect(try PortlightWire.encode(.text("héllo")) == #"{"text":"héllo","type":"text"}"#)
        #expect(try PortlightWire.encode(.text("say \"hi\"\n/😀")) == #"{"text":"say \"hi\"\n/😀","type":"text"}"#)
        #expect(try Self.reparse(PortlightWire.encode(.text("tab\there \u{1}"))).string("text") == "tab\there \u{1}")
        #expect(throws: Never.self) { try PortlightWire.encode(.text(String(repeating: "a", count: 4_096))) }
        #expect(throws: Never.self) { try PortlightWire.encode(.text(String(repeating: "é", count: 2_048))) }
        F.expectEncode(.outboundInvalid("text"), .text(""))
        F.expectEncode(.outboundInvalid("text"), .text(String(repeating: "a", count: 4_097)))
        F.expectEncode(.outboundInvalid("text"), .text(String(repeating: "é", count: 2_049)))
    }
}
