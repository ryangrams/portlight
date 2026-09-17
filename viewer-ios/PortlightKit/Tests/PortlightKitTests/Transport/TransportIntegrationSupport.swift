#if os(macOS)
import AVFoundation
import Darwin
import Foundation
@testable import PortlightKit

// Real processes and sockets for the "Integration: transport" suite. This file must not import Testing (the Command
// Line Tools ship `_Testing_Foundation` without its module); TransportIntegrationTests.swift holds the tests.

/// Where the integration hosts live. Defaults resolve inside this checkout (app/verification/iphone-host-build,
/// viewer-ios/scripts/mock-host.py, app/.test-venv); PORTLIGHT_FIXTURE_EXE, PORTLIGHT_MOCK_HOST and
/// PORTLIGHT_TEST_PYTHON override them. A missing host skips its tests unless PORTLIGHT_REQUIRE_INTEGRATION=1.
enum TransportIntegration {
    struct Requirement: Sendable {
        /// Why the host can't run here; nil when it can.
        let problem: String?
        /// Run when available, or when required: a missing host then fails the test instead of skipping it.
        var runnable: Bool { problem == nil || TransportIntegration.isRequired }
        var skipNote: String { "\(problem ?? "Available"). Set PORTLIGHT_REQUIRE_INTEGRATION=1 to fail instead of skipping." }
        func check() throws {
            if let problem { throw TransportHostError.unavailable(problem) }
        }
    }

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    /// app/: six levels above this file (Transport, PortlightKitTests, Tests, PortlightKit, viewer-ios, app).
    static let appRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    static var fixtureExecutable: String {
        environment["PORTLIGHT_FIXTURE_EXE"]
            ?? appRoot.appendingPathComponent("verification/iphone-host-build/Portlight Host.app/Contents/MacOS/SURemoteServer").path
    }
    static var mockHostScript: String {
        environment["PORTLIGHT_MOCK_HOST"] ?? appRoot.appendingPathComponent("viewer-ios/scripts/mock-host.py").path
    }
    static var python: String {
        environment["PORTLIGHT_TEST_PYTHON"] ?? appRoot.appendingPathComponent(".test-venv/bin/python").path
    }
    static var isRequired: Bool { environment["PORTLIGHT_REQUIRE_INTEGRATION"] == "1" }

    static var fixture: Requirement {
        Requirement(problem: FileManager.default.isExecutableFile(atPath: fixtureExecutable) ? nil : "Fixture host not found at \(fixtureExecutable)")
    }
    static var mock: Requirement {
        if !FileManager.default.isReadableFile(atPath: mockHostScript) { return Requirement(problem: "Mock host not found at \(mockHostScript)") }
        if !FileManager.default.isExecutableFile(atPath: python) { return Requirement(problem: "Test Python not found at \(python)") }
        return Requirement(problem: nil)
    }

