import Foundation
import Security
@testable import PortlightKit

// Foundation-typed helpers for the Transport tests. This file must not import Testing: the Command Line Tools
// ship `_Testing_Foundation` without its module, so a file importing both fails to compile. The @Test files
// import only Testing and PortlightKit and reach Foundation types through the helpers here.

/// Equatable mirror of `TransportEvent` for assertions.
enum TransportRecorded: Equatable, Sendable, CustomStringConvertible {
    case identityVerified(CertificateFingerprint)
    case trustRequired(TrustPrompt)
    case opened
    case message(InboundMessage)
    case closed(ConnectionFailure)

    init(_ event: TransportEvent) {
        switch event {
        case .identityVerified(let fingerprint): self = .identityVerified(fingerprint)
        case .trustRequired(let prompt): self = .trustRequired(prompt)
        case .opened: self = .opened
        case .message(let message): self = .message(message)
        case .closed(let failure): self = .closed(failure)
        }
    }

    /// `.trustRequired` and `.closed` end an attempt.
    var isTerminal: Bool {
        switch self {
        case .trustRequired, .closed: return true
        case .identityVerified, .opened, .message: return false
        }
    }

    var description: String {
        switch self {
        case .identityVerified: return "identityVerified"
        case .trustRequired(let prompt): return "trustRequired(\(prompt.fingerprint)\(prompt.isChange ? ", changed" : ""))"
        case .opened: return "opened"
        case .message(.frame(let header, let payload)):
            return "frame(\(header.display) rev \(header.revision) seq \(header.sequence) \(header.rect) \(payload.count) B)"
        case .message(let message): return "message(\(String(describing: message).prefix(160)))"
        case .closed(let failure): return "closed(\(failure))"
        }
    }
}

/// A lock-guarded value for results captured by @Sendable callbacks.
final class TransportBox<Value>: @unchecked Sendable {
    // Invariant: `stored` is only touched under `lock`.
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - Scripted sockets

/// A socket the unit tests script by hand. Like URLSession it retains its delegate (the attempt) and hands every
/// callback to the attempt's delegate queue; each control waits until that work has run.
final class TransportScriptedSocket: TransportSocket, @unchecked Sendable {
    // Invariant: every `var` is only touched under `lock`; callbacks run outside it.
    typealias ReceiveCompletion = @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    static let dummyURL = URL(string: "https://192.168.1.20:5920/remote")!

    let url: URL
    let connection: TransportConnection
    let delegateQueue: OperationQueue
    private let lock = NSLock()
    private var starts = 0
    private var shutdowns = 0
    private var receives: [ReceiveCompletion] = []
    private var sends: [(text: String, completion: @Sendable (Error?) -> Void)] = []
    private var closeFrame = false

    init(url: URL, connection: TransportConnection, delegateQueue: OperationQueue) {
        self.url = url; self.connection = connection; self.delegateQueue = delegateQueue
    }

    // TransportSocket
    func start() { lock.withLock { starts += 1 } }
    func receive(_ completion: @escaping ReceiveCompletion) { lock.withLock { receives.append(completion) } }
    func send(_ text: String, _ completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { sends.append((text, completion)) }
    }
    var receivedCloseFrame: Bool { lock.withLock { closeFrame } }
    func shutdown() { lock.withLock { shutdowns += 1 } }

    // Observations
    var urlString: String { url.absoluteString }
    var startCount: Int { lock.withLock { starts } }
    var shutdownCount: Int { lock.withLock { shutdowns } }
    var pendingReceiveCount: Int { lock.withLock { receives.count } }
    var sentTexts: [String] { lock.withLock { sends.map { $0.text } } }

    // Controls
    /// The WebSocket opens, with no certificate check first. Real sockets never do this; see `handshake`.
    func open() { onDelegateQueue { $0.didOpen() } }
    /// What URLSession does on every attempt (measured against the fixture and mock hosts): the host's certificate is
    /// checked, then the WebSocket opens. Returns the challenge's answers.
    @discardableResult func handshake(leafDER: Data = TransportTestCertificate.der) -> [Bool] {
        let answers = challenge(leafDER: leafDER)
        open()
        return answers
    }
    /// Completes the oldest outstanding receive; false when none was outstanding.
    @discardableResult func receive(text: String) -> Bool { completeReceive(.success(.string(text))) }
    @discardableResult func receive(data: Data) -> Bool { completeReceive(.success(.data(data))) }
    @discardableResult func receive(bytes: [UInt8]) -> Bool { completeReceive(.success(.data(Data(bytes)))) }
    @discardableResult func failReceive(_ error: Error) -> Bool { completeReceive(.failure(error)) }
    func complete(error: Error?) { onDelegateQueue { $0.didComplete(error: error) } }
    func hostSendsCloseFrame() {
        markCloseFrameReceived()
        onDelegateQueue { $0.didReceiveCloseFrame() }
    }
    func markCloseFrameReceived() { lock.withLock { closeFrame = true } }
    /// Fails the send at `index`; false when no such send was made (so a test can't fail a send that never happened).
    @discardableResult func failSend(_ error: Error, at index: Int = 0) -> Bool {
        guard let completion = lock.withLock({ index < sends.count ? sends[index].completion : nil }) else { return false }
        delegateQueue.addOperation { completion(error) }
        delegateQueue.waitUntilAllOperationsAreFinished()
        return true
    }

