import Testing
@testable import PortlightKit

@Suite("Wire: binary envelopes")
struct WireBinaryDecodingTests {
    private typealias F = WireFixtures

    /// The frame header from PROTOCOL-IMPLEMENTATION-NOTES §5.
    private static let noteFrame = FrameHeader(revision: 1, display: "fixture-1", rect: PixelRect(x: 0, y: 0, width: 128, height: 128),
                                               canvas: PixelSize(width: 1280, height: 720), codec: .png, sequence: 12)

    // MARK: - Envelope framing

    @Test(arguments: 0...4)
    func messagesShorterThanFiveBytes(count: Int) {
        let bytes: [UInt8] = [0, 0, 0, 1, 0x7B]
        F.expectBinary(.binaryTooShort(count), F.Bytes(bytes.prefix(count)))
    }

    @Test func messagesLargerThan32MiB() {
        F.expectBinary(.binaryTooLarge(33_554_433), F.Bytes(count: PortlightProtocol.maxBinaryMessageBytes + 1))
    }

    @Test func exactly32MiBPassesFramingButNotThePayloadCap() {
        let header = F.jsonData(F.frameHeader())
        let message = F.envelope(headerBytes: header, payload: F.pngPayload(count: PortlightProtocol.maxBinaryMessageBytes - 4 - header.count))
        #expect(message.count == PortlightProtocol.maxBinaryMessageBytes)
        F.expectBinary(.invalidField("payload"), message)
    }

    @Test func headerLengthMustBePositiveBoundedAndPresent() {
        F.expectBinary(.invalidHeaderLength(0), F.Bytes([0, 0, 0, 0, 0x7B, 0x7D]))
        // N = 65 537 with enough bytes behind it: rejected for size, not truncation.
        F.expectBinary(.invalidHeaderLength(65_537), F.envelope(headerBytes: F.Bytes(count: 65_545), payload: F.Bytes(), declaredLength: 65_537))
        F.expectBinary(.invalidHeaderLength(4_294_967_295), F.Bytes([0xFF, 0xFF, 0xFF, 0xFF, 0x7B]))
        // N larger than the bytes that follow (the Windows viewer's vector declares 255 and sends 2).
        F.expectBinary(.invalidHeaderLength(255), F.Bytes([0, 0, 0, 255, 0x7B, 0x7D]))
        let header = F.jsonData(F.frameHeader())
        F.expectBinary(.invalidHeaderLength(header.count + 1),
                       F.envelope(headerBytes: header, payload: F.Bytes(), declaredLength: UInt32(header.count + 1)))
    }

    @Test func headerOfExactly64KiBIsAccepted() throws {
        var header = F.jsonData(F.frameHeader())
        header.append(F.Bytes(repeating: 0x20, count: PortlightProtocol.maxBinaryHeaderBytes - header.count)) // trailing JSON whitespace
        #expect(header.count == 65_536)
        #expect(try PortlightWire.decodeBinary(F.envelope(headerBytes: header, payload: F.png)) == .frame(Self.noteFrame, payload: F.png))
    }

