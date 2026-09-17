import Foundation
@testable import PortlightKit

// Test doubles for the session engine. Each is thread-safe because the engine calls them from its
// engine and decode queues while the test thread reads them after draining.

/// One ordered record of framebuffer calls and transport sends, for cross-queue ordering checks.
final class EventLog: @unchecked Sendable {
    // Invariant: `storage` is only touched while holding `lock`.
    enum Entry: Equatable {
        case accept(revision: Int)
        case commit(revision: Int, sequence: Int)
        case sent(transport: Int, OutboundMessage)
    }
    private let lock = NSLock()
    private var storage: [Entry] = []
    func append(_ entry: Entry) { lock.withLock { storage.append(entry) } }
    var entries: [Entry] { lock.withLock { storage } }
}

/// Deterministic clock: `advance(by:)` fires due timers in time order, each synchronously on its queue.
final class ManualClock: SessionClock, @unchecked Sendable {
    // Invariant: `time`, `timers` and `nextID` are only touched while holding `lock`; work runs outside it.
    final class ManualTimer: Cancellable, @unchecked Sendable {
        // Invariant: `cancelled` is only touched while holding `lock`.
        let id: Int
        let fireAt: TimeInterval
        let queue: DispatchQueue
        let work: @Sendable () -> Void
        private let lock = NSLock()
        private var cancelled = false
        init(id: Int, fireAt: TimeInterval, queue: DispatchQueue, work: @escaping @Sendable () -> Void) {
            self.id = id; self.fireAt = fireAt; self.queue = queue; self.work = work
        }
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var timers: [ManualTimer] = []
    private var nextID = 0

    func now() -> TimeInterval { lock.withLock { time } }

    func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> Cancellable {
        lock.withLock {
            nextID += 1
            let timer = ManualTimer(id: nextID, fireAt: time + max(0, delay), queue: queue, work: work)
            timers.append(timer)
            return timer
        }
    }

    /// Fires every timer due up to now + `interval`, including ones scheduled by fired work. Never call
    /// from the queue a timer runs on.
    func advance(by interval: TimeInterval) {
        let target = lock.withLock { time + interval }
        while let timer = nextDue(upTo: target) {
            timer.queue.sync { if !timer.isCancelled { timer.work() } }
        }
        lock.withLock { time = max(time, target) }
    }

    private func nextDue(upTo target: TimeInterval) -> ManualTimer? {
        lock.withLock {
            timers.removeAll { $0.isCancelled }
            guard let next = timers.filter({ $0.fireAt <= target })
                .min(by: { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }) else { return nil }
            timers.removeAll { $0 === next }
            time = max(time, next.fireAt)
            return next
        }
    }

    var pendingTimerCount: Int { lock.withLock { timers.filter { !$0.isCancelled }.count } }
}

/// Scripted transport: records every send and close; `emit` delivers events on the engine queue.
final class FakeTransport: PortlightTransport, @unchecked Sendable {
    // Invariant: `connection`, `sentStorage` and `closes` are only touched while holding `lock`.
    struct Connection {
        let endpoint: HostEndpoint
        let pin: CertificateFingerprint?
        let generation: ConnectionGeneration
        let queue: DispatchQueue
        let onEvent: (ConnectionGeneration, TransportEvent) -> Void
    }
    let number: Int
    private let log: EventLog
    private let lock = NSLock()
    private var connection: Connection?
    private var sentStorage: [OutboundMessage] = []
    private var closes = 0

    init(number: Int, log: EventLog) { self.number = number; self.log = log }

    func connect(to endpoint: HostEndpoint, pin: CertificateFingerprint?, generation: ConnectionGeneration,
                 queue: DispatchQueue, onEvent: @escaping (ConnectionGeneration, TransportEvent) -> Void) {
        lock.withLock { connection = Connection(endpoint: endpoint, pin: pin, generation: generation, queue: queue, onEvent: onEvent) }
    }
    func send(_ message: OutboundMessage) {
        lock.withLock { sentStorage.append(message) }
        log.append(.sent(transport: number, message))
    }
    func close() { lock.withLock { closes += 1 } }

