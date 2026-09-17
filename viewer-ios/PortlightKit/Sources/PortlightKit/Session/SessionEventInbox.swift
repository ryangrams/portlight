import Foundation

// The single ordered path from other queues into the main-actor controller: engine callbacks (delivered
// on the controller's private event queue) and the controller's own timers are posted here in order and
// drained on the main actor. Tests drain it synchronously, which keeps every session test deterministic.

enum SessionTimer: Equatable, Sendable {
    /// Region refinement settle deadline.
    case settle
    /// Next automatic reconnect attempt.
    case reconnect
    /// Next batch of typed text (`SessionController.typingBatchInterval`).
    case typing
}

/// One engine callback, as the relay received it.
enum EngineCallback: Sendable {
    case phase(ConnectionPhase)
    case welcome(WelcomeMessage, topologyChange: Bool)
    case sent(SubscriptionRequest)
    case accepted(SubscribedMessage, SubscriptionRequest)
    case hostReported(HostErrorMessage)
    case cursor(CursorMessage)
    case stats(StatsMessage)
    case diagnostics(EngineDiagnostics)
    case recovery(String)
    case budgetExceeded(SubscribedMessage)
}

enum SessionEvent: Sendable {
    /// An engine callback with the relay's stamp at delivery. Only the stamp of the latest connect, disconnect or
    /// cancel (`SessionController.issue`) is current; a callback with an older one belongs to a retired generation.
    case engine(EngineCallback, stamp: UInt64)
    case timer(SessionTimer, token: UInt64)
}

/// FIFO of pending events. `post` may be called from any thread; the wake handler schedules one
/// main-actor drain per batch.
final class SessionEventInbox: @unchecked Sendable {
    // Invariant for @unchecked Sendable: `events`, `drainScheduled` and `wake` are only touched while
    // holding `lock`; the wake handler itself runs outside it.
    private let lock = NSLock()
    private var events: [SessionEvent] = []
    private var drainScheduled = false
    private var wake: (@Sendable () -> Void)?

    func setWake(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { wake = handler }
    }

    func post(_ event: SessionEvent) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            events.append(event)
            guard !drainScheduled, let wake else { return nil }
            drainScheduled = true
            return wake
        }
        handler?()
    }

    /// Everything posted so far, in order.
    func takeAll() -> [SessionEvent] {
        lock.withLock {
            drainScheduled = false
            let taken = events
            events.removeAll()
            return taken
        }
    }

    var pendingCount: Int { lock.withLock { events.count } }
}

/// The engine's delegate: forwards each callback into the inbox, in engine order, stamped with the engine command
/// it belongs to.
final class SessionEngineRelay: SessionEngineDelegate, @unchecked Sendable {
    // Invariant for @unchecked Sendable: `inbox` is immutable and itself thread-safe. `stamp` is only read or
    // written on the controller's event queue: the engine delivers every callback there (it is the engine's
    // delegate queue), and the controller changes it only inside `eventQueue.sync` (`SessionController.issue`).
    let inbox: SessionEventInbox
    var stamp: UInt64 = 0
    init(inbox: SessionEventInbox) { self.inbox = inbox }

    private func forward(_ callback: EngineCallback) { inbox.post(.engine(callback, stamp: stamp)) }

    func engine(_ engine: SessionEngine, phaseDidChange phase: ConnectionPhase) { forward(.phase(phase)) }
    func engine(_ engine: SessionEngine, didReceiveWelcome welcome: WelcomeMessage, topologyChange: Bool) {
        forward(.welcome(welcome, topologyChange: topologyChange))
    }
    func engine(_ engine: SessionEngine, didSend request: SubscriptionRequest) { forward(.sent(request)) }
    func engine(_ engine: SessionEngine, didAccept ack: SubscribedMessage, for request: SubscriptionRequest) {
        forward(.accepted(ack, request))
    }
    func engine(_ engine: SessionEngine, hostReported error: HostErrorMessage) { forward(.hostReported(error)) }
    func engine(_ engine: SessionEngine, cursor: CursorMessage) { forward(.cursor(cursor)) }
    func engine(_ engine: SessionEngine, stats: StatsMessage) { forward(.stats(stats)) }
    func engine(_ engine: SessionEngine, diagnostics: EngineDiagnostics) { forward(.diagnostics(diagnostics)) }
    func engine(_ engine: SessionEngine, needsRecoverySubscription reason: String) { forward(.recovery(reason)) }
    func engine(_ engine: SessionEngine, canvasBudgetExceeded ack: SubscribedMessage) { forward(.budgetExceeded(ack)) }
}
