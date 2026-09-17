#if os(macOS)
import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files (the Command Line Tools' Testing lacks the Foundation overlay). Processes,
// pipes and bounded waits live in TransportIntegrationSupport.swift.

/// Real sockets against hosts this suite starts itself on free 127.0.0.1 ports with temporary data directories:
/// the fixture host (`--fixture`, synthetic password on stdin) and scripts/mock-host.py. Never a live Portlight Host.
/// Evidence for NET-01 (trust), NET-04 (refused, wrong password, busy), WIRE-01 (real host bytes decode), and the
/// viewer's own input and audio at message level against the mock host.
@Suite("Integration: transport", .serialized)
struct TransportIntegrationTests {
    static let fixtureIDs: [DisplayID] = ["fixture-1", "fixture-2", "fixture-3"]
    static let hd = PixelSize(width: 1280, height: 720)
    static let fixtureSkip = Comment(rawValue: TransportIntegration.fixture.skipNote)
    static let mockSkip = Comment(rawValue: TransportIntegration.mock.skipNote)

    static func subscribeAll(_ displays: [DisplayID]) -> OutboundMessage {
        .subscribe(SubscriptionRequest(revision: 1, displays: displays, resolution: .hd, color: .full, quality: .automatic))
    }

    // MARK: Trust (NET-01)

    @Test("First use: trust required for exactly the fixture's certificate, nothing sent",
          .enabled(if: TransportIntegration.fixture.runnable, TransportIntegrationTests.fixtureSkip))
    func firstUseRequiresTrust() throws {
        let host = try TransportHost.startFixture()
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        client.connect(to: host.endpoint, pin: nil)
        #expect(client.waitForEnd())
        let prompt = TrustPrompt(endpoint: host.endpoint, fingerprint: host.fingerprint, previousFingerprint: nil)
        #expect(client.events == [.trustRequired(prompt)])
        // The attempt ended inside the TLS handshake: a hello now goes nowhere and nothing else arrives.
        client.send(.hello(password: host.password))
        #expect(!client.waitForEvents(beyond: 1, timeout: 0.5))
    }

    @Test("First use sends no application data (mock host transcript, with a pinned control)",
          .enabled(if: TransportIntegration.mock.runnable, TransportIntegrationTests.mockSkip))
    func firstUseSendsNoApplicationData() throws {
        let host = try TransportHost.startMock(transcript: true)
        defer { host.stop() }
        let unpinned = TransportLiveClient()
        defer { unpinned.close() }
        unpinned.connect(to: host.endpoint, pin: nil)
        #expect(unpinned.waitForEnd())
        #expect(unpinned.events == [.trustRequired(TrustPrompt(endpoint: host.endpoint, fingerprint: host.fingerprint, previousFingerprint: nil))])
        // Control: the transcript does record a pinned client's hello, so its absence above is meaningful.
        let pinned = TransportLiveClient()
        defer { pinned.close() }
        #expect(pinned.authenticate(with: host) != nil)
        #expect(host.inboundMessageTypes() == ["hello"])
    }

    @Test("Pinned certificate: identity verified, then open", .enabled(if: TransportIntegration.fixture.runnable, TransportIntegrationTests.fixtureSkip))
    func pinnedCertificateVerifiesThenOpens() throws {
        let host = try TransportHost.startFixture()
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        client.connect(to: host.endpoint, pin: host.fingerprint)
        #expect(client.waitForOpen())
        #expect(client.events == [.identityVerified(host.fingerprint), .opened])
    }

    @Test("Changed certificate: trust required again with the previous pin", .enabled(if: TransportIntegration.fixture.runnable, TransportIntegrationTests.fixtureSkip))
    func changedPinRequiresApprovalAgain() throws {
        let host = try TransportHost.startFixture()
        defer { host.stop() }
        let stale = CertificateFingerprint(digest: [UInt8](repeating: 0xAB, count: 32))
        let client = TransportLiveClient()
        defer { client.close() }
        client.connect(to: host.endpoint, pin: stale)
        #expect(client.waitForEnd())
        let prompt = TrustPrompt(endpoint: host.endpoint, fingerprint: host.fingerprint, previousFingerprint: stale)
        #expect(client.events == [.trustRequired(prompt)])
        #expect(prompt.isChange)
    }

    @Test("Every attempt checks the certificate: pinned attempts in a row each verify before opening",
          .enabled(if: TransportIntegration.fixture.runnable, TransportIntegrationTests.fixtureSkip))
    func everyAttemptVerifiesTheCertificate() throws {
        let host = try TransportHost.startFixture()
        defer { host.stop() }
        // `.opened` requires a pin match in the same attempt. This is the evidence that URLSession asks on every
        // repeat connection (no TLS session resumed across attempts), with fresh transports and a reused one.
        let pair: [TransportRecorded] = [.identityVerified(host.fingerprint), .opened]
        for _ in 0..<3 {
            let client = TransportLiveClient()
            defer { client.close() }
            client.connect(to: host.endpoint, pin: host.fingerprint)
            #expect(client.waitForOpen())
            #expect(client.events == pair)
        }
        let reused = TransportLiveClient()
        defer { reused.close() }
        for attempt in 1...3 {
            reused.connect(to: host.endpoint, pin: host.fingerprint, generation: UInt64(attempt))
            #expect(reused.log.wait(timeout: 20) { events in
                events.filter { $0 == .opened }.count == attempt || events.contains(where: \.isTerminal)
            })
            reused.close()
        }
        #expect(reused.events == pair + pair + pair)
    }

    /// No attempt outlives its end, so reconnects can't accumulate sessions. A guard, not a fix: URLSession drops its
    /// delegate (the attempt) once invalidation completes, and the reviewed code already released everything when
    /// autorelease pools were drained (an undrained test-thread pool had looked like a leak).
    @Test("Ended attempts release their URLSession socket and connection",
          .enabled(if: TransportIntegration.fixture.runnable, TransportIntegrationTests.fixtureSkip))
    func endedAttemptsReleaseTheirSessions() throws {
        let host = try TransportHost.startFixture()
        defer { host.stop() }
        let refused = try #require(HostEndpoint(host: "127.0.0.1", port: try TransportIntegration.unusedPort()))
        let attempts = TransportAttemptRefs()
        do {
            let client = TransportLiveClient(attempts: attempts)
            // Opened, then closed by the consumer (the engine's disconnect).
            for attempt in 1...3 {
                client.connect(to: host.endpoint, pin: host.fingerprint, generation: UInt64(attempt))
                #expect(client.log.wait(timeout: 20) { $0.filter { $0 == .opened }.count == attempt })
                client.close()
            }
            // Ended by the transport itself (a trust prompt), then closed as the engine does.
            client.connect(to: host.endpoint, pin: nil, generation: 4)
            #expect(client.waitForEnd())
            client.close()
        }
        do {
            // Ended by the transport (refused) and never closed: the engine releases the transport instead.
            let client = TransportLiveClient(attempts: attempts)
            client.connect(to: refused, pin: nil)
            #expect(client.waitForEnd())
        }
        #expect(attempts.count == 5)
        #expect(attempts.waitUntilReleased(timeout: 5), "\(attempts.alive) of \(attempts.count) ended attempts are still alive")
    }

    // MARK: Session (WIRE-01)

    @Test("Hello: welcome with the three fixture displays", .enabled(if: TransportIntegration.fixture.runnable, TransportIntegrationTests.fixtureSkip))
    func helloReturnsTheFixtureWelcome() throws {
        let host = try TransportHost.startFixture()
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        let welcome = try #require(client.authenticate(with: host))
        #expect(welcome.version == 1)
        #expect(welcome.serverName == "Portlight Test Host")
        #expect(welcome.displays.map(\.id) == Self.fixtureIDs)
        #expect(welcome.displays.map(\.logicalFrame.width) == [1920, 1920, 1920])
        #expect(welcome.capabilities.maxViewers == 1)
        #expect(welcome.capabilities.audioCodecs.isEmpty)
    }

    @Test("Subscribe all three at HD: subscribed, then real frames that decode", .enabled(if: TransportIntegration.fixture.runnable, TransportIntegrationTests.fixtureSkip))
    func subscribeStreamsDecodableFrames() throws {
        let host = try TransportHost.startFixture()
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        _ = try #require(client.authenticate(with: host))
        client.send(Self.subscribeAll(Self.fixtureIDs))
        let ack = try #require(client.waitForSubscribed(revision: 1))
        #expect(ack.canvases.map(\.display).sorted() == Self.fixtureIDs)
        #expect(ack.canvases.allSatisfy { $0.size == Self.hd })
        #expect(ack.resolution == .preset(.hd))

        let frames = client.waitForFrames(from: Self.fixtureIDs, count: 2)
        for display in Self.fixtureIDs {
            let received = try #require(frames[display], "no frames from \(display): \(client.events.suffix(5))")
            #expect(received.count >= 2)
            for frame in received {
                #expect(frame.header.revision == 1)
                #expect(frame.header.canvas == Self.hd)
                #expect(frame.header.rect.fits(in: Self.hd))
                // The host's own PNG/JPEG bytes decode to exactly the declared rectangle.
                let patch = try ImageTileDecoder.decode(header: frame.header, payload: frame.payload,
                                                        allocate: { PortlightKit.HeapPatchBuffer(byteCount: $0) })
                #expect(patch.bytesPerRow == frame.header.rect.width * 4)
            }
        }
        #expect(!client.hasEnded)
    }

    // MARK: Failures (NET-04)

    @Test("Wrong password: authentication error, then closed", .enabled(if: TransportIntegration.fixture.runnable, TransportIntegrationTests.fixtureSkip))
    func wrongPasswordIsRejectedThenClosed() throws {
        let host = try TransportHost.startFixture()
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        #expect(client.authenticate(with: host, password: "not-the-fixture-password") == nil)
        #expect(client.waitForEnd())
        let rejected = HostErrorMessage(code: .authentication, message: "Incorrect password or incompatible protocol")
        #expect(client.events == [.identityVerified(host.fingerprint), .opened, .message(.error(rejected)), .closed(.hostClosed)])
    }

    @Test("Unused port: refused")
    func unusedPortIsRefused() throws {
        let endpoint = try #require(HostEndpoint(host: "127.0.0.1", port: try TransportIntegration.unusedPort()))
        let client = TransportLiveClient()
        defer { client.close() }
        client.connect(to: endpoint, pin: nil)
        #expect(client.waitForEnd())
        #expect(client.events == [.closed(.refused)])
    }

    @Test("Second authenticated viewer: busy", .enabled(if: TransportIntegration.fixture.runnable, TransportIntegrationTests.fixtureSkip))
    func secondViewerIsBusy() throws {
        let host = try TransportHost.startFixture()
        defer { host.stop() }
        let first = TransportLiveClient()
        defer { first.close() }
        _ = try #require(first.authenticate(with: host))
        let second = TransportLiveClient()
        defer { second.close() }
        #expect(second.authenticate(with: host) == nil)
        #expect(second.waitForEnd())
        let busy = HostErrorMessage(code: .busy, message: "Another viewer is connected. Disconnect it before connecting here.")
        // Like the wrong-password case, the host closes without a close frame (measured: POSIX 57).
        #expect(second.events == [.identityVerified(host.fingerprint), .opened, .message(.error(busy)), .closed(.hostClosed)])
        // The first session is unaffected.
        #expect(!first.hasEnded)
    }

    @Test("close() mid-stream: no further events", .enabled(if: TransportIntegration.fixture.runnable, TransportIntegrationTests.fixtureSkip))
    func closeMidStreamDeliversNothingMore() throws {
        let host = try TransportHost.startFixture()
        defer { host.stop() }
        let client = TransportLiveClient()
        _ = try #require(client.authenticate(with: host))
        client.send(Self.subscribeAll(Self.fixtureIDs))
        let frames = client.waitForFrames(from: Self.fixtureIDs)
        #expect(frames.count == Self.fixtureIDs.count, "streaming must be live before the close")
        // Still streaming: without a close more events arrive, so the silence below is the close's doing.
        #expect(client.waitForEvents(beyond: client.events.count, timeout: 2.0))
        let atClose = client.closeReturningEventCount()
        #expect(!client.waitForEvents(beyond: atClose, timeout: 1.0))
        client.close()
        client.close()
        #expect(client.events.count == atClose)
        #expect(!client.hasEnded)
    }

    // MARK: Input and audio at message level (INPUT-01…04, AUDIO-01)

    static func wireType(_ message: OutboundMessage) -> String {
        switch message {
        case .pointer: "pointer"
        case .wheel: "wheel"
        case .key: "key"
        case .text: "text"
        default: "other"
        }
    }

    @Test("Mock: input built by the viewer's own ledger is accepted exactly as sent",
          .enabled(if: TransportIntegration.mock.runnable, TransportIntegrationTests.mockSkip))
    func ledgerInputIsAcceptedByTheMock() throws {
        let host = try TransportHost.startMock(transcript: true)
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        _ = try #require(client.authenticate(with: host))
        client.send(Self.subscribeAll(Self.fixtureIDs))
        _ = try #require(client.waitForSubscribed(revision: 1))

        // Built by the Input module the way the session builds them, not hand-written JSON.
        let ledger = InputLedger()
        var latches = ModifierLatches()
        let target = PointerTarget(display: "fixture-2", x: 0.25, y: 0.5, desktop: LogicalPoint(x: 2400, y: 540))
        var messages = ledger.apply(.move(target), modifiers: &latches)
        messages += ledger.apply(.press(.left, target), modifiers: &latches)
        messages += ledger.apply(.release(.left, target), modifiers: &latches)
        messages += ledger.apply(.press(.right, target), modifiers: &latches)
        messages += ledger.apply(.release(.right, target), modifiers: &latches)
        messages += ledger.apply(.scroll(target, dx: 0, dy: -3), modifiers: &latches)
        messages += ledger.pressKey(keysym: 0xff0d, modifiers: &latches)   // Return
        messages += ledger.text("héllo wörld 👋🏽 👨‍👩‍👧")
        messages += ledger.releaseAll()
        #expect(Set(messages.map(Self.wireType)) == ["pointer", "wheel", "key", "text"])
        for message in messages { client.send(message) }

        let recorded = host.waitForInboundInput(count: messages.count)
        #expect(recorded.map(\.type) == messages.map(Self.wireType))
        let refused = recorded.filter { !$0.accepted || $0.typeWarnings }
        #expect(refused.isEmpty, "the mock refused or coerced: \(refused)")
        #expect(!client.hasEnded)
    }

    @Test("Mock: AAC audio arrives in order and every packet decodes to 1024 frames",
          .enabled(if: TransportIntegration.mock.runnable, TransportIntegrationTests.mockSkip))
    func aacAudioArrivesAndDecodes() throws {
        try expectAudio(codec: .aac, sampleRate: 48000, samples: 1024)
    }

    @Test("Mock: μ-law audio arrives in order and every packet decodes to 480 frames",
          .enabled(if: TransportIntegration.mock.runnable, TransportIntegrationTests.mockSkip))
    func muLawAudioArrivesAndDecodes() throws {
        try expectAudio(codec: .mulaw, sampleRate: 24000, samples: 480)
    }

    private func expectAudio(codec: AudioCodec, sampleRate: Int, samples: Int) throws {
        let host = try TransportHost.startMock(arguments: ["--audio", codec.rawValue])
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        let welcome = try #require(client.authenticate(with: host))
        #expect(welcome.capabilities.audioCodecs.contains(codec))
        client.send(.subscribe(SubscriptionRequest(revision: 1, displays: Self.fixtureIDs, resolution: .hd, color: .full,
                                                   quality: .automatic, audio: true, audioCodec: codec)))
        let ack = try #require(client.waitForSubscribed(revision: 1))
        #expect(ack.audio)
        let packets = client.waitForAudio(count: 20)
        #expect(packets.count >= 20, "only \(packets.count) audio packets; last events: \(client.events.suffix(3))")
        #expect(packets.allSatisfy { $0.header.codec == codec && $0.header.sampleRate == sampleRate && $0.header.revision == 1 })
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $1.header.sequence > $0.header.sequence })
        #expect(TransportAudio.decodedFrameCounts(packets) == Array(repeating: samples, count: packets.count))
        #expect(!client.hasEnded)
    }

    // MARK: Mock host scenarios

    @Test("Mock bad-json: protocol violation", .enabled(if: TransportIntegration.mock.runnable, TransportIntegrationTests.mockSkip))
    func malformedJSONIsAProtocolViolation() throws {
        try expectViolation(scenario: "bad-json", reason: TransportFailureClassifier.violationReason(.invalidJSON))
    }

    @Test("Mock binary-short: protocol violation", .enabled(if: TransportIntegration.mock.runnable, TransportIntegrationTests.mockSkip))
    func shortBinaryIsAProtocolViolation() throws {
        try expectViolation(scenario: "binary-short", reason: TransportFailureClassifier.violationReason(.binaryTooShort(3)))
    }

    private func expectViolation(scenario: String, reason: String) throws {
        let host = try TransportHost.startMock(scenarios: [scenario])
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        let welcome = try #require(client.authenticate(with: host))
        client.send(Self.subscribeAll(welcome.displays.map(\.id)))
        #expect(client.waitForEnd())
        #expect(client.events.last == .closed(.protocolViolation(reason)))
        #expect(client.terminalEventCount == 1)
        #expect(!client.waitForEvents(beyond: client.events.count, timeout: 0.3))
    }

    @Test("Mock: a message over the socket's size limit is a protocol violation",
          .enabled(if: TransportIntegration.mock.runnable, TransportIntegrationTests.mockSkip))
    func overLimitMessageIsAProtocolViolation() throws {
        let host = try TransportHost.startMock()
        defer { host.stop() }
        // Production allows 32 MiB, inclusive (measured: a limit equal to a message's size accepts it). A 64-byte
        // limit makes the host's welcome too large, which URLSession reports as EMSGSIZE: the path a 32 MiB + 1 byte
        // message takes.
        let client = TransportLiveClient(messageSizeLimit: 64)
        defer { client.close() }
        #expect(client.authenticate(with: host) == nil)
        #expect(client.waitForEnd())
        #expect(client.events == [.identityVerified(host.fingerprint), .opened,
                                  .closed(.protocolViolation(TransportFailureClassifier.messageTooLarge))])
    }

    @Test("Mock stall-after: the transport stays open (the engine's read deadline owns stalls)",
          .enabled(if: TransportIntegration.mock.runnable, TransportIntegrationTests.mockSkip))
    func stalledHostLeavesTheTransportOpen() throws {
        let host = try TransportHost.startMock(scenarios: ["stall-after=0.3"])
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        _ = try #require(client.authenticate(with: host))
        // Let the stall begin, then watch 2 s of silence: nothing arrives and nothing closes.
        _ = client.waitForEvents(beyond: .max, timeout: 0.8)
        let quiet = client.events.count
        #expect(!client.waitForEvents(beyond: quiet, timeout: 2.0))
        #expect(!client.hasEnded)
    }

    @Test("Mock close frame after welcome: host closed", .enabled(if: TransportIntegration.mock.runnable, TransportIntegrationTests.mockSkip))
    func closeFrameIsHostClosed() throws {
        let host = try TransportHost.startMock(scenarios: ["close-after-welcome"], arguments: ["--close-style", "websocket"])
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        _ = try #require(client.authenticate(with: host))
        #expect(client.waitForEnd())
        #expect(client.events.last == .closed(.hostClosed))
    }

    @Test("Mock TLS close without a close frame: host closed", .enabled(if: TransportIntegration.mock.runnable, TransportIntegrationTests.mockSkip))
    func endOfStreamIsHostClosed() throws {
        let host = try TransportHost.startMock(scenarios: ["close-after-welcome"], arguments: ["--close-style", "tls"])
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        _ = try #require(client.authenticate(with: host))
        #expect(client.waitForEnd())
        #expect(client.events.last == .closed(.hostClosed))
    }

    @Test("Mock TCP reset: network lost", .enabled(if: TransportIntegration.mock.runnable, TransportIntegrationTests.mockSkip))
    func connectionResetIsNetworkLost() throws {
        let host = try TransportHost.startMock(scenarios: ["drop-after=0.3"])
        defer { host.stop() }
        let client = TransportLiveClient()
        defer { client.close() }
        _ = try #require(client.authenticate(with: host))
        #expect(client.waitForEnd())
        #expect(client.events.last == .closed(.networkLost))
    }
}
#endif
