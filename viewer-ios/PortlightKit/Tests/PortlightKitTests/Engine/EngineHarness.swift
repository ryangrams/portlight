import Foundation
@testable import PortlightKit

enum Fixture {
    static let endpoint = HostEndpoint(host: "127.0.0.1", port: 15920)!
    static let pin = CertificateFingerprint(string: String(repeating: "AB", count: 32))!
    static let password = "correct horse battery staple"
    static let hd = PixelSize(width: 1280, height: 720)
    static let displayIDs: [DisplayID] = ["fixture-1", "fixture-2", "fixture-3"]
    static let trustPrompt = TrustPrompt(endpoint: endpoint, fingerprint: pin, previousFingerprint: nil)

    /// The synthetic host's three displays, side by side in logical points.
    static func display(_ number: Int) -> HostDisplay {
        let retina = number != 2
        return HostDisplay(id: "fixture-\(number)", name: "Test Display \(number)", number: number,
                           nativeSize: retina ? PixelSize(width: 3840, height: 2160) : PixelSize(width: 1920, height: 1080),
                           logicalFrame: LogicalRect(x: Double(1920 * (number - 1)), y: 0, width: 1920, height: 1080),
                           scale: retina ? 2 : 1, isPrimary: number == 1)
    }
    static let welcome = WelcomeMessage(
        version: 1, serverName: "Portlight Test Host", sessionID: "session-1",
        displays: [display(1), display(2), display(3)],
        capabilities: HostCapabilities(imageCodecs: ["png", "jpeg"], audioCodecs: [.aac, .mulaw],
                                       colorModes: ["gray16", "color256", "rgb565", "full"], maxViewers: 1))

    static func subscribed(for request: SubscriptionRequest, size: PixelSize = hd, audio: Bool = false,
                           audioCodec: AudioCodec? = nil, audioBitrate: Int? = nil) -> SubscribedMessage {
        SubscribedMessage(revision: request.revision, canvases: request.displays.map { .init(display: $0, size: size) },
                          paused: request.paused, audio: audio, audioCodec: audioCodec, audioBitrate: audioBitrate,
                          resolution: .preset(request.resolution), notice: nil)
    }

    static func frame(revision: Int, display: DisplayID = "fixture-1", sequence: Int, canvas: PixelSize = hd,
                      rect: PixelRect = PixelRect(x: 0, y: 0, width: 64, height: 32), bytes: Int = 64) -> InboundMessage {
        .frame(FrameHeader(revision: revision, display: display, rect: rect, canvas: canvas, codec: .png, sequence: sequence),
               payload: Data(repeating: 0x5A, count: bytes))
    }

    static func audio(revision: Int, sequence: Int) -> InboundMessage {
        .audio(AudioHeader(revision: revision, codec: .aac, sampleRate: 48000, channels: 2, samples: 1024,
                           sequence: sequence, bitrate: 96000, cookie: Data([0x11, 0x90])),
               payload: Data(count: 100))
    }
}

/// One engine wired to fakes, a manual clock and a private delegate queue. All helpers run on the test
/// thread; `drain()` flushes the engine, decode and delegate queues so assertions see a settled state.
final class EngineHarness {
    let log: EventLog
    let clock: ManualClock
    let framebuffer: FakeFramebufferSink
    let audio: FakeAudioSink
    let decoder: FakeDecoder
    let delegate: RecordingDelegate
    let transcript: RecordingTranscript
    let registry: TransportRegistry
    let delegateQueue: DispatchQueue
    let engine: SessionEngine

    init(configuration: EngineConfiguration = .init()) {
        let log = EventLog(), clock = ManualClock(), framebuffer = FakeFramebufferSink(log: log)
        let audio = FakeAudioSink(), decoder = FakeDecoder(), delegate = RecordingDelegate()
        let transcript = RecordingTranscript(), registry = TransportRegistry(log: log)
        let delegateQueue = DispatchQueue(label: "test.engine.delegate")
        let engine = SessionEngine(transportFactory: { registry.make() }, clock: clock, framebuffer: framebuffer,
                                   audio: audio, decoder: decoder, configuration: configuration,
                                   delegateQueue: delegateQueue, transcript: transcript)
        delegateQueue.sync { engine.delegate = delegate }
        self.log = log; self.clock = clock; self.framebuffer = framebuffer; self.audio = audio; self.decoder = decoder
        self.delegate = delegate; self.transcript = transcript; self.registry = registry
        self.delegateQueue = delegateQueue; self.engine = engine
    }

    var transports: [FakeTransport] { registry.all }
    var transport: FakeTransport { registry.all.last! }
    var phases: [ConnectionPhase] { delegate.phases }
    var diagnostics: EngineDiagnostics { engine.diagnosticsForTesting }

