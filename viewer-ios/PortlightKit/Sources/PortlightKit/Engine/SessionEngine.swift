import Foundation

/// The ordered, generation-safe pipeline between one `PortlightTransport` and the app.
///
/// Queues: all session state lives on one private serial engine queue; image decode runs on one
/// private serial decode queue (arrival order = commit order, bounded by jobs and bytes); callbacks go
/// to `delegateQueue`. Every transport event, timer and decode completion carries its generation and
/// is dropped when stale. `connect`, `disconnect` and `cancel` retire the current generation on the
/// caller's thread before they return: from then on nothing of it reaches the framebuffer, the socket or
/// the delegate, not even callbacks already queued. The framebuffer is never cleared here: a frozen frame
/// is the controller's call.
public final class SessionEngine: @unchecked Sendable {
    // Invariant for @unchecked Sendable: `attempt`, `phase`, `publishedGeneration`, `diagnostics` and
    // `lastCommitTime` are read and written only on `queue`; `delegate` only on `delegateQueue`; `gate` has
    // its own locks; every other stored property is immutable after init.
    public weak var delegate: SessionEngineDelegate?
    public let configuration: EngineConfiguration
    /// The newest generation handed out. Bumped the moment connect, disconnect or cancel is called.
    public var currentGeneration: ConnectionGeneration { gate.issued }

    let queue = DispatchQueue(label: "studio.upgrade.portlight.engine", qos: .userInitiated)
    let decodeQueue = DispatchQueue(label: "studio.upgrade.portlight.engine.decode", qos: .userInitiated)
    let delegateQueue: DispatchQueue
    let transportFactory: () -> PortlightTransport
    let clock: SessionClock
    let framebuffer: FramebufferSink
    let audio: AudioPacketSink
    let decoder: TileDecoding
    let transcript: TranscriptSink?
    let gate = GenerationGate()

    var attempt: EngineAttempt?
    var phase: ConnectionPhase = .idle
    /// The generation delegate callbacks belong to: the running attempt's, or the last stop's.
    var publishedGeneration = ConnectionGeneration.none
    var diagnostics = EngineDiagnostics()
    var lastCommitTime: TimeInterval?

    public init(transportFactory: @escaping () -> PortlightTransport, clock: SessionClock = SystemSessionClock(),
                framebuffer: FramebufferSink, audio: AudioPacketSink, decoder: TileDecoding,
                configuration: EngineConfiguration = .init(), delegateQueue: DispatchQueue = .main,
                transcript: TranscriptSink? = nil) {
        self.transportFactory = transportFactory; self.clock = clock; self.framebuffer = framebuffer
        self.audio = audio; self.decoder = decoder; self.configuration = configuration
        self.delegateQueue = delegateQueue; self.transcript = transcript
    }

    deinit {
        // No other reference exists any more, so touching engine-queue state here is safe. Decode jobs don't
        // retain the engine: closing the gate keeps any still queued out of a framebuffer that outlives it.
        gate.close()
        attempt?.cancelTimers()
        attempt?.transport.close()
    }

    // MARK: Commands (any thread; they run on the engine queue in call order)

    /// Starts a new generation, closing any current attempt first. Revisions restart at 1. The previous
    /// generation is retired before this returns.
    public func connect(_ request: ConnectRequest) {
        let generation = gate.reserve()
        queue.async { self.start(request, generation: generation) }
    }
    /// Sends the complete desired state at the next revision unless it equals the last sent one.
    public func submit(_ desired: SubscriptionRequest, force: Bool = false) {
        queue.async { self.sendSubscription(desired, force: force) }
    }
    /// Remote input, sent only while connected for the current generation (else dropped and counted).
    public func send(input messages: [OutboundMessage]) { queue.async { self.sendInput(messages) } }
    /// Graceful close, audio stopped, phase `.idle`. The framebuffer keeps its last picture. Once this returns
    /// nothing of the session reaches the framebuffer or the delegate, so a following `removeAll()` is final.
    public func disconnect() {
        let generation = gate.reserve()
        queue.async { self.stop(canceled: false, generation: generation) }
    }
    /// Like `disconnect`; an attempt still in progress ends as `.failed(.canceled)` (not an error to show).
    public func cancel() {
        let generation = gate.reserve()
        queue.async { self.stop(canceled: true, generation: generation) }
    }

    // MARK: Lifecycle (engine queue)

