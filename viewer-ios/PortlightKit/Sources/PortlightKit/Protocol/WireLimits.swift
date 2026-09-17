import Foundation

extension PortlightWire {
    /// Validation bounds applied by the codec. Each mirrors a host rule (Server.swift, Display.swift,
    /// Capture.swift, shared/AAC.swift) or caps an attacker-controlled size before anything is allocated.
    enum Limits {
        /// Deepest object/array nesting accepted in any JSON document. Real messages nest three deep.
        static let maxNestingDepth = 16
        /// Rows accepted in `welcome`/`displays`. The host enumerates at most 32 active displays.
        static let maxAdvertisedDisplays = 64
        /// UTF-8 bytes in an opaque display ID. Real IDs are 36-byte CFUUID strings or `display-<n>`.
        static let maxDisplayIDBytes = 256
        /// Native capture pixels per side advertised in `welcome`.
        static let nativeSideRange = 1...32_768
        /// Magnitude bound for logical origins and sizes: 32768 native pixels at the minimum 0.25 scale.
        static let maxLogicalMagnitude = 131_072.0
        /// Native pixels per logical point.
        static let scaleRange = 0.25...8.0
        /// Stream canvas pixels per side. The host tile encoder refuses anything larger.
        static let canvasSideRange = 1...7_680
        /// Encoded image bytes in one frame (the Mac viewer's decode guard).
        static let maxFramePayloadBytes = 20_000_000
        static let aacSampleRate = 48_000
        static let aacSamplesPerPacket = 1_024
        /// Decoded AAC magic cookie bytes (`AACDecoder` refuses larger cookies).
        static let aacCookieBytes = 1...4_096
        /// Base64 characters that can encode `aacCookieBytes.upperBound`, checked before decoding.
        static let maxCookieBase64Characters = (aacCookieBytes.upperBound + 2) / 3 * 4
        /// One raw AAC access unit (`AACDecoder` refuses larger units).
        static let aacPacketBytes = 1...16_384
        static let muLawSampleRate = 24_000
        /// One μ-law packet: one byte per sample, at most one second.
        static let muLawPacketBytes = 1...24_000
        /// Longest `subscribed.notice` kept, in characters.
        static let maxNoticeCharacters = 512
        /// Host-supplied names quoted in errors and `.ignored` are cut to this many characters.
        static let maxDiagnosticCharacters = 64
        /// The host's password verifier rejects anything longer.
        static let maxPasswordBytes = 1_024
        /// The host clamps each wheel message to ±100 lines; clamping here keeps both ends in agreement.
        static let maxWheelLines = 100.0
        /// Manual video data rate; 0 means automatic.
        static let bandwidthKbpsRange = 100...100_000
        static let fpsRange = 1...60
        /// Mouse button mask: left 1, right 2, middle 4.
        static let buttonMaskRange = 0...7
    }

    /// Display IDs are opaque, but an empty or oversized one can never name a real host display.
    static func isValidDisplayID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= Limits.maxDisplayIDBytes
    }

    /// Host-controlled text quoted in errors and diagnostics, bounded so it can't flood logs or UI copy.
    static func diagnostic(_ text: String) -> String {
        String(text.prefix(Limits.maxDiagnosticCharacters))
    }
}