    @Test func headerJSONIsStrict() {
        let invalidUTF8 = F.Bytes(Array(#"{"type":"frame","display":"fixture-"#.utf8) + [0xFF] + Array(#""}"#.utf8))
        F.expectBinary(.invalidUTF8, F.envelope(headerBytes: invalidUTF8, payload: F.png))
        F.expectBinary(.notAnObject, F.envelope(headerJSON: "[]", payload: F.png))
        F.expectBinary(.notAnObject, F.envelope(headerJSON: #""frame""#, payload: F.png))
        F.expectBinary(.invalidJSON, F.envelope(headerJSON: #"{"type":"frame""#, payload: F.png))
        F.expectBinary(.nestingTooDeep, F.envelope(headerJSON: String(repeating: "[", count: 60_000), payload: F.png))
        let seventeen = #"{"type":"frame","a":"# + String(repeating: "[", count: 16) + String(repeating: "]", count: 16) + "}"
        F.expectBinary(.nestingTooDeep, F.envelope(headerJSON: seventeen, payload: F.png))
        F.expectBinary(.missingType, F.envelope(headerJSON: #"{"display":"fixture-1"}"#, payload: F.png))
        F.expectBinary(.missingType, F.envelope(headerJSON: #"{"type":1}"#, payload: F.png))
    }

    @Test func onlyFrameAndAudioAreBinaryTypes() {
        F.expectBinary(.unexpectedBinaryType("video"), F.envelope(["type": "video", "sequence": 1], payload: F.png))
        F.expectBinary(.unexpectedBinaryType("welcome"), F.envelope(headerJSON: F.fixtureWelcomeJSON, payload: F.Bytes([0])))
        // The reported type is bounded for diagnostics.
        F.expectBinary(.unexpectedBinaryType(String(repeating: "v", count: 64)),
                       F.envelope(["type": String(repeating: "v", count: 1_000)], payload: F.Bytes([0])))
    }

    // MARK: - frame

    @Test func frameFromTheProtocolNotes() throws {
        #expect(try PortlightWire.decodeBinary(F.frame()) == .frame(Self.noteFrame, payload: F.png))
    }

    @Test func jpegVisibleAreaFrame() throws {
        // Video with Full Color sends one JPEG of the whole visible area (Capture.swift TileEncoder).
        let message = F.frame(payload: F.jpeg) {
            $0["codec"] = "jpeg"; $0["width"] = 1280; $0["height"] = 720; $0["revision"] = 4; $0["sequence"] = 913
        }
        let expected = FrameHeader(revision: 4, display: "fixture-1", rect: PixelRect(x: 0, y: 0, width: 1280, height: 720),
                                   canvas: PixelSize(width: 1280, height: 720), codec: .jpeg, sequence: 913)
        #expect(try PortlightWire.decodeBinary(message) == .frame(expected, payload: F.jpeg))
    }

    @Test func payloadIsAStandaloneCopyEvenFromASlice() throws {
        let buffer = F.Bytes([0xAA, 0xBB, 0xCC]) + F.frame()
        let slice = buffer[3...]
        #expect(slice.startIndex == 3)
        guard case .frame(let header, let payload) = try PortlightWire.decodeBinary(slice) else {
            Issue.record("expected a frame")
            return
        }
        #expect(header == Self.noteFrame)
        #expect(payload == F.png)
        #expect(payload.startIndex == 0)
        #expect(payload[0] == 0x89)
    }

    @Test func extraHeaderFieldsAreIgnored() throws {
        let message = F.frame { $0["futureField"] = ["nested": [1, 2, 3]]; $0["priority"] = "high" }
        #expect(try PortlightWire.decodeBinary(message) == .frame(Self.noteFrame, payload: F.png))
    }

    @Test func rectangleBoundsAreOverflowSafe() throws {
        func uhd(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> F.Bytes {
            F.frame {
                $0["x"] = x; $0["y"] = y; $0["width"] = width; $0["height"] = height
                $0["canvasWidth"] = 3840; $0["canvasHeight"] = 2160
            }
        }
        // The last in-bounds 128-pixel tile of a 3840×2160 canvas (Windows viewer vector).
        guard case .frame(let corner, _) = try PortlightWire.decodeBinary(uhd(3712, 2032, 128, 128)) else {
            Issue.record("expected a frame")
            return
        }
        #expect(corner.rect == PixelRect(x: 3712, y: 2032, width: 128, height: 128))
        #expect(corner.canvas == PixelSize(width: 3840, height: 2160))
        F.expectBinary(.invalidRectangle, uhd(3713, 2032, 128, 128), "one pixel past the right edge")
        F.expectBinary(.invalidRectangle, uhd(3712, 2033, 128, 128), "one pixel past the bottom edge")
        F.expectBinary(.invalidRectangle, uhd(Int.max, 0, 128, 128), "x = Int.max")
        F.expectBinary(.invalidRectangle, uhd(0, Int.max, 128, 128), "y = Int.max")
        F.expectBinary(.invalidRectangle, uhd(0, 0, Int.max, 1), "width = Int.max")
        F.expectBinary(.invalidRectangle, uhd(1, 0, 3840, 1), "full width shifted by one")
        F.expectBinary(.invalidRectangle, uhd(0, 0, 3841, 1), "wider than the canvas")
    }

    @Test func largestCanvasIsAccepted() throws {
        let message = F.frame { $0["canvasWidth"] = 7_680; $0["canvasHeight"] = 7_680; $0["x"] = 7_552; $0["y"] = 7_552 }
        guard case .frame(let header, _) = try PortlightWire.decodeBinary(message) else {
            Issue.record("expected a frame")
            return
        }
        #expect(header.canvas == PixelSize(width: 7_680, height: 7_680))
        #expect(header.rect == PixelRect(x: 7_552, y: 7_552, width: 128, height: 128))
    }

    @Test func frameFieldTypesAndRanges() {
        F.expectBinary(.invalidField("revision"), F.frame { $0["revision"] = true })
        F.expectBinary(.invalidField("revision"), F.frame { $0["revision"] = -1 })
        F.expectBinary(.invalidField("revision"), F.frame { $0["revision"] = 1.5 })
        F.expectBinary(.invalidField("revision"), F.frame { $0["revision"] = "1" })
        F.expectBinary(.invalidField("display"), F.frame { $0["display"] = "" })
        F.expectBinary(.invalidField("display"), F.frame { $0["display"] = 1 })
        F.expectBinary(.invalidField("display"), F.frame { $0["display"] = String(repeating: "d", count: 257) })
        F.expectBinary(.invalidField("x"), F.frame { $0["x"] = -1 })
        F.expectBinary(.invalidField("y"), F.frame { $0["y"] = 0.5 })
        F.expectBinary(.invalidField("width"), F.frame { $0["width"] = 1.5 })
        F.expectBinary(.invalidField("width"), F.frame { $0["width"] = "3" })
        F.expectBinary(.invalidField("width"), F.frame { $0["width"] = true })
        F.expectBinary(.invalidField("width"), F.frame { $0["width"] = 0 })
        F.expectBinary(.invalidField("height"), F.frame { $0["height"] = -128 })
        F.expectBinary(.invalidField("canvasWidth"), F.frame { $0["canvasWidth"] = 0 })
        F.expectBinary(.invalidField("canvasWidth"), F.frame { $0["canvasWidth"] = 7_681 })
        F.expectBinary(.invalidField("canvasHeight"), F.frame { $0["canvasHeight"] = 0 })
        F.expectBinary(.invalidField("canvasHeight"), F.frame { $0["canvasHeight"] = 7_681 })
        F.expectBinary(.invalidField("codec"), F.frame { $0["codec"] = 1 })
        F.expectBinary(.invalidField("sequence"), F.frame { $0["sequence"] = -1 })
        F.expectBinary(.invalidField("sequence"), F.frame { $0["sequence"] = false })
        F.expectBinary(.invalidField("sequence"), F.frame { $0["sequence"] = 12.5 })
    }

    @Test func unknownImageCodecs() {
        F.expectBinary(.unsupportedCodec("h264"), F.frame { $0["codec"] = "h264" })
        F.expectBinary(.unsupportedCodec("PNG"), F.frame { $0["codec"] = "PNG" })
        F.expectBinary(.unsupportedCodec("webp"), F.frame { $0["codec"] = "webp" })
    }

    @Test func integralFloatLiteralIsNotAnInteger() {
        let original = String(decoding: F.jsonData(F.frameHeader()), as: UTF8.self)
        let header = F.replacing(original, #""width":128"#, with: #""width":128.0"#)
        #expect(header != original)
        F.expectBinary(.invalidField("width"), F.envelope(headerJSON: header, payload: F.png))
    }

    @Test(arguments: ["revision", "display", "x", "y", "width", "height", "canvasWidth", "canvasHeight", "codec", "sequence"])
    func frameRequiredField(_ key: String) {
        F.expectBinary(.missingField(key), F.frame { $0[key] = nil })
    }

    @Test func framePayloadMustMatchItsCodec() {
        F.expectBinary(.invalidField("payload"), F.frame(payload: F.jpeg), "PNG codec, JPEG bytes")
        F.expectBinary(.invalidField("payload"), F.frame(payload: F.png) { $0["codec"] = "jpeg" }, "JPEG codec, PNG bytes")
        F.expectBinary(.invalidField("payload"), F.frame(payload: F.png.prefix(7)), "truncated PNG signature")
        F.expectBinary(.invalidField("payload"), F.frame(payload: F.Bytes()), "empty payload")
        F.expectBinary(.invalidField("payload"), F.frame(payload: F.Bytes("<html>".utf8)), "not an image")
    }

    @Test func framePayloadIsCappedAt20MB() {
        #expect(throws: Never.self) { try PortlightWire.decodeBinary(F.frame(payload: F.pngPayload(count: 20_000_000))) }
        F.expectBinary(.invalidField("payload"), F.frame(payload: F.pngPayload(count: 20_000_001)))
    }

    // MARK: - audio

    @Test func aacHeaderFromTheFixtureFile() throws {
        let message = F.envelope(F.aacHeader(), payload: F.aacMonoFirstPacket)
        guard case .audio(let header, let payload) = try PortlightWire.decodeBinary(message) else {
            Issue.record("expected audio")
            return
        }
        let cookie = try #require(F.Bytes(base64Encoded: F.aacMonoCookieBase64))
        #expect(header == AudioHeader(revision: 3, codec: .aac, sampleRate: 48_000, channels: 1, samples: 1024, sequence: 40,
                                      bitrate: 48_000, cookie: cookie))
        #expect(header.cookie.map(F.hex) == F.aacMonoCookieHex)
        #expect(payload == F.Bytes([0x00, 0xD0, 0x40, 0x07]))
    }

    @Test func aacStereoHeader() throws {
        let message = F.envelope(F.aacHeader(channels: 2, bitrate: 96_000, cookie: F.aacStereoCookieBase64), payload: F.aacStereoFirstPacket)
        guard case .audio(let header, let payload) = try PortlightWire.decodeBinary(message) else {
            Issue.record("expected audio")
            return
        }
        #expect(header.channels == 2)
        #expect(header.bitrate == 96_000)
        #expect(header.cookie == F.Bytes(base64Encoded: F.aacStereoCookieBase64))
        #expect(payload == F.aacStereoFirstPacket)
        #expect(payload.count == 6)
    }

    @Test func aacBoundariesAndOptionalBitrate() throws {
        let largestCookie = F.Bytes((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })
        let header = F.aacHeader(cookie: largestCookie.base64EncodedString()) { $0["bitrate"] = nil }
        guard case .audio(let decoded, let payload) = try PortlightWire.decodeBinary(F.envelope(header, payload: F.Bytes(count: 16_384))) else {
            Issue.record("expected audio")
            return
        }
        #expect(decoded.cookie == largestCookie)
        #expect(decoded.bitrate == nil)
        #expect(payload.count == 16_384)
    }

    @Test func muLawHeader() throws {
        let expected = AudioHeader(revision: 2, codec: .mulaw, sampleRate: 24_000, channels: 1, samples: 480, sequence: 41, bitrate: nil, cookie: nil)
        #expect(try PortlightWire.decodeBinary(F.envelope(F.muLawHeader(), payload: F.muLawPayload)) == .audio(expected, payload: F.muLawPayload))
        // A cookie means nothing for μ-law and is not passed on.
        let withCookie = F.envelope(F.muLawHeader { $0["cookie"] = F.aacMonoCookieBase64 }, payload: F.muLawPayload)
        #expect(try PortlightWire.decodeBinary(withCookie) == .audio(expected, payload: F.muLawPayload))
        // One second is the most one packet may carry.
        let oneSecond = F.envelope(F.muLawHeader { $0["samples"] = 24_000 }, payload: F.Bytes(count: 24_000))
        #expect(throws: Never.self) { try PortlightWire.decodeBinary(oneSecond) }
    }

    @Test func aacValidation() {
        let packet = F.aacMonoFirstPacket
        F.expectBinary(.invalidField("sampleRate"), F.envelope(F.aacHeader { $0["sampleRate"] = 44_100 }, payload: packet))
        F.expectBinary(.invalidField("sampleRate"), F.envelope(F.aacHeader { $0["sampleRate"] = 48_000.5 }, payload: packet))
        F.expectBinary(.invalidField("channels"), F.envelope(F.aacHeader { $0["channels"] = 0 }, payload: packet))
        F.expectBinary(.invalidField("channels"), F.envelope(F.aacHeader { $0["channels"] = 3 }, payload: packet))
        F.expectBinary(.invalidField("samples"), F.envelope(F.aacHeader { $0["samples"] = 960 }, payload: packet))
        F.expectBinary(.missingField("cookie"), F.envelope(F.aacHeader { $0["cookie"] = nil }, payload: packet))
        F.expectBinary(.invalidField("cookie"), F.envelope(F.aacHeader { $0["cookie"] = 7 }, payload: packet))
        F.expectBinary(.invalidField("cookie"), F.envelope(F.aacHeader { $0["cookie"] = "not base64!" }, payload: packet))
        F.expectBinary(.invalidField("cookie"), F.envelope(F.aacHeader { $0["cookie"] = "" }, payload: packet))
        let oversizedCookie = F.Bytes(count: 4_097).base64EncodedString()
        F.expectBinary(.invalidField("cookie"), F.envelope(F.aacHeader { $0["cookie"] = oversizedCookie }, payload: packet))
        F.expectBinary(.invalidField("payload"), F.envelope(F.aacHeader(), payload: F.Bytes()))
        F.expectBinary(.invalidField("payload"), F.envelope(F.aacHeader(), payload: F.Bytes(count: 16_385)))
        F.expectBinary(.invalidField("bitrate"), F.envelope(F.aacHeader { $0["bitrate"] = "96k" }, payload: packet))
        F.expectBinary(.invalidField("revision"), F.envelope(F.aacHeader { $0["revision"] = true }, payload: packet))
        F.expectBinary(.invalidField("sequence"), F.envelope(F.aacHeader { $0["sequence"] = -40 }, payload: packet))
        F.expectBinary(.unsupportedCodec("opus"), F.envelope(F.aacHeader { $0["codec"] = "opus" }, payload: packet))
        F.expectBinary(.invalidField("codec"), F.envelope(F.aacHeader { $0["codec"] = 1 }, payload: packet))
    }

    @Test func muLawValidation() {
        let payload = F.muLawPayload
        F.expectBinary(.invalidField("sampleRate"), F.envelope(F.muLawHeader { $0["sampleRate"] = 48_000 }, payload: payload))
        F.expectBinary(.invalidField("channels"), F.envelope(F.muLawHeader { $0["channels"] = 2 }, payload: payload))
        F.expectBinary(.invalidField("samples"), F.envelope(F.muLawHeader { $0["samples"] = 479 }, payload: payload))
        F.expectBinary(.invalidField("samples"), F.envelope(F.muLawHeader { $0["samples"] = 960 }, payload: payload))
        F.expectBinary(.invalidField("payload"), F.envelope(F.muLawHeader { $0["samples"] = 0 }, payload: F.Bytes()))
        F.expectBinary(.invalidField("payload"), F.envelope(F.muLawHeader { $0["samples"] = 24_001 }, payload: F.Bytes(count: 24_001)))
        F.expectBinary(.invalidField("bitrate"), F.envelope(F.muLawHeader { $0["bitrate"] = 1.5 }, payload: payload))
    }

    @Test(arguments: ["revision", "codec", "sequence", "sampleRate", "channels", "samples"])
    func audioRequiredField(_ key: String) {
        F.expectBinary(.missingField(key), F.envelope(F.aacHeader { $0[key] = nil }, payload: F.aacMonoFirstPacket), "AAC")
        F.expectBinary(.missingField(key), F.envelope(F.muLawHeader { $0[key] = nil }, payload: F.muLawPayload), "μ-law")
    }
}