    /// Presents a server-trust challenge for `leafDER` to the state machine; every answer given, in order.
    func challenge(leafDER: Data?) -> [Bool] {
        let answers = TransportBox<[Bool]>([])
        onDelegateQueue { connection in
            connection.handleServerTrust(leafCertificateDER: leafDER) { answers.value.append($0) }
        }
        return answers.value
    }

    /// Presents a challenge through the real URLSession delegate method (session- or task-level).
    func presentChallenge(_ method: TransportChallengeMethod, trust: SecTrust?, taskLevel: Bool = false) -> [TransportChallengeAnswer] {
        let answers = TransportBox<[TransportChallengeAnswer]>([])
        let space = TransportTrustSpace(method: method.authenticationMethod, trust: trust)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                   failureResponse: nil, error: nil, sender: TransportChallengeSender())
        onDelegateQueue { connection in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let record: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = {
                answers.value.append(TransportChallengeAnswer($0, $1))
            }
            if taskLevel {
                connection.urlSession(session, task: session.dataTask(with: Self.dummyURL), didReceive: challenge, completionHandler: record)
            } else {
                connection.urlSession(session, didReceive: challenge, completionHandler: record)
            }
        }
        return answers.value
    }

    /// Offers a redirect to another address through the real delegate method; true for each nil (refused) answer.
    func presentRedirect() -> [Bool] {
        let answers = TransportBox<[Bool]>([])
        onDelegateQueue { connection in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let target = URL(string: "wss://203.0.113.9:5920/remote")!
            let response = HTTPURLResponse(url: Self.dummyURL, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            connection.urlSession(session, task: session.dataTask(with: Self.dummyURL), willPerformHTTPRedirection: response,
                                  newRequest: URLRequest(url: target)) { answers.value.append($0 == nil) }
        }
        return answers.value
    }

    private func completeReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) -> Bool {
        guard let completion = lock.withLock({ receives.isEmpty ? nil : receives.removeFirst() }) else { return false }
        delegateQueue.addOperation { completion(result) }
        delegateQueue.waitUntilAllOperationsAreFinished()
        return true
    }

    private func onDelegateQueue(_ work: @escaping @Sendable (TransportConnection) -> Void) {
        let connection = connection
        delegateQueue.addOperation { work(connection) }
        delegateQueue.waitUntilAllOperationsAreFinished()
    }
}

enum TransportChallengeMethod: Sendable {
    case serverTrust, httpBasic
    var authenticationMethod: String {
        switch self {
        case .serverTrust: return NSURLAuthenticationMethodServerTrust
        case .httpBasic: return NSURLAuthenticationMethodHTTPBasic
        }
    }
}

enum TransportChallengeAnswer: Equatable, Sendable {
    case useCredential(hasCredential: Bool), performDefaultHandling, cancel, rejectProtectionSpace, unknown
    init(_ disposition: URLSession.AuthChallengeDisposition, _ credential: URLCredential?) {
        switch disposition {
        case .useCredential: self = .useCredential(hasCredential: credential != nil)
        case .performDefaultHandling: self = .performDefaultHandling
        case .cancelAuthenticationChallenge: self = .cancel
        case .rejectProtectionSpace: self = .rejectProtectionSpace
        @unknown default: self = .unknown
        }
    }
}

/// A protection space whose `serverTrust` is a real SecTrust, so the delegate's challenge path runs without a network.
final class TransportTrustSpace: URLProtectionSpace, @unchecked Sendable {
    // Invariant for @unchecked Sendable: `trustValue` is immutable (SecTrust is only read).
    private let trustValue: SecTrust?
    init(method: String, trust: SecTrust?) {
        trustValue = trust
        super.init(host: "192.168.1.20", port: 5920, protocol: NSURLProtectionSpaceHTTPS, realm: nil, authenticationMethod: method)
    }
    required init?(coder: NSCoder) { return nil }
    override var serverTrust: SecTrust? { trustValue }
}

