import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// Connect, trust, credentials and explicit endings (DISP-01 unit, NET-01/NET-03 controller parts).
@Suite @MainActor struct SessionConnectionTests {
    @Test func freshConnectSelectsAllDisplaysAtRevisionOneAndFits() throws { // DISP-01 (unit)
        let h = SessionHarness()
        try h.connect()
        #expect(h.controller.phase == .connecting(patient: false))
        #expect(h.transport.pin == Fixture.pin)
        h.open()
        #expect(h.controller.phase == .authenticating)
        #expect(h.transport.hellos == [Fixture.password])
        h.welcome()
        #expect(h.controller.phase == .loadingDisplays)
        let first = try #require(h.transport.subscribes.first)
        #expect(first.revision == 1)
        #expect(first.displays == Fixture.displayIDs)
        #expect(first.resolution == .hd && first.color == .full && first.quality == .automatic && first.fps == 60)
        #expect(!first.paused && !first.audio && !first.viewOnly && !first.dither && first.regions.isEmpty)
        #expect(h.controller.selection == Fixture.displayIDs)
        #expect(h.controller.displays.map(\.id) == Fixture.displayIDs)
        h.accept()
        #expect(h.controller.phase == .connected)
        #expect(h.controller.effective?.revision == 1)
        #expect(h.controller.effective?.canvases.count == 3)
        #expect(h.controller.isFit)
        #expect(Set(h.controller.viewport.layout.keys) == Set(Fixture.displayIDs))
        #expect(h.controller.serverName == "Portlight Test Host")
        #expect(h.controller.wantsIdleTimerDisabled)
        #expect(h.subscribes.count == 1)
    }

    @Test func freshConnectAppliesProfilePreferencesButNeverStartsInPan() throws {
        let preferences = ViewerPreferences(resolution: .fhd, color: .color256, quality: .video, inputMode: .pan,
                                            audioQuality: .mono48, bandwidthKbps: 5000, smoothGradients: true)
        let h = SessionHarness(preferences: preferences)
        try h.connect()
        h.open(); h.welcome()
        let first = try #require(h.transport.subscribes.first)
        #expect(first.resolution == .fhd && first.color == .color256 && first.quality == .video)
        #expect(first.bandwidthKbps == 5000 && first.audioBitrate == .mono48 && first.dither)
        #expect(h.controller.settings.inputMode == .trackpad)
        #expect(!h.controller.settings.audioEnabled && !h.controller.settings.paused && h.controller.settings.controlEnabled)
    }

