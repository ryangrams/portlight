import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// Phases, deadlines, trust, password handling (NET-03), generation isolation (NET-02) and host errors.
@Suite struct EngineConnectTests {
    @Test func phasesFollowTheConnectionInOrder() {
        let h = EngineHarness()
        h.connect()
        #expect(h.transport.endpoint == Fixture.endpoint)
        #expect(h.transport.pin == Fixture.pin)
        #expect(h.transport.generation == h.engine.currentGeneration)
        h.open()
        h.sendWelcome()
        h.accept()
        #expect(h.phases == [.connecting(patient: false), .checkingIdentity, .authenticating, .loadingDisplays, .connected])
    }

    @Test func patienceTurnsOnWithoutAnAnswer() {
        let h = EngineHarness()
        h.connect()
        h.advance(2.5)
        #expect(h.phases == [.connecting(patient: false)])
        h.advance(0.5)
        #expect(h.phases == [.connecting(patient: false), .connecting(patient: true)])
        h.transport.emit(.identityVerified(Fixture.pin))
        h.drain()
        #expect(h.phases.last == .checkingIdentity)
    }

    @Test func identityBeforePatienceKeepsItOff() {
        let h = EngineHarness()
        h.connect()
        h.advance(1)
        h.transport.emit(.identityVerified(Fixture.pin))
        h.advance(5)
        #expect(h.phases == [.connecting(patient: false), .checkingIdentity])
    }

    @Test func connectDeadlineTimesOut() { // NET-04
        let h = EngineHarness()
        h.connect()
        let stopsAtConnect = h.audio.stopCount
        h.transport.emit(.identityVerified(Fixture.pin))
        h.advance(9.5)
        #expect(h.phases.last == .checkingIdentity)
        h.advance(0.5)
        #expect(h.phases.last == .failed(.timedOut))
        #expect(h.transport.closeCount == 1)
        #expect(h.transport.hellos.isEmpty)
        #expect(h.audio.stopCount == stopsAtConnect + 1) // the timeout itself stops audio
        // A late open from the timed-out attempt sends nothing.
        h.transport.emit(.opened)
        h.drain()
        #expect(h.transport.sent.isEmpty)
        #expect(h.phases.last == .failed(.timedOut))
    }