    /// Delivers one event synchronously on the engine queue, tagged with this attempt's generation
    /// (or a forged one, to prove the engine checks).
    func emit(_ event: TransportEvent, generation forged: ConnectionGeneration? = nil) {
        guard let current = lock.withLock({ self.connection }) else { preconditionFailure("emit before connect") }
        current.queue.sync { current.onEvent(forged ?? current.generation, event) }
    }
    func emit(_ message: InboundMessage) { emit(.message(message)) }
    /// Queues one event behind whatever the engine queue is doing (for tests that park that queue).
    func emitAsync(_ event: TransportEvent) {
        guard let current = lock.withLock({ self.connection }) else { preconditionFailure("emit before connect") }
        let generation = current.generation, onEvent = current.onEvent
        current.queue.async { onEvent(generation, event) }
    }

    var sent: [OutboundMessage] { lock.withLock { sentStorage } }
    var closeCount: Int { lock.withLock { closes } }
    var generation: ConnectionGeneration? { lock.withLock { connection?.generation } }
    var pin: CertificateFingerprint? { lock.withLock { connection?.pin } }
    var endpoint: HostEndpoint? { lock.withLock { connection?.endpoint } }
    var hellos: [String] { sent.compactMap { if case .hello(let password) = $0 { return password }; return nil } }
    var subscribes: [SubscriptionRequest] { sent.compactMap { if case .subscribe(let request) = $0 { return request }; return nil } }
    var acks: [Int] { sent.compactMap { if case .frameAck(let sequence) = $0 { return sequence }; return nil } }
    var pings: [Double] { sent.compactMap { if case .ping(let time) = $0 { return time }; return nil } }
    var inputs: [OutboundMessage] { sent.filter(\.isInput) }
}

/// Creates one FakeTransport per connect, as the production factory creates one WebSocket per attempt.
final class TransportRegistry: @unchecked Sendable {
    // Invariant: `list` is only touched while holding `lock`.
    private let lock = NSLock()
    private let log: EventLog
    private var list: [FakeTransport] = []
    init(log: EventLog) { self.log = log }
    func make() -> FakeTransport {
        lock.withLock {
            let transport = FakeTransport(number: list.count + 1, log: log)
            list.append(transport)
            return transport
        }
    }
    var all: [FakeTransport] { lock.withLock { list } }
}

/// Records acceptRevision/commit order. Like `SurfaceLedger`, only patches of the newest accepted revision
/// land; chosen sequences can also be refused as stale (a local loss) or failed.
/// Staging memory is PortlightKit's own `HeapPatchBuffer`; no test double shadows that name target-wide.
final class FakeFramebufferSink: FramebufferSink, @unchecked Sendable {
    // Invariant: every `var` is only touched while holding `lock`.
    struct Acceptance: Equatable {
        let revision: Int
        let canvases: [DisplayID: PixelSize]
        let regions: [DisplayID: NormalizedRect]
    }
    private let lock = NSLock()
    private let log: EventLog
    private var acceptances: [Acceptance] = []
    private var commitHeaders: [FrameHeader] = []
    private var committedSequences: [Int] = []
    private var staleSet: Set<Int> = []
    private var failSet: Set<Int> = []
    private var allocationFails = false
    private var removeAllCalls = 0

    init(log: EventLog) { self.log = log }

    var staleSequences: Set<Int> {
        get { lock.withLock { staleSet } }
        set { lock.withLock { staleSet = newValue } }
    }
    var failedSequences: Set<Int> {
        get { lock.withLock { failSet } }
        set { lock.withLock { failSet = newValue } }
    }
    var failAllocation: Bool {
        get { lock.withLock { allocationFails } }
        set { lock.withLock { allocationFails = newValue } }
    }
    var accepted: [Acceptance] { lock.withLock { acceptances } }
    /// Every commit call, whatever its result.
    var commits: [FrameHeader] { lock.withLock { commitHeaders } }
    /// Sequences whose commit returned `.committed`.
    var committed: [Int] { lock.withLock { committedSequences } }
    var removeAllCount: Int { lock.withLock { removeAllCalls } }