    @Test func keychainIsReadOnlyInsideConnectAndThePasswordIsKeptForReconnects() throws { // NET-03
        let h = SessionHarness()
        #expect(h.secrets.readCount == 0)
        try h.connectToStreaming()
        #expect(h.secrets.readCount == 1)
        h.transport.emit(.closed(.networkLost))
        h.settle()
        h.advance(1)
        #expect(h.transports.count == 2)
        #expect(h.transports[1].pin == Fixture.pin)
        h.open()
        #expect(h.transports[1].hellos == [Fixture.password])
        #expect(h.secrets.readCount == 1)
        h.controller.disconnect()
        h.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.retry() == false) // the password is gone with the session
        try h.connect()
        #expect(h.secrets.readCount == 2)
    }

    @Test func aTypedPasswordNeverTouchesTheKeychain() throws {
        let h = SessionHarness()
        try h.connect(typedPassword: "typed-password")
        h.open()
        #expect(h.transport.hellos == ["typed-password"])
        #expect(h.secrets.readCount == 0)
    }

    @Test func connectWithoutAnyPasswordThrowsAndStartsNothing() {
        let h = SessionHarness(savedPassword: nil)
        #expect(throws: SessionConnectError.passwordRequired) { try h.controller.connect(profile: h.profile) }
        #expect(h.transports.isEmpty)
        #expect(h.controller.phase == .idle)
    }

    @Test func aKeychainFailureIsReportedWithoutConnecting() {
        let h = SessionHarness()
        h.secrets.injectFailures(read: .keychain(-25308))
        #expect(throws: SessionConnectError.self) { try h.controller.connect(profile: h.profile) }
        #expect(h.transports.isEmpty)
    }

    @Test func approveTrustPinsAndReconnectsWithThePin() throws { // NET-01 (controller)
        let h = SessionHarness(pinned: false)
        try h.connect()
        #expect(h.transport.pin == nil)
        h.transport.emit(.trustRequired(Fixture.trustPrompt))
        h.settle()
        #expect(h.controller.phase == .awaitingTrust(Fixture.trustPrompt))
        #expect(h.transport.hellos.isEmpty)
        let generation = h.controller.engine.currentGeneration
        h.controller.approveTrust(Fixture.trustPrompt)
        h.settle()
        #expect(h.trust.pinnedFingerprint(for: Fixture.endpoint) == Fixture.pin)
        #expect(h.transports.count == 2)
        #expect(h.transport.pin == Fixture.pin)
        #expect(h.controller.engine.currentGeneration > generation)
        h.open(); h.welcome(); h.accept()
        #expect(h.controller.phase == .connected)
        #expect(h.transport.subscribes.first?.displays == Fixture.displayIDs)
    }

    @Test func declineTrustFailsWithoutSendingAnything() throws {
        let h = SessionHarness(pinned: false)
        try h.connect()
        h.transport.emit(.trustRequired(Fixture.trustPrompt))
        h.settle()
        h.controller.declineTrust(Fixture.trustPrompt)
        h.advance(30)
        #expect(h.controller.phase == .failed(.trustDeclined))
        #expect(h.transports.count == 1)
        #expect(h.transport.sent.isEmpty)
        #expect(h.trust.pins.isEmpty)
    }

    @Test func approvingAStalePromptDoesNothing() throws {
        let h = SessionHarness(pinned: false)
        try h.connect()
        h.transport.emit(.trustRequired(Fixture.trustPrompt))
        h.settle()
        let other = TrustPrompt(endpoint: Fixture.endpoint, fingerprint: CertificateFingerprint(string: String(repeating: "CD", count: 32))!,
                                previousFingerprint: nil)
        h.controller.approveTrust(other)
        h.controller.declineTrust(other)
        h.settle()
        #expect(h.controller.phase == .awaitingTrust(Fixture.trustPrompt))
        #expect(h.trust.pins.isEmpty)
        #expect(h.transports.count == 1)
        // After a new attempt started, the old prompt is stale too.
        h.controller.cancel()
        try h.connect()
        h.controller.approveTrust(Fixture.trustPrompt)
        h.settle()
        #expect(h.trust.pins.isEmpty)
        #expect(h.transports.count == 2)
    }

    @Test func cancelAndDisconnectReturnToIdleAndForgetThePicture() throws {
        let h = SessionHarness()
        try h.connect()
        h.controller.cancel()
        h.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.transport.closeCount >= 1)
        try h.connectToStreaming()
        h.paintAll()
        #expect(h.controller.hasRetainedFrame)
        h.controller.disconnect()
        h.settle()
        #expect(h.controller.phase == .idle)
        #expect(!h.controller.hasRetainedFrame)
        #expect(h.controller.displays.isEmpty && h.controller.selection.isEmpty)
        #expect(!h.framebuffer.hasValidPixels(display: "fixture-1", x: 0.5, y: 0.5))
        #expect(h.audioControl.isEnabled == false)
        #expect(h.audio.stopCount >= 1)
        // Late callbacks from the ended session change nothing.
        h.transport.emit(.stats(StatsMessage(fps: 3)))
        h.settle()
        #expect(h.controller.phase == .idle)
    }

    @Test func authenticationFailureIsNeverRetried() throws {
        let h = SessionHarness()
        try h.connect()
        h.open()
        h.transport.emit(.error(HostErrorMessage(code: .authentication, message: "Wrong password")))
        h.settle()
        h.advance(60)
        #expect(h.controller.phase == .failed(.authenticationRejected("Wrong password")))
        #expect(h.transports.count == 1)
        #expect(h.controller.retry() == false)
    }

    @Test func authenticationFailureDuringAutomaticReconnectStopsIt() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.transport.emit(.closed(.networkLost))
        h.settle()
        h.advance(1)
        #expect(h.transports.count == 2)
        h.open()
        h.transport.emit(.error(HostErrorMessage(code: .authentication, message: "Wrong password")))
        h.settle()
        h.advance(60)
        #expect(h.controller.phase == .failed(.authenticationRejected("Wrong password")))
        #expect(h.transports.count == 2)
    }

    @Test func aUserInitiatedBusyIsShownImmediately() throws {
        let h = SessionHarness()
        try h.connect()
        h.open()
        h.transport.emit(.error(HostErrorMessage(code: .busy, message: "")))
        h.settle()
        h.advance(30)
        #expect(h.controller.phase == .failed(.busy("")))
        #expect(h.transports.count == 1)
    }

    @Test func hostNoticesBecomeSessionNotices() throws {
        let h = SessionHarness()
        try h.connect(); h.open(); h.welcome()
        h.accept(notice: "Using FHD: Display 2 supports no higher")
        h.transport.emit(.error(HostErrorMessage(code: .capture, message: "Screen Recording is off")))
        h.transport.emit(.error(HostErrorMessage(code: .subscription, message: "Bad region")))
        h.settle()
        #expect(h.controller.notices == [.resolutionLimited("Using FHD: Display 2 supports no higher"),
                                         .captureFailed("Screen Recording is off"), .settingsRejected("Bad region")])
        #expect(h.controller.phase == .connected)
        h.controller.dismissNotice()
        #expect(h.controller.notices.first == .captureFailed("Screen Recording is off"))
    }
}