    /// A 127.0.0.1 port nothing listens on at this moment (bound, read, released).
    static func unusedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportHostError.startup("socket() failed: errno \(errno)") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0 else { throw TransportHostError.startup("could not probe a free port: errno \(errno)") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

enum TransportHostError: Error, CustomStringConvertible {
    case unavailable(String)
    case startup(String)
    var description: String {
        switch self {
        case .unavailable(let problem): return "\(problem), and PORTLIGHT_REQUIRE_INTEGRATION=1 requires it"
        case .startup(let detail): return detail
        }
    }
}

/// A child's stdout as lines, with bounded waits that end early when the child exits.
final class TransportLineCollector: @unchecked Sendable {
    // Invariant: `buffer`, `storage` and `ended` are only touched while holding `condition`.
    private let condition = NSCondition()
    private var buffer = Data()
    private var storage: [String] = []
    private var ended = false

    func append(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            storage.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        condition.broadcast()
    }

    func end() {
        condition.lock()
        ended = true
        condition.broadcast()
        condition.unlock()
    }

    var lines: [String] {
        condition.lock()
        defer { condition.unlock() }
        return storage
    }

    func wait(timeout: Double, until predicate: ([String]) -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !predicate(storage) {
            if ended || !condition.wait(until: deadline) { return predicate(storage) }
        }
        return true
    }
}

/// One isolated host process on a free 127.0.0.1 port with its own temporary directory. `stop()` (also run on
/// deinit) terminates it (SIGTERM, then SIGKILL after 5 s) and deletes the directory.
final class TransportHost: @unchecked Sendable {
    // Invariant: `stopped` is only touched under `lock`; every other property is immutable after launch.
    /// Synthetic test passwords, passed on stdin. Never studio credentials.
    static let fixturePassword = "fixture-password"
    static let mockPassword = "mock-password"
    private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    let endpoint: HostEndpoint
    let fingerprint: CertificateFingerprint
    let password: String
    let directory: URL
    private let process: Process
    private let stdout: Pipe
    private let exited: DispatchSemaphore
    private let transcript: URL?
    private let lock = NSLock()
    private var stopped = false

    private init(endpoint: HostEndpoint, fingerprint: CertificateFingerprint, password: String, directory: URL,
                 process: Process, stdout: Pipe, exited: DispatchSemaphore, transcript: URL?) {
        self.endpoint = endpoint; self.fingerprint = fingerprint; self.password = password; self.directory = directory
        self.process = process; self.stdout = stdout; self.exited = exited; self.transcript = transcript
    }

    deinit { stop() }

    /// The synthetic fixture host: three displays, no capture, no input injection.
    static func startFixture() throws -> TransportHost {
        try TransportIntegration.fixture.check()
        var failure: Error = TransportHostError.startup("the fixture host did not start")
        for _ in 0..<3 {   // a probed port can be taken before the host binds it
            let port = try TransportIntegration.unusedPort()
            do {
                return try launch(executable: TransportIntegration.fixtureExecutable, password: fixturePassword, transcript: false) { directory in
                    ["--fixture", "--port", String(port), "--data-dir", directory.appendingPathComponent("data").path, "--password-stdin"]
                }
            } catch {
                failure = error
            }
        }
        throw failure
    }

    /// scripts/mock-host.py with the fixture's three displays, the given scenarios and extra arguments.
    static func startMock(scenarios: [String] = [], arguments extra: [String] = [], transcript: Bool = false) throws -> TransportHost {
        try TransportIntegration.mock.check()
        return try launch(executable: TransportIntegration.python, password: mockPassword, transcript: transcript) { directory in
            var arguments = [TransportIntegration.mockHostScript, "--port", "0", "--data-dir",
                             directory.appendingPathComponent("data").path, "--password-stdin"]
            for scenario in scenarios { arguments += ["--scenario", scenario] }
            if transcript { arguments += ["--transcript", directory.appendingPathComponent("transcript.jsonl").path] }
            return arguments + extra
        }
    }

    private static func launch(executable: String, password: String, transcript: Bool,
                               arguments: (URL) -> [String]) throws -> TransportHost {
        _ = ignoreBrokenPipes
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("portlight-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("data"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let stderrURL = directory.appendingPathComponent("host.stderr")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(directory)
        process.currentDirectoryURL = directory
        let stdin = Pipe(), stdout = Pipe()
        let stderr = try FileHandle(forWritingTo: stderrURL)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let collector = TransportLineCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.end()
            } else {
                collector.append(data)
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            collector.end()
            exited.signal()
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: directory)
            throw TransportHostError.startup("could not launch \(executable): \(error)")
        }
        try? stderr.close()
        try? stdin.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
        try? stdin.fileHandleForWriting.close()

        let ready = collector.wait(timeout: 30) { lines in
            lines.contains { $0.hasPrefix("TLS SHA256 ") } && lines.contains { $0.hasPrefix("Listening on port ") }
        }
        let lines = collector.lines
        let fingerprint = lines.first { $0.hasPrefix("TLS SHA256 ") }
            .flatMap { CertificateFingerprint(string: String($0.dropFirst("TLS SHA256 ".count))) }
        let port = lines.first { $0.hasPrefix("Listening on port ") }
            .flatMap { Int($0.dropFirst("Listening on port ".count).trimmingCharacters(in: .whitespaces)) }
        guard ready, let fingerprint, let port, let endpoint = HostEndpoint(host: "127.0.0.1", port: port) else {
            let errors = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            terminate(process, exited)
            stdout.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: directory)
            throw TransportHostError.startup("\(executable) did not become ready. stdout: \(lines.suffix(10)) stderr: \(errors.suffix(2000))")
        }
        return TransportHost(endpoint: endpoint, fingerprint: fingerprint, password: password, directory: directory, process: process,
                             stdout: stdout, exited: exited,
                             transcript: transcript ? directory.appendingPathComponent("transcript.jsonl") : nil)
    }

    private static func terminate(_ process: Process, _ exited: DispatchSemaphore) {
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 5) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 5)
        }
    }

    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        Self.terminate(process, exited)
        stdout.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// `type` of every client message the mock recorded in its transcript (direction "in"), in order.
    func inboundMessageTypes() -> [String] {
        guard let transcript, let text = try? String(contentsOf: transcript, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  object["dir"] as? String == "in" else { return nil }
            return object["type"] as? String ?? "<invalid>"
        }
    }
}

// MARK: - Live client

struct TransportFrame {
    let header: FrameHeader
    let payload: Data
}

/// Every event a live client received, in delivery order, with bounded waits.
final class TransportEventLog: @unchecked Sendable {
    // Invariant: `storage` is only touched while holding `condition`.
    private let condition = NSCondition()
    private var storage: [TransportRecorded] = []

