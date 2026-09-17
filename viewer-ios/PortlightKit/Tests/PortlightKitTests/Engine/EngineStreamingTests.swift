import Testing
@testable import PortlightKit

/// Input gating and ordering, the heartbeat (ping cadence, read deadline, RTT), audio pass-through,
/// cursor/stats forwarding, diagnostics and configuration defaults.
@Suite struct EngineStreamingTests {
    private let move = OutboundMessage.pointer(display: "fixture-1", x: 0.5, y: 0.5, buttons: [])

    @Test func inputIsDroppedUntilStreaming() {
        let h = EngineHarness()
        h.connect()
        h.open()
        h.sendWelcome() // loading displays: not streaming yet
        h.engine.send(input: [move])
        h.drain()
        #expect(h.transport.inputs.isEmpty)
        #expect(h.diagnostics.inputMessagesDropped == 1)
        h.accept()
        h.engine.send(input: [move, .frameAck(sequence: 3)]) // only input may use this path
        h.drain()
        #expect(h.transport.inputs == [move])
        #expect(!h.transport.acks.contains(3))
        #expect(h.diagnostics.inputMessagesSent == 1)
        #expect(h.diagnostics.inputMessagesDropped == 2)
        h.engine.disconnect()
        h.drain()
        h.engine.send(input: [move])
        h.drain()
        #expect(h.transport.inputs == [move])
    }

    @Test func inputKeepsItsOrderRelativeToSubmits() {
        let h = EngineHarness()
        h.connectToStreaming()
        let down = OutboundMessage.key(keysym: 0xffe3, down: true)
        let up = OutboundMessage.key(keysym: 0xffe3, down: false)
        let changed = h.changedRequest()
        h.engine.send(input: [down])
        h.engine.submit(changed)
        h.engine.send(input: [up])
        h.drain()
        let tail = Array(h.transport.sent.suffix(3))
        #expect(tail.count == 3)
        #expect(tail.first == down)
        guard tail.count == 3, case .subscribe(let request) = tail[1] else {
            Issue.record("expected key down, subscribe, key up; got \(tail)"); return
        }
        #expect(request.revision == 2)
        #expect(tail[2] == up)
    }

    @Test func pingCadenceAndRoundTrip() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.advanceKeepingAlive(seconds: 1)
        #expect(h.transport.pings.isEmpty)
        h.advanceKeepingAlive(seconds: 1)
        #expect(h.transport.pings == [2])
        h.advanceKeepingAlive(seconds: 8)
        #expect(h.transport.pings == [2, 4, 6, 8, 10])
        h.clock.advance(by: 0.25)
        h.transport.emit(.pong(time: 10))
        h.drain()
        #expect(h.diagnostics.lastRTTMilliseconds == 250)
        #expect(h.phases.last == .connected)
    }

    @Test func silenceBeyondTheReadDeadlineIsNetworkLost() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.advance(5.5)
        #expect(h.phases.last == .connected)
        #expect(h.transport.pings == [2, 4])
        h.advance(0.5)
        #expect(h.phases.last == .failed(.networkLost))
        #expect(h.transport.closeCount == 1)
        #expect(h.clock.pendingTimerCount == 0)
    }

    @Test func inboundTrafficKeepsTheSessionAlive() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.advanceKeepingAlive(seconds: 30)
        #expect(h.phases.last == .connected)
        h.advance(5.5) // the last inbound message was at t = 30
        #expect(h.phases.last == .connected)
        h.advance(0.5)
        #expect(h.phases.last == .failed(.networkLost))
    }

    @Test func readDeadlineAlsoGuardsLoadingDisplays() {
        let h = EngineHarness()
        h.connect()
        h.open()
        h.sendWelcome()
        h.advance(6)
        #expect(h.phases.last == .failed(.networkLost))
    }

    @Test func audioPassesThroughWithoutAcks() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.transport.emit(Fixture.audio(revision: 1, sequence: 3))
        h.drain()
        #expect(h.audio.submitted.map(\.sequence) == [3])
        #expect(h.transport.acks.isEmpty)
        #expect(h.diagnostics.audioPackets == 1)
        #expect(h.diagnostics.binaryMessages == 1)
        let old = h.transport
        let stops = h.audio.stopCount
        h.connect()
        #expect(h.audio.stopCount == stops + 1)
        old.emit(Fixture.audio(revision: 1, sequence: 4))
        h.drain()
        #expect(h.audio.submitted.map(\.sequence) == [3])
    }

    @Test func cursorStatsAndIgnoredMessages() {
        let h = EngineHarness()
        h.connectToStreaming()
        let cursor = CursorMessage(display: "fixture-2", x: 0.25, y: 0.75)
        let stats = StatsMessage(bytesSent: 1000, fps: 24, streamingDisplays: Fixture.displayIDs, pendingImageBytes: 4096, inFlightFrames: 3)
        h.transport.emit(.cursor(cursor))
        h.transport.emit(.stats(stats))
        h.transport.emit(.ignored(type: "future"))
        h.drain()
        #expect(h.delegate.events.contains(.cursor(cursor)))
        #expect(h.delegate.events.contains(.stats(stats)))
        let d = h.diagnostics
        #expect(d.hostFPS == 24)
        #expect(d.hostInFlightFrames == 3)
        #expect(d.hostPendingImageBytes == 4096)
        #expect(d.ignoredMessages == 1)
        #expect(d.textMessages == 5) // welcome, subscribed, cursor, stats, ignored
        #expect(h.transcript.lines.contains("← future {ignored}"))
    }

    @Test func diagnosticsArePublishedPeriodically() {
        let h = EngineHarness()
        h.connectToStreaming()
        let before = h.delegate.diagnostics.count
        h.advance(0.5)
        #expect(h.delegate.diagnostics.count == before + 1)
        h.advance(1)
        #expect(h.delegate.diagnostics.count == before + 3)
        #expect(h.delegate.diagnostics.last?.generation == h.engine.currentGeneration)
        #expect(h.delegate.diagnostics.last?.subscriptionsSent == 1)
    }

    @Test func configurationDefaultsMatchTheHandoff() {
        let c = EngineConfiguration()
        #expect(c.connectDeadline == 10)
        #expect(c.patienceDelay == 3)
        #expect(c.welcomeDeadline == 10)
        #expect(c.pingInterval == 2)
        #expect(c.readDeadline == 6)
        #expect(c.maxDecodeJobs == 48)
        #expect(c.maxDecodeBytes == 64 * 1024 * 1024)
        #expect(c.recoveryLimit == 3)
        #expect(c.recoveryWindow == 10)
        #expect(c.diagnosticsInterval == 0.5)
        #expect(c.maxTotalCanvasPixels == 33_177_600)
        #expect(c.maxCanvasSide == 7680)
    }
}
