import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// The pure failure mapping (URLError / NSError / POSIX → ConnectionFailure). Codes are written as numbers on
/// purpose: they are what URLSession actually reports.
@Suite struct TransportClassificationTests {
    static let lan = "192.168.1.20"
    static let remote = "203.0.113.7"

    private func classify(_ error: any Error, host: String = lan, established: Bool = false,
                          device: DeviceNetwork = .unknown) -> ConnectionFailure {
        TransportFailureClassifier.classify(error, host: host, established: established, deviceNetwork: device)
    }

    @Test func refused() {
        #expect(classify(TransportErrors.url(-1004, posix: 61)) == .refused)       // CannotConnectToHost + ECONNREFUSED
        #expect(classify(TransportErrors.url(-1004)) == .refused)
        #expect(classify(TransportErrors.posix(61)) == .refused)
        #expect(classify(TransportErrors.network("kNWErrorDomainPOSIX", 61)) == .refused)
    }

    @Test func noRoute() {
        #expect(classify(TransportErrors.posix(51)) == .noRoute)                    // ENETUNREACH
        #expect(classify(TransportErrors.posix(65)) == .noRoute)                    // EHOSTUNREACH
        #expect(classify(TransportErrors.url(-1004, posix: 65)) == .noRoute)        // the POSIX code outranks -1004
    }

    @Test func timedOut() {
        #expect(classify(TransportErrors.url(-1001)) == .timedOut)
        #expect(classify(TransportErrors.posix(60)) == .timedOut)                   // ETIMEDOUT
        #expect(classify(TransportErrors.url(-1004, posix: 60)) == .timedOut)
    }

    @Test func hostNotFound() {
        #expect(classify(TransportErrors.url(-1003)) == .hostNotFound)              // CannotFindHost
        #expect(classify(TransportErrors.url(-1006)) == .hostNotFound)              // DNSLookupFailed
        #expect(classify(TransportErrors.url(-1003, netDB: 8)) == .hostNotFound)    // EAI_NONAME
        #expect(classify(TransportErrors.network("kNWErrorDomainDNS", -65554)) == .hostNotFound)
    }

