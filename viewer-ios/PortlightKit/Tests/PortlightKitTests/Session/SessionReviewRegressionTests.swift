import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// Regressions from the Session review (wave 3). Each drives only API that existed before the fixes, so every
/// test here also runs against the earlier sources, where it fails (except the stale-callback test, which the
/// earlier epoch markers passed too and which fails once the stamp check is removed).
@Suite @MainActor struct SessionReviewRegressionTests {
    static func pressed(_ messages: [OutboundMessage]) -> Bool { SessionInputTests.pressed(messages) }
    static func returnKeys(_ messages: [OutboundMessage], down: Bool) -> Int {
        messages.filter { $0 == .key(keysym: 0xff0d, down: down) }.count
    }

    // MARK: Engine generations

    /// The engine drops callbacks of a retired generation, but ones it already delivered wait in the controller's
    /// inbox for the main-actor drain. A new connection started meanwhile must not apply any of them.
    @Test func callbacksWaitingInTheInboxNeverReachANewConnection() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.setColor(.gray16)
        h.settle()
        h.transport.emit(.subscribed(Fixture.subscribed(for: h.transport.subscribes.last!)))
        h.transport.emit(.error(HostErrorMessage(code: .capture, message: "Old host capture")))
        h.transport.emit(.cursor(CursorMessage(display: "fixture-2", x: 0.5, y: 0.5)))
        h.transport.emit(.closed(.networkLost))
        h.deliverWithoutApplying()
        #expect(h.controller.inbox.pendingCount >= 4)

