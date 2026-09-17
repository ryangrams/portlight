import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// The planner, render stores, transcript sink, preference persistence and diagnostics.
@Suite @MainActor struct SessionPartsTests {
    static func welcome(displays count: Int, audio: [AudioCodec] = [.aac, .mulaw]) -> WelcomeMessage {
        let displays = (1...count).map { n in
            HostDisplay(id: "d\(n)", name: "Display \(n)", number: n, nativeSize: PixelSize(width: 1920, height: 1080),
                        logicalFrame: LogicalRect(x: Double(1920 * (n - 1)), y: 0, width: 1920, height: 1080), scale: 1, isPrimary: n == 1)
        }
        return WelcomeMessage(version: 1, serverName: "Host", sessionID: "s", displays: displays,
                              capabilities: HostCapabilities(imageCodecs: ["png"], audioCodecs: audio, colorModes: [], maxViewers: 1))
    }

    // MARK: Planner

    @Test func plannerSelectsEveryDisplayUpToTheWireLimitInHostOrder() {
        let planner = DefaultSubscriptionPlanner(settings: SessionSettings(), pixelBudget: 1 << 40)
        let request = planner.initialSubscription(for: Self.welcome(displays: 17), previousSelection: nil)
        #expect(request.displays == (1...16).map { "d\($0)" })
        #expect(request.revision == 0 && request.fps == 60 && request.regions.isEmpty)
    }

    @Test func plannerIntersectsOnReconnect() {
        let planner = DefaultSubscriptionPlanner(settings: SessionSettings())
        let request = planner.initialSubscription(for: Self.welcome(displays: 3), previousSelection: ["d3", "gone", "d1", "d3"])
        #expect(request.displays == ["d1", "d3"])
        #expect(planner.initialSubscription(for: Self.welcome(displays: 2), previousSelection: ["gone"]).displays.isEmpty)
    }

    @Test func plannerLowersResolutionForTheBudgetButNeverDropsDisplays() {
        var settings = SessionSettings()
        settings.resolution = .uhd
        let roomy = DefaultSubscriptionPlanner(settings: settings, pixelBudget: 33_177_600)
        let tight = DefaultSubscriptionPlanner(settings: settings, pixelBudget: 8_294_400)
        // A ceiling that fits passes through; the host itself picks FHD, the highest preset 1080p natives support.
        #expect(roomy.initialSubscription(for: Self.welcome(displays: 2), previousSelection: nil).resolution == .uhd)
        let limited = tight.initialSubscription(for: Self.welcome(displays: 3), previousSelection: nil)
        #expect(limited.resolution == .hd && limited.displays.count == 3)
        let capped = DefaultSubscriptionPlanner(settings: settings, pixelBudget: 33_177_600, resolutionCap: .hd)
        #expect(capped.initialSubscription(for: Self.welcome(displays: 1), previousSelection: nil).resolution == .hd)
    }

    @Test func plannerChoosesAudioFromCapabilitiesAndPause() {
        var settings = SessionSettings()
        settings.audioEnabled = true
        let planner = DefaultSubscriptionPlanner(settings: settings)
        #expect(planner.initialSubscription(for: Self.welcome(displays: 1), previousSelection: nil).audioCodec == .aac)
        let mulaw = planner.initialSubscription(for: Self.welcome(displays: 1, audio: [.mulaw]), previousSelection: nil)
        #expect(mulaw.audio && mulaw.audioCodec == .mulaw)
        #expect(!planner.initialSubscription(for: Self.welcome(displays: 1, audio: []), previousSelection: nil).audio)
        settings.paused = true
        let paused = DefaultSubscriptionPlanner(settings: settings).initialSubscription(for: Self.welcome(displays: 1), previousSelection: nil)
        #expect(paused.paused && !paused.audio)
    }

    @Test func plannerDithersOnlyForVideoWithReducedColor() { // QUALITY-02 (request side)
        var settings = SessionSettings()
        settings.smoothGradients = true
        settings.color = .gray16
        settings.quality = .video
        #expect(DefaultSubscriptionPlanner(settings: settings).initialSubscription(for: Self.welcome(displays: 1), previousSelection: nil).dither)
        settings.quality = .text
        #expect(!DefaultSubscriptionPlanner(settings: settings).initialSubscription(for: Self.welcome(displays: 1), previousSelection: nil).dither)
        settings.quality = .video
        settings.color = .full
        #expect(!DefaultSubscriptionPlanner(settings: settings).initialSubscription(for: Self.welcome(displays: 1), previousSelection: nil).dither)
    }

