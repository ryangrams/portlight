import Foundation

/// The production `PortlightTransport`: one URLSession and `URLSessionWebSocketTask` per `connect`, pinned-certificate
/// TLS, strict message decoding and classified failures.
///
/// Trust is probe-then-pin (DECISIONS.md). The certificate is accepted only when the SHA-256 of its leaf DER equals
/// the pin. Anything else cancels the TLS handshake before the WebSocket upgrade, so no application data (never the
/// password) is sent, and reports `.trustRequired`. No other path ever accepts a certificate, and redirects are
/// refused. `.opened` is delivered only after the same attempt accepted the pinned certificate, and a second,
/// different certificate within one attempt ends it as `.tlsFailed` rather than asking for approval.
///
/// Threading: events are delivered serially on the queue passed to `connect` (URLSession's delegate queue is an
/// OperationQueue on top of it). Call `connect` and `send` on that queue. `close()` may be called from any thread;
/// called on the delivery queue, as the engine does, no event of the closed attempt is delivered after it returns.
public final class WebSocketTransport: PortlightTransport, @unchecked Sendable {
    // Invariant for @unchecked Sendable: `epoch` and `current` are only touched under `lock`, which is never held
    // while calling out to a socket or an event handler.
    typealias SocketFactory = (URL, TransportConnection, OperationQueue) -> TransportSocket

    private let makeSocket: SocketFactory
    /// Whether the device has any network, read when a failure is classified.
    private let readDeviceNetwork: @Sendable () -> DeviceNetwork
    private let lock = NSLock()
    /// Bumped by every connect and close. Only the attempt stamped with the current epoch may deliver events.
    private var epoch: UInt64 = 0
    private var current: TransportConnection?

    public convenience init() {
        Self.startMonitoringNetwork()
        self.init(socketFactory: { url, connection, delegateQueue in
            URLSessionSocket(url: url, delegate: connection, delegateQueue: delegateQueue)
        }, deviceNetwork: { DeviceNetworkMonitor.shared.status })
    }

    init(socketFactory: @escaping SocketFactory, deviceNetwork: @escaping @Sendable () -> DeviceNetwork = { .unknown }) {
        makeSocket = socketFactory
        readDeviceNetwork = deviceNetwork
    }

    /// Starts watching whether the device has any network (idempotent), so that even the first failed connection can
    /// tell an offline iPhone from a computer it has no route to. Call it at launch; `init()` calls it too.
    public static func startMonitoringNetwork() {
        DeviceNetworkMonitor.shared.start()
    }

    func deviceNetwork() -> DeviceNetwork { readDeviceNetwork() }

    deinit { close() }

    public func connect(to endpoint: HostEndpoint, pin: CertificateFingerprint?, generation: ConnectionGeneration,
                        queue: DispatchQueue, onEvent: @escaping (ConnectionGeneration, TransportEvent) -> Void) {
        let delegateQueue = Self.makeDelegateQueue(on: queue)
        let (connection, superseded) = lock.withLock { () -> (TransportConnection, TransportConnection?) in
            epoch &+= 1
            let connection = TransportConnection(epoch: epoch, generation: generation, endpoint: endpoint, pin: pin,
                                                 delegateQueue: delegateQueue, transport: self, onEvent: onEvent)
            defer { current = connection }
            return (connection, current)
        }
        superseded?.cancel()
        guard let url = endpoint.webSocketURL else {
            connection.failBeforeStart(.invalidAddress)
            return
        }
        connection.start(with: makeSocket(url, connection, delegateQueue))
    }

    public func send(_ message: OutboundMessage) {
        lock.withLock { current }?.send(message)
    }

    public func close() {
        let closing = lock.withLock { () -> TransportConnection? in
            epoch &+= 1
            defer { current = nil }
            return current
        }
        closing?.cancel()
    }

    /// Whether `connection` still belongs to the current epoch.
    func isCurrent(_ connection: TransportConnection) -> Bool {
        lock.withLock { connection.epoch == epoch }
    }

    /// Serial, and on `queue`, so every URLSession callback is ordered with the caller's own work.
    static func makeDelegateQueue(on queue: DispatchQueue) -> OperationQueue {
        // An OperationQueue can't sit on the main queue; OperationQueue.main already runs serially there.
        if queue === DispatchQueue.main { return OperationQueue.main }
        let operations = OperationQueue()
        operations.name = "studio.upgrade.portlight.transport"
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue
        return operations
    }
}
