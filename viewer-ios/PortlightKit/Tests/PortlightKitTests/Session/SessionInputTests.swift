import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// Input routing and gating: View Only and Pause silence (VIEW-02), mode switches, pixel gating, keys and text.
@Suite @MainActor struct SessionInputTests {
    static func pressed(_ messages: [OutboundMessage]) -> Bool {
        messages.contains { if case .pointer(_, _, _, let buttons) = $0 { return !buttons.isEmpty }; return false }
    }

    /// Every kind of input the session surface and accessory can produce.
    static func exerciseEveryInput(_ h: SessionHarness) {
        let (x, y) = h.viewCenter(of: "fixture-2")
        h.tap(x, y)
        h.touch(.began([TouchPoint(id: 1, x: x, y: y), TouchPoint(id: 2, x: x + 40, y: y)]))
        for step in 1...6 { h.touch(.moved([TouchPoint(id: 1, x: x, y: y + Double(step) * 8), TouchPoint(id: 2, x: x + 40, y: y + Double(step) * 8)])) }
        h.touch(.ended([TouchPoint(id: 1, x: x, y: y + 48), TouchPoint(id: 2, x: x + 40, y: y + 48)]))
        h.drag(from: (x, y), to: (x - 30, y + 20))
        h.controller.click(.right)
        h.controller.toggleButtonLatch(.left)
        h.controller.toggleButtonLatch(.left)
        h.controller.tapModifier(.shift)
        h.controller.press(hidUsage: 0x04, characters: "a", down: true)
        h.controller.press(hidUsage: 0x04, characters: "a", down: false)
        h.controller.pressSoftKey(.escape)
        h.controller.insertText("héllo")
        h.controller.deleteBackward()
        h.controller.typePastedText("pasted")
        h.settle()
    }

    @Test func viewOnlySendsZeroInputButKeepsLocalNavigation() throws { // VIEW-02
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.setControlEnabled(false)
        h.settle()
        #expect(h.transport.subscribes.last?.viewOnly == true)
        h.accept()
        let before = h.inputs.count
        Self.exerciseEveryInput(h)
        #expect(h.inputs.count == before)
        // Local navigation stays live: a pinch zooms and a drag pans, still without any input.
        let fitted = h.transformBits
        h.pinch(at: 195, 420, from: 80, to: 200)
        let zoomed = h.transformBits
        h.drag(from: (200, 400), to: (140, 360))
        #expect(fitted != zoomed && zoomed != h.transformBits)
        #expect(h.inputs.count == before)
        h.controller.setControlEnabled(true)
        h.settle()
        h.accept()
        let (x, y) = h.viewCenter(of: "fixture-2")
        h.tap(x, y)
        #expect(Self.pressed(Array(h.inputs[before...])))
    }

    @Test func pauseSendsPausedWithoutAudioAndResumeRestoresIt() throws { // VIEW-02
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.setAudioEnabled(true)
        h.settle()
        #expect(h.transport.subscribes.last?.audio == true)
        #expect(h.transport.subscribes.last?.audioCodec == .aac)
        #expect(h.audioControl.isEnabled)
        h.accept(audio: true, audioCodec: .aac)
        #expect(h.controller.audioState == .playing)

        h.controller.setPaused(true)
        h.settle()
        let paused = try #require(h.transport.subscribes.last)
        #expect(paused.paused && !paused.audio)
        #expect(h.controller.settings.audioEnabled)
        #expect(!h.audioControl.isEnabled)
        #expect(h.controller.audioState == .off)
        #expect(h.controller.transformStore.snapshot.dimmed)
        h.accept()
        let before = h.inputs.count
        Self.exerciseEveryInput(h)
        #expect(h.inputs.count == before)

        h.controller.setPaused(false)
        h.settle()
        let resumed = try #require(h.transport.subscribes.last)
        #expect(!resumed.paused && resumed.audio && resumed.audioCodec == .aac)
        #expect(h.audioControl.isEnabled)
        #expect(!h.controller.transformStore.snapshot.dimmed)
    }