    @Test func plannerKeepsOnlyMeaningfulRegionsOfSelectedDisplays() {
        let welcome = Self.welcome(displays: 3)
        let request = DefaultSubscriptionPlanner.request(
            displays: welcome.displays, selection: ["d1", "d2"], settings: SessionSettings(), capabilities: welcome.capabilities,
            pixelBudget: 1 << 40,
            regions: ["d1": .full, "d2": .zero, "d3": NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5),
                      "d4": NormalizedRect(x: 0.9, y: 0, width: 0.5, height: 0.5)])
        #expect(request.regions == ["d2": .zero])
    }

    // MARK: Stores and transcript

    @Test func renderStoresVersionOnlyRealChanges() {
        let store = TransformStore()
        let model = ViewportFixtures.model(ViewportFixtures.row)
        #expect(store.publish(model, dimmed: false))
        #expect(!store.publish(model, dimmed: false))
        #expect(store.publish(model, dimmed: true))
        #expect(store.snapshot.version == 2)
        #expect(store.scene(cursor: nil).dimmed && store.scene(cursor: nil).quads.count == 3)
        let cursor = CursorStore()
        cursor.set(LogicalPoint(x: 1, y: 2))
        #expect(cursor.visiblePoint == nil)
        cursor.setVisible(true)
        #expect(cursor.visiblePoint == LogicalPoint(x: 1, y: 2))
        #expect(store.scene(cursor: cursor).cursor == LogicalPoint(x: 1, y: 2))
    }

    @Test func fileTranscriptWritesOneEscapedLinePerRecord() throws {
        let directory = SessionTempDirectory()
        defer { directory.remove() }
        let url = directory.file("evidence/transcript.log")
        let sink = try FileTranscriptSink(url: url)
        sink.record("→ subscribe {revision:1}")
        sink.record("← subscribed {notice:\"two\nlines\"}")
        sink.close()
        sink.record("ignored after close")
        #expect(sink.lineCount == 2)
        #expect(try FileTranscriptSink.lines(at: url) == ["→ subscribe {revision:1}", "← subscribed {notice:\"two\\nlines\"}"])
    }

    @Test func theEngineTranscriptRecordsRevisionOneWithoutSecrets() throws { // DISP-01 evidence shape
        let h = SessionHarness()
        try h.connectToStreaming()
        let lines = h.transcript.lines
        #expect(lines.contains { $0.hasPrefix("→ subscribe {revision:1 displays:[fixture-1,fixture-2,fixture-3]") })
        #expect(!lines.contains { $0.contains(Fixture.password) })
    }

    // MARK: Persistence

    @Test func preferenceChangesPersistToTheProfileButPanNeverDoes() throws {
        let h = SessionHarness(persistProfiles: true)
        defer { h.profileFixture?.directory.remove() }
        try h.connectToStreaming()
        h.controller.setResolution(.fhd)
        h.controller.setColor(.gray16)
        h.controller.setQuality(.text)
        h.controller.setAudioQuality(.stereo160)
        h.controller.setBandwidth(kbps: 50)
        h.controller.setSmoothGradients(true)
        h.controller.setInputMode(.direct)
        h.controller.setInputMode(.pan)
        h.controller.setAudioEnabled(true)
        h.settle()
        h.waitForPreferenceWrites()
        let stored = try #require(h.profileFixture?.stored())
        #expect(stored.preferences == ViewerPreferences(resolution: .fhd, color: .gray16, quality: .text, inputMode: .direct,
                                                        audioQuality: .stereo160, bandwidthKbps: 100, smoothGradients: true))
        #expect(stored.lastConnectedAt != nil)
        #expect(stored.name == "Studio Mac")
        #expect(h.profileFixture?.storedProfileCount == 2)
        #expect(h.controller.preferenceWriter?.failureCount == 0)
    }

    // MARK: Diagnostics and derived state

    @Test func diagnosticsMergeEngineFramebufferAndSchedulerCounters() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.paintAll()
        h.advance(0.5)
        h.paintAll(shade: 1)
        h.advance(0.5)
        let snapshot = h.controller.diagnostics
        #expect(snapshot.engine.framesCommitted >= 6)
        #expect(snapshot.framebuffer?.committed ?? 0 >= 6)
        #expect(snapshot.regions.subscriptionsLastMinute == 1)
        #expect(snapshot.receiveMbps != nil)
        #expect(snapshot.requestedResolution == .hd)
        #expect(snapshot.canvases.count == 3)
        let text = snapshot.exportText
        #expect(!text.contains(Fixture.password) && !text.contains("Portlight Test Host") && !text.contains("127.0.0.1"))
    }

    @Test func idleTimerOwnershipFollowsConnectionVisibilityAndForeground() throws {
        let h = SessionHarness()
        #expect(!h.controller.wantsIdleTimerDisabled)
        try h.connectToStreaming()
        #expect(h.controller.wantsIdleTimerDisabled)
        h.controller.setSurfaceVisible(false)
        #expect(!h.controller.wantsIdleTimerDisabled)
        h.controller.setSurfaceVisible(true)
        h.controller.disconnect()
        h.settle()
        #expect(!h.controller.wantsIdleTimerDisabled)
    }

    @Test func audioInterruptionsBecomeANoticeAndAResumeAction() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.setAudioEnabled(true)
        h.settle()
        h.accept(audio: true, audioCodec: .aac)
        h.audioControl.simulate(.paused(.outputDeviceRemoved))
        #expect(h.controller.audioState == .interrupted)
        #expect(h.controller.notices.contains(.audioInterrupted))
        h.controller.resumeAudio()
        #expect(h.audioControl.resumeCount == 1)
        h.audioControl.simulate(.active)
        #expect(h.controller.audioState == .playing)
    }

    @Test func audioOnAHostWithoutAudioIsExplained() throws {
        let h = SessionHarness()
        var silent = Fixture.welcome
        silent.capabilities.audioCodecs = []
        try h.connectToStreaming(silent)
        h.controller.setAudioEnabled(true)
        h.settle()
        #expect(!h.controller.audioAvailable)
        #expect(h.controller.notices.contains(.audioUnavailable))
        #expect(h.transport.subscribes.allSatisfy { !$0.audio })
        #expect(!h.audioControl.isEnabled)
    }
}
