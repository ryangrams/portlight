import Foundation
@testable import PortlightKit

/// One `SessionController` wired to the Engine test fakes (FakeTransport per attempt, ManualClock,
/// FakeAudioSink), a real `SoftwareFramebuffer` with the real ImageIO decoder, a spy Keychain and an
/// in-memory trust store. Every helper runs on the main actor and ends with `settle()`, so assertions
/// see a quiet state: nothing queued in the engine, decoder, event queue or inbox.
@MainActor
final class SessionHarness {
    let log = EventLog()
    let clock = ManualClock()
    let registry: TransportRegistry
    let framebuffer: FramebufferSink
    let audio = FakeAudioSink()
    let audioControl = SessionFakeAudioControl()
    let secrets: SpySecretStore
    let trust: InMemoryTrustStore
    let transcript = RecordingTranscript()
    let profileFixture: SessionProfileFixture?
    var profile: ConnectionProfile
    let controller: SessionController
    private var sequence = 1000

    static let contentScale = 3.0

    init(framebuffer: FramebufferSink = SoftwareFramebuffer(), decoder: TileDecoding = ImageTileDecoding(), pinned: Bool = true,
         savedPassword: String? = Fixture.password, preferences: ViewerPreferences = .standard, pixelBudget: Int = 33_177_600,
         persistProfiles: Bool = false, random: Double = 0.5, presentation: PresentationState? = nil) {
        let profile = ConnectionProfile(id: SessionProfileFixture.profileID, name: "Studio Mac", host: Fixture.endpoint.host,
                                        port: Fixture.endpoint.port, createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                        hasSavedPassword: savedPassword != nil, preferences: preferences)
        let registry = TransportRegistry(log: log)
        self.registry = registry
        self.framebuffer = framebuffer
        self.profile = profile
        secrets = SpySecretStore(passwords: savedPassword.map { [profile.secretAccount: $0] } ?? [:])
        trust = InMemoryTrustStore(pins: pinned ? [Fixture.endpoint: Fixture.pin] : [:])
        profileFixture = persistProfiles ? SessionProfileFixture(profile: profile) : nil
        let dependencies = SessionDependencies(
            transportFactory: { registry.make() }, clock: clock, framebuffer: framebuffer, decoder: decoder,
            audio: audio, audioControl: audioControl, presentation: presentation, secrets: secrets, trust: trust,
            profiles: profileFixture?.store, pixelBudget: pixelBudget, random: { random },
            transcript: transcript, wallClock: { Date(timeIntervalSinceReferenceDate: 810_000_000) })
        controller = SessionController(dependencies: dependencies)
        controller.surfaceGeometryChanged(drawableSize: ViewportFixtures.portraitSize, usableRect: ViewportFixtures.portraitUsable,
                                          contentScale: Self.contentScale)
        controller.setSurfaceVisible(true)
    }

    // MARK: Queues

    /// Drains the engine, decoder and event queues and applies pending events until nothing new arrives.
    func settle() {
        for _ in 0..<100 {
            controller.engine.drainForTesting()
            controller.eventQueue.sync {}
            if !controller.processPendingEvents() { return }
        }
    }

    /// Lets the engine deliver everything it has (into the controller's inbox) without applying any of it, as when
    /// callbacks are waiting for the main-actor drain while the app calls the controller.
    func deliverWithoutApplying() {
        controller.engine.drainForTesting()
        controller.eventQueue.sync {}
    }

    /// Advances the manual clock (firing due engine and controller timers), then settles.
    func advance(_ seconds: Double) {
        clock.advance(by: seconds)
        settle()
    }

    /// Advances `count` display frames (1/60 s each), settling after each: paced work (typed text) moves one step
    /// per frame, the way the controller reschedules it.
    func advanceFrames(_ count: Int) {
        for _ in 0..<count { advance(1.0 / 60) }
    }

    /// The text of every `text` message sent, in order.
    var typedText: String {
        inputs.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
    }

