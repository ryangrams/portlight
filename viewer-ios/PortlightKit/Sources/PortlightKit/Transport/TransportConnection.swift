import Foundation

/// One connection attempt behind `WebSocketTransport`: the URLSession delegate plus the per-attempt state machine.
/// Inputs arrive on the attempt's delegate queue (an OperationQueue on the caller's queue); events leave through
/// `deliver`, which drops everything once the transport has moved on to another attempt or closed.
final class TransportConnection: NSObject, @unchecked Sendable {
    // Invariant for @unchecked Sendable: `state`, `socket` and `verified` are only touched under `lock`,
    // which is never held while calling out; every other stored property is immutable after init.
    enum State { case connecting, open, finished }

    let epoch: UInt64
    let generation: ConnectionGeneration
    let endpoint: HostEndpoint
    let pin: CertificateFingerprint?
    let delegateQueue: OperationQueue
    private weak var transport: WebSocketTransport?
    private let onEvent: (ConnectionGeneration, TransportEvent) -> Void
    private let lock = NSLock()
    private var state = State.connecting
    private var socket: TransportSocket?
    /// Set once this attempt accepted a certificate matching the pin. `.opened` requires it.
    private var verified = false

    init(epoch: UInt64, generation: ConnectionGeneration, endpoint: HostEndpoint, pin: CertificateFingerprint?,
         delegateQueue: OperationQueue, transport: WebSocketTransport,
         onEvent: @escaping (ConnectionGeneration, TransportEvent) -> Void) {
        self.epoch = epoch; self.generation = generation; self.endpoint = endpoint; self.pin = pin
        self.delegateQueue = delegateQueue; self.transport = transport; self.onEvent = onEvent
        super.init()
    }

    var isFinished: Bool { lock.withLock { state == .finished } }

    // MARK: Commands from the transport

    func start(with socket: TransportSocket) {
        let live = lock.withLock { () -> Bool in
            guard state != .finished else { return false }
            self.socket = socket
            return true
        }
        if live { socket.start() } else { socket.shutdown() }
    }

    /// Ends the attempt without reporting anything (close, or a newer connect on the same transport).
    func cancel() {
        let socket = lock.withLock { () -> TransportSocket? in
            defer { state = .finished }
            return state == .finished ? nil : self.socket
        }
        socket?.shutdown()
    }

    /// Reports a failure found before any socket existed, asynchronously like every other event.
    func failBeforeStart(_ failure: ConnectionFailure) {
        delegateQueue.addOperation { [self] in finish(.closed(failure)) }
    }

    /// Encodes and sends while open; ignored before `.opened` and after the attempt ended.
    func send(_ message: OutboundMessage) {
        guard let socket = lock.withLock({ state == .open ? self.socket : nil }) else { return }
        let text: String
        do {
            text = try PortlightWire.encode(message)
        } catch {
            // The engine only builds valid messages. The error is not interpolated: a hello carries the password.
            assertionFailure("An outbound Portlight message could not be encoded")
            return
        }
        socket.send(text) { [weak self] error in
            guard let error else { return }
            self?.onDelegateQueue { $0.sendFailed(error) }
        }
    }

    // MARK: Inputs (delegate queue)

    func didOpen() {
        enum Outcome { case ignored, unverified, opened }
        let outcome = lock.withLock { () -> Outcome in
            guard state == .connecting else { return .ignored }
            guard verified else { return .unverified }
            state = .open
            return .opened
        }
        switch outcome {
        case .ignored:
            return
        case .unverified:
            // `.opened` means "trusted TLS, send hello". URLSession asked about the certificate on every measured
            // attempt, but the promise is kept here rather than assumed: without a pin match in this attempt (a
            // resumed TLS session or a skipped challenge), the socket never carries the password.
            finish(.closed(.tlsFailed(TransportFailureClassifier.certificateUnchecked)))
        case .opened:
            deliver(.opened)
            receiveNext()
        }
    }