    func append(_ event: TransportRecorded) {
        condition.lock()
        storage.append(event)
        condition.broadcast()
        condition.unlock()
    }

    var events: [TransportRecorded] {
        condition.lock()
        defer { condition.unlock() }
        return storage
    }
    var count: Int { events.count }

    /// Waits until `predicate` holds, for at most `timeout` seconds; returns whether it held.
    func wait(timeout: Double, until predicate: ([TransportRecorded]) -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !predicate(storage) {
            if !condition.wait(until: deadline) { return predicate(storage) }
        }
        return true
    }
}

/// Weak references to every attempt's `TransportConnection` and `URLSessionSocket` (its URLSession and task).
final class TransportAttemptRefs: @unchecked Sendable {
    // Invariant: `entries` is only touched under `lock`.
    private struct Entry {
        weak var connection: TransportConnection?
        weak var socket: URLSessionSocket?
    }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(_ connection: TransportConnection, _ socket: URLSessionSocket) {
        lock.withLock { entries.append(Entry(connection: connection, socket: socket)) }
    }
    var count: Int { lock.withLock { entries.count } }
    /// Attempts whose connection or socket is still alive.
    var alive: Int { lock.withLock { entries.filter { $0.connection != nil || $0.socket != nil }.count } }

    /// Waits up to `timeout` seconds for every recorded attempt to be released (URLSession lets go of its delegate
    /// once invalidation completes, asynchronously).
    func waitUntilReleased(timeout: Double) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            if autoreleasepool(invoking: { alive }) == 0 { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

/// A production `WebSocketTransport` on its own serial queue, standing in for the engine queue.
final class TransportLiveClient: @unchecked Sendable {
    // Invariant: `transport` is only called on `queue`; `log` is internally synchronized.
    /// Drains an autorelease pool per block, so URLSession objects are freed as promptly as on the engine's queue.
    let queue = DispatchQueue(label: "studio.upgrade.portlight.tests.transport-live", autoreleaseFrequency: .workItem)
    let transport: WebSocketTransport
    let log = TransportEventLog()
    private let acknowledgesFrames: Bool

    /// `messageSizeLimit` replaces the production socket's 32 MiB `maximumMessageSize`; `attempts` records weak
    /// references to every attempt's connection and production socket.
    init(acknowledgesFrames: Bool = true, messageSizeLimit: Int? = nil, attempts: TransportAttemptRefs? = nil) {
        self.acknowledgesFrames = acknowledgesFrames
        if messageSizeLimit == nil && attempts == nil {
            transport = WebSocketTransport()
        } else {
            transport = WebSocketTransport(socketFactory: { url, connection, delegateQueue in
                let socket = URLSessionSocket(url: url, delegate: connection, delegateQueue: delegateQueue)
                if let messageSizeLimit { socket.task.maximumMessageSize = messageSizeLimit }
                attempts?.record(connection, socket)
                return socket
            })
        }
    }

    func connect(to endpoint: HostEndpoint, pin: CertificateFingerprint?, generation: UInt64 = 1) {
        onQueue {
            transport.connect(to: endpoint, pin: pin, generation: ConnectionGeneration(rawValue: generation), queue: queue) {
                [log = self.log, weak transport = self.transport, acknowledgesFrames = self.acknowledgesFrames] _, event in
                log.append(TransportRecorded(event))
                // Acknowledge like the engine; the host sends nothing new for a display with an unacknowledged frame.
                if acknowledgesFrames, case .message(.frame(let header, _)) = event {
                    transport?.send(.frameAck(sequence: header.sequence))
                }
            }
        }
    }

    func send(_ message: OutboundMessage) { onQueue { transport.send(message) } }
    func close() { onQueue { transport.close() } }
    /// Closes on the delivery queue and returns how many events had arrived at that moment.
    func closeReturningEventCount() -> Int { onQueue { transport.close(); return log.count } }

    /// `queue.sync` runs its block on the calling test thread, whose autorelease pool Swift Testing drains only when
    /// the test returns. Draining here frees the URLSession objects `connect` creates as the engine's queue would.
    private func onQueue<Value>(_ work: () -> Value) -> Value {
        autoreleasepool { queue.sync { autoreleasepool(invoking: work) } }
    }
    var events: [TransportRecorded] { log.events }
    /// Whether a terminal event (`.trustRequired` or `.closed`) arrived.
    var hasEnded: Bool { events.contains { $0.isTerminal } }
    var terminalEventCount: Int { events.filter { $0.isTerminal }.count }

    /// Waits for `.trustRequired` or `.closed`.
    @discardableResult func waitForEnd(timeout: Double = 20) -> Bool {
        log.wait(timeout: timeout) { $0.contains(where: \.isTerminal) }
    }

    func waitForOpen(timeout: Double = 20) -> Bool {
        _ = log.wait(timeout: timeout) { $0.contains(.opened) || $0.contains(where: \.isTerminal) }
        return events.contains(.opened)
    }

    func waitForEvents(beyond count: Int, timeout: Double) -> Bool {
        log.wait(timeout: timeout) { $0.count > count }
    }

    func waitForWelcome(timeout: Double = 20) -> WelcomeMessage? {
        waitFor(timeout: timeout) { if case .message(.welcome(let welcome)) = $0 { return welcome }; return nil }
    }

    func waitForSubscribed(revision: Int, timeout: Double = 20) -> SubscribedMessage? {
        waitFor(timeout: timeout) {
            if case .message(.subscribed(let ack)) = $0, ack.revision == revision { return ack }
            return nil
        }
    }

    /// Waits until every display in `displays` delivered at least `count` frames; returns the frames by display.
    func waitForFrames(from displays: [DisplayID], count: Int = 1, timeout: Double = 30) -> [DisplayID: [TransportFrame]] {
        _ = log.wait(timeout: timeout) { events in
            let frames = Self.frames(in: events)
            return displays.allSatisfy { (frames[$0]?.count ?? 0) >= count } || events.contains(where: \.isTerminal)
        }
        return Self.frames(in: events)
    }

    /// Pinned connect, then hello once open; the welcome, or nil if anything else happened first.
    func authenticate(with host: TransportHost, password: String? = nil) -> WelcomeMessage? {
        connect(to: host.endpoint, pin: host.fingerprint)
        guard waitForOpen() else { return nil }
        send(.hello(password: password ?? host.password))
        return waitForWelcome()
    }

    private func waitFor<Value>(timeout: Double, _ match: @escaping (TransportRecorded) -> Value?) -> Value? {
        _ = log.wait(timeout: timeout) { events in events.contains { match($0) != nil } || events.contains(where: \.isTerminal) }
        return events.lazy.compactMap(match).first
    }

    private static func frames(in events: [TransportRecorded]) -> [DisplayID: [TransportFrame]] {
        var frames: [DisplayID: [TransportFrame]] = [:]
        for case .message(.frame(let header, let payload)) in events {
            frames[header.display, default: []].append(TransportFrame(header: header, payload: payload))
        }
        return frames
    }
}

// MARK: - Input and audio at message level

/// One pointer, wheel, key or text message the mock recorded, with its verdict.
struct TransportMockInput: Equatable, Sendable {
    let type: String
    let accepted: Bool
    let reason: String?
    /// The mock had to coerce a field's type (for example a number sent as a string).
    let typeWarnings: Bool
}

extension TransportHost {
    /// Pointer, wheel, key and text messages the mock recorded (started with `transcript: true`), in order.
    func inboundInput() -> [TransportMockInput] {
        guard let transcript, let text = try? String(contentsOf: transcript, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  object["dir"] as? String == "in", let type = object["type"] as? String,
                  ["pointer", "wheel", "key", "text"].contains(type) else { return nil }
            return TransportMockInput(type: type, accepted: object["accepted"] as? Bool ?? false,
                                      reason: object["reason"] as? String, typeWarnings: object["typeWarnings"] != nil)
        }
    }

    /// Waits up to `timeout` seconds until the mock recorded at least `count` input messages.
    func waitForInboundInput(count: Int, timeout: Double = 10) -> [TransportMockInput] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var input = inboundInput()
        while input.count < count && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            input = inboundInput()
        }
        return input
    }
}

/// One audio message as the transport delivered it.
struct TransportAudio {
    let header: AudioHeader
    let payload: Data

    /// The frames each packet decodes to through the viewer's own decoder (AAC through AudioConverter, μ-law by
    /// table), in order; 0 for a packet that doesn't decode.
    static func decodedFrameCounts(_ packets: [TransportAudio]) -> [Int] {
        var decoder = AudioPacketDecoder()
        return packets.map { Int(decoder.decode($0.header, payload: $0.payload)?.buffer.frameLength ?? 0) }
    }
}

extension TransportLiveClient {
    /// Waits until at least `count` audio messages arrived, or the attempt ended; returns them in order.
    func waitForAudio(count: Int, timeout: Double = 20) -> [TransportAudio] {
        _ = log.wait(timeout: timeout) { events in
            Self.audio(in: events).count >= count || events.contains(where: \.isTerminal)
        }
        return Self.audio(in: events)
    }

    private static func audio(in events: [TransportRecorded]) -> [TransportAudio] {
        events.compactMap { event in
            if case .message(.audio(let header, let payload)) = event { return TransportAudio(header: header, payload: payload) }
            return nil
        }
    }
}
#endif