    @Test func offlineVersusLocalNetworkDenied() {
        #expect(classify(TransportErrors.url(-1009), host: Self.remote) == .offline)
        #expect(classify(TransportErrors.url(-1009), host: Self.lan) == .localNetworkDenied)
        #expect(classify(TransportErrors.url(-1009), host: "studio.local") == .localNetworkDenied)
        #expect(classify(TransportErrors.posix(50), host: Self.remote) == .offline)           // ENETDOWN
        #expect(classify(TransportErrors.posix(50), host: "fe80::1") == .localNetworkDenied)
        #expect(classify(TransportErrors.url(-1020)) == .offline)                             // DataNotAllowed
        // An explicit path reason wins over the address heuristic.
        let prohibited = "unsatisfied (Local network prohibited), interface: en0[802.11], ipv4, dns"
        #expect(classify(TransportErrors.url(-1009, posix: 50, path: prohibited), host: "mac-studio.example.net") == .localNetworkDenied)
        // Any other unsatisfied path falls back to the heuristic; a satisfied path changes nothing.
        #expect(classify(TransportErrors.url(-1004, path: "unsatisfied (No network route)"), host: Self.remote) == .offline)
        #expect(classify(TransportErrors.url(-1004, path: "unsatisfied (No network route)"), host: "10.0.0.5") == .localNetworkDenied)
        #expect(classify(TransportErrors.url(-1004, posix: 61, path: "satisfied (Path is satisfied), interface: lo0"),
                         host: "127.0.0.1") == .refused)
    }

    /// The device-wide path splits "no usable network". Measured on the Mac that runs the simulator, a destination
    /// without a route (`wss://[100::1]`, IPv4-only routing) fails at once with a bare -1009: the code an offline
    /// device gets too.
    @Test func theDevicesOwnNetworkSeparatesOfflineFromNoRoute() {
        let online = DeviceNetwork.available, offline = DeviceNetwork.unavailable
        #expect(classify(TransportErrors.url(-1009), host: "100::1", device: online) == .noRoute)
        #expect(classify(TransportErrors.url(-1009), host: Self.remote, device: online) == .noRoute)
        #expect(classify(TransportErrors.url(-1004, path: "unsatisfied (No network route)"), host: "100.64.0.1", device: online) == .noRoute)
        #expect(classify(TransportErrors.posix(50), host: Self.remote, device: online) == .noRoute)          // ENETDOWN
        // A connected iPhone that can't use the network for a local address: Local Network access, as before.
        #expect(classify(TransportErrors.url(-1009), host: Self.lan, device: online) == .localNetworkDenied)
        #expect(classify(TransportErrors.url(-1009), host: "studio.local", device: online) == .localNetworkDenied)
        // No network at all is offline whatever the address, a LAN one included.
        #expect(classify(TransportErrors.url(-1009), host: Self.remote, device: offline) == .offline)
        #expect(classify(TransportErrors.url(-1009), host: Self.lan, device: offline) == .offline)
        #expect(classify(TransportErrors.posix(50), host: "fe80::1", device: offline) == .offline)
        // The system's explicit reason still wins, and more specific codes are untouched.
        let prohibited = "unsatisfied (Local network prohibited), interface: en0[802.11], ipv4, dns"
        #expect(classify(TransportErrors.url(-1009, path: prohibited), host: Self.remote, device: offline) == .localNetworkDenied)
        #expect(classify(TransportErrors.url(-1004, posix: 61), host: Self.remote, device: online) == .refused)
        #expect(classify(TransportErrors.url(-1001), host: Self.remote, device: offline) == .timedOut)
        #expect(classify(TransportErrors.url(-1003), host: Self.remote, device: online) == .hostNotFound)
    }

    /// Once open, a device that still has a network lost this connection; one without a network is offline.
    @Test func anEstablishedConnectionOnAConnectedDeviceWasLost() {
        #expect(classify(TransportErrors.url(-1009), host: Self.remote, established: true, device: .available) == .networkLost)
        #expect(classify(TransportErrors.url(-1009), host: Self.lan, established: true, device: .available) == .networkLost)
        #expect(classify(TransportErrors.url(-1009), host: Self.lan, established: true, device: .unavailable) == .offline)
        #expect(classify(TransportErrors.url(-1009), host: Self.remote, established: true, device: .unavailable) == .offline)
        let prohibited = "unsatisfied (Local network prohibited), interface: en0[802.11], ipv4, dns"
        #expect(classify(TransportErrors.url(-1009, path: prohibited), established: true, device: .available) == .localNetworkDenied)
    }

    /// NWPathMonitor always delivers a first path; until then the classifier falls back to the address alone.
    @Test func theDeviceNetworkMonitorReportsAStatus() async throws {
        WebSocketTransport.startMonitoringNetwork()
        var waited = 0
        while DeviceNetworkMonitor.shared.status == .unknown && waited < 100 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        #expect(DeviceNetworkMonitor.shared.status != .unknown)
    }

    @Test(arguments: ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.0.10", "169.254.10.20",
                      "::1", "fe80::1", "FE80::ABCD", "fd12:3456::1", "::ffff:192.168.1.2", "studio.local", "Studio.LOCAL.", "localhost"])
    func localNetworkHosts(host: String) {
        #expect(TransportFailureClassifier.isLocalNetworkHost(host))
    }

    @Test(arguments: ["203.0.113.7", "8.8.8.8", "172.32.0.1", "172.15.255.1", "100.64.0.1", "2001:db8::1", "::ffff:8.8.8.8",
                      "mac-studio", "example.com", "local", "notlocal"])
    func remoteHosts(host: String) {
        #expect(!TransportFailureClassifier.isLocalNetworkHost(host))
    }

    @Test func networkLost() {
        #expect(classify(TransportErrors.url(-1005)) == .networkLost)               // NetworkConnectionLost
        #expect(classify(TransportErrors.posix(54)) == .networkLost)                // ECONNRESET
        #expect(classify(TransportErrors.posix(32)) == .networkLost)                // EPIPE
        #expect(classify(TransportErrors.posix(53)) == .networkLost)                // ECONNABORTED
        #expect(classify(TransportErrors.url(-1005, posix: 54)) == .networkLost)
        #expect(classify(TransportErrors.url(-999)) == .networkLost)                // an unexpected cancellation
        #expect(classify(TransportErrors.unknown()) == .networkLost)
    }

    @Test func endOfStreamIsHostClosed() {
        // URLSessionWebSocketTask reports a host that closed without a close frame as ENOTCONN.
        #expect(classify(TransportErrors.posix(57), established: true) == .hostClosed)
        #expect(classify(TransportErrors.network("kNWErrorDomainPOSIX", 57), established: true) == .hostClosed)
    }

    @Test func tlsFailed() {
        #expect(classify(TransportErrors.url(-1200, tlsStatus: -9806)) == .tlsFailed("the host ended the handshake"))
        #expect(classify(TransportErrors.url(-1200)) == .tlsFailed("secure connection failed"))
        #expect(classify(TransportErrors.url(-1202)) == .tlsFailed("certificate rejected"))
        #expect(classify(TransportErrors.url(-1206)) == .tlsFailed("the host asked for a client certificate"))
        #expect(classify(TransportErrors.osStatus(-9808)) == .tlsFailed("TLS error -9808"))
        #expect(classify(TransportErrors.network("kNWErrorDomainTLS", -9836)) == .tlsFailed("TLS error -9836"))
        #expect(classify(TransportErrors.osStatus(-50)) == .networkLost, "an OSStatus outside errSSL… is not TLS")
    }

    @Test func protocolLevelFailures() {
        #expect(classify(TransportErrors.url(-1011)) == .protocolViolation("an invalid WebSocket handshake or frame"))
        #expect(classify(TransportErrors.url(-1017)) == .protocolViolation("an unreadable response"))
        #expect(classify(TransportErrors.posix(40)) == .protocolViolation(TransportFailureClassifier.messageTooLarge))  // EMSGSIZE
        #expect(classify(TransportErrors.url(-1007)) == .protocolViolation(TransportFailureClassifier.redirectRefused))
        #expect(classify(TransportErrors.url(-1000)) == .invalidAddress)
    }

    @Test func anEstablishedConnectionReportsLossesNotConnectFailures() {
        #expect(classify(TransportErrors.url(-1001), established: true) == .networkLost)
        #expect(classify(TransportErrors.posix(61), established: true) == .networkLost)
        #expect(classify(TransportErrors.posix(65), established: true) == .networkLost)
        #expect(classify(TransportErrors.url(-1003), established: true) == .networkLost)
        #expect(classify(TransportErrors.url(-1009), host: Self.remote, established: true) == .offline)
        #expect(classify(TransportErrors.url(-1200, tlsStatus: -9806), established: true) == .tlsFailed("the host ended the handshake"))
    }

    /// The socket reached the host, so Local Network access was granted: losing the network afterwards (Wi-Fi off or
    /// out of range) is `.offline`, which may be retried, whatever the address. Only the system's explicit reason
    /// still means permission.
    @Test func anEstablishedConnectionNeverBlamesLocalNetworkPermission() {
        let noRoute = "unsatisfied (No network route), interface: en0[802.11], ipv4"
        #expect(classify(TransportErrors.url(-1005, posix: 57, path: noRoute), established: true) == .offline)
        #expect(classify(TransportErrors.url(-1009), established: true) == .offline)
        #expect(classify(TransportErrors.posix(50), host: "fe80::1", established: true) == .offline)   // ENETDOWN
        #expect(classify(TransportErrors.url(-1009), host: "studio.local", established: true) == .offline)
        let prohibited = "unsatisfied (Local network prohibited), interface: en0[802.11], ipv4, dns"
        #expect(classify(TransportErrors.url(-1009, path: prohibited), established: true) == .localNetworkDenied)
        #expect(classify(TransportErrors.url(-1009, path: prohibited), host: Self.remote, established: true) == .localNetworkDenied)
        // Before the socket opens the address heuristic still applies.
        #expect(classify(TransportErrors.url(-1009)) == .localNetworkDenied)
        #expect(classify(TransportErrors.url(-1005, posix: 57, path: noRoute)) == .localNetworkDenied)
    }

    @Test func underlyingErrorChainsAreReadToABoundedDepth() {
        #expect(classify(TransportErrors.chain(depth: 5, bottom: TransportErrors.posix(61))) == .refused)
        #expect(classify(TransportErrors.chain(depth: 20, bottom: TransportErrors.posix(61))) == .networkLost)
    }

    @Test func violationReasonsAreShortAndBounded() {
        typealias C = TransportFailureClassifier
        #expect(C.violationReason(.invalidJSON) == "malformed JSON")
        #expect(C.violationReason(.invalidUTF8) == "text that isn’t valid UTF-8")
        #expect(C.violationReason(.binaryTooShort(3)) == "a 3-byte binary message")
        #expect(C.violationReason(.binaryTooLarge(40_000_000)) == "a 40000000-byte binary message")
        #expect(C.violationReason(.invalidHeaderLength(70_000)) == "a binary header length of 70000")
        #expect(C.violationReason(.missingField("displays[0].id")) == "a message without “displays[0].id”")
        #expect(C.violationReason(.duplicateDisplayID("private-display-name")) == "a duplicate display ID")
        #expect(C.violationReason(.unsupportedCodec(String(repeating: "x", count: 500))).count < 100)
    }
}