    func didReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard lock.withLock({ state == .open }) else { return }
        switch result {
        case .success(let message):
            do {
                deliver(.message(try Self.decode(message)))
            } catch let error as ProtocolError {
                finish(.closed(.protocolViolation(TransportFailureClassifier.violationReason(error))))
                return
            } catch {
                finish(.closed(.protocolViolation("an unknown kind of WebSocket message")))
                return
            }
            receiveNext()
        case .failure(let error):
            finish(.closed(failure(for: error)))
        }
    }

    /// The host's WebSocket close frame.
    func didReceiveCloseFrame() {
        finish(.closed(.hostClosed))
    }

    func didComplete(error: Error?) {
        guard !isFinished else { return }
        if let error {
            finish(.closed(failure(for: error)))
        } else {
            // No error: after the upgrade that's an orderly close; before it, the host answered without upgrading.
            let wasOpen = lock.withLock { state == .open }
            finish(.closed(wasOpen ? .hostClosed : .protocolViolation(TransportFailureClassifier.upgradeRefused)))
        }
    }

    func sendFailed(_ error: Error) {
        guard !isFinished else { return }
        finish(.closed(receivedCloseFrame ? .hostClosed : .networkLost))
    }

    /// Answers one server-trust challenge exactly once through `answer` (true: use the presented trust).
    /// Only an exact pin match is ever accepted, and never for an attempt that has ended.
    func handleServerTrust(leafCertificateDER der: Data?, answer: (Bool) -> Void) {
        guard !isFinished else { answer(false); return }
        switch ServerTrustPolicy.verdict(leafCertificateDER: der, pin: pin) {
        case .matchesPin(let fingerprint):
            let first = lock.withLock { () -> Bool in
                defer { verified = true }
                return !verified
            }
            if first { deliver(.identityVerified(fingerprint)) }
            // The consumer may have ended the attempt while handling the event.
            answer(!isFinished)
        case .needsApproval(let fingerprint):
            answer(false)
            if lock.withLock({ verified }) {
                // One attempt has one identity. After the pin matched, another certificate is neither a first use
                // nor a change to approve (`.trustRequired` promises nothing was sent, and hello may have been): the
                // peer switched certificates inside the connection.
                finish(.closed(.tlsFailed(TransportFailureClassifier.certificateSwitched)))
            } else {
                finish(.trustRequired(TrustPrompt(endpoint: endpoint, fingerprint: fingerprint, previousFingerprint: pin)))
            }
        case .noCertificate:
            answer(false)
            finish(.closed(.tlsFailed("the host presented no certificate")))
        }
    }

    /// A redirect could lead to another identity; the attempt ends instead.
    func refuseRedirect() {
        finish(.closed(.protocolViolation(TransportFailureClassifier.redirectRefused)))
    }

    // MARK: Internals

    static func decode(_ message: URLSessionWebSocketTask.Message) throws -> InboundMessage {
        switch message {
        case .string(let text): return try PortlightWire.decodeText(text)
        case .data(let data): return try PortlightWire.decodeBinary(data)
        @unknown default: throw UnknownMessageKind()
        }
    }

    private struct UnknownMessageKind: Error {}

    private var receivedCloseFrame: Bool { lock.withLock { socket }?.receivedCloseFrame ?? false }

    private func failure(for error: Error) -> ConnectionFailure {
        if receivedCloseFrame { return .hostClosed }
        let established = lock.withLock { state == .open }
        return TransportFailureClassifier.classify(error, host: endpoint.host, established: established,
                                                   deviceNetwork: transport?.deviceNetwork() ?? .unknown)
    }

    /// One receive at a time: the next is requested only after the previous message was delivered.
    private func receiveNext() {
        guard let socket = lock.withLock({ state == .open ? self.socket : nil }) else { return }
        socket.receive { [weak self] result in
            self?.onDelegateQueue { $0.didReceive(result) }
        }
    }

    /// Terminal: marks the attempt finished and stops the socket, then reports `event` unless superseded.
    private func finish(_ event: TransportEvent) {
        let (first, socket) = lock.withLock { () -> (Bool, TransportSocket?) in
            guard state != .finished else { return (false, nil) }
            state = .finished
            return (true, self.socket)
        }
        guard first else { return }
        socket?.shutdown()
        deliver(event)
    }

    private func deliver(_ event: TransportEvent) {
        guard let transport, transport.isCurrent(self) else { return }
        onEvent(generation, event)
    }

    /// Socket completions run on the delegate queue: inline when URLSession already delivered them there, which
    /// keeps them ordered with delegate calls, otherwise queued behind them.
    private func onDelegateQueue(_ work: @escaping @Sendable (TransportConnection) -> Void) {
        if OperationQueue.current === delegateQueue {
            work(self)
        } else {
            delegateQueue.addOperation { [self] in work(self) }
        }
    }
}

extension TransportConnection: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        didOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        didReceiveCloseFrame()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        didComplete(error: error)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        refuseRedirect()
    }

    /// Server trust is decided by the pin alone; every other challenge type gets default handling.
    private func answer(_ challenge: URLAuthenticationChallenge,
                        _ completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completion(.performDefaultHandling, nil)
            return
        }
        let trust = challenge.protectionSpace.serverTrust
        handleServerTrust(leafCertificateDER: trust.flatMap(ServerTrustPolicy.leafCertificateDER(of:))) { accept in
            if accept, let trust {
                completion(.useCredential, URLCredential(trust: trust))
            } else {
                completion(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
