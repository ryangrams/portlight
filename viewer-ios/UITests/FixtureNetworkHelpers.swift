import XCTest
import CryptoKit
import Darwin

/// A second Portlight viewer the test itself holds, to occupy the fixture host's single viewer slot. It trusts only
/// the fixture's exact certificate (SHA-256 of the leaf DER, like the app), sends hello with the fixture's synthetic
/// password and waits for welcome. It subscribes to nothing, so the host sends it no images, and it holds the slot
/// until `close()`.
final class FixtureViewerSlot: NSObject, URLSessionDelegate, @unchecked Sendable {
    // Invariant for @unchecked Sendable: `session`, `task` and `answer` are only touched under `lock`; `fingerprint`
    // and `answered` are immutable.
    struct Failure: Error, CustomStringConvertible { let description: String }

    private let fingerprint: String
    private let answered = XCTestExpectation(description: "the host answered the holding viewer's hello")
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var answer: String?

    init(fingerprint: String) {
        self.fingerprint = FixtureSessionTests.hexDigits(fingerprint)
    }

    /// Returns once the host welcomed this viewer; throws with the host's answer otherwise (never the password).
    func hold(host: String, port: Int, password: String) throws {
        guard let url = URL(string: "wss://\(host):\(port)/remote") else { throw Failure(description: "bad fixture address") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        lock.withLock { self.session = session; self.task = task }
        task.resume()
        let hello = try JSONSerialization.data(withJSONObject: [
            "type": "hello", "version": 1, "password": password, "codecs": ["png", "jpeg"],
        ] as [String: Any])
        task.send(.string(String(decoding: hello, as: UTF8.self))) { [weak self] error in
            if error != nil { self?.finish("the hello could not be sent") }
        }
        receive(from: task)
        guard XCTWaiter().wait(for: [answered], timeout: 20) == .completed else {
            throw Failure(description: "the fixture host never answered the holding viewer")
        }
        let answer = lock.withLock { self.answer }
        guard answer == "welcome" else {
            throw Failure(description: "the holding viewer was not welcomed: \(answer ?? "no answer")")
        }
    }

    /// Frees the slot. Idempotent.
    func close() {
        let (task, session) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            defer { self.task = nil; self.session = nil }
            return (self.task, self.session)
        }
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    /// Reads and discards whatever the host sends while the slot is held; the first welcome or error answers hello.
    private func receive(from task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                switch object?["type"] as? String {
                case "welcome": self.finish("welcome")
                case "error": self.finish("error \(object?["code"] as? String ?? "?")")
                default: break
                }
                self.receive(from: task)
            case .success:
                self.receive(from: task)
            case .failure:
                self.finish("the connection closed")
            }
        }
    }

    private func finish(_ answer: String) {
        let first = lock.withLock { () -> Bool in
            guard self.answer == nil else { return false }
            self.answer = answer
            return true
        }
        if first { answered.fulfill() }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            finish("the host presented no certificate")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02X", $0) }.joined()
        guard digest == fingerprint else {
            finish("the host's certificate is not the fixture's")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// A loopback TCP port that accepts connections and never says anything: the kernel completes each handshake into
/// the listen backlog and nothing ever reads, so a TLS client waits for a ServerHello that never comes.
final class SilentLoopbackListener {
    struct Failure: Error, CustomStringConvertible { let description: String }

    let port: Int
    private var descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(description: "socket() failed: errno \(errno)") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(descriptor, raw, length) == 0 && listen(descriptor, 8) == 0 && getsockname(descriptor, raw, &length) == 0
            }
        }
        guard ready else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure(description: "could not listen on loopback: errno \(code)")
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    /// Idempotent.
    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}

enum FixtureRouting {
    /// The kernel's immediate answer to a non-blocking TCP connect to [address]:port: EHOSTUNREACH or ENETUNREACH when
    /// this Mac has no route (then nothing is sent), nil when a connection started (a route exists) or on any other
    /// error.
    static func noRouteError(toIPv6 address: String, port: UInt16) -> Int32? {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var target = sockaddr_in6()
        target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        target.sin6_family = sa_family_t(AF_INET6)
        target.sin6_port = port.bigEndian
        guard inet_pton(AF_INET6, address, &target.sin6_addr) == 1 else { return nil }
        let code = withUnsafePointer(to: &target) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 ? 0 : errno
            }
        }
        return code == EHOSTUNREACH || code == ENETUNREACH ? code : nil
    }
}