    func acceptRevision(_ revision: Int, canvases: [DisplayID: PixelSize], requestedRegions: [DisplayID: NormalizedRect]) {
        lock.withLock { acceptances.append(Acceptance(revision: revision, canvases: canvases, regions: requestedRegions)) }
        log.append(.accept(revision: revision))
    }
    func makePatchBuffer(byteCount: Int) -> PatchBuffer? {
        if lock.withLock({ allocationFails }) { return nil }
        return HeapPatchBuffer(byteCount: byteCount)
    }
    func commit(_ patch: DecodedPatch) -> PatchCommitResult {
        let result = lock.withLock { () -> PatchCommitResult in
            commitHeaders.append(patch.header)
            let sequence = patch.header.sequence
            if failSet.contains(sequence) { return .failed }
            guard !staleSet.contains(sequence), acceptances.last?.revision == patch.header.revision else { return .stale }
            committedSequences.append(sequence)
            return .committed
        }
        log.append(.commit(revision: patch.header.revision, sequence: patch.header.sequence))
        return result
    }
    func hasValidPixels(display: DisplayID, x: Double, y: Double) -> Bool { true }
    func removeAll() { lock.withLock { removeAllCalls += 1 } }
}

final class FakeAudioSink: AudioPacketSink, @unchecked Sendable {
    // Invariant: every `var` is only touched while holding `lock`.
    struct Acknowledgement: Equatable {
        let configuration: AudioConfiguration?
        let revision: Int
    }
    private let lock = NSLock()
    private var acknowledgements: [Acknowledgement] = []
    private var packets: [AudioHeader] = []
    private var stops = 0

    var acks: [Acknowledgement] { lock.withLock { acknowledgements } }
    var submitted: [AudioHeader] { lock.withLock { packets } }
    var stopCount: Int { lock.withLock { stops } }

    func audioConfigurationAcknowledged(_ configuration: AudioConfiguration?, revision: Int) {
        lock.withLock { acknowledgements.append(Acknowledgement(configuration: configuration, revision: revision)) }
    }
    func submit(_ header: AudioHeader, payload: Data) { lock.withLock { packets.append(header) } }
    func stopAudio() { lock.withLock { stops += 1 } }
}

enum FakeDecodeError: Error { case corrupt, noBuffer }

/// Success/failure/nil-buffer/bad-stride decoder that can hold inside `decode` until released.
final class FakeDecoder: TileDecoding, @unchecked Sendable {
    // Invariant: every `var` is only touched while holding `lock`; waiting on `release` happens outside it.
    enum Mode { case success, failure, shortStride }
    private let lock = NSLock()
    private var modeValue = Mode.success
    private var failing: Set<Int> = []
    private var decodedSequences: [Int] = []
    private var holding = false
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    var mode: Mode {
        get { lock.withLock { modeValue } }
        set { lock.withLock { modeValue = newValue } }
    }
    var failSequences: Set<Int> {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    /// Sequences passed to `decode`, in call order.
    var decoded: [Int] { lock.withLock { decodedSequences } }

    /// Every later decode signals `started` and blocks until `releaseAll()`.
    func hold() { lock.withLock { holding = true } }
    func releaseAll() {
        lock.withLock { holding = false }
        release.signal()
    }
    /// Blocks (bounded) until a held decode has begun; not a sleep.
    func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 5) == .success }

    func decode(_ header: FrameHeader, payload: Data, allocate: (Int) -> PatchBuffer?) throws -> DecodedPatch {
        let (mode, fails, held) = lock.withLock { () -> (Mode, Bool, Bool) in
            decodedSequences.append(header.sequence)
            return (modeValue, failing.contains(header.sequence), holding)
        }
        if held { started.signal(); release.wait() }
        if mode == .failure || fails { throw FakeDecodeError.corrupt }
        let bytesPerRow = header.rect.width * 4
        guard let buffer = allocate(bytesPerRow * header.rect.height) else { throw FakeDecodeError.noBuffer }
        return DecodedPatch(header: header, buffer: buffer, bytesPerRow: mode == .shortStride ? bytesPerRow - 4 : bytesPerRow)
    }
}

