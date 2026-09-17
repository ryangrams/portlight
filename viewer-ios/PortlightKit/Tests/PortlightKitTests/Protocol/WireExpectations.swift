import Testing
@testable import PortlightKit

// Error expectations for wire tests. Like every file here that imports Testing, this one must not import
// Foundation (see WireFixtures.swift); `Bytes` is Foundation's `Data`.
extension WireFixtures {
    static func expectText(_ expected: ProtocolError, _ text: String, _ comment: Comment? = nil,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: expected, comment, sourceLocation: sourceLocation) { try PortlightWire.decodeText(text) }
    }

    static func expectText(_ expected: ProtocolError, bytes: Bytes, _ comment: Comment? = nil,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: expected, comment, sourceLocation: sourceLocation) { try PortlightWire.decodeText(bytes) }
    }

    static func expectBinary(_ expected: ProtocolError, _ data: Bytes, _ comment: Comment? = nil,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: expected, comment, sourceLocation: sourceLocation) { try PortlightWire.decodeBinary(data) }
    }

    static func expectEncode(_ expected: ProtocolError, _ message: OutboundMessage, _ comment: Comment? = nil,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: expected, comment, sourceLocation: sourceLocation) { try PortlightWire.encode(message) }
    }
}