    func start(_ request: ConnectRequest, generation: ConnectionGeneration) {
        if let old = attempt { teardown(old, closeTransport: true) }
        audio.stopAudio()
        // A later connect, disconnect or cancel was already called: this attempt never opens a socket.
        guard gate.open(generation) else { return }
        publishedGeneration = generation
        diagnostics = EngineDiagnostics()
        diagnostics.generation = generation
        lastCommitTime = nil
        let transport = transportFactory()
        let a = EngineAttempt(generation: generation, transport: transport, pin: request.pin, planner: request.planner,
                              previousSelection: request.previousSelection, password: request.password, now: clock.now())
        attempt = a
        record("· connect \(generation)")
        // Forced: the retired generation's equal phase may have been dropped undelivered.
        setPhase(.connecting(patient: false), force: true)
        schedule(.patience, after: configuration.patienceDelay, for: a)
        schedule(.connectDeadline, after: configuration.connectDeadline, for: a)
        schedule(.diagnostics, after: configuration.diagnosticsInterval, for: a)
        transport.connect(to: request.endpoint, pin: request.pin, generation: generation, queue: queue) { [weak self] generation, event in
            self?.handle(event, generation: generation)
        }
    }

    /// Ends an attempt without choosing a phase: timers off, password dropped, no further commits.
    func teardown(_ a: EngineAttempt, closeTransport: Bool) {
        a.cancelTimers()
        a.password = nil
        gate.close()
        if closeTransport { a.transport.close() }
        if attempt === a { attempt = nil }
    }

    /// Terminal outcome of an attempt. Audio stops; the framebuffer keeps its frozen picture.
    func end(_ a: EngineAttempt, phase next: ConnectionPhase, closeTransport: Bool) {
        teardown(a, closeTransport: closeTransport)
        audio.stopAudio()
        emitDiagnostics()
        setPhase(next)
    }

    func fail(_ a: EngineAttempt, _ failure: ConnectionFailure) {
        record("· failed \(Self.describe(failure))")
        end(a, phase: .failed(failure), closeTransport: true)
    }

    func stop(canceled: Bool, generation: ConnectionGeneration) {
        let wasInProgress = phase.isInProgress
        publishedGeneration = generation
        if let a = attempt {
            teardown(a, closeTransport: true)
            emitDiagnostics()
        }
        audio.stopAudio()
        record(canceled ? "· cancel" : "· disconnect")
        // Forced: the retired generation's equal phase may have been dropped undelivered.
        setPhase(canceled && wasInProgress ? .failed(.canceled) : .idle, force: true)
    }

    // MARK: Outbound (engine queue)

    func sendSubscription(_ desired: SubscriptionRequest, force: Bool) {
        // Before welcome there is nothing to subscribe to; the planner supplies revision 1.
        guard let a = attempt, a.welcome != nil else { return }
        if !force, let last = a.lastSent, last.isEquivalent(to: desired) { return }
        var request = desired
        request.revision = a.nextRevision
        a.nextRevision += 1
        a.lastSent = request
        a.outstanding.append(request)
        // Bounded even if answers stop coming: the host answers in order, so the oldest would be answered first.
        if a.outstanding.count > EngineAttempt.maxOutstanding { a.outstanding.removeFirst() }
        a.transport.send(.subscribe(request))
        diagnostics.subscriptionsSent += 1
        record(EngineTranscript.line(.subscribe(request)))
        let sent = request
        notify { $0.engine($1, didSend: sent) }
    }

    func sendInput(_ messages: [OutboundMessage]) {
        let input = messages.filter(\.isInput)
        diagnostics.inputMessagesDropped += messages.count - input.count
        guard let a = attempt, phase == .connected else {
            diagnostics.inputMessagesDropped += input.count
            return
        }
        for message in input {
            a.transport.send(message)
            record(EngineTranscript.line(message))
        }
        diagnostics.inputMessagesSent += input.count
    }

    // MARK: Timers (engine queue)

    func schedule(_ kind: EngineAttempt.TimerKind, after delay: TimeInterval, for a: EngineAttempt) {
        a.cancelTimer(kind)
        let generation = a.generation
        a.timers[kind] = clock.schedule(after: delay, on: queue) { [weak self] in
            self?.timerFired(kind, generation: generation)
        }
    }

    func timerFired(_ kind: EngineAttempt.TimerKind, generation: ConnectionGeneration) {
        guard let a = attempt, a.generation == generation, gate.isLive(generation) else { return }
        a.timers[kind] = nil
        switch kind {
        case .patience:
            if phase == .connecting(patient: false) { setPhase(.connecting(patient: true)) }
        case .connectDeadline:
            if !a.helloSent { fail(a, .timedOut) }
        case .welcomeDeadline:
            // A trusted host answers hello at once, so silence here is a stalled path rather than bad data:
            // "didn't answer", which a foreground reconnect may retry.
            if a.welcome == nil { fail(a, .timedOut) }
        case .ping:
            let time = clock.now()
            a.transport.send(.ping(time: time))
            record(EngineTranscript.line(.ping(time: time)))
            schedule(.ping, after: configuration.pingInterval, for: a)
        case .readDeadline:
            // One watchdog re-armed from the last inbound time, instead of a timer reset per message.
            let silence = clock.now() - a.lastInbound
            if silence >= configuration.readDeadline { fail(a, .networkLost) }
            else { schedule(.readDeadline, after: configuration.readDeadline - silence, for: a) }
        case .diagnostics:
            emitDiagnostics()
            schedule(.diagnostics, after: configuration.diagnosticsInterval, for: a)
        }
    }

