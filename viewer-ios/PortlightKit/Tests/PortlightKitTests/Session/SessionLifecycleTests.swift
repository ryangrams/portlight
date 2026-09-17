import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// Background/foreground (LIFE-01 automated part) and automatic reconnect rules.
@Suite @MainActor struct SessionLifecycleTests {
    static let changedPrompt = TrustPrompt(endpoint: Fixture.endpoint,
                                           fingerprint: CertificateFingerprint(string: String(repeating: "CD", count: 32))!,
                                           previousFingerprint: Fixture.pin)

    static func pressed(_ messages: ArraySlice<OutboundMessage>) -> Bool {
        messages.contains { if case .pointer(_, _, _, let buttons) = $0 { return !buttons.isEmpty }; return false }
    }

    @Test func backgroundThenForegroundRestoresTheSelectionMinusMissingDisplays() throws { // LIFE-01 (automated)
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.toggleDisplay("fixture-2")
        h.settle()
        h.accept()
        h.paintAll()
        h.controller.toggleButtonLatch(.left)
        h.settle()
        #expect(h.controller.wantsIdleTimerDisabled)
        let first = h.transport
        let mark = first.sent.count

        h.controller.scenePhaseChanged(.background)
        h.settle()
        #expect(Array(first.sent[mark...]).first == .pointer(display: "fixture-1", x: 0, y: 0, buttons: []))
        #expect(first.closeCount >= 1)
        #expect(h.controller.phase == .reconnecting(attempt: 0, after: .networkLost))
        #expect(h.controller.isShowingFrozenFrame)
        #expect(h.controller.transformStore.snapshot.dimmed)
        #expect(!h.controller.wantsIdleTimerDisabled)
        #expect(!h.audioControl.isEnabled)
        #expect((h.framebuffer as! SoftwareFramebuffer).snapshot(display: "fixture-1") != nil) // textures kept
        h.advance(30)
        #expect(h.transports.count == 1) // no retries in the background

        h.controller.scenePhaseChanged(.active)
        h.settle()
        #expect(h.transports.count == 2)
        #expect(h.controller.phase == .reconnecting(attempt: 1, after: .networkLost))
        let inputsBefore = h.inputs.count
        let (x, y) = h.viewCenter(of: "fixture-1")
        h.tap(x, y) // the frozen frame is never controllable
        #expect(h.inputs.count == inputsBefore)
        h.open()
        var onlyOneAndTwo = Fixture.welcome
        onlyOneAndTwo.displays = [Fixture.display(1), Fixture.display(2)]
        h.welcome(onlyOneAndTwo)
        #expect(h.transport.subscribes.first?.displays == ["fixture-1"]) // [1, 3] ∩ [1, 2]
        h.accept()
        #expect(h.controller.phase == .connected)
        #expect(h.controller.selection == ["fixture-1"])
        // Connected, but the retained pixels belong to the old connection: presses wait for fresh ones.
        let (x1, y1) = h.viewCenter(of: "fixture-1")
        h.tap(x1, y1)
        #expect(!Self.pressed(h.inputs[inputsBefore...]))
        h.paintAll()
        h.tap(x1, y1)
        #expect(Self.pressed(h.inputs[inputsBefore...]))
    }

    @Test func inactiveReleasesHeldInputAndKeepsTheSession() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.toggleButtonLatch(.left)
        h.settle()
        let mark = h.transport.sent.count
        h.controller.scenePhaseChanged(.inactive)
        h.settle()
        #expect(Array(h.transport.sent[mark...]) == [.pointer(display: "fixture-1", x: 0, y: 0, buttons: [])])
        #expect(h.controller.phase == .connected)
    }

    @Test func aChangedCertificateStopsAutomaticReconnect() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.transport.emit(.closed(.networkLost))
        h.settle()
        #expect(h.controller.phase == .reconnecting(attempt: 1, after: .networkLost))
        h.advance(1)
        #expect(h.transports.count == 2)
        #expect(h.transport.pin == Fixture.pin)
        h.transport.emit(.trustRequired(Self.changedPrompt))
        h.settle()
        #expect(h.controller.phase == .awaitingTrust(Self.changedPrompt))
        h.advance(60)
        #expect(h.transports.count == 2)
        #expect(h.transport.hellos.isEmpty)
        #expect(h.controller.phase == .awaitingTrust(Self.changedPrompt))
    }

    @Test func aCertificateChangedFailureAlsoStopsAndShowsTrust() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.transport.emit(.closed(.networkLost))
        h.settle()
        h.advance(1)
        h.transport.emit(.closed(.certificateChanged(Self.changedPrompt)))
        h.settle()
        h.advance(60)
        #expect(h.controller.phase == .awaitingTrust(Self.changedPrompt))
        #expect(h.transports.count == 2)
        h.controller.approveTrust(Self.changedPrompt)
        h.settle()
        #expect(h.transports.count == 3)
        #expect(h.transport.pin == Self.changedPrompt.fingerprint)
        #expect(h.trust.pinnedFingerprint(for: Fixture.endpoint) == Self.changedPrompt.fingerprint)
    }

    @Test func busyDuringAnAutomaticReconnectIsRetriedOnlyInsideItsWindow() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.transport.emit(.closed(.networkLost)) // t = 0: first failure
        h.settle()
        h.advance(0.2)                           // the first retry (0.125 s) starts
        #expect(h.transports.count == 2)
        for _ in 0..<10 {
            let count = h.transports.count
            h.open()
            h.transport.emit(.error(HostErrorMessage(code: .busy, message: "")))
            h.settle()
            if case .reconnecting = h.controller.phase {} else { break }
            h.advance(2)
            #expect(h.transports.count == count + 1)
        }
        h.open()
        h.transport.emit(.error(HostErrorMessage(code: .busy, message: "")))
        h.settle()
        // Busy at 0.2, 2.2 … 18.2 s is retried; at 20.2 s the 20 s window is over.
        #expect(h.transports.count == 12)
        #expect(h.controller.phase == .failed(.busy("")))
        h.advance(30)
        #expect(h.transports.count == 12)
    }

    @Test func networkLossFollowsTheLadderAndStops() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.transport.emit(.closed(.networkLost))
        h.settle()
        var attempts: [Int] = []
        for _ in 0..<8 {
            if case .reconnecting(let attempt, _) = h.controller.phase { attempts.append(attempt) } else { break }
            h.advance(10)
            h.transport.emit(.closed(.refused))
            h.settle()
        }
        #expect(attempts == [1, 2, 3, 4, 5, 6])
        #expect(h.transports.count == 7)
        #expect(h.controller.phase == .failed(.refused))
        #expect(h.controller.retry())
        h.settle()
        #expect(h.transports.count == 8)
        #expect(h.transport.hellos.isEmpty)
        h.open()
        #expect(h.transport.hellos == [Fixture.password])
    }

    @Test func aReconnectRestoresTheSelectionAndKeepsTheZoom() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.setSelection(["fixture-2", "fixture-3"])
        h.settle()
        h.accept()
        h.controller.setInputMode(.pan)
        h.pinch(at: 195, 420, from: 100, to: 220)
        let zoomed = h.transformBits
        h.transport.emit(.closed(.networkLost))
        h.settle()
        h.advance(1)
        h.open(); h.welcome()
        #expect(h.transport.subscribes.first?.displays == ["fixture-2", "fixture-3"])
        h.accept()
        #expect(h.controller.phase == .connected)
        #expect(h.transformBits == zoomed)
    }
}