    /// Advances in one-second steps with a host `stats` each, as the real host sends, so the read deadline stays quiet.
    func advanceKeepingAlive(seconds: Int) {
        for _ in 0..<seconds {
            clock.advance(by: 1)
            if controller.phase == .connected || controller.phase == .loadingDisplays {
                transport.emit(.stats(StatsMessage(fps: 1)))
            }
            settle()
        }
    }

    // MARK: Transports

    var transports: [FakeTransport] { registry.all }
    var transport: FakeTransport { registry.all.last! }
    /// Every remote-input message on every transport, in order.
    var inputs: [OutboundMessage] { transports.flatMap(\.inputs) }
    var subscribes: [SubscriptionRequest] { transports.flatMap(\.subscribes) }

    // MARK: Connection script

    func connect(typedPassword: String = "") throws {
        try controller.connect(profile: profile, typedPassword: typedPassword)
        settle()
    }

    func open(pin: CertificateFingerprint = Fixture.pin) {
        transport.emit(.identityVerified(pin))
        transport.emit(.opened)
        settle()
    }

    func welcome(_ message: WelcomeMessage = Fixture.welcome) {
        transport.emit(.welcome(message))
        settle()
    }

    /// Acknowledges the newest (or the given) sent revision with one canvas per requested display.
    @discardableResult
    func accept(revision: Int? = nil, size: PixelSize = Fixture.hd, audio: Bool = false, audioCodec: AudioCodec? = nil,
                resolution: EffectiveResolution? = nil, notice: String? = nil) -> SubscribedMessage {
        let sent = transport.subscribes
        let request = revision.flatMap { wanted in sent.first { $0.revision == wanted } } ?? sent.last!
        var ack = Fixture.subscribed(for: request, size: size, audio: audio, audioCodec: audioCodec,
                                     audioBitrate: audio ? request.audioBitrate.rawValue : nil)
        if let resolution { ack.resolution = resolution }
        ack.notice = notice
        transport.emit(.subscribed(ack))
        settle()
        return ack
    }

    /// Connect → trusted open → welcome → revision 1 accepted.
    func connectToStreaming(_ message: WelcomeMessage = Fixture.welcome) throws {
        try connect()
        open()
        welcome(message)
        accept()
    }

    func nextSequence() -> Int {
        sequence += 1
        return sequence
    }

    /// Commits one full-canvas PNG per display of the accepted revision, so every input cell is valid.
    func paintAll(shade: Int = 0) {
        guard let effective = controller.effective else { return }
        for (display, canvas) in effective.canvases.sorted(by: { $0.key < $1.key }) {
            let header = FrameHeader(revision: effective.revision, display: display,
                                     rect: PixelRect(x: 0, y: 0, width: canvas.width, height: canvas.height),
                                     canvas: canvas, codec: .png, sequence: nextSequence())
            transport.emit(.frame(header, payload: SessionPNG.solid(width: canvas.width, height: canvas.height, shade: shade)))
        }
        settle()
    }

    /// A frame whose canvas doesn't match the accepted one: the engine ACKs it, rejects it and asks for recovery.
    func emitMismatchedFrame() {
        guard let effective = controller.effective, let display = effective.canvases.keys.sorted().first else { return }
        let header = FrameHeader(revision: effective.revision, display: display, rect: PixelRect(x: 0, y: 0, width: 64, height: 64),
                                 canvas: PixelSize(width: 1920, height: 1080), codec: .png, sequence: nextSequence())
        transport.emit(.frame(header, payload: SessionPNG.solid(width: 64, height: 64)))
        settle()
    }

    /// Emits `count` real 64×64 PNG tiles for the accepted revision without settling (a flood).
    func emitTiles(_ count: Int, shade: Int) {
        guard let effective = controller.effective else { return }
        let displays = effective.canvases.sorted { $0.key < $1.key }
        guard !displays.isEmpty else { return }
        for index in 0..<count {
            let (display, canvas) = displays[(shade + index) % displays.count]
            let columns = max(1, canvas.width / 64), rows = max(1, canvas.height / 64)
            let cell = (shade * 7 + index * 13) % (columns * rows)
            let rect = PixelRect(x: (cell % columns) * 64, y: (cell / columns) * 64, width: 64, height: 64)
            let header = FrameHeader(revision: effective.revision, display: display, rect: rect, canvas: canvas,
                                     codec: .png, sequence: nextSequence())
            transport.emit(.frame(header, payload: SessionPNG.solid(width: 64, height: 64, shade: (shade + index) % 5)))
        }
    }

