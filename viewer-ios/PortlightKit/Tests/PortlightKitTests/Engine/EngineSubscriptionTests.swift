import Testing
@testable import PortlightKit

/// DISP-01, dedupe/force, `subscribed` validation, the canvas budget, rejected subscriptions and topology.
@Suite struct EngineSubscriptionTests {
    private func sentRevisions(_ h: EngineHarness) -> [Int] {
        h.delegate.events.compactMap { event -> Int? in
            if case .sent(let request) = event { return request.revision }
            return nil
        }
    }

    @Test func firstSubscribeIsRevisionOneWithAllDisplaysInTheWelcomeTurn() { // DISP-01
        let h = EngineHarness()
        h.connect()
        h.open()
        h.transport.emit(.welcome(Fixture.welcome)) // one engine turn, nothing drained afterwards
        let first = h.transport.subscribes
        #expect(first.count == 1)
        #expect(first.first?.revision == 1)
        #expect(first.first?.displays == Fixture.displayIDs)
        h.drain()
        #expect(Array(h.delegate.events.suffix(3)) == [
            .phase(.loadingDisplays), .welcome(Fixture.welcome, topologyChange: false), .sent(first[0]),
        ])
    }

    @Test func reconnectHandsThePreviousSelectionToThePlanner() {
        let h = EngineHarness()
        h.connect(previousSelection: ["fixture-3", "gone"])
        h.open()
        h.sendWelcome()
        #expect(h.transport.subscribes.map(\.displays) == [["fixture-3"]])
    }

    @Test func submitBeforeWelcomeIsDropped() {
        let h = EngineHarness()
        h.connect()
        h.open()
        h.engine.submit(SubscriptionRequest(revision: 0, displays: ["fixture-1"], resolution: .hd, color: .full, quality: .automatic), force: true)
        h.drain()
        #expect(h.transport.subscribes.isEmpty)
        h.sendWelcome()
        #expect(h.transport.subscribes.map(\.revision) == [1])
        #expect(h.transport.subscribes[0].displays == Fixture.displayIDs)
    }

    @Test func equivalentStateIsDedupedUnlessForced() {
        let h = EngineHarness()
        h.connectToStreaming()
        var same = h.transport.subscribes[0]
        same.revision = 42
        h.engine.submit(same)
        h.drain()
        #expect(h.transport.subscribes.count == 1)
        h.engine.submit(same, force: true)
        h.drain()
        #expect(h.transport.subscribes.map(\.revision) == [1, 2])
        let changed = h.changedRequest()
        h.engine.submit(changed)
        h.drain()
        #expect(h.transport.subscribes.map(\.revision) == [1, 2, 3])
        #expect(h.transport.subscribes[2].resolution == .fhd)
        // Full regions count as omitted.
        var fullRegions = changed
        fullRegions.regions = ["fixture-1": .full]
        h.engine.submit(fullRegions)
        h.drain()
        #expect(h.transport.subscribes.count == 3)
        #expect(h.diagnostics.subscriptionsSent == 3)
        #expect(sentRevisions(h) == [1, 2, 3])
    }

    @Test func acceptanceReachesFramebufferAudioAndDelegate() {
        let h = EngineHarness()
        h.connect()
        h.open()
        h.sendWelcome()
        let request = h.transport.subscribes[0]
        h.accept()
        let canvases: [DisplayID: PixelSize] = ["fixture-1": Fixture.hd, "fixture-2": Fixture.hd, "fixture-3": Fixture.hd]
        #expect(h.framebuffer.accepted == [.init(revision: 1, canvases: canvases, regions: request.regions)])
        #expect(h.audio.acks == [.init(configuration: nil, revision: 1)])
        #expect(h.delegate.accepted.map(\.revision) == [1])
        #expect(h.phases.last == .connected)
        // Audio on: codec and bitrate come from the ack, falling back to the request.
        h.engine.submit(h.changedRequest { $0.audio = true; $0.audioBitrate = .stereo160 })
        h.drain()
        h.accept(audio: true, audioCodec: .mulaw, audioBitrate: 192000)
        h.engine.submit(h.changedRequest { $0.resolution = .qhd })
        h.drain()
        h.accept(audio: true)
        #expect(h.audio.acks.map(\.configuration) == [nil, AudioConfiguration(codec: .mulaw, bitrate: 192000),
                                                       AudioConfiguration(codec: .aac, bitrate: 160000)])
        #expect(h.audio.acks.map(\.revision) == [1, 2, 3])
    }

    @Test func acceptRevisionPrecedesEveryCommitOfThatRevision() throws {
        let h = EngineHarness()
        h.connectToStreaming()
        h.frame(sequence: 1)
        h.frame(display: "fixture-2", sequence: 2)
        h.drain()
        h.engine.submit(h.changedRequest())
        h.drain()
        h.accept()
        h.frame(revision: 2, sequence: 3)
        h.drain()
        let entries = h.log.entries
        let accept1 = try #require(entries.firstIndex(of: .accept(revision: 1)))
        let commit1 = try #require(entries.firstIndex(of: .commit(revision: 1, sequence: 1)))
        let accept2 = try #require(entries.firstIndex(of: .accept(revision: 2)))
        let commit3 = try #require(entries.firstIndex(of: .commit(revision: 2, sequence: 3)))
        #expect(accept1 < commit1)
        #expect(accept2 < commit3)
        #expect(h.framebuffer.commits.map(\.sequence) == [1, 2, 3])
    }

    @Test func rejectedSubscriptionKeepsCommittingTheAcceptedRevision() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.engine.submit(h.changedRequest())
        h.drain()
        h.transport.emit(.error(HostErrorMessage(code: .subscription,
                                                 message: "Invalid displays, revision, resolution, color, quality, frame rate or bandwidth")))
        h.frame(sequence: 10)
        h.frame(sequence: 11)
        h.drain()
        #expect(h.framebuffer.commits.map(\.sequence) == [10, 11])
        #expect(h.transport.acks == [10, 11])
        #expect(h.diagnostics.framesCommitted == 2)
        #expect(h.phases.last == .connected)
        #expect(h.delegate.hostReports.map(\.code) == [.subscription])
        // Resending the rejected state unchanged is deduped (it would be rejected again).
        h.engine.submit(h.changedRequest { _ in })
        h.drain()
        #expect(h.transport.subscribes.count == 2)
    }

    @Test func acksForUnknownRevisionsAreIgnored() {
        let h = EngineHarness()
        h.connectToStreaming()
        var bogus = h.transport.subscribes[0]
        bogus.revision = 7
        h.transport.emit(.subscribed(Fixture.subscribed(for: bogus)))
        // A duplicate ack for the already answered revision 1 is unknown as well.
        h.transport.emit(.subscribed(Fixture.subscribed(for: h.transport.subscribes[0])))
        h.drain()
        #expect(h.framebuffer.accepted.count == 1)
        #expect(h.diagnostics.subscriptionAcksIgnored == 2)
        #expect(h.phases.last == .connected)
    }

    @Test func answeringANewerRevisionDropsOlderOutstandingOnes() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.engine.submit(h.changedRequest { $0.resolution = .fhd })
        h.engine.submit(h.changedRequest { $0.resolution = .qhd })
        h.drain()
        h.accept(revision: 3)
        h.accept(revision: 2) // late answer for a superseded revision
        #expect(h.framebuffer.accepted.map(\.revision) == [1, 3])
        #expect(h.diagnostics.subscriptionAcksIgnored == 1)
    }

    @Test func canvasesThatDontMatchTheRequestAreAProtocolViolation() {
        let hd = Fixture.hd
        let variants: [[SubscribedMessage.Canvas]] = [
            [.init(display: "fixture-1", size: hd), .init(display: "fixture-2", size: hd)],
            [.init(display: "fixture-1", size: hd), .init(display: "fixture-2", size: hd), .init(display: "fixture-3", size: hd),
             .init(display: "fixture-4", size: hd)],
            [.init(display: "fixture-1", size: hd), .init(display: "fixture-1", size: hd), .init(display: "fixture-3", size: hd)],
            [.init(display: "fixture-1", size: PixelSize(width: 0, height: 720)), .init(display: "fixture-2", size: hd),
             .init(display: "fixture-3", size: hd)],
            [.init(display: "fixture-1", size: PixelSize(width: 7681, height: 16)), .init(display: "fixture-2", size: hd),
             .init(display: "fixture-3", size: hd)],
        ]
        for canvases in variants {
            let h = EngineHarness()
            h.connect()
            h.open()
            h.sendWelcome()
            h.transport.emit(.subscribed(SubscribedMessage(revision: 1, canvases: canvases, paused: false, audio: false,
                                                           audioCodec: nil, audioBitrate: nil, resolution: .preset(.hd), notice: nil)))
            h.drain()
            guard case .failed(.protocolViolation) = h.phases.last else {
                Issue.record("expected a protocol violation for \(canvases)"); continue
            }
            #expect(h.framebuffer.accepted.isEmpty)
            #expect(h.transport.closeCount == 1)
        }
    }

    @Test func largestAllowedCanvasIsAccepted() {
        let h = EngineHarness()
        h.connect(previousSelection: ["fixture-1"])
        h.open()
        h.sendWelcome()
        h.accept(size: PixelSize(width: 7680, height: 4320)) // exactly the aggregate budget
        #expect(h.framebuffer.accepted.map(\.revision) == [1])
        #expect(h.phases.last == .connected)
    }

    @Test func canvasBudgetOverflowPausesWithoutAllocating() throws {
        let h = EngineHarness()
        h.connect()
        h.open()
        h.sendWelcome()
        let request = h.transport.subscribes[0]
        let big = PixelSize(width: 3840, height: 3840) // 3 × 14.7 M pixels > 33.2 M
        let ack = h.accept(size: big)
        #expect(h.delegate.budgetExceeded == [ack])
        #expect(h.framebuffer.accepted.isEmpty)
        let resend = try #require(h.transport.subscribes.last)
        var expected = request
        expected.revision = 2
        expected.paused = true
        #expect(resend == expected)
        #expect(h.phases.last == .loadingDisplays)
        // Frames of the refused revision are ACKed as unexpected and never decoded.
        h.frame(sequence: 1, canvas: big)
        h.drain()
        #expect(h.transport.acks == [1])
        #expect(h.decoder.decoded.isEmpty)
        #expect(h.diagnostics.framesUnexpected == 1)
        // The paused resend is over budget too: it goes live without allocating, and without a loop.
        h.accept(revision: 2, size: big)
        #expect(h.framebuffer.accepted.isEmpty)
        #expect(h.delegate.budgetExceeded.count == 1)
        #expect(h.delegate.accepted.map(\.revision) == [2])
        // The refused revision was applied by the host, so its audio configuration is acknowledged too.
        #expect(h.audio.acks.map(\.revision) == [1, 2])
        #expect(h.transport.subscribes.count == 2)
        #expect(h.phases.last == .connected)
        // A request within budget then allocates normally.
        h.engine.submit(h.changedRequest { $0.paused = false })
        h.drain()
        h.accept(revision: 3)
        #expect(h.framebuffer.accepted.map(\.revision) == [3])
    }

    @Test func refusedRevisionStillAcknowledgesItsAudio() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.engine.submit(h.changedRequest { $0.resolution = .uhd; $0.audio = true })
        h.drain()
        let big = PixelSize(width: 3840, height: 3840)
        h.accept(revision: 2, size: big, audio: true, audioCodec: .aac, audioBitrate: 96000)
        #expect(h.delegate.budgetExceeded.map(\.revision) == [2])
        let aac = AudioConfiguration(codec: .aac, bitrate: 96000)
        #expect(h.audio.acks == [.init(configuration: nil, revision: 1), .init(configuration: aac, revision: 2)])
        // With the real epoch gate, revision 2's audio plays instead of being dropped until the paused resend lands.
        var gate = AudioEpochGate()
        for ack in h.audio.acks { gate.acknowledged(ack.configuration, revision: ack.revision) }
        guard case .audio(let header, _) = Fixture.audio(revision: 2, sequence: 30) else { Issue.record("expected audio"); return }
        #expect(gate.accept(header))
        h.accept(revision: 3, size: big, audio: true, audioCodec: .aac, audioBitrate: 96000)
        #expect(h.audio.acks.map(\.revision) == [1, 2, 3])
        #expect(h.delegate.budgetExceeded.count == 1)
    }

    @Test func refusedSubscriptionsDontAccumulate() {
        let h = EngineHarness()
        h.connectToStreaming()
        for step in 0..<100 {
            h.engine.submit(h.changedRequest { $0.bandwidthKbps = 1000 + step })
            h.transport.emit(.error(HostErrorMessage(code: .subscription, message: "Invalid visible region")))
        }
        h.drain()
        #expect(h.outstandingRevisions.isEmpty)
        #expect(h.delegate.hostReports.count == 100)
        // A later revision the host accepts still goes live.
        h.engine.submit(h.changedRequest { $0.resolution = .fhd })
        h.drain()
        h.accept()
        #expect(h.framebuffer.accepted.map(\.revision) == [1, 102])
    }

    @Test func unansweredSubscriptionsAreBounded() {
        let h = EngineHarness()
        h.connectToStreaming()
        for step in 0..<40 {
            h.engine.submit(h.changedRequest { $0.bandwidthKbps = 1000 + step })
            h.syncEngine()
        }
        #expect(h.outstandingRevisions == Array(10...41))
        h.accept() // the newest still goes live
        #expect(h.framebuffer.accepted.map(\.revision) == [1, 41])
        #expect(h.outstandingRevisions.isEmpty)
    }

    @Test func topologyChangeReportsAndResetsTheDedupeBaseline() {
        let h = EngineHarness()
        h.connectToStreaming()
        var changed = Fixture.welcome
        changed.displays.removeLast()
        h.transport.emit(.displays(changed))
        h.transport.emit(.error(HostErrorMessage(code: .topology, message: "Displays changed. Select displays again.")))
        h.drain()
        #expect(h.delegate.events.contains(.welcome(changed, topologyChange: true)))
        #expect(h.delegate.hostReports.map(\.code) == [.topology])
        #expect(h.phases.last == .connected)
        // The host dropped its subscription, so even an unchanged state must go out, at a higher revision.
        let same = h.transport.subscribes[0]
        h.engine.submit(same)
        h.drain()
        #expect(h.transport.subscribes.map(\.revision) == [1, 2])
        h.engine.submit(same)
        h.drain()
        #expect(h.transport.subscribes.count == 2)
    }

    @Test func unexpectedWelcomeDisplaysOrVersionAreProtocolViolations() {
        let h = EngineHarness()
        h.connectToStreaming()
        h.transport.emit(.welcome(Fixture.welcome))
        h.drain()
        #expect(h.phases.last == .failed(.protocolViolation("unexpected welcome")))

        let d = EngineHarness()
        d.connect()
        d.open()
        d.transport.emit(.displays(Fixture.welcome))
        d.drain()
        #expect(d.phases.last == .failed(.protocolViolation("displays before welcome")))

        let v = EngineHarness()
        v.connect()
        v.open()
        var future = Fixture.welcome
        future.version = 2
        v.transport.emit(.welcome(future))
        v.drain()
        #expect(v.phases.last == .failed(.protocolViolation("unsupported protocol version 2")))
        #expect(v.transport.subscribes.isEmpty)
    }
}