    func drain() {
        engine.drainForTesting()
        delegateQueue.sync {}
    }
    /// Flushes only the engine and delegate queues (safe while the decoder is held).
    func syncEngine() {
        engine.queue.sync {}
        delegateQueue.sync {}
    }
    /// Flushes only the engine queue (safe while the delegate queue is parked).
    func syncEngineQueue() { engine.queue.sync {} }
    /// Flushes only the decode queue (safe while the engine queue is parked).
    func syncDecode() { engine.decodeQueue.sync {} }

    func request(password: String = Fixture.password, pin: CertificateFingerprint? = Fixture.pin,
                 previousSelection: [DisplayID]? = nil) -> ConnectRequest {
        ConnectRequest(endpoint: Fixture.endpoint, pin: pin, password: password, planner: FakePlanner(),
                       previousSelection: previousSelection)
    }
    func connect(password: String = Fixture.password, pin: CertificateFingerprint? = Fixture.pin,
                 previousSelection: [DisplayID]? = nil, drain shouldDrain: Bool = true) {
        engine.connect(request(password: password, pin: pin, previousSelection: previousSelection))
        if shouldDrain { drain() } else { syncEngine() }
    }
    func open() {
        transport.emit(.identityVerified(Fixture.pin))
        transport.emit(.opened)
        drain()
    }
    func sendWelcome(_ welcome: WelcomeMessage = Fixture.welcome) {
        transport.emit(.welcome(welcome))
        drain()
    }
    /// Acknowledges the given (default: newest) sent revision with one canvas per requested display.
    @discardableResult
    func accept(revision: Int? = nil, size: PixelSize = Fixture.hd, audio: Bool = false,
                audioCodec: AudioCodec? = nil, audioBitrate: Int? = nil) -> SubscribedMessage {
        let subscribes = transport.subscribes
        let request = revision.flatMap { wanted in subscribes.first { $0.revision == wanted } } ?? subscribes.last!
        let ack = Fixture.subscribed(for: request, size: size, audio: audio, audioCodec: audioCodec, audioBitrate: audioBitrate)
        transport.emit(.subscribed(ack))
        drain()
        return ack
    }
    /// Connect → trusted open → welcome → revision 1 accepted, all at t = 0.
    func connectToStreaming() {
        connect(); open(); sendWelcome(); accept()
    }
    /// Emits one frame without draining.
    func frame(revision: Int = 1, display: DisplayID = "fixture-1", sequence: Int, canvas: PixelSize = Fixture.hd,
               rect: PixelRect = PixelRect(x: 0, y: 0, width: 64, height: 32), bytes: Int = 64) {
        transport.emit(Fixture.frame(revision: revision, display: display, sequence: sequence, canvas: canvas, rect: rect, bytes: bytes))
    }
    func advance(_ seconds: TimeInterval) {
        clock.advance(by: seconds)
        drain()
    }
    /// One-second steps with a host `stats` each, as the real host sends, so the read deadline stays quiet.
    func advanceKeepingAlive(seconds: Int) {
        for _ in 0..<seconds {
            clock.advance(by: 1)
            transport.emit(.stats(StatsMessage(fps: 1)))
        }
        drain()
    }
    /// The newest sent request with one change (default: FHD), revision left for the engine to assign.
    func changedRequest(_ change: (inout SubscriptionRequest) -> Void = { $0.resolution = .fhd }) -> SubscriptionRequest {
        var request = transport.subscribes.last!
        change(&request)
        return request
    }

    // MARK: Probes for cross-queue races and engine lifetime

    /// Parks `queue` until the returned closure runs, so work piles up behind it. Bounded: a forgotten
    /// release resumes after 5 s. Never park the calling thread's own queue.
    func park(_ queue: DispatchQueue) -> () -> Void {
        let parked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        queue.async {
            parked.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        _ = parked.wait(timeout: .now() + 5)
        return { release.signal() }
    }
    func parkEngineQueue() -> () -> Void { park(engine.queue) }
    func parkDelegateQueue() -> () -> Void { park(delegateQueue) }

    /// Revisions sent and not yet answered, as the engine tracks them.
    var outstandingRevisions: [Int] { engine.queue.sync { engine.attempt?.outstanding.map(\.revision) ?? [] } }
    /// Whether the running attempt still holds the password in memory.
    var attemptHoldsPassword: Bool { engine.queue.sync { engine.attempt?.password != nil } }

    /// Another engine on the same fakes that nothing here retains (lifetime tests).
    func makeDetachedEngine() -> SessionEngine {
        let registry = self.registry
        return SessionEngine(transportFactory: { registry.make() }, clock: clock, framebuffer: framebuffer, audio: audio,
                             decoder: decoder, delegateQueue: delegateQueue)
    }
    /// Flushes `engine`'s decode queue without keeping the engine alive.
    func decodeFlusher(for engine: SessionEngine) -> () -> Void {
        let queue = engine.decodeQueue
        return { queue.sync {} }
    }
}

/// Observes whether an object is still alive without keeping it so.
final class EngineWeakProbe<Object: AnyObject> {
    weak var object: Object?
    init(_ object: Object?) { self.object = object }
}
