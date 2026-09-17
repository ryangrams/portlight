import CoreGraphics
import Foundation
@testable import PortlightKit

// Foundation-dependent wire fixtures. This file must not import Testing: these Command Line Tools ship
// `_Testing_Foundation.framework` without its module, so a file importing both Testing and Foundation fails
// with "no such module '_Testing_Foundation'". Assertions live in WireExpectations.swift and the test files,
// which import Testing but not Foundation and name Foundation's `Data` through `WireFixtures.Bytes`.

/// Thrown by test helpers when a message decodes to a different case than the test needs.
struct UnexpectedWireMessage: Error, CustomStringConvertible {
    let message: InboundMessage
    var description: String { "unexpected message: \(message)" }
}

/// Wire fixtures shaped like the host's real output. Binary envelopes mirror `binaryMessage(_:payload:)`
/// in server-macos/Sources/Server.swift: a sorted-key JSON header behind a 4-byte big-endian length.
enum WireFixtures {
    /// Foundation's `Data`, nameable from test files that can't import Foundation.
    typealias Bytes = Data

    // MARK: - JSON and envelopes

    static func jsonData(_ object: [String: Any], sortedKeys: Bool = true) -> Data {
        // Fixtures are always valid JSON objects; a crash here is a broken test, not a codec failure.
        try! JSONSerialization.data(withJSONObject: object, options: sortedKeys ? [.sortedKeys] : [])
    }

    static func jsonText(_ object: [String: Any]) -> String {
        String(decoding: jsonData(object), as: UTF8.self)
    }

