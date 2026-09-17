import Testing
@testable import PortlightKit

@Test func protocolConstantsMatchHost() {
    #expect(PortlightProtocol.version == 1)
    #expect(PortlightProtocol.defaultPort == 5920)
    #expect(PortlightProtocol.maxBinaryMessageBytes == 33_554_432)
}
