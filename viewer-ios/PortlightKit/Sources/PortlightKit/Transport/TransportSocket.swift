import Foundation

/// The socket operations `WebSocketTransport` drives for one attempt. Production: `URLSessionSocket`. Unit tests
/// substitute a scripted socket so generation isolation is testable without a network.
protocol TransportSocket: AnyObject, Sendable {
    /// Starts TCP, TLS and the WebSocket upgrade.
    func start()
    /// One receive. The completion runs on the attempt's delegate queue.
    func receive(_ completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func send(_ text: String, _ completion: @escaping @Sendable (Error?) -> Void)
    /// True once the host's WebSocket close frame has arrived.
    var receivedCloseFrame: Bool { get }
    /// Going-away close, then session invalidation. Idempotent.
    func shutdown()
}

/// One ephemeral URLSession per attempt, owning one WebSocket task. Delegate calls and completions are
/// delivered serially on the delegate queue.
final class URLSessionSocket: TransportSocket, @unchecked Sendable {
    // Invariant for @unchecked Sendable: `session` and `task` are immutable references to thread-safe
    // Foundation objects; `didShutdown` is only touched under `lock`.

    /// Per-request timeout. The engine owns the real 10 s connect deadline; this only reaps an abandoned attempt.
    static let requestTimeout: TimeInterval = 15

    let session: URLSession
    let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var didShutdown = false

    init(url: URL, delegate: URLSessionDelegate, delegateQueue: OperationQueue) {
        session = URLSession(configuration: Self.configuration(), delegate: delegate, delegateQueue: delegateQueue)
        task = session.webSocketTask(with: url)
        // The 1 MiB default would reject the host's larger keyframes.
        task.maximumMessageSize = PortlightProtocol.maxBinaryMessageBytes
    }

    /// Ephemeral and stateless: no cookies, cache or credential storage outlive the attempt.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        // Fail fast when there is no path; retries are the engine's decision.
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    func start() { task.resume() }

    func receive(_ completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        task.receive(completionHandler: completion)
    }

    func send(_ text: String, _ completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }

    var receivedCloseFrame: Bool { task.closeCode != .invalid }

    func shutdown() {
        guard lock.withLock({ () -> Bool in
            defer { didShutdown = true }
            return !didShutdown
        }) else { return }
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