final class TransportChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

// MARK: - Probe

/// A `WebSocketTransport` over scripted sockets, on a private serial queue standing in for the engine queue.
final class TransportUnitProbe: @unchecked Sendable {
    // Invariant: `recorded` and `reactionStorage` are only touched under `lock`; the transport is driven on `queue`.
    /// Never contacted: every socket is scripted.
    static let endpoint = HostEndpoint(host: "192.168.1.20", port: 5920)!

    final class Registry: @unchecked Sendable {
        // Invariant: `list` is only touched under `lock`.
        private let lock = NSLock()
        private var list: [TransportScriptedSocket] = []
        func make(url: URL, connection: TransportConnection, delegateQueue: OperationQueue) -> TransportScriptedSocket {
            let socket = TransportScriptedSocket(url: url, connection: connection, delegateQueue: delegateQueue)
            lock.withLock { list.append(socket) }
            return socket
        }
        var sockets: [TransportScriptedSocket] { lock.withLock { list } }
    }

    let queue = DispatchQueue(label: "studio.upgrade.portlight.tests.transport-unit")
    let transport: WebSocketTransport
    private let registry: Registry
    private let onQueueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var recorded: [(generation: UInt64, event: TransportRecorded, onQueue: Bool)] = []
    private var reactionStorage: (@Sendable (TransportRecorded, WebSocketTransport) -> Void)?

    init() {
        let registry = Registry()
        self.registry = registry
        transport = WebSocketTransport(socketFactory: { url, connection, delegateQueue in
            registry.make(url: url, connection: connection, delegateQueue: delegateQueue)
        })
        queue.setSpecific(key: onQueueKey, value: true)
    }

    /// Runs on the delivery queue after each recorded event, e.g. to close the transport inside a handler.
    var reaction: (@Sendable (TransportRecorded, WebSocketTransport) -> Void)? {
        get { lock.withLock { reactionStorage } }
        set { lock.withLock { reactionStorage = newValue } }
    }

    func connect(generation: UInt64, pin: CertificateFingerprint?, endpoint: HostEndpoint = TransportUnitProbe.endpoint) {
        queue.sync {
            transport.connect(to: endpoint, pin: pin, generation: ConnectionGeneration(rawValue: generation), queue: queue) { [self] generation, event in
                record(generation, event)
            }
        }
    }
    func send(_ message: OutboundMessage) { queue.sync { transport.send(message) } }
    func close() { queue.sync { transport.close() } }

    var sockets: [TransportScriptedSocket] { registry.sockets }
    func socket(_ index: Int) -> TransportScriptedSocket? {
        let all = sockets
        return index < all.count ? all[index] : nil
    }
    var events: [TransportRecorded] { lock.withLock { recorded.map { $0.event } } }
    var generations: [UInt64] { lock.withLock { recorded.map { $0.generation } } }
    var allDeliveredOnQueue: Bool { lock.withLock { recorded.allSatisfy { $0.onQueue } } }

    private func record(_ generation: ConnectionGeneration, _ event: TransportEvent) {
        let entry = TransportRecorded(event)
        let onQueue = DispatchQueue.getSpecific(key: onQueueKey) == true
        let reaction = lock.withLock { () -> (@Sendable (TransportRecorded, WebSocketTransport) -> Void)? in
            recorded.append((generation.rawValue, entry, onQueue))
            return reactionStorage
        }
        reaction?(entry, transport)
    }
}

// MARK: - Errors shaped like URLSession's