    @Test func aModeSwitchReleasesInputAndClearsLatches() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.tapModifier(.command)
        h.controller.tapModifier(.option)
        h.controller.tapModifier(.option) // double tap: locked
        #expect(h.controller.latches[.command] == .latched && h.controller.latches[.option] == .locked)
        h.controller.toggleButtonLatch(.left)
        h.settle()
        #expect(h.controller.buttonLatch == .left)
        let subscribes = h.subscribes.count
        let mark = h.transport.sent.count
        h.controller.setInputMode(.direct)
        h.settle()
        #expect(Array(h.transport.sent[mark...]) == [
            .pointer(display: "fixture-1", x: 0, y: 0, buttons: []),
            .key(keysym: 0xffeb, down: false),
            .key(keysym: 0xffe9, down: false),
        ])
        #expect(h.controller.latches.values.allSatisfy { $0 == .off })
        #expect(h.controller.buttonLatch == nil)
        #expect(h.controller.settings.inputMode == .direct)
        #expect(h.subscribes.count == subscribes) // the mode is not on the wire
    }

    /// INPUT-03: with Hold Left, a locked ⌥ and a hardware "a" all held, Pause, View Only and Disconnect each put
    /// every release on the wire (before the subscription that carries the change) and press nothing again.
    @Test(arguments: ["pause", "viewOnly", "disconnect"])
    func heldInputIsReleasedOnTheWire(_ action: String) throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.toggleButtonLatch(.left)
        h.controller.tapModifier(.option)
        h.controller.tapModifier(.option) // double tap: locked
        h.controller.press(hidUsage: 0x04, characters: "a", down: true)
        h.settle()
        #expect(h.controller.buttonLatch == .left)
        let mark = h.transport.sent.count
        switch action {
        case "pause": h.controller.setPaused(true)
        case "viewOnly": h.controller.setControlEnabled(false)
        default: h.controller.disconnect()
        }
        h.settle()
        let wire = Array(h.transport.sent[mark...])
        let releases = Array(wire.prefix { if case .subscribe = $0 { return false }; return true })
        #expect(releases.contains(.pointer(display: "fixture-1", x: 0, y: 0, buttons: [])), "\(wire)")
        #expect(releases.contains(.key(keysym: 0x61, down: false)), "\(wire)")
        #expect(releases.contains(.key(keysym: 0xffe9, down: false)), "\(wire)")
        let pressedAgain = wire.contains { message in
            switch message {
            case .pointer(_, _, _, let buttons): return !buttons.isEmpty
            case .key(_, let down): return down
            default: return false
            }
        }
        #expect(!pressedAgain, "\(wire)")
        #expect(h.controller.buttonLatch == nil)
        guard action != "disconnect" else { return }
        guard case .subscribe(let request)? = wire.dropFirst(releases.count).first else {
            Issue.record("the releases should be followed by the subscription: \(wire)")
            return
        }
        #expect(action == "pause" ? request.paused : request.viewOnly)
    }

    @Test func pressesAndScrollsWaitForValidPixels() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        let (x, y) = h.viewCenter(of: "fixture-1")
        h.tap(x, y)
        #expect(!Self.pressed(h.inputs))
        #expect(h.inputs.contains { if case .pointer(_, _, _, let buttons) = $0 { return buttons.isEmpty }; return false })
        h.controller.refreshDiagnostics()
        #expect(h.controller.diagnostics.inputBlocked > 0)
        h.paintAll()
        h.tap(x, y)
        #expect(Self.pressed(h.inputs))
    }

    @Test func textKeysAndChordsTakeTheirOwnPaths() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.insertText("héllo")
        h.controller.deleteBackward()
        h.controller.pressSoftKey(.escape)
        h.controller.tapModifier(.command)
        h.controller.insertText("c")
        h.controller.typePastedText("a\nb")
        h.settle()
        #expect(h.inputs == [
            .text("héllo"),
            .key(keysym: 0xff08, down: true), .key(keysym: 0xff08, down: false),
            .key(keysym: 0xff1b, down: true), .key(keysym: 0xff1b, down: false),
            .key(keysym: 0xffeb, down: true), .key(keysym: 0x63, down: true), .key(keysym: 0x63, down: false),
            .key(keysym: 0xffeb, down: false),
            .text("a"), .key(keysym: 0xff0d, down: true), .key(keysym: 0xff0d, down: false), .text("b"),
        ])
        #expect(h.controller.latches[.command] == .off) // consumed by the chord
    }

    @Test func hardwareChordsUseKeysymsAndALostModifierReleaseIsRepaired() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.press(hidUsage: 0xE3, characters: "", down: true)                        // left ⌘ down
        h.controller.press(hidUsage: 0x06, characters: "c", modifiers: [.command], down: true)
        h.controller.press(hidUsage: 0x06, characters: "c", modifiers: [.command], down: false)
        h.controller.press(hidUsage: 0xE3, characters: "", down: false)
        h.settle()
        #expect(h.inputs == [.key(keysym: 0xffeb, down: true), .key(keysym: 0x63, down: true),
                             .key(keysym: 0x63, down: false), .key(keysym: 0xffeb, down: false)])
        // ⌘ goes down, its key-up never arrives, and the next key's flags say no modifiers: release first.
        h.controller.press(hidUsage: 0xE3, characters: "", down: true)
        h.controller.press(hidUsage: 0x04, characters: "a", modifiers: [], down: true)
        h.controller.press(hidUsage: 0x04, characters: "a", modifiers: [], down: false)
        h.settle()
        #expect(Array(h.inputs.dropFirst(4)) == [.key(keysym: 0xffeb, down: true), .key(keysym: 0xffeb, down: false),
                                                 .key(keysym: 0x61, down: true), .key(keysym: 0x61, down: false)])
        #expect(!h.controller.ledger.isHoldingInput)
    }

    /// The host releases input when it *processes* a subscribe (Server.swift `applySubscription`, messages handled in
    /// arrival order), not when the phone reads `subscribed`. A button or key pressed after the subscribe went out
    /// is therefore still held when `subscribed` arrives, and its release must still reach the Mac.
    @Test func inputPressedAfterASubscribeStaysHeldUntilReleased() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.setColor(.gray16)   // revision 2 on the wire, with nothing held
        h.settle()
        h.controller.toggleButtonLatch(.left)
        h.controller.press(hidUsage: 0x04, characters: "a", down: true)
        h.settle()
        h.accept()                       // the host applied revision 2 before these presses: it still holds both
        #expect(h.controller.ledger.isHoldingInput)
        #expect(h.controller.buttonLatch == .left)
        let mark = h.inputs.count
        h.controller.press(hidUsage: 0x04, characters: "a", down: false)
        h.controller.toggleButtonLatch(.left)
        h.settle()
        let tail = Array(h.inputs[mark...])
        #expect(tail.count == 2)
        #expect(tail.first == .key(keysym: 0x61, down: false))
        #expect({ if case .pointer(_, _, _, let buttons)? = tail.last { return buttons.isEmpty }; return false }())
        #expect(!h.controller.ledger.isHoldingInput && h.controller.buttonLatch == nil)
        h.controller.releaseInput()
        h.settle()
        #expect(h.inputs.count == mark + 2) // nothing is replayed or double-released
    }

    @Test func hostCursorReportsMoveTheLocalCursor() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.transport.emit(.cursor(CursorMessage(display: "fixture-2", x: 0.5, y: 0.25)))
        h.settle()
        #expect(h.controller.cursorStore.visiblePoint == LogicalPoint(x: 1920 + 960, y: 270))
        h.controller.setInputMode(.pan)
        #expect(h.controller.cursorStore.visiblePoint == nil)
    }

    @Test func hiddenControlsRevealOnTapWithoutClicking() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.setControlsHidden(true)
        let before = h.inputs.count
        let (x, y) = h.viewCenter(of: "fixture-1")
        h.tap(x, y)
        #expect(!h.controller.controlsHidden)
        #expect(h.inputs.count == before)
    }
}