    @Test func welcomeDeadlineStartsAtOpen() {
        let h = EngineHarness()
        h.connect()
        h.advance(5)
        h.open()
        h.advance(9.5) // t = 14.5: past the connect deadline, which the open cancelled
        #expect(h.phases.last == .authenticating)
        h.advance(0.5)
        // A stalled path after a trusted open: "didn't answer", retryable, never "update the apps".
        #expect(h.phases.last == .failed(.timedOut))
        #expect(ReconnectPolicy.standard.decision(after: .timedOut, attempt: 1, automatic: true,
                                                  elapsedSinceFirstFailure: 0, random: 0.5) != .stop)
        #expect(h.transport.closeCount == 1)
    }

    @Test func trustPromptEndsTheAttemptWithoutSendingAnything() { // NET-03
        let h = EngineHarness()
        h.connect(pin: nil)
        #expect(h.transport.pin == nil)
        h.transport.emit(.trustRequired(Fixture.trustPrompt))
        h.drain()
        #expect(h.phases == [.connecting(patient: false), .awaitingTrust(Fixture.trustPrompt)])
        h.transport.emit(.opened)
        h.advance(30)
        #expect(h.transport.sent.isEmpty)
        #expect(h.phases.last == .awaitingTrust(Fixture.trustPrompt))
        #expect(h.clock.pendingTimerCount == 0)
    }

    @Test func passwordGoesOnlyInOneHelloAfterOpen() { // NET-03
        let h = EngineHarness()
        h.connect()
        h.transport.emit(.identityVerified(Fixture.pin))
        h.drain()
        #expect(h.transport.sent.isEmpty)
        #expect(h.attemptHoldsPassword)
        h.transport.emit(.opened)
        h.transport.emit(.opened)
        h.drain()
        #expect(h.transport.hellos == [Fixture.password])
        #expect(!h.attemptHoldsPassword) // dropped the moment hello went out
        #expect(h.transport.sent.first == .hello(password: Fixture.password))
        h.sendWelcome()
        h.accept()
        h.frame(sequence: 5)
        h.drain()
        h.engine.send(input: [.text("typed secret"), .key(keysym: 0x61, down: true), .key(keysym: 0xff0d, down: true)])
        h.drain()
        #expect(h.transport.hellos.count == 1)
        let lines = h.transcript.lines
        #expect(lines.contains { $0.hasPrefix("→ hello") && $0.contains("password:<redacted>") })
        #expect(!lines.contains { $0.contains(Fixture.password) })
        #expect(!lines.contains { $0.contains("typed secret") })
        #expect(lines.contains("→ text {utf8Bytes:12}"))
        #expect(lines.contains("→ key {key:<redacted> down:true}"))
        #expect(lines.contains("→ key {key:0xff0d down:true}"))
        #expect(lines.contains { $0.hasPrefix("→ subscribe {revision:1 displays:[fixture-1,fixture-2,fixture-3]") })
        #expect(lines.contains { $0.hasPrefix("← subscribed {revision:1 canvases:[fixture-1 1280×720") })
        #expect(lines.contains("← frame {revision:1 display:fixture-1 rect:(0,0 64×32) canvas:1280×720 codec:png sequence:5 bytes:64}"))
        #expect(lines.contains("→ frameAck {sequence:5}"))
        #expect(!lines.contains { $0.contains("Portlight Test Host") })
    }

    @Test func connectRequestNeverPrintsThePassword() {
        let request = ConnectRequest(endpoint: Fixture.endpoint, pin: nil, password: Fixture.password, planner: FakePlanner())
        #expect(!String(describing: request).contains(Fixture.password))
        #expect(!String(reflecting: request).contains(Fixture.password))
        var dumped = ""
        dump(request, to: &dumped)
        #expect(!dumped.contains(Fixture.password))
    }

    @Test func openingWithoutAPinNeverSendsThePassword() { // NET-03
        let h = EngineHarness()
        h.connect(pin: nil)
        h.transport.emit(.opened) // a transport that skipped the first-use trust prompt
        h.drain()
        #expect(h.transport.sent.isEmpty)
        #expect(h.phases.last == .failed(.tlsFailed("certificate not verified")))
        #expect(h.transport.closeCount == 1)
    }

    @Test func anIdentityOtherThanThePinNeverGetsThePassword() { // NET-03
        let h = EngineHarness()
        h.connect()
        let other = CertificateFingerprint(string: String(repeating: "CD", count: 32))!
        h.transport.emit(.identityVerified(other))
        h.transport.emit(.opened)
        h.drain()
        #expect(h.transport.sent.isEmpty)
        #expect(h.phases.last == .failed(.tlsFailed("unexpected certificate")))
        #expect(!h.transcript.lines.contains { $0.contains("CD:CD") })
    }

    @Test func oldGenerationEventsHaveNoEffect() { // NET-02
        let h = EngineHarness()
        h.connectToStreaming()
        let old = h.transport
        let oldGeneration = h.engine.currentGeneration
        let sentBefore = old.sent.count
        h.connect()
        let fresh = h.transport
        #expect(fresh !== old)
        #expect(old.closeCount == 1)
        #expect(h.engine.currentGeneration > oldGeneration)
        old.emit(.subscribed(Fixture.subscribed(for: old.subscribes[0])))
        old.emit(Fixture.frame(revision: 1, sequence: 40))
        old.emit(.trustRequired(Fixture.trustPrompt))
        old.emit(.error(HostErrorMessage(code: .authentication, message: "late")))
        old.emit(.closed(.networkLost))
        // The same stale generation arriving through the new attempt's callback is ignored too.
        fresh.emit(.opened, generation: oldGeneration)
        h.drain()
        #expect(old.sent.count == sentBefore)
        #expect(fresh.sent.isEmpty)
        #expect(h.phases.last == .connecting(patient: false))
        #expect(h.framebuffer.commits.isEmpty)
    }

    @Test func oldGenerationTimersHaveNoEffect() { // NET-02
        let h = EngineHarness()
        h.connect()
        h.advance(5)
        h.connect()
        h.advance(5) // t = 10: the first attempt's deadline would fire here
        #expect(h.phases == [.connecting(patient: false), .connecting(patient: true),
                             .connecting(patient: false), .connecting(patient: true)])
        h.advance(5)
        #expect(h.phases.last == .failed(.timedOut))
        #expect(h.transports.count == 2)
        #expect(h.transports[0].closeCount == 1)
        #expect(h.transports[1].closeCount == 1)
    }

    @Test func oldGenerationDecodeCompletionNeverCommitsOrAcks() { // NET-02
        let h = EngineHarness()
        h.connectToStreaming()
        let old = h.transport
        h.decoder.hold()
        h.frame(sequence: 7)
        #expect(h.decoder.waitUntilStarted())
        h.connect(drain: false) // the decode of sequence 7 is in progress
        h.decoder.releaseAll()
        h.drain()
        #expect(h.decoder.decoded == [7])
        #expect(!old.acks.contains(7))
        #expect(h.transport.acks.isEmpty)
        #expect(h.framebuffer.commits.isEmpty)
    }

    @Test func revisionsRestartAtOneForEveryConnection() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.engine.submit(h.changedRequest())
        h.drain()
        #expect(h.transport.subscribes.map(\.revision) == [1, 2])
        h.connect()
        h.open()
        h.sendWelcome()
        #expect(h.transport.subscribes.map(\.revision) == [1])
    }

    @Test func disconnectStopsAudioClosesAndKeepsTheFrozenFrame() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.frame(sequence: 1)
        h.drain()
        let generation = h.engine.currentGeneration
        let stopsBefore = h.audio.stopCount
        h.engine.disconnect()
        h.drain()
        #expect(h.phases.last == .idle)
        #expect(h.transport.closeCount == 1)
        #expect(h.audio.stopCount == stopsBefore + 1)
        #expect(h.framebuffer.removeAllCount == 0)
        #expect(h.engine.currentGeneration > generation)
        #expect(h.clock.pendingTimerCount == 0)
        h.frame(sequence: 2)
        h.drain()
        #expect(h.transport.acks == [1])
    }

    @Test func cancelEndsAnAttemptAsCanceledAndASessionAsIdle() {
        let h = EngineHarness()
        h.connect()
        h.open()
        h.engine.cancel()
        h.drain()
        #expect(h.phases.last == .failed(.canceled))
        #expect(h.transport.closeCount == 1)

        let s = EngineHarness()
        s.connectToStreaming()
        s.engine.cancel()
        s.drain()
        #expect(s.phases.last == .idle)
    }

    @Test func fatalHostErrorsEndTheSessionWithTheirOwnReason() {
        let cases: [(HostErrorCode, String, ConnectionFailure)] = [
            (.authentication, "Incorrect password or incompatible protocol",
             .authenticationRejected("Incorrect password or incompatible protocol")),
            (.busy, "Another viewer is connected. Disconnect it before connecting here.",
             .busy("Another viewer is connected. Disconnect it before connecting here.")),
            (.timeout, "Viewer stopped acknowledging image updates", .hostTimeout("Viewer stopped acknowledging image updates")),
        ]
        for (code, message, failure) in cases {
            let h = EngineHarness()
            h.connect()
            h.open()
            if code == .timeout { h.sendWelcome(); h.accept() }
            h.transport.emit(.error(HostErrorMessage(code: code, message: message)))
            h.drain()
            #expect(h.phases.last == .failed(failure))
            #expect(h.transport.closeCount == 1)
            // The host's close right after its error doesn't overwrite the specific reason.
            h.transport.emit(.closed(.hostClosed))
            h.drain()
            #expect(h.phases.last == .failed(failure))
        }
    }

    @Test func otherHostErrorsAreReportedAndNonFatal() {
        let h = EngineHarness()
        h.connectToStreaming()
        let codes: [HostErrorCode] = [.topology, .capture, .subscription, .message, .other("future")]
        for code in codes { h.transport.emit(.error(HostErrorMessage(code: code, message: "detail"))) }
        h.drain()
        #expect(h.delegate.hostReports.map(\.code) == codes)
        #expect(h.phases.last == .connected)
        #expect(h.transport.closeCount == 0)
    }

    @Test func transportCloseFailsWithItsReason() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.transport.emit(.closed(.networkLost))
        h.drain()
        #expect(h.phases.last == .failed(.networkLost))
        #expect(h.transport.closeCount == 0)
        #expect(h.clock.pendingTimerCount == 0)
    }
}
