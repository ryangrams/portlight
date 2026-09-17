import Foundation

// Seams between the session engine and the network/time. Production: WebSocketTransport and
// SystemSessionClock. Tests: scripted fakes that make ordering, deadlines and generations deterministic.

/// Everything a transport reports for one connection attempt, in order, on the engine's queue.
public enum TransportEvent: Sendable {
    /// The host's certificate matched the pinned fingerprint; the handshake continues.
    case identityVerified(CertificateFingerprint)
    /// Unknown or changed certificate. The attempt was canceled before any application data was sent.
    case trustRequired(TrustPrompt)
    /// The WebSocket is open over trusted TLS; `hello` may be sent now.
    case opened
    /// One decoded message, in arrival order.
    case message(InboundMessage)
    /// Terminal for this generation. No further events follow.
    case closed(ConnectionFailure)
}

/// One Portlight WebSocket connection at a time. Every event carries the generation it belongs to, and
/// a transport never delivers an event for a generation older than its current one.
public protocol PortlightTransport: AnyObject {
    /// Starts an attempt. `pin` nil means first use: any certificate yields `.trustRequired`.
    /// Events are delivered serially on `queue`.
    func connect(to endpoint: HostEndpoint, pin: CertificateFingerprint?, generation: ConnectionGeneration,
                 queue: DispatchQueue, onEvent: @escaping (ConnectionGeneration, TransportEvent) -> Void)
    /// Encodes and sends in call order. Call on the engine queue. Ignored when not open.
    func send(_ message: OutboundMessage)
    /// Graceful close (WebSocket going-away). Invalidates the current generation; no further events.
    /// Idempotent, and safe after the transport has already closed itself: the engine creates one
    /// transport per connect and closes it after trust prompts, deadlines and fatal errors.
    func close()
}

/// A scheduled piece of work that can be canceled.
public protocol Cancellable: AnyObject {
    func cancel()
}

/// Monotonic time and timers, injectable for deterministic tests.
public protocol SessionClock: Sendable {
    /// Monotonic seconds (not wall-clock).
    func now() -> TimeInterval
    func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> Cancellable
}

/// Production clock: monotonic uptime and DispatchSourceTimer-backed one-shot timers.
public struct SystemSessionClock: SessionClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return WorkItemCancellable(item)
    }
}

private final class WorkItemCancellable: Cancellable {
    private let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}
