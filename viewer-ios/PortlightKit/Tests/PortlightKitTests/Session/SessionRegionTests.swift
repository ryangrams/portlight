import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// Region refinement (REGION-01 input-state part): only after a 150 ms settle, never while touches are down
/// or input is held, never while paused; hidden selected displays get explicit zero regions.
@Suite @MainActor struct SessionRegionTests {
    /// Zooms 10× into display 1 in Pan mode (displays 2 and 3 end up entirely off screen, margin included)
    /// and returns with the fingers lifted, the last viewport change 8 ms ago.
    static func zoomIntoDisplayOne(_ h: SessionHarness) {
        h.controller.setInputMode(.pan)
        let (x, y) = h.viewCenter(of: "fixture-1")
        h.pinch(at: x, y, from: 40, to: 400)
    }

    @Test func refinementWaitsForTheSettleAndZeroesHiddenDisplays() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        let before = h.subscribes.count
        Self.zoomIntoDisplayOne(h)
        #expect(h.subscribes.count == before)
        h.advance(0.13) // 138 ms after the last viewport change
        #expect(h.subscribes.count == before)
        h.advance(0.02) // 158 ms
        #expect(h.subscribes.count == before + 1)
        let refined = try #require(h.subscribes.last)
        #expect(refined.displays == Fixture.displayIDs)
        #expect(refined.regions["fixture-2"] == .zero)
        #expect(refined.regions["fixture-3"] == .zero)
        let one = try #require(refined.regions["fixture-1"])
        #expect(one.isValid && !one.isFull && !one.isZero)

        h.accept()
        h.paintAll()
        h.controller.tick(at: h.clock.now())
        h.controller.refreshDiagnostics()
        #expect(h.controller.diagnostics.regions.refinementsSent == 1)
        #expect(h.controller.diagnostics.regions.lastTimeToFreshRegion != nil)
        #expect(h.controller.diagnostics.regions.subscriptionsLastMinute == 2)

        // A small pan stays inside the planned margin: no capture restart.
        h.drag(from: (200, 400), to: (196, 398), steps: 2)
        h.advance(0.5)
        #expect(h.subscribes.count == before + 1)
    }

    @Test func refinementNeverHappensWhileInputIsHeld() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.toggleButtonLatch(.left) // Trackpad: left button held on the Mac
        h.settle()
        let before = h.subscribes.count
        for _ in 0..<16 { h.controller.zoom(in: true) }
        h.advance(0.5)
        h.advance(2)
        #expect(h.subscribes.count == before)
        h.controller.refreshDiagnostics()
        #expect(h.controller.diagnostics.regions.deferrals == 1)
        let mark = h.transport.sent.count
        h.controller.toggleButtonLatch(.left) // release: the deferred refinement goes out right after
        h.settle()
        let tail = Array(h.transport.sent[mark...])
        #expect(tail.first == .pointer(display: "fixture-1", x: 0, y: 0, buttons: []))
        #expect(tail.contains { if case .subscribe(let request) = $0 { return !request.regions.isEmpty }; return false })
        #expect(h.subscribes.count == before + 1)
    }

    @Test func refinementWaitsForFingersToLift() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        Self.zoomIntoDisplayOne(h)
        let before = h.subscribes.count
        // A finger stays down (pan in progress) well past the settle time.
        h.touch(.began([TouchPoint(id: 1, x: 200, y: 400)]))
        h.touch(.moved([TouchPoint(id: 1, x: 170, y: 380)]))
        h.advance(1)
        #expect(h.subscribes.count == before)
        h.touch(.ended([TouchPoint(id: 1, x: 170, y: 380)]))
        #expect(h.subscribes.count == before + 1)
    }

    @Test func pausedSessionsRefineOnlyAfterResume() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.setPaused(true)
        h.settle()
        h.accept()
        let before = h.subscribes.count
        Self.zoomIntoDisplayOne(h)
        h.advance(1)
        #expect(h.subscribes.count == before) // local zoom still works; nothing is requested
        #expect(!h.controller.isFit)
        h.controller.setPaused(false)
        h.settle()
        #expect(h.subscribes.count == before + 1)
        #expect(h.subscribes.last?.regions.isEmpty == true) // resume first, with the current regions
        h.accept()
        h.advance(0.2)
        #expect(h.subscribes.count == before + 2)
        #expect(h.subscribes.last?.regions["fixture-3"] == .zero)
    }

    @Test func selectionChangesResetRegionsToFull() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        Self.zoomIntoDisplayOne(h)
        h.advance(0.2)
        h.accept()
        #expect(h.subscribes.last?.regions.isEmpty == false)
        h.controller.toggleDisplay("fixture-3")
        h.settle()
        let request = try #require(h.subscribes.last)
        #expect(request.displays == ["fixture-1", "fixture-2"])
        #expect(request.regions.isEmpty)
    }
}