/// NSErrors in URLSession's shape: an NSURLErrorDomain error over a kCFErrorDomainCFNetwork error, both carrying the
/// CFStream domain/code keys and, optionally, the Network framework path description.
enum TransportErrors {
    static func url(_ code: Int, posix: Int32? = nil, tlsStatus: Int? = nil, netDB: Int? = nil, path: String? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let posix { info["_kCFStreamErrorDomainKey"] = 1; info["_kCFStreamErrorCodeKey"] = Int(posix) }
        if let tlsStatus { info["_kCFStreamErrorDomainKey"] = 3; info["_kCFStreamErrorCodeKey"] = tlsStatus }
        if let netDB { info["_kCFStreamErrorDomainKey"] = 12; info["_kCFStreamErrorCodeKey"] = netDB }
        if let path { info["_NSURLErrorNWPathKey"] = path }
        var outer = info
        outer[NSUnderlyingErrorKey] = NSError(domain: "kCFErrorDomainCFNetwork", code: code, userInfo: info)
        return NSError(domain: NSURLErrorDomain, code: code, userInfo: outer)
    }
    static func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    static func osStatus(_ status: Int) -> NSError { NSError(domain: NSOSStatusErrorDomain, code: status) }
    /// A Network framework error domain such as kNWErrorDomainPOSIX, kNWErrorDomainDNS or kNWErrorDomainTLS.
    static func network(_ domain: String, _ code: Int) -> NSError { NSError(domain: domain, code: code) }
    static func unknown() -> NSError { NSError(domain: "com.example.unrelated", code: 7) }
    /// `bottom` wrapped as the underlying error `depth` times.
    static func chain(depth: Int, bottom: NSError) -> NSError {
        (0..<depth).reduce(bottom) { inner, _ in NSError(domain: "com.example.wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: inner]) }
    }
}

// MARK: - Certificates and sockets

/// A self-signed P-256 certificate (CN "Portlight Transport Test") and its SHA-256 as printed by
/// `openssl x509 -noout -fingerprint -sha256`.
enum TransportTestCertificate {
    static let der = Data(base64Encoded:
        "MIIBNDCB3AIJALka/EKCgxxVMAoGCCqGSM49BAMCMCMxITAfBgNVBAMMGFBvcnRsaWdodCBUcmFuc3BvcnQgVGVzdDAeFw0yNjA5"
        + "MTEwNjI0NTlaFw0zNjA5MDgwNjI0NTlaMCMxITAfBgNVBAMMGFBvcnRsaWdodCBUcmFuc3BvcnQgVGVzdDBZMBMGByqGSM49AgEG"
        + "CCqGSM49AwEHA0IABJuLSzKL4DYkv8RlyVlV4MVteAA11bWVFkAQqyBdJlmM0h5Z4QsbXqOOI2sZSW3HPBlPMujP63MZJ9l8gCvS"
        + "8IswCgYIKoZIzj0EAwIDRwAwRAIgBxHoc1EzxatPG6UwokWRMghElGxZMuAlRie2R7lvIl8CIFNVTNyMMtoR384ivbbf1TZpWHoh"
        + "agI0ENB+QepXLmQR")!
    static let fingerprint = CertificateFingerprint(
        string: "3D:A0:C0:F9:9D:BF:A5:1F:69:DF:F7:4D:6A:4E:05:34:1C:E9:71:58:8D:37:7D:07:A4:6C:12:AF:89:B1:4A:54")!
    static let abc = Data("abc".utf8)
    static let empty = Data()

    static func trust() -> SecTrust? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess else { return nil }
        return trust
    }
}

/// Facts about the production socket and delegate queue, read without starting anything.
enum TransportSocketFacts {
    struct Configuration: Equatable {
        var requestTimeout: Double
        var waitsForConnectivity: Bool
        var keepsNoCookiesCacheOrCredentials: Bool
        var minimumTLS12: Bool
        var maximumMessageSize: Int
    }

    final class NullDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {}

    static func configuration() -> Configuration {
        let socket = URLSessionSocket(url: URL(string: "wss://192.168.1.20:5920/remote")!, delegate: NullDelegate(),
                                      delegateQueue: OperationQueue())
        defer { socket.shutdown(); socket.shutdown() }
        let c = socket.session.configuration
        return Configuration(
            requestTimeout: c.timeoutIntervalForRequest, waitsForConnectivity: c.waitsForConnectivity,
            keepsNoCookiesCacheOrCredentials: c.httpCookieStorage == nil && c.urlCache == nil && c.urlCredentialStorage == nil
                && !c.httpShouldSetCookies,
            minimumTLS12: c.tlsMinimumSupportedProtocolVersion == .TLSv12,
            maximumMessageSize: socket.task.maximumMessageSize)
    }

    /// (serial, runs on the given queue, main maps to OperationQueue.main)
    static func delegateQueue() -> (serial: Bool, onGivenQueue: Bool, mainIsOperationQueueMain: Bool) {
        let queue = DispatchQueue(label: "studio.upgrade.portlight.tests.transport-facts")
        let operations = WebSocketTransport.makeDelegateQueue(on: queue)
        return (operations.maxConcurrentOperationCount == 1, operations.underlyingQueue === queue,
                WebSocketTransport.makeDelegateQueue(on: .main) === OperationQueue.main)
    }
}
