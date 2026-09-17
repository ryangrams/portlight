import Testing
@testable import PortlightKit

/// RENDER-02 ACK accounting, the bounded decode path and image-failure recovery.
@Suite struct EngineFrameTests {
    @Test func everyFrameIsAcknowledgedExactlyOnce() { // RENDER-02
        let h = EngineHarness()
        h.connectToStreaming()
        h.decoder.failSequences = [7]
        h.frame(sequence: 1)                                                    // committed
        h.frame(display: "fixture-2", sequence: 2)                              // committed
        h.frame(revision: 0, sequence: 3)                                       // stale
        h.frame(revision: 5, sequence: 4)                                       // unexpected
        h.frame(display: "unknown", sequence: 5)                                // rejected: display
        h.frame(sequence: 6, canvas: PixelSize(width: 1920, height: 1080))      // rejected: canvas
        h.frame(sequence: 7)                                                    // rejected: decoder
        h.frame(sequence: 8, rect: PixelRect(x: 1250, y: 0, width: 64, height: 32)) // rejected: outside canvas
        h.drain()
        #expect(h.transport.acks.sorted() == Array(1...8))
        #expect(h.decoder.decoded == [1, 2, 7])
        #expect(h.framebuffer.commits.map(\.sequence) == [1, 2])
        let d = h.diagnostics
        #expect(d.framesReceived == 8)
        #expect(d.framesDecoded == 2)
        #expect(d.framesCommitted == 2)
        #expect(d.framesStale == 1)
        #expect(d.framesUnexpected == 1)
        #expect(d.framesRejected == 4)
        #expect(d.acksSent == 8)
        #expect(d.decodeJobsInFlight == 0)
        #expect(d.decodeBytesInFlight == 0)
        #expect(d.bytesReceived == 8 * 64)
        #expect(h.delegate.recoveries.count == 1)
    }

