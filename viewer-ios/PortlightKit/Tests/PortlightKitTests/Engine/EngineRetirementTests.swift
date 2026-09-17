import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// NET-02 at call time: `connect`, `disconnect` and `cancel` retire the old generation before they return.
/// Callbacks it already queued are never delivered, a commit or `subscribed` still in flight never reaches the
/// framebuffer, a new generation always publishes its phase, and a released engine commits nothing more.
@Suite struct EngineRetirementTests {
    private func topologyWithoutLastDisplay() -> WelcomeMessage {
        var changed = Fixture.welcome
        changed.displays.removeLast()
        return changed
    }

    @Test func callbacksQueuedBeforeDisconnectAreNeverDelivered() {
        let h = EngineHarness()
        h.connectToStreaming()
        let resume = h.parkDelegateQueue()
        h.transport.emit(.cursor(CursorMessage(display: "fixture-1", x: 0.5, y: 0.5)))
        h.transport.emit(.displays(topologyWithoutLastDisplay()))
        h.transport.emit(.stats(StatsMessage(fps: 3)))
        let before = h.delegate.events.count
        h.engine.disconnect() // the controller's call, while those callbacks still wait in its queue
        resume()
        h.drain()
        #expect(Array(h.delegate.events.dropFirst(before)) == [.phase(.idle)])
    }

    @Test func callbacksQueuedBeforeAReconnectAreNeverDelivered() {
        let h = EngineHarness()
        h.connectToStreaming()
        let resume = h.parkDelegateQueue()
        h.transport.emit(.displays(topologyWithoutLastDisplay()))
        h.frame(display: "unknown", sequence: 3) // asks for a recovery subscription
        let before = h.delegate.events.count
        h.engine.connect(h.request())
        resume()
        h.drain()
        // Neither the old host's topology nor its recovery request can steer the new connection.
        #expect(Array(h.delegate.events.dropFirst(before)) == [.phase(.connecting(patient: false))])
    }

    @Test func noCommitLandsOnceDisconnectReturns() {
        let h = EngineHarness()
        h.connectToStreaming()
        let old = h.transport
        h.decoder.hold()
        h.frame(sequence: 7)
        #expect(h.decoder.waitUntilStarted())
        let resumeEngine = h.parkEngineQueue()
        h.engine.disconnect() // its work is queued behind the parked engine queue
        h.decoder.releaseAll()
        h.syncDecode() // the decode of 7 finishes before the engine queue gets to the disconnect
        #expect(h.framebuffer.commits.isEmpty)
        resumeEngine()
        h.drain()
        #expect(old.acks.isEmpty)
        #expect(h.phases.last == .idle)
    }

    @Test func noRevisionReachesTheFramebufferOnceDisconnectReturns() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.engine.submit(h.changedRequest())
        h.drain()
        let ack = Fixture.subscribed(for: h.transport.subscribes[1])
        let resumeEngine = h.parkEngineQueue()
        h.transport.emitAsync(.message(.subscribed(ack))) // already on its way when the user disconnects
        h.engine.disconnect()
        h.framebuffer.removeAll() // the controller clears the picture right after disconnecting
        resumeEngine()
        h.drain()
        #expect(h.framebuffer.accepted.map(\.revision) == [1])
        #expect(h.delegate.accepted.map(\.revision) == [1])
        #expect(h.phases.last == .idle)
    }

    @Test func aNewGenerationAlwaysPublishesItsPhase() {
        let h = EngineHarness()
        h.connectToStreaming()
        // The first reconnect's `.connecting` is still queued when a second reconnect retires it.
        let resume = h.parkDelegateQueue()
        h.engine.connect(h.request())
        h.syncEngineQueue()
        h.engine.connect(h.request())
        h.syncEngineQueue()
        resume()
        h.drain()
        #expect(h.phases.last == .connecting(patient: false))
        // Likewise two disconnects: the second `.idle` still reaches the delegate.
        let resumeAgain = h.parkDelegateQueue()
        h.engine.disconnect()
        h.syncEngineQueue()
        h.engine.disconnect()
        h.syncEngineQueue()
        resumeAgain()
        h.drain()
        #expect(h.phases.last == .idle)
    }

    @Test func aConnectRetiredBeforeItStartsNeverOpensASocket() {
        let h = EngineHarness()
        h.connectToStreaming()
        let resumeEngine = h.parkEngineQueue()
        h.engine.connect(h.request(password: "first attempt"))
        h.engine.connect(h.request(password: "second attempt"))
        resumeEngine()
        h.drain()
        #expect(h.transports.count == 2)
        #expect(h.transport.generation == h.engine.currentGeneration)
        h.open()
        #expect(h.transport.hellos == ["second attempt"])
        #expect(h.phases.last == .authenticating)
    }

    @Test func releasingTheEngineStopsQueuedCommits() {
        let h = EngineHarness()
        var engine: SessionEngine? = h.makeDetachedEngine()
        engine?.connect(h.request())
        engine?.drainForTesting()
        let transport = h.transport
        transport.emit(.identityVerified(Fixture.pin))
        transport.emit(.opened)
        transport.emit(.welcome(Fixture.welcome))
        transport.emit(.subscribed(Fixture.subscribed(for: transport.subscribes[0])))
        let flushDecode = h.decodeFlusher(for: engine!)
        h.decoder.hold()
        transport.emit(Fixture.frame(revision: 1, sequence: 9))
        #expect(h.decoder.waitUntilStarted())
        let released = EngineWeakProbe(engine)
        engine = nil // the app drops its engine while a decode is still running
        #expect(released.object == nil)
        h.decoder.releaseAll()
        flushDecode()
        #expect(h.framebuffer.commits.isEmpty)
    }
}