    static func parse(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    static func replacing(_ text: String, _ target: String, with replacement: String) -> String {
        text.replacingOccurrences(of: target, with: replacement)
    }

    static func envelope(_ header: [String: Any], payload: Data) -> Data {
        envelope(headerBytes: jsonData(header), payload: payload)
    }

    static func envelope(headerJSON: String, payload: Data = Data()) -> Data {
        envelope(headerBytes: Data(headerJSON.utf8), payload: payload)
    }

    /// `declaredLength` lets a test lie about N.
    static func envelope(headerBytes: Data, payload: Data, declaredLength: UInt32? = nil) -> Data {
        let length = declaredLength ?? UInt32(headerBytes.count)
        var message = Data([UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)])
        message.append(headerBytes)
        message.append(payload)
        return message
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Image payloads

    /// A complete 1×1 RGBA PNG that ImageIO decodes. The codec checks only the signature; comparing
    /// decoded size with the header is the image decoder's job.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
    /// JPEG start-of-image, a JFIF APP0 segment and end-of-image: enough for the codec's signature check.
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
                            0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9])

    /// `count` zero bytes that start with the PNG signature.
    static func pngPayload(count: Int) -> Data {
        var payload = Data(count: count)
        payload.replaceSubrange(0..<8, with: png.prefix(8))
        return payload
    }

    // MARK: - Frame headers

    /// The frame header from PROTOCOL-IMPLEMENTATION-NOTES §5, with the field set of Server.swift `acceptImage`.
    static func frameHeader(_ edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var header: [String: Any] = ["type": "frame", "revision": 1, "display": "fixture-1", "x": 0, "y": 0, "width": 128, "height": 128,
                                     "canvasWidth": 1280, "canvasHeight": 720, "codec": "png", "sequence": 12]
        edit(&header)
        return header
    }

    static func frame(payload: Data = WireFixtures.png, _ edit: (inout [String: Any]) -> Void = { _ in }) -> Data {
        envelope(frameHeader(edit), payload: payload)
    }

    // MARK: - Audio headers (viewer-windows/tests/aac-fixtures.json)

    /// First case: 48 kbps mono AAC-LC.
    static let aacMonoCookieBase64 = "A4CAgCIAAAAEgICAFEAUABgAAAAAAAAAu4AFgICAAhGIBoCAgAEC"
    /// The MPEG-4 ESDS those 52 characters decode to (AudioSpecificConfig 11 88: AAC-LC, 48 kHz, mono).
    static let aacMonoCookieHex = "038080802200000004808080144014001800000000000000bb8005808080021188068080800102"
    /// The first case's first raw access unit (no ADTS header).
    static let aacMonoFirstPacket = Data(base64Encoded: "ANBABw==")!
    /// Second case: 96 kbps stereo.
    static let aacStereoCookieBase64 = "A4CAgCIAAAAEgICAFEAUABgAAAAAAAABdwAFgICAAhGQBoCAgAEC"
    static let aacStereoFirstPacket = Data(base64Encoded: "ISADQGgc")!

    /// An AAC header as `RemoteSession.acceptAudio` (Server.swift) builds it.
    static func aacHeader(channels: Int = 1, bitrate: Int = 48_000, cookie: String = WireFixtures.aacMonoCookieBase64,
                          _ edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var header: [String: Any] = ["type": "audio", "revision": 3, "codec": "aac", "sampleRate": 48_000, "channels": channels,
                                     "sequence": 40, "samples": 1024, "bitrate": bitrate, "cookie": cookie]
        edit(&header)
        return header
    }

    /// A μ-law header as `acceptAudio` builds it: 480 samples of 24 kHz mono, no bitrate or cookie.
    static func muLawHeader(_ edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var header: [String: Any] = ["type": "audio", "revision": 2, "codec": "mulaw", "sampleRate": 24_000, "channels": 1,
                                     "sequence": 41, "samples": 480]
        edit(&header)
        return header
    }

    static let muLawPayload = Data((0..<480).map { UInt8(truncatingIfNeeded: $0 &* 37) })

    // MARK: - welcome / displays

    static let fixtureSessionID = "5B1E3C1A-7D2F-4E0B-9A61-2C8D4F6E0A13"

    /// The synthetic host's welcome built the way the host builds it: `DisplayInfo.json` (Display.swift)
    /// plus `primary`, inside `RemoteSession.welcome` (Server.swift), serialized by the host's unsorted `send`.
    static func hostFixtureWelcome(type: String = "welcome") -> Data {
        var displays: [[String: Any]] = []
        for i in 1...3 {
            let width = i == 2 ? 1920 : 3840
            let height = i == 2 ? 1080 : 2160
            let bounds = CGRect(x: CGFloat((i - 1) * 1920), y: 0, width: 1920, height: 1080)
            displays.append(["id": "fixture-\(i)", "name": "Test Display \(i)", "index": i, "width": width, "height": height,
                             "x": Int(bounds.minX), "y": Int(bounds.minY), "logicalWidth": bounds.width, "logicalHeight": bounds.height,
                             "scale": Double(width) / Double(max(1, bounds.width)), "primary": i == 1])
        }
        let capabilities: [String: Any] = ["codecs": ["png", "jpeg"], "audio": [String](),
                                           "colorModes": ["gray16", "color256", "rgb565", "full"], "maxViewers": 1]
        let message: [String: Any] = ["type": type, "version": 1, "serverName": "Portlight Test Host", "sessionId": fixtureSessionID,
                                      "displays": displays, "capabilities": capabilities]
        return jsonData(message, sortedKeys: false)
    }

    /// The same welcome as text, as JSONSerialization writes it (integral doubles print without ".0").
    static let fixtureWelcomeJSON = #"{"type":"welcome","version":1,"serverName":"Portlight Test Host","sessionId":"5B1E3C1A-7D2F-4E0B-9A61-2C8D4F6E0A13","displays":[{"id":"fixture-1","name":"Test Display 1","index":1,"width":3840,"height":2160,"x":0,"y":0,"logicalWidth":1920,"logicalHeight":1080,"scale":2,"primary":true},{"id":"fixture-2","name":"Test Display 2","index":2,"width":1920,"height":1080,"x":1920,"y":0,"logicalWidth":1920,"logicalHeight":1080,"scale":1,"primary":false},{"id":"fixture-3","name":"Test Display 3","index":3,"width":3840,"height":2160,"x":3840,"y":0,"logicalWidth":1920,"logicalHeight":1080,"scale":2,"primary":false}],"capabilities":{"codecs":["png","jpeg"],"audio":[],"colorModes":["gray16","color256","rgb565","full"],"maxViewers":1}}"#

    static let fixtureDisplays: [HostDisplay] = [
        HostDisplay(id: "fixture-1", name: "Test Display 1", number: 1, nativeSize: PixelSize(width: 3840, height: 2160),
                    logicalFrame: LogicalRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2, isPrimary: true),
        HostDisplay(id: "fixture-2", name: "Test Display 2", number: 2, nativeSize: PixelSize(width: 1920, height: 1080),
                    logicalFrame: LogicalRect(x: 1920, y: 0, width: 1920, height: 1080), scale: 1, isPrimary: false),
        HostDisplay(id: "fixture-3", name: "Test Display 3", number: 3, nativeSize: PixelSize(width: 3840, height: 2160),
                    logicalFrame: LogicalRect(x: 3840, y: 0, width: 1920, height: 1080), scale: 2, isPrimary: false),
    ]

    static let fixtureWelcome = WelcomeMessage(
        version: 1, serverName: "Portlight Test Host", sessionID: fixtureSessionID, displays: fixtureDisplays,
        capabilities: HostCapabilities(imageCodecs: ["png", "jpeg"], audioCodecs: [], colorModes: ["gray16", "color256", "rgb565", "full"], maxViewers: 1))

    /// The fixture welcome with `edit` applied to the whole message.
    static func welcomeText(_ edit: (inout [String: Any]) -> Void) -> String {
        var object = parse(fixtureWelcomeJSON)
        edit(&object)
        return jsonText(object)
    }

    /// The fixture welcome with `edit` applied to one display row.
    static func welcomeText(row index: Int, _ edit: (inout [String: Any]) -> Void) -> String {
        welcomeText { object in
            var rows = object["displays"] as! [[String: Any]]
            edit(&rows[index])
            object["displays"] = rows
        }
    }

    /// A minimal welcome around `rows`.
    static func welcomeText(rows: [[String: Any]], extra: [String: Any] = [:]) -> String {
        var message: [String: Any] = ["type": "welcome", "version": 1, "displays": rows]
        message.merge(extra) { $1 }
        return jsonText(message)
    }

    static func displayRow(_ id: String, width: Int, height: Int, _ extra: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = ["id": id, "width": width, "height": height]
        row.merge(extra) { $1 }
        return row
    }

    // MARK: - subscribed

    /// `applySubscription`'s reply to revision 1 of all three fixture displays at HD (the fixture forces audio off).
    static let subscribedJSON = #"{"type":"subscribed","revision":1,"displays":[{"id":"fixture-1","width":1280,"height":720},{"id":"fixture-2","width":1280,"height":720},{"id":"fixture-3","width":1280,"height":720}],"paused":false,"audio":false,"audioCodec":"aac","audioBitrate":96000,"resolution":"hd"}"#

    static func subscribedText(_ edit: (inout [String: Any]) -> Void) -> String {
        var object = parse(subscribedJSON)
        edit(&object)
        return jsonText(object)
    }

    static func subscribedText(row index: Int, _ edit: (inout [String: Any]) -> Void) -> String {
        subscribedText { object in
            var rows = object["displays"] as! [[String: Any]]
            edit(&rows[index])
            object["displays"] = rows
        }
    }
}
