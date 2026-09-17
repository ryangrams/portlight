import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// Generation isolation, terminal events, close semantics, sending and the receive loop, driven through scripted
/// sockets on a private queue (no network). `handshake()` is what URLSession does on every attempt: the pinned
/// certificate is checked, then the socket opens.
@Suite struct TransportGenerationTests {
    static let pin = TransportTestCertificate.fingerprint
    static let der = TransportTestCertificate.der
    /// The events of one pinned handshake.
    static let verifiedOpen: [TransportRecorded] = [.identityVerified(pin), .opened]

    // MARK: Connecting

    @Test func connectBuildsTheURLAndStartsOneSocket() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        #expect(probe.sockets.count == 1)
        #expect(socket.startCount == 1)
        #expect(socket.urlString == "wss://192.168.1.20:5920/remote")
        #expect(probe.events.isEmpty)
    }

    @Test func ipv6EndpointsAreBracketedInTheURL() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin, endpoint: try #require(HostEndpoint(host: "fe80::1", port: 5921)))
        #expect(try #require(probe.socket(0)).urlString == "wss://[fe80::1]:5921/remote")
    }

    @Test func pinnedIdentityThenOpenThenMessagesInArrivalOrder() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 7, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        #expect(socket.challenge(leafDER: Self.der) == [true])
        socket.open()
        #expect(socket.pendingReceiveCount == 1)
        #expect(socket.receive(text: WireFixtures.fixtureWelcomeJSON))
        #expect(socket.pendingReceiveCount == 1)
        #expect(socket.receive(data: WireFixtures.frame()))
        #expect(socket.pendingReceiveCount == 1)
        let welcome = try PortlightWire.decodeText(WireFixtures.fixtureWelcomeJSON)
        let frame = try PortlightWire.decodeBinary(WireFixtures.frame())
        #expect(probe.events == [.identityVerified(Self.pin), .opened, .message(welcome), .message(frame)])
        #expect(probe.generations == [7, 7, 7, 7])
        #expect(probe.allDeliveredOnQueue)
    }

    @Test func identityIsReportedOnceAcrossRepeatedChallenges() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        #expect(socket.challenge(leafDER: Self.der) == [true])
        #expect(socket.challenge(leafDER: Self.der) == [true])
        #expect(probe.events == [.identityVerified(Self.pin)])
    }

    // MARK: Trust is terminal

    @Test func firstUseIsTerminalAndNothingIsSent() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: nil)
        let socket = try #require(probe.socket(0))
        #expect(socket.challenge(leafDER: Self.der) == [false])
        let prompt = TrustPrompt(endpoint: TransportUnitProbe.endpoint, fingerprint: Self.pin, previousFingerprint: nil)
        #expect(probe.events == [.trustRequired(prompt)])
        #expect(socket.shutdownCount == 1)
        // Late activity from the ended attempt is ignored, and nothing can be sent on it.
        socket.open()
        probe.send(.hello(password: "fixture-password"))
        socket.complete(error: TransportErrors.url(-999))
        #expect(socket.challenge(leafDER: Self.der) == [false])
        #expect(probe.events == [.trustRequired(prompt)])
        #expect(socket.sentTexts.isEmpty)
        #expect(socket.pendingReceiveCount == 0)
    }

    @Test func changedCertificateCarriesThePreviousPin() throws {
        let previous = CertificateFingerprint(digest: [UInt8](repeating: 0xAB, count: 32))
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: previous)
        let socket = try #require(probe.socket(0))
        #expect(socket.challenge(leafDER: Self.der) == [false])
        let prompt = TrustPrompt(endpoint: TransportUnitProbe.endpoint, fingerprint: Self.pin, previousFingerprint: previous)
        #expect(probe.events == [.trustRequired(prompt)])
        #expect(prompt.isChange)
    }

    @Test func missingCertificateFailsTLS() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        #expect(socket.challenge(leafDER: nil) == [false])
        #expect(socket.challenge(leafDER: TransportTestCertificate.empty) == [false])
        #expect(probe.events == [.closed(.tlsFailed("the host presented no certificate"))])
    }

    /// `.opened` promises trusted TLS, so it needs a pin match in the same attempt. A socket that opens without one
    /// (a resumed TLS session, a skipped challenge) must never carry the password.
    @Test func openingWithoutACertificateCheckFailsAndSendsNothing() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        socket.open()
        probe.send(.hello(password: "fixture-password"))
        #expect(probe.events == [.closed(.tlsFailed(TransportFailureClassifier.certificateUnchecked))])
        #expect(socket.sentTexts.isEmpty)
        #expect(socket.pendingReceiveCount == 0)
        #expect(socket.shutdownCount == 1)
    }

    /// One attempt has one identity. A different certificate after the pin matched is not a first use or a change
    /// to approve (`.trustRequired` promises nothing was sent, but hello may have been).
    @Test func aDifferentCertificateAfterOpeningEndsTheAttemptWithoutAPrompt() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        #expect(socket.handshake() == [true])
        probe.send(.hello(password: "fixture-password"))
        #expect(socket.challenge(leafDER: TransportTestCertificate.abc) == [false])
        #expect(probe.events == Self.verifiedOpen + [.closed(.tlsFailed(TransportFailureClassifier.certificateSwitched))])
        #expect(socket.shutdownCount == 1)
        #expect(socket.pendingReceiveCount == 1, "the receive requested at open is never re-armed")
        #expect(socket.receive(text: WireFixtures.fixtureWelcomeJSON))
        #expect(probe.events.count == 3)
    }

    @Test func aDifferentCertificateBeforeOpeningIsNotOfferedForApproval() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        #expect(socket.challenge(leafDER: Self.der) == [true])
        #expect(socket.challenge(leafDER: TransportTestCertificate.abc) == [false])
        socket.open()
        #expect(probe.events == [.identityVerified(Self.pin), .closed(.tlsFailed(TransportFailureClassifier.certificateSwitched))])
    }

    // MARK: Close and supersede

    @Test func closeStopsDeliveryAndIsIdempotent() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        #expect(socket.handshake() == [true])
        probe.send(.frameAck(sequence: 1))
        probe.close()
        #expect(socket.shutdownCount == 1)
        // The receive requested before close completes, then everything else a dying socket can report.
        #expect(socket.receive(text: WireFixtures.fixtureWelcomeJSON))
        socket.hostSendsCloseFrame()
        #expect(socket.failSend(TransportErrors.posix(32)))
        socket.complete(error: TransportErrors.posix(54))
        #expect(socket.challenge(leafDER: Self.der) == [false])
        probe.close()
        probe.close()
        #expect(socket.shutdownCount == 1)
        #expect(socket.pendingReceiveCount == 0)
        #expect(probe.events == Self.verifiedOpen)
    }

    @Test func closeAfterTheAttemptEndedItselfIsSafe() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        socket.handshake()
        #expect(socket.receive(text: #"{"type":"#))
        #expect(probe.events == Self.verifiedOpen + [.closed(.protocolViolation("malformed JSON"))])
        #expect(socket.shutdownCount == 1)
        #expect(socket.pendingReceiveCount == 0)
        probe.close()
        probe.close()
        socket.complete(error: TransportErrors.posix(57))
        #expect(socket.shutdownCount == 1)
        #expect(probe.events.count == 3)
    }

    @Test func aNewConnectSupersedesTheOlderGeneration() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let first = try #require(probe.socket(0))
        first.handshake()
        probe.connect(generation: 2, pin: Self.pin)
        let second = try #require(probe.socket(1))
        #expect(first.shutdownCount == 1)
        #expect(second.startCount == 1)
        // Everything the superseded socket still reports is dropped.
        #expect(first.receive(text: WireFixtures.fixtureWelcomeJSON))
        first.hostSendsCloseFrame()
        first.complete(error: TransportErrors.posix(54))
        #expect(first.challenge(leafDER: Self.der) == [false])
        second.handshake()
        probe.send(.frameAck(sequence: 3))
        #expect(probe.events == Self.verifiedOpen + Self.verifiedOpen)
        #expect(probe.generations == [1, 1, 2, 2])
        #expect(first.sentTexts.isEmpty)
        #expect(second.sentTexts == [try PortlightWire.encode(.frameAck(sequence: 3))])
    }

    @Test func closingInsideAnEventHandlerStopsTheReceiveLoop() throws {
        let probe = TransportUnitProbe()
        probe.reaction = { event, transport in if event == .opened { transport.close() } }
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        socket.handshake()
        #expect(probe.events == Self.verifiedOpen)
        #expect(socket.pendingReceiveCount == 0)
        #expect(socket.shutdownCount == 1)
    }

    @Test func closingWhileIdentityIsReportedCancelsTheChallenge() throws {
        let probe = TransportUnitProbe()
        probe.reaction = { event, transport in if case .identityVerified = event { transport.close() } }
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        #expect(socket.challenge(leafDER: Self.der) == [false])
        socket.open()
        #expect(probe.events == [.identityVerified(Self.pin)])
    }

    // MARK: Sending

    @Test func sendIsIgnoredUntilOpenAndAfterClose() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        probe.send(.ping(time: 1))
        #expect(socket.challenge(leafDER: Self.der) == [true])
        probe.send(.ping(time: 1.5))
        #expect(socket.sentTexts.isEmpty, "a verified certificate alone is not an open socket")
        socket.open()
        probe.send(.frameAck(sequence: 7))
        probe.send(.ping(time: 2))
        #expect(socket.sentTexts == [try PortlightWire.encode(.frameAck(sequence: 7)), try PortlightWire.encode(.ping(time: 2))])
        probe.close()
        probe.send(.frameAck(sequence: 8))
        #expect(socket.sentTexts.count == 2)
    }

    @Test func sendFailureIsNetworkLost() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        socket.handshake()
        probe.send(.frameAck(sequence: 1))
        #expect(socket.failSend(TransportErrors.posix(32)))
        #expect(probe.events == Self.verifiedOpen + [.closed(.networkLost)])
        #expect(socket.shutdownCount == 1)
    }

    @Test func sendFailureAfterACloseFrameIsHostClosed() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        socket.handshake()
        probe.send(.frameAck(sequence: 1))
        socket.markCloseFrameReceived()
        #expect(socket.failSend(TransportErrors.posix(32)))
        #expect(probe.events == Self.verifiedOpen + [.closed(.hostClosed)])
    }

    // MARK: Receiving and ending

    @Test func malformedMessagesAreProtocolViolations() throws {
        func violation(_ feed: (TransportScriptedSocket) -> Void) throws -> [TransportRecorded] {
            let probe = TransportUnitProbe()
            probe.connect(generation: 1, pin: Self.pin)
            let socket = try #require(probe.socket(0))
            socket.handshake()
            feed(socket)
            #expect(socket.pendingReceiveCount == 0, "the receive loop stops after a violation")
            return probe.events
        }
        #expect(try violation { $0.receive(text: "[]") } == Self.verifiedOpen + [.closed(.protocolViolation("JSON that isn’t an object"))])
        #expect(try violation { $0.receive(bytes: [0, 0, 0]) } == Self.verifiedOpen + [.closed(.protocolViolation("a 3-byte binary message"))])
        #expect(try violation { $0.receive(bytes: [0, 0, 0, 200, 0x7b]) }
                == Self.verifiedOpen + [.closed(.protocolViolation("a binary header length of 200"))])
        let incomplete = #"{"type":"welcome"}"#
        let missingField = TransportFailureClassifier.violationReason(try TransportWireProbe.error(incomplete))
        #expect(try violation { $0.receive(text: incomplete) } == Self.verifiedOpen + [.closed(.protocolViolation(missingField))])
    }

    @Test func hostCloseFrameIsHostClosed() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        socket.handshake()
        socket.hostSendsCloseFrame()
        #expect(socket.failReceive(TransportErrors.posix(57)))
        #expect(probe.events == Self.verifiedOpen + [.closed(.hostClosed)])
    }

    @Test func receiveFailureAfterACloseFrameIsHostClosed() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        socket.handshake()
        socket.markCloseFrameReceived()
        #expect(socket.failReceive(TransportErrors.posix(54)))
        #expect(probe.events == Self.verifiedOpen + [.closed(.hostClosed)])
    }

    @Test func connectFailuresAreClassified() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: nil)
        let socket = try #require(probe.socket(0))
        socket.complete(error: TransportErrors.url(-1004, posix: 61))
        socket.complete(error: TransportErrors.url(-1001))
        #expect(probe.events == [.closed(.refused)])
        #expect(socket.shutdownCount == 1)
    }

    @Test func failuresAfterOpeningAreConnectionLosses() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        socket.handshake()
        #expect(socket.failReceive(TransportErrors.url(-1001)))
        #expect(probe.events == Self.verifiedOpen + [.closed(.networkLost)])
    }

    @Test func completionWithoutAnErrorDependsOnWhetherTheSocketOpened() throws {
        let before = TransportUnitProbe()
        before.connect(generation: 1, pin: Self.pin)
        try #require(before.socket(0)).complete(error: nil)
        #expect(before.events == [.closed(.protocolViolation(TransportFailureClassifier.upgradeRefused))])

        let after = TransportUnitProbe()
        after.connect(generation: 1, pin: Self.pin)
        let socket = try #require(after.socket(0))
        socket.handshake()
        socket.complete(error: nil)
        #expect(after.events == Self.verifiedOpen + [.closed(.hostClosed)])
    }

    @Test func redirectsAreRefused() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        #expect(socket.presentRedirect() == [true])
        #expect(probe.events == [.closed(.protocolViolation(TransportFailureClassifier.redirectRefused))])
        #expect(socket.shutdownCount == 1)
    }

    // MARK: Production socket

    @Test func productionSocketIsEphemeralWithThe32MiBLimit() {
        let facts = TransportSocketFacts.configuration()
        #expect(facts == .init(requestTimeout: 15, waitsForConnectivity: false, keepsNoCookiesCacheOrCredentials: true,
                               minimumTLS12: true, maximumMessageSize: 32 * 1024 * 1024))
    }

    @Test func delegateQueueIsSerialOnTheCallersQueue() {
        let facts = TransportSocketFacts.delegateQueue()
        #expect(facts.serial)
        #expect(facts.onGivenQueue)
        #expect(facts.mainIsOperationQueueMain)
    }
}

/// The `ProtocolError` the codec throws for a text message, so expectations follow the codec.
enum TransportWireProbe {
    struct NoError: Error {}
    static func error(_ text: String) throws -> ProtocolError {
        do {
            _ = try PortlightWire.decodeText(text)
        } catch let error as ProtocolError {
            return error
        }
        throw NoError()
    }
}
