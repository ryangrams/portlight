import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// Display selection, topology changes, resolution and the canvas budget.
@Suite @MainActor struct SessionSelectionTests {
    static func isSubscribe(_ message: OutboundMessage) -> Bool {
        if case .subscribe = message { return true }
        return false
    }

    @Test func aDisplayToggleSendsReleasesBeforeTheSubscribe() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.toggleButtonLatch(.left)          // Trackpad: left held at the cursor
        h.controller.tapModifier(.command)             // latched ⌘
        h.controller.press(hidUsage: 0x04, characters: "a", down: true) // ⌘ + a held
        h.settle()
        #expect(h.controller.buttonLatch == .left)
        let mark = h.transport.sent.count
        h.controller.toggleDisplay("fixture-2")
        h.settle()
        let tail = Array(h.transport.sent[mark...])
        let subscribeAt = try #require(tail.firstIndex(where: Self.isSubscribe))
        #expect(Array(tail[..<subscribeAt]) == [
            .pointer(display: "fixture-1", x: 0, y: 0, buttons: []),
            .key(keysym: 0x61, down: false),
            .key(keysym: 0xffeb, down: false),
        ])
        #expect(h.transport.subscribes.last?.displays == ["fixture-1", "fixture-3"])
        #expect(h.controller.selection == ["fixture-1", "fixture-3"])
        #expect(h.controller.buttonLatch == nil)
        // Compact layout: 1 and 3 become adjacent in the viewer.
        #expect(h.controller.viewport.layout["fixture-3"]?.x == 1920)
        #expect(h.controller.isFit)
    }

    @Test func selectionOrderIsTheHostsAndUnknownIDsAreIgnored() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.setSelection(["fixture-3", "nope", "fixture-1", "fixture-3"])
        h.settle()
        #expect(h.controller.selection == ["fixture-1", "fixture-3"])
        h.controller.selectAll()
        h.settle()
        #expect(h.transport.subscribes.last?.displays == Fixture.displayIDs)
    }

    @Test func noneIsAValidEmptySelectionWithoutInput() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.selectNone()
        h.settle()
        #expect(h.transport.subscribes.last?.displays == [])
        h.accept()
        #expect(h.controller.phase == .connected)
        #expect(!h.controller.allowsRemoteInput)
        #expect(!h.controller.viewport.isReady)
        let before = h.inputs.count
        h.tap(195, 400)
        h.controller.pressSoftKey(.escape)
        h.controller.insertText("x")
        #expect(h.inputs.count == before)
    }

    @Test func topologyChangeIntersectsTheSelectionAndHandlesTheEmptyCase() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.toggleButtonLatch(.left)
        h.settle()
        let mark = h.transport.sent.count
        var two = Fixture.welcome
        two.displays = [Fixture.display(1), Fixture.display(2)]
        h.transport.emit(.displays(two))
        h.settle()
        let tail = Array(h.transport.sent[mark...])
        let subscribeAt = try #require(tail.firstIndex(where: Self.isSubscribe))
        #expect(tail[..<subscribeAt].contains(.pointer(display: "fixture-1", x: 0, y: 0, buttons: [])))
        #expect(h.controller.selection == ["fixture-1", "fixture-2"])
        #expect(h.transport.subscribes.last?.displays == ["fixture-1", "fixture-2"])
        #expect(h.controller.notices.contains(.displaysChanged))
        #expect(h.controller.buttonLatch == nil)
        h.accept()

        // Only display 2 selected, then a topology without it: the selection becomes empty, never another display.
        h.controller.setSelection(["fixture-2"])
        h.settle()
        h.accept()
        var onlyOneAndThree = Fixture.welcome
        onlyOneAndThree.displays = [Fixture.display(1), Fixture.display(3)]
        h.transport.emit(.displays(onlyOneAndThree))
        h.settle()
        #expect(h.controller.selection.isEmpty)
        #expect(h.transport.subscribes.last?.displays == [])
        #expect(h.controller.displays.map(\.id) == ["fixture-1", "fixture-3"])
        h.accept()
        let before = h.inputs.count
        h.tap(195, 400)
        #expect(h.inputs.count == before)
    }

    @Test func resolutionOnlyChangesNeverTouchTheViewport() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.controller.setInputMode(.pan)
        h.pinch(at: 195, 420, from: 100, to: 260)
        h.drag(from: (200, 400), to: (150, 380))
        #expect(!h.controller.isFit)
        let before = h.transformBits
        h.controller.setResolution(.fhd)
        h.settle()
        #expect(h.transport.subscribes.last?.resolution == .fhd)
        h.accept(size: PixelSize(width: 1920, height: 1080))
        h.paintAll()
        #expect(h.transformBits == before)
        #expect(!h.controller.isFit)
        #expect(h.controller.effective?.canvases["fixture-1"] == PixelSize(width: 1920, height: 1080))
    }

    @Test func overBudgetCanvasesLowerTheResolutionWhenThatFits() throws {
        let h = SessionHarness(preferences: ViewerPreferences(resolution: .fhd), pixelBudget: 16_588_800)
        try h.connect(); h.open(); h.welcome()
        #expect(h.transport.subscribes.first?.resolution == .fhd)
        // The host answers with canvases far above the prediction (e.g. its native rule).
        h.accept(size: PixelSize(width: 3840, height: 2160), resolution: .preset(.fhd))
        #expect(h.transport.subscribes.map(\.paused) == [false, true, false])
        #expect(h.transport.subscribes.last?.resolution == .hd)
        #expect(h.transport.subscribes.last?.displays == Fixture.displayIDs) // never fewer displays
        #expect(h.controller.notices.contains { if case .resolutionLimited = $0 { return true }; return false })
        #expect(!h.controller.displayBudgetExceeded)
        #expect(h.controller.settings.resolution == .fhd) // the desire stays; only the request is capped
    }

    @Test func overBudgetCanvasesAtHDAskForFewerDisplays() throws {
        let h = SessionHarness(pixelBudget: 8_294_400)
        try h.connect(); h.open(); h.welcome()
        #expect(h.transport.subscribes.first?.resolution == .hd)
        h.accept(size: PixelSize(width: 3840, height: 2160), resolution: .native)
        #expect(h.transport.subscribes.count == 2) // only the engine's paused resend
        #expect(h.transport.subscribes.last?.paused == true)
        #expect(h.controller.displayBudgetExceeded)
        #expect(h.controller.selection == Fixture.displayIDs)
        h.controller.setSelection(["fixture-1"])
        h.settle()
        #expect(!h.controller.displayBudgetExceeded)
        #expect(h.transport.subscribes.last?.displays == ["fixture-1"])
        #expect(h.transport.subscribes.last?.paused == false)
    }

    @Test func presetAvailabilityExplainsDisplayAndMemoryLimits() throws {
        let h = SessionHarness(pixelBudget: 8_294_400)
        try h.connect(); h.open(); h.welcome()
        let all = Dictionary(uniqueKeysWithValues: h.controller.presetAvailability.map { ($0.preset, $0) })
        #expect(all[.hd]?.isAvailable == true)
        #expect(all[.fhd]?.isAvailable == false)
        #expect(all[.fhd]?.reason?.contains("memory") == true)
        #expect(all[.qhd]?.isAvailable == false)
        #expect(all[.qhd]?.reason == "Test Display 2 is smaller than QHD.")
        h.accept()
        h.controller.setSelection(["fixture-1"])
        h.settle()
        let one = Dictionary(uniqueKeysWithValues: h.controller.presetAvailability.map { ($0.preset, $0) })
        #expect(one[.qhd]?.isAvailable == true)
        #expect(one[.uhd]?.isAvailable == false)
    }
}