    // MARK: Delegate and transcript

    func setPhase(_ next: ConnectionPhase, force: Bool = false) {
        guard force || next != phase else { return }
        phase = next
        notify { $0.engine($1, phaseDidChange: next) }
    }

    /// Queues a delegate callback. It is dropped on delivery once a later connect, disconnect or cancel has
    /// been called, so a retired generation can never publish state (not even callbacks already queued).
    func notify(_ body: @escaping @Sendable (SessionEngineDelegate, SessionEngine) -> Void) {
        let generation = publishedGeneration
        delegateQueue.async { [weak self] in
            guard let self, self.gate.isCurrent(generation), let delegate = self.delegate else { return }
            body(delegate, self)
        }
    }

    func record(_ line: @autoclosure () -> String) { transcript?.record(line()) }

    func emitDiagnostics() {
        let snapshot = diagnosticsSnapshot()
        notify { $0.engine($1, diagnostics: snapshot) }
    }

    func diagnosticsSnapshot() -> EngineDiagnostics {
        var snapshot = diagnostics
        snapshot.lastPatchAge = lastCommitTime.map { max(0, clock.now() - $0) }
        return snapshot
    }

    /// Transcript wording for a failure; a changed certificate's fingerprints stay out of logs.
    static func describe(_ failure: ConnectionFailure) -> String {
        if case .certificateChanged = failure { return "certificateChanged" }
        return String(describing: failure)
    }

    // MARK: Test support

    /// Runs every queued engine, decode and completion block. Never call from the engine or decode queue.
    func drainForTesting() {
        for _ in 0..<2 { queue.sync {}; decodeQueue.sync {} }
        queue.sync {}
    }
    var diagnosticsForTesting: EngineDiagnostics { queue.sync { diagnosticsSnapshot() } }
}

/// Per-attempt state. Confined to the engine queue; replaced wholesale by every `connect`.
final class EngineAttempt {
    enum TimerKind: Hashable, Sendable { case patience, connectDeadline, welcomeDeadline, ping, readDeadline, diagnostics }
    /// Unanswered subscriptions kept at most (the host answers each at once, so this is only a safety bound).
    static let maxOutstanding = 32

    let generation: ConnectionGeneration
    let transport: PortlightTransport
    /// The approved certificate. The password is never sent without one.
    let pin: CertificateFingerprint?
    let planner: any SubscriptionPlanner
    let previousSelection: [DisplayID]?
    /// Held only until `hello` is sent or the attempt ends.
    var password: String?
    var helloSent = false
    var welcome: WelcomeMessage?
    var timers: [TimerKind: Cancellable] = [:]
    /// Revisions restart at 1 for every connection; the host requires strict increase within one.
    var nextRevision = 1
    /// Dedupe baseline. Cleared by a topology change, because the host dropped its subscription.
    var lastSent: SubscriptionRequest?
    /// Sent and not yet answered, ascending by revision.
    var outstanding: [SubscriptionRequest] = []
    var accepted: AcceptedRevision?
    /// The engine's own paused resend after a canvas-budget refusal.
    var budgetFallbackRevision: Int?
    var lastInbound: TimeInterval
    var decodeJobs = 0
    var decodeBytes = 0
    /// Open image-failure burst; closes once a revision sent after it started is accepted.
    var recoveryBurst: (afterRevision: Int, startedAt: TimeInterval)?
    var recoveryStarts: [TimeInterval] = []

    init(generation: ConnectionGeneration, transport: PortlightTransport, pin: CertificateFingerprint?,
         planner: any SubscriptionPlanner, previousSelection: [DisplayID]?, password: String, now: TimeInterval) {
        self.generation = generation; self.transport = transport; self.pin = pin; self.planner = planner
        self.previousSelection = previousSelection; self.password = password; self.lastInbound = now
    }
    var lastSentRevision: Int { nextRevision - 1 }
    func cancelTimer(_ kind: TimerKind) { timers.removeValue(forKey: kind)?.cancel() }
    func cancelTimers() {
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
    }
}

/// The revision whose frames are decoded and committed, with its acknowledged canvases.
struct AcceptedRevision {
    let request: SubscriptionRequest
    let canvases: [DisplayID: PixelSize]
    var revision: Int { request.revision }
}