    @Test func oldRevisionFramesAreAckedImmediatelyAndNeverDecoded() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.engine.submit(h.changedRequest())
        h.drain()
        h.accept(revision: 2)
        h.decoder.hold() // a decode would block, so an ACK now proves none was needed
        h.frame(revision: 1, sequence: 20)
        h.frame(revision: 1, sequence: 21)
        h.syncEngine()
        #expect(h.transport.acks == [20, 21])
        #expect(h.decoder.decoded.isEmpty)
        #expect(h.diagnostics.framesStale == 2)
        h.decoder.releaseAll()
    }

    @Test func commitHappensBeforeItsAckInArrivalOrder() throws {
        let h = EngineHarness()
        h.connectToStreaming()
        for sequence in 1...20 { h.frame(display: Fixture.displayIDs[sequence % 3], sequence: sequence) }
        h.drain()
        let entries = h.log.entries
        for sequence in 1...20 {
            let commit = try #require(entries.firstIndex(of: .commit(revision: 1, sequence: sequence)))
            let ack = try #require(entries.firstIndex(of: .sent(transport: 1, .frameAck(sequence: sequence))))
            #expect(commit < ack)
        }
        #expect(h.framebuffer.commits.map(\.sequence) == Array(1...20))
        #expect(h.transport.acks == Array(1...20))
    }

    @Test func staleResultForACurrentPatchIsALocalLossAndRecovers() {
        let h = EngineHarness()
        h.connectToStreaming()
        // Nothing replaced revision 1, so "stale" means the framebuffer lost it (e.g. no texture for the canvas).
        h.framebuffer.staleSequences = [9]
        h.frame(sequence: 9)
        h.frame(sequence: 10)
        h.drain()
        #expect(h.transport.acks == [9, 10])
        #expect(h.framebuffer.committed == [10])
        #expect(h.diagnostics.framesRejected == 1)
        #expect(h.diagnostics.framesStale == 0)
        #expect(h.diagnostics.framesCommitted == 1)
        #expect(h.diagnostics.framesDecoded == 2)
        #expect(h.delegate.recoveries == ["framebuffer discarded a current patch"])
    }

    @Test func staleResultAfterANewerRevisionIsAckedWithoutRecovery() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.engine.submit(h.changedRequest())
        h.drain()
        h.decoder.hold()
        h.frame(sequence: 9) // current when it arrives
        #expect(h.decoder.waitUntilStarted())
        h.transport.emit(.subscribed(Fixture.subscribed(for: h.transport.subscribes[1]))) // revision 2 lands mid-decode
        h.decoder.releaseAll()
        h.drain()
        #expect(h.framebuffer.accepted.map(\.revision) == [1, 2])
        #expect(h.framebuffer.committed.isEmpty)
        #expect(h.transport.acks == [9])
        #expect(h.diagnostics.framesStale == 1)
        #expect(h.diagnostics.framesRejected == 0)
        #expect(h.delegate.recoveries.isEmpty)
    }

    @Test func failedCommitIsAckedAndRecovered() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.framebuffer.failedSequences = [4]
        h.frame(sequence: 4)
        h.frame(sequence: 5)
        h.drain()
        #expect(h.transport.acks == [4, 5])
        #expect(h.framebuffer.committed == [5])
        #expect(h.diagnostics.framesRejected == 1)
        #expect(h.diagnostics.framesCommitted == 1)
        #expect(h.delegate.recoveries == ["framebuffer could not commit the patch"])
    }

    @Test func pendingDecodesHoldTheirAcksUntilCommitted() {
        let h = EngineHarness(configuration: EngineConfiguration(maxDecodeJobs: 4))
        h.connectToStreaming()
        h.decoder.hold()
        for sequence in 1...4 { h.frame(sequence: sequence) }
        #expect(h.decoder.waitUntilStarted())
        h.syncEngine()
        #expect(h.transport.acks.isEmpty)
        #expect(h.phases.last == .connected)
        #expect(h.diagnostics.decodeJobsInFlight == 4)
        #expect(h.diagnostics.decodeBytesInFlight == 256)
        h.decoder.releaseAll()
        h.drain()
        #expect(h.transport.acks == [1, 2, 3, 4])
        #expect(h.diagnostics.decodeJobsInFlight == 0)
        #expect(h.diagnostics.decodeJobsPeak == 4)
        #expect(h.diagnostics.decodeBytesPeak == 256)
    }

    @Test func decodeJobBacklogFailsTheSession() {
        let h = EngineHarness(configuration: EngineConfiguration(maxDecodeJobs: 4))
        h.connectToStreaming()
        h.decoder.hold()
        for sequence in 1...5 { h.frame(sequence: sequence) }
        h.syncEngine()
        #expect(h.phases.last == .failed(.protocolViolation("decoder backlog")))
        #expect(h.transport.closeCount == 1)
        h.decoder.releaseAll()
        h.drain()
        // The queued jobs were abandoned with their attempt: nothing lands, nothing is ACKed.
        #expect(h.framebuffer.commits.isEmpty)
        #expect(h.transport.acks.isEmpty)
    }

    @Test func decodeByteBacklogFailsTheSession() {
        let h = EngineHarness(configuration: EngineConfiguration(maxDecodeBytes: 1000))
        h.connectToStreaming()
        h.decoder.hold()
        h.frame(sequence: 1, bytes: 600)
        h.syncEngine()
        #expect(h.phases.last == .connected)
        h.frame(sequence: 2, bytes: 600)
        h.syncEngine()
        #expect(h.phases.last == .failed(.protocolViolation("decoder backlog")))
        h.decoder.releaseAll()
        h.drain()
    }

    @Test func imageFailuresRequestOneRecoveryPerBurst() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.decoder.failSequences = [1, 2]
        h.frame(sequence: 1)
        h.drain()
        h.frame(sequence: 2)
        h.drain()
        h.frame(display: "unknown", sequence: 3)
        h.drain()
        #expect(h.delegate.recoveries == ["image decode failed"])
        #expect(h.transport.acks == [1, 2, 3])
        #expect(h.diagnostics.recoveries == 1)
        // The controller's forced resubmission closes the burst once accepted.
        h.engine.submit(h.transport.subscribes[0], force: true)
        h.drain()
        h.accept(revision: 2)
        h.frame(revision: 2, display: "unknown", sequence: 4)
        h.drain()
        #expect(h.delegate.recoveries == ["image decode failed", "frame doesn't match the accepted canvas"])
    }

    @Test func missingPatchBufferIsRejectedWithRecovery() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.framebuffer.failAllocation = true
        h.frame(sequence: 1)
        h.drain()
        #expect(h.transport.acks == [1])
        #expect(h.framebuffer.commits.isEmpty)
        #expect(h.delegate.recoveries == ["patch buffer unavailable"])
        #expect(h.diagnostics.framesRejected == 1)
    }

    @Test func decodedPatchThatDoesntMatchItsHeaderIsRejected() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.decoder.mode = .shortStride
        h.frame(sequence: 1)
        h.drain()
        #expect(h.transport.acks == [1])
        #expect(h.framebuffer.commits.isEmpty)
        #expect(h.delegate.recoveries == ["decoded patch doesn't match its header"])
    }

    /// Three bursts, each closed by an accepted forced resubmission.
    private func runThreeBursts(_ h: EngineHarness) {
        for burst in 1...3 {
            h.frame(revision: burst, display: "unknown", sequence: burst * 10)
            h.drain()
            #expect(h.delegate.recoveries.count == burst)
            h.engine.submit(h.transport.subscribes[0], force: true)
            h.drain()
            h.accept()
        }
    }

    @Test func repeatedFailureBurstsFailTheSession() {
        let h = EngineHarness()
        h.connectToStreaming()
        runThreeBursts(h)
        h.frame(revision: 4, display: "unknown", sequence: 40)
        h.drain()
        #expect(h.phases.last == .failed(.protocolViolation("repeated image failures")))
        #expect(h.delegate.recoveries.count == 3)
        #expect(h.transport.acks.contains(40))
    }

    @Test func recoveryLimitWindowSlides() {
        let h = EngineHarness()
        h.connectToStreaming()
        runThreeBursts(h)
        h.advanceKeepingAlive(seconds: 10)
        h.frame(revision: 4, display: "unknown", sequence: 40)
        h.drain()
        #expect(h.phases.last == .connected)
        #expect(h.delegate.recoveries.count == 4)
    }

    @Test func unresolvedBurstReopensAfterTheWindow() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.frame(display: "unknown", sequence: 1)
        h.drain()
        h.advanceKeepingAlive(seconds: 5)
        h.frame(display: "unknown", sequence: 2)
        h.drain()
        #expect(h.delegate.recoveries.count == 1)
        h.advanceKeepingAlive(seconds: 5)
        h.frame(display: "unknown", sequence: 3)
        h.drain()
        #expect(h.delegate.recoveries.count == 2)
    }

    @Test func lastPatchAgeTracksTheNewestCommit() {
        let h = EngineHarness()
        h.connectToStreaming()
        #expect(h.diagnostics.lastPatchAge == nil)
        h.frame(sequence: 1)
        h.drain()
        h.advanceKeepingAlive(seconds: 2)
        #expect(h.diagnostics.lastPatchAge == 2)
    }
}