    // MARK: Touches (view points; timestamps from the manual clock)

    func touch(_ event: TouchEvent, after dt: Double = 0.008) {
        if dt > 0 { clock.advance(by: dt) }
        controller.touch(event, at: clock.now())
        settle()
    }

    /// A quick one-finger tap.
    func tap(_ x: Double, _ y: Double) {
        touch(.began([TouchPoint(id: 1, x: x, y: y)]))
        touch(.ended([TouchPoint(id: 1, x: x, y: y)]), after: 0.05)
    }

    /// A two-finger pinch about (x, y) from `startSpan` to `endSpan` view points.
    func pinch(at x: Double, _ y: Double, from startSpan: Double, to endSpan: Double, steps: Int = 8) {
        func points(_ span: Double) -> [TouchPoint] {
            [TouchPoint(id: 1, x: x - span / 2, y: y), TouchPoint(id: 2, x: x + span / 2, y: y)]
        }
        touch(.began(points(startSpan)))
        for step in 1...steps {
            touch(.moved(points(startSpan + (endSpan - startSpan) * Double(step) / Double(steps))))
        }
        touch(.ended(points(endSpan)))
    }

    /// A one-finger drag (local pan in Direct and Pan modes).
    func drag(from start: (Double, Double), to end: (Double, Double), steps: Int = 8) {
        touch(.began([TouchPoint(id: 1, x: start.0, y: start.1)]))
        for step in 1...steps {
            let f = Double(step) / Double(steps)
            touch(.moved([TouchPoint(id: 1, x: start.0 + (end.0 - start.0) * f, y: start.1 + (end.1 - start.1) * f)]))
        }
        touch(.ended([TouchPoint(id: 1, x: end.0, y: end.1)]))
    }

    /// Direct-mode long press at a view point, leaving the finger down (a held left button).
    func longPress(_ x: Double, _ y: Double) {
        touch(.began([TouchPoint(id: 1, x: x, y: y)]))
        clock.advance(by: 0.6)
        controller.tick(at: clock.now())
        settle()
    }

    /// View point at the center of a display in the current layout.
    func viewCenter(of display: DisplayID) -> (Double, Double) {
        let rect = controller.viewport.layout[display]!
        return controller.viewport.viewPoint(atDesktop: rect.center)
    }

    var transformBits: [UInt64] {
        let t = controller.transformStore.transform
        return [t.scale.bitPattern, t.tx.bitPattern, t.ty.bitPattern]
    }

    func waitForPreferenceWrites() { controller.preferenceWriter?.waitUntilIdle() }

    /// A closure that makes the current attempt's host acknowledge its newest sent revision and paint every display
    /// of it in full, then drains the engine: late traffic of that computer, to run from inside another call.
    func lateHostTraffic(size: PixelSize = Fixture.hd) -> @Sendable () -> Void {
        let transport = self.transport, engine = controller.engine
        let request = transport.subscribes.last!
        let ack = Fixture.subscribed(for: request, size: size)
        var frames: [(FrameHeader, Data)] = []
        for display in request.displays {
            let header = FrameHeader(revision: request.revision, display: display,
                                     rect: PixelRect(x: 0, y: 0, width: size.width, height: size.height),
                                     canvas: size, codec: .png, sequence: nextSequence())
            frames.append((header, SessionPNG.solid(width: size.width, height: size.height, shade: 3)))
        }
        let late = frames
        return {
            transport.emit(.subscribed(ack))
            for (header, payload) in late { transport.emit(.frame(header, payload: payload)) }
            engine.drainForTesting()
        }
    }
}