        try h.controller.connect(profile: h.profile)
        h.settle()
        #expect(h.controller.notices.isEmpty)
        #expect(h.controller.phase == .connecting(patient: false))
        #expect(h.controller.effective == nil && !h.controller.hasRetainedFrame)
        #expect(h.controller.cursorStore.snapshot.point == nil)
        #expect(h.transports.count == 2)
        h.open(); h.welcome(); h.accept()
        #expect(h.controller.phase == .connected)
        #expect(h.controller.effective?.revision == 1)
        #expect(h.controller.notices.isEmpty)
    }

    // MARK: Input ledger and subscriptions

    /// The host applied the refused revision and the engine's paused resend, releasing held input. A mask the
    /// ledger kept would come back on the next pointer message as a phantom press.
    @Test func aBudgetRefusalLeavesNothingHeldAndNoPhantomPress() throws {
        let h = SessionHarness(preferences: ViewerPreferences(resolution: .fhd), pixelBudget: 16_588_800)
        try h.connect(); h.open(); h.welcome(); h.accept()
        h.paintAll()
        h.controller.setColor(.gray16)        // revision 2 on the wire
        h.settle()
        h.controller.toggleButtonLatch(.left) // pressed after it
        h.settle()
        #expect(h.controller.ledger.isHoldingInput)
        h.accept(size: PixelSize(width: 3840, height: 2160), resolution: .preset(.fhd))
        #expect(h.transport.subscribes.map(\.paused) == [false, false, true, false])
        #expect(!h.controller.ledger.isHoldingInput)
        #expect(h.controller.buttonLatch == nil)
        let sent = h.transport.sent
        let lastSubscribe = try #require(sent.lastIndex { if case .subscribe = $0 { return true }; return false })
        let release = try #require(sent.lastIndex { if case .pointer(_, _, _, let buttons) = $0 { return buttons.isEmpty }; return false })
        #expect(release < lastSubscribe)
        let mark = h.inputs.count
        h.drag(from: (200, 400), to: (240, 430)) // Trackpad: moves the cursor
        #expect(h.inputs.count > mark)
        #expect(!Self.pressed(Array(h.inputs[mark...])))
    }

    /// A Locked ⌘ stays down on the host between actions, and the host drops it when it processes a subscribe.
    /// The next click after a region refinement must press ⌘ again first.
    @Test func aLockedModifierIsReassertedAfterARegionRefinement() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.tapModifier(.command)
        h.controller.tapModifier(.command)
        #expect(h.controller.latches[.command] == .locked)
        h.controller.click(.left)
        h.settle()
        let before = h.subscribes.count
        for _ in 0..<16 { h.controller.zoom(in: true) }
        h.advance(0.5)
        #expect(h.subscribes.count == before + 1)
        let sent = h.transport.sent
        let subscribeAt = try #require(sent.lastIndex { if case .subscribe = $0 { return true }; return false })
        #expect(sent[subscribeAt - 1] == .key(keysym: 0xffeb, down: false)) // released just before the subscribe
        let mark = sent.count
        h.controller.click(.left)             // before `subscribed` arrives
        h.settle()
        let tail = Array(h.transport.sent[mark...])
        let downAt = tail.firstIndex(of: .key(keysym: 0xffeb, down: true))
        let pressAt = tail.firstIndex { if case .pointer(_, _, _, let buttons) = $0 { return !buttons.isEmpty }; return false }
        #expect(downAt != nil && pressAt != nil)
        if let downAt, let pressAt { #expect(downAt < pressAt) }
        #expect(h.controller.latches[.command] == .locked)
    }

    /// A press refused by the pixel gate put nothing down on the Mac, so the latch must not show as held.
    @Test func aLatchPressRefusedByThePixelGateIsNotShownAsHeld() throws {
        let h = SessionHarness()
        try h.connectToStreaming()             // nothing painted yet
        h.controller.toggleButtonLatch(.left)
        h.settle()
        #expect(h.controller.buttonLatch == nil)
        #expect(!Self.pressed(h.inputs))
        h.paintAll()
        h.controller.toggleButtonLatch(.left)
        h.settle()
        #expect(h.controller.buttonLatch == .left)
        #expect(Self.pressed(h.inputs))
    }

    // MARK: Pixels, reconnects and diagnostics

    /// Late traffic of the last computer (its answer to a pending revision and a repaint) arriving exactly when a
    /// deliberate connect clears the framebuffer must not recreate its surfaces.
    @Test func aDeliberateConnectNeverKeepsTheLastComputersLatePixels() throws {
        let framebuffer = SessionHookedFramebuffer()
        let h = SessionHarness(framebuffer: framebuffer)
        try h.connectToStreaming()
        h.controller.setColor(.gray16)
        h.settle()
        framebuffer.afterNextRemoveAll(h.lateHostTraffic())
        try h.controller.connect(profile: h.profile)
        h.settle()
        for display in Fixture.displayIDs {
            #expect(!framebuffer.hasValidPixels(display: display, x: 0.5, y: 0.5))
            #expect(framebuffer.coverage(display: display) == nil)
        }
    }

    /// A recovery that waited for held input belongs to the connection that asked for it.
    @Test func aRecoveryWaitingForTheOldConnectionIsNotReplayedAfterAReconnect() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.toggleButtonLatch(.left) // held: the recovery waits
        h.settle()
        h.emitMismatchedFrame()
        #expect(h.controller.pendingRecovery)
        h.transport.emit(.closed(.networkLost))
        h.settle()
        h.advance(1)
        h.open(); h.welcome(); h.accept()
        #expect(h.controller.phase == .connected)
        #expect(h.transport.subscribes.map(\.revision) == [1]) // no extra capture restart
    }

    /// A selection the user changes over the frozen frame while the reconnect is on its way follows revision 1.
    @Test func aSelectionChosenDuringAReconnectIsKept() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.transport.emit(.closed(.networkLost))
        h.settle()
        h.advance(1)
        h.controller.toggleDisplay("fixture-2")
        h.settle()
        h.open(); h.welcome()
        #expect(h.transport.subscribes.map(\.displays) == [Fixture.displayIDs, ["fixture-1", "fixture-3"]])
        h.accept()
        #expect(h.controller.phase == .connected)
        #expect(h.controller.selection == ["fixture-1", "fixture-3"])
        #expect(h.controller.viewport.layout["fixture-2"] == nil)
    }

    @Test func aSelectionChosenDuringAReconnectIsIntersectedWithTheNewDisplays() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.transport.emit(.closed(.networkLost))
        h.settle()
        h.advance(1)
        h.controller.setSelection(["fixture-2", "fixture-3"])
        h.settle()
        h.open()
        var oneAndTwo = Fixture.welcome
        oneAndTwo.displays = [Fixture.display(1), Fixture.display(2)]
        h.welcome(oneAndTwo)
        h.accept()
        #expect(h.controller.selection == ["fixture-2"])
        #expect(h.transport.subscribes.last?.displays == ["fixture-2"])
    }

    /// The receive rate is measured between engine samples only; the view refreshing in between doesn't skew it.
    @Test func theReceiveRateIsMeasuredBetweenEngineSamplesOnly() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.advance(0.5)                          // engine sample 1: the baseline
        let first = h.controller.diagnostics
        h.paintAll(shade: 1)
        h.advance(0.1)
        h.controller.refreshDiagnostics()       // the diagnostics view asks for fresh counters
        #expect(h.controller.diagnostics.receiveMbps == first.receiveMbps)
        #expect(h.controller.diagnostics.capturedAt > first.capturedAt)
        h.advance(0.4)                          // engine sample 2
        let second = h.controller.diagnostics
        let expected = Double(second.engine.bytesReceived - first.engine.bytesReceived) * 8 / 0.5 / 1_000_000
        #expect(expected > 0)
        #expect(abs((second.receiveMbps ?? 0) - expected) < 1e-9)
    }

    // MARK: Typed text (bounded, paced)

    @Test func aLongPasteTypesOnlyItsFirst4096Characters() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        let paste = String(repeating: "abcdefghij", count: 10_000) // 100,000 characters
        h.controller.typePastedText(paste)
        h.advanceFrames(20)
        #expect(h.typedText == String(paste.prefix(4096)))
        #expect(h.inputs.count == 205) // 20 UTF-16 units per message
    }

    /// Bounding cuts at whole characters: no half of a family emoji reaches the Mac.
    @Test func aPasteOfLongGraphemesIsCutAtAWholeCharacter() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        let family = "👨‍👩‍👧‍👦"                  // 7 scalars, 11 UTF-16 units
        h.controller.typePastedText(String(repeating: family, count: 3000))
        h.advanceFrames(60)
        let typed = h.typedText
        #expect(!typed.isEmpty)
        #expect(typed.unicodeScalars.count <= 16_384)
        #expect(typed.allSatisfy { String($0) == family })
    }

    /// One grapheme of 50,001 scalars: bounding stops after a fixed number of scalars instead of walking it all,
    /// and never types a partial character.
    @Test func aPathologicalGraphemeIsBoundedWithoutTypingAPartialCharacter() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.typePastedText("e" + String(repeating: "\u{301}", count: 50_000))
        h.advanceFrames(10)
        #expect(h.inputs.isEmpty)
    }

    /// At most one batch per engine turn, and every Return that goes down comes up in the same turn.
    @Test func aPasteIsTypedInBatchesThatNeverSplitAKeyPress() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.typePastedText(String(repeating: "a\n", count: 2000)) // 6,000 messages
        h.settle()
        #expect(h.inputs.count == 64)
        var frames = 0
        while h.inputs.count < 6000 && frames < 500 {
            h.advance(1.0 / 60)
            frames += 1
            #expect(Self.returnKeys(h.inputs, down: true) == Self.returnKeys(h.inputs, down: false))
        }
        #expect(h.inputs.count == 6000)
        #expect(frames > 80)
        #expect(h.typedText == String(repeating: "a", count: 2000))
    }

    /// Other input goes out after the rest of a paste, never into the middle of it.
    @Test func otherInputWaitsForTheRestOfAPaste() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.typePastedText(String(repeating: "a\n", count: 100)) // 300 messages
        h.settle()
        #expect(h.inputs.count < 300)
        h.controller.pressSoftKey(.escape)
        h.settle()
        #expect(h.inputs.count == 302)
        #expect(Array(h.inputs.suffix(2)) == [.key(keysym: 0xff1b, down: true), .key(keysym: 0xff1b, down: false)])
        h.advanceFrames(10)
        #expect(h.inputs.count == 302)
    }

    /// Pause and View Only stop typing in progress, leaving no key down.
    @Test func pauseAndViewOnlyStopAPasteInProgress() throws {
        for viewOnly in [false, true] {
            let h = SessionHarness()
            try h.connectToStreaming()
            h.controller.typePastedText(String(repeating: "a\n", count: 100))
            h.settle()
            let typed = h.inputs.count
            #expect(typed < 300)
            if viewOnly { h.controller.setControlEnabled(false) } else { h.controller.setPaused(true) }
            h.advanceFrames(20)
            #expect(h.inputs.count == typed)
            #expect(Self.returnKeys(h.inputs, down: true) == Self.returnKeys(h.inputs, down: false))
        }
    }

    /// A dropped connection stops typing in progress; nothing of it reaches the next connection.
    @Test func aLostConnectionStopsAPasteInProgress() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.typePastedText(String(repeating: "a\n", count: 100))
        h.settle()
        let typed = h.inputs.count
        h.transport.emit(.closed(.networkLost))
        h.settle()
        h.advance(1)
        h.open(); h.welcome(); h.accept()
        h.advanceFrames(20)
        #expect(h.inputs.count == typed)
        #expect(h.transport.inputs.isEmpty)
    }
}