/// Selects every display (max 16) on a fresh connection; intersects on a reconnect. Its revision is junk
/// on purpose: the engine must assign its own.
struct FakePlanner: SubscriptionPlanner {
    var resolution: ResolutionPreset = .hd
    func initialSubscription(for welcome: WelcomeMessage, previousSelection: [DisplayID]?) -> SubscriptionRequest {
        let valid = welcome.displays.map(\.id)
        let displays = previousSelection.map { $0.filter(valid.contains) } ?? Array(valid.prefix(PortlightProtocol.maxSubscribedDisplays))
        return SubscriptionRequest(revision: 999, displays: displays, resolution: resolution, color: .full, quality: .automatic)
    }
}

final class RecordingDelegate: SessionEngineDelegate, @unchecked Sendable {
    // Invariant: `storage` and `snapshots` are only touched while holding `lock`.
    enum Event: Equatable {
        case phase(ConnectionPhase)
        case welcome(WelcomeMessage, topologyChange: Bool)
        case sent(SubscriptionRequest)
        case accepted(SubscribedMessage, SubscriptionRequest)
        case hostReported(HostErrorMessage)
        case cursor(CursorMessage)
        case stats(StatsMessage)
        case recovery(String)
        case budgetExceeded(SubscribedMessage)
    }
    private let lock = NSLock()
    private var storage: [Event] = []
    private var snapshots: [EngineDiagnostics] = []

    var events: [Event] { lock.withLock { storage } }
    var diagnostics: [EngineDiagnostics] { lock.withLock { snapshots } }
    var phases: [ConnectionPhase] { events.compactMap { if case .phase(let phase) = $0 { return phase }; return nil } }
    var recoveries: [String] { events.compactMap { if case .recovery(let reason) = $0 { return reason }; return nil } }
    var hostReports: [HostErrorMessage] { events.compactMap { if case .hostReported(let error) = $0 { return error }; return nil } }
    var budgetExceeded: [SubscribedMessage] { events.compactMap { if case .budgetExceeded(let ack) = $0 { return ack }; return nil } }
    var accepted: [SubscribedMessage] { events.compactMap { if case .accepted(let ack, _) = $0 { return ack }; return nil } }

    private func add(_ event: Event) { lock.withLock { storage.append(event) } }
    func engine(_ engine: SessionEngine, phaseDidChange phase: ConnectionPhase) { add(.phase(phase)) }
    func engine(_ engine: SessionEngine, didReceiveWelcome welcome: WelcomeMessage, topologyChange: Bool) {
        add(.welcome(welcome, topologyChange: topologyChange))
    }
    func engine(_ engine: SessionEngine, didSend request: SubscriptionRequest) { add(.sent(request)) }
    func engine(_ engine: SessionEngine, didAccept ack: SubscribedMessage, for request: SubscriptionRequest) {
        add(.accepted(ack, request))
    }
    func engine(_ engine: SessionEngine, hostReported error: HostErrorMessage) { add(.hostReported(error)) }
    func engine(_ engine: SessionEngine, cursor: CursorMessage) { add(.cursor(cursor)) }
    func engine(_ engine: SessionEngine, stats: StatsMessage) { add(.stats(stats)) }
    func engine(_ engine: SessionEngine, diagnostics: EngineDiagnostics) { lock.withLock { snapshots.append(diagnostics) } }
    func engine(_ engine: SessionEngine, needsRecoverySubscription reason: String) { add(.recovery(reason)) }
    func engine(_ engine: SessionEngine, canvasBudgetExceeded ack: SubscribedMessage) { add(.budgetExceeded(ack)) }
}

final class RecordingTranscript: TranscriptSink, @unchecked Sendable {
    // Invariant: `storage` is only touched while holding `lock`.
    private let lock = NSLock()
    private var storage: [String] = []
    func record(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}
