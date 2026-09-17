import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Maps URLSession, NSError and POSIX failures to the `ConnectionFailure` the user sees. Pure and table-tested;
/// the transport adds only what an error can't carry: a received close frame, a refused redirect, and whether the
/// device itself has a network.
///
/// Precedence: an unsatisfied network path wins (an explicit "Local network prohibited" reason, otherwise "no usable
/// network" below), then POSIX codes from anywhere in the underlying-error chain (they are more specific than
/// URLSession's umbrella codes), then TLS status codes, then DNS, then URL error codes.
///
/// "No usable network" (-1009, an unsatisfied path, ENETDOWN) comes both from an offline device and from a single
/// destination without a route. Measured on the Mac that runs the simulator, `wss://[100::1]` with IPv4-only routing
/// fails at once with a bare -1009, while a BSD connect to the same address says EHOSTUNREACH. The device-wide path
/// separates the two:
/// - No network at all is `.offline`, whatever the address.
/// - A device that has a network is missing Local Network access for a local address (the likely remedy on iPhone),
///   and has no route to any other address, such as a VPN-only address while the VPN is off.
/// - Until the device's path is known, the address alone decides: `.localNetworkDenied` for a local address,
///   `.offline` for anything else.
///
/// After the WebSocket opened, connect-style failures mean an established connection dropped, so they become
/// `.networkLost`, and Local Network permission is no longer suspected: the socket reached the host, so access was
/// granted. There, no usable network is `.offline` (Wi-Fi off or out of range), or `.networkLost` when the device
/// still has a network. Only an explicit "Local network prohibited" reason still gives `.localNetworkDenied`.
enum TransportFailureClassifier {
    static let redirectRefused = "a redirect to another address"
    static let upgradeRefused = "no WebSocket upgrade"
    static let messageTooLarge = "a message over 32 MiB"
    /// `.tlsFailed` details for the pin rule's own refusals.
    static let certificateUnchecked = "the certificate was never checked"
    static let certificateSwitched = "the host switched certificates mid-connection"

    static func classify(_ error: Error, host: String, established: Bool,
                         deviceNetwork: DeviceNetwork = .unknown) -> ConnectionFailure {
        let codes = ErrorCodes(error)
        let failure = classify(codes, host: host, deviceNetwork: deviceNetwork)
        guard established else { return failure }
        switch failure {
        case .refused, .noRoute, .timedOut, .hostNotFound: return .networkLost
        case .localNetworkDenied where !codes.localNetworkProhibited:
            return deviceNetwork == .available ? .networkLost : .offline
        default: return failure
        }
    }

    // MARK: - Local network heuristic

    /// Whether `host` can only be reached over the local network, which on iOS needs Local Network permission:
    /// loopback, RFC 1918 private and link-local IPv4 (also as IPv4-mapped IPv6), IPv6 loopback, link-local
    /// (fe80::/10) and unique-local (fc00::/7) addresses, `localhost` and mDNS `.local` names. Everything else,
    /// including CGNAT/VPN ranges such as 100.64.0.0/10 and other names, counts as remote.
    ///
    /// Without an explicit "Local network prohibited" path reason, a device that has a network but can't use it for
    /// a local host is reported as denied Local Network access (the likely remedy on iPhone). Until the device's own
    /// path is known, Wi-Fi switched off while connecting to a LAN address reads the same way.
    static func isLocalNetworkHost(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return isLocalIPv4(UInt32(bigEndian: ipv4.s_addr)) }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let b = withUnsafeBytes(of: &ipv6) { Array($0) }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }            // ::1
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }                        // fe80::/10
            if (b[0] & 0xfe) == 0xfc { return true }                                        // fc00::/7
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {       // ::ffff:a.b.c.d
                return isLocalIPv4(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
            }
            return false
        }
        let name = host.lowercased()
        return name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".local.")
    }

    private static func isLocalIPv4(_ address: UInt32) -> Bool {
        let first = address >> 24, second = (address >> 16) & 0xff
        return first == 10 || first == 127 || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168) || (first == 169 && second == 254)
    }

    // MARK: - Protocol violations

    /// Short phrase for `.protocolViolation`, read inside "The Mac sent data this app can't use (…)".
    /// Host-controlled names are already bounded by the codec; they are cut again here for the UI.
    static func violationReason(_ error: ProtocolError) -> String {
        switch error {
        case .controlMessageTooLarge(let bytes): return "a \(bytes)-byte control message"
        case .invalidUTF8: return "text that isn’t valid UTF-8"
        case .invalidJSON: return "malformed JSON"
        case .nestingTooDeep: return "JSON nested too deeply"
        case .notAnObject: return "JSON that isn’t an object"
        case .missingType: return "a message without a type"
        case .binaryTooShort(let bytes), .binaryTooLarge(let bytes): return "a \(bytes)-byte binary message"
        case .invalidHeaderLength(let length): return "a binary header length of \(length)"
        case .unexpectedBinaryType(let type): return "a binary “\(short(type))” message"
        case .missingField(let field): return "a message without “\(short(field))”"
        case .invalidField(let field): return "an invalid “\(short(field))”"
        case .unsupportedCodec(let codec): return "the unsupported codec “\(short(codec))”"
        case .invalidRectangle: return "an image outside its canvas"
        case .duplicateDisplayID: return "a duplicate display ID"
        case .tooManyDisplays(let count): return "\(count) displays"
        case .outboundInvalid: return "an invalid message"
        }
    }

    private static func short(_ text: String) -> String { String(text.prefix(64)) }

    // MARK: - Error codes

    /// Everything the classifier reads from an error and its underlying-error chain.
    struct ErrorCodes {
        /// NSURLErrorDomain and kCFErrorDomainCFNetwork codes (the same numbers), outermost first.
        var url: [Int] = []
        /// NSPOSIXErrorDomain codes and POSIX-domain stream codes.
        var posix: [Int32] = []
        /// SSL-domain stream codes and Security `errSSL…` statuses.
        var tls: [Int] = []
        /// A NetDB-domain stream code or a DNS-domain error (name resolution failed).
        var dns = false
        /// Lowercased `_NSURLErrorNWPathKey` descriptions, e.g. "unsatisfied (local network prohibited), …".
        var paths: [String] = []
        /// The system said this app may not use the local network (the one unambiguous Local Network signal).
        var localNetworkProhibited: Bool { paths.contains { $0.contains("local network prohibited") } }

        init(_ error: Error) { collect(error as NSError, depth: 0) }

        private mutating func collect(_ error: NSError, depth: Int) {
            switch error.domain {
            case NSURLErrorDomain, "kCFErrorDomainCFNetwork": url.append(error.code)
            case NSPOSIXErrorDomain, "kNWErrorDomainPOSIX": posix.append(Int32(truncatingIfNeeded: error.code))
            case "kNWErrorDomainTLS": tls.append(error.code)
            case "kNWErrorDomainDNS": dns = true
            case NSOSStatusErrorDomain where (-9899 ... -9800).contains(error.code): tls.append(error.code)
            default: break
            }
            if let domain = (error.userInfo["_kCFStreamErrorDomainKey"] as? NSNumber)?.intValue,
               let code = (error.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber)?.intValue {
                switch domain {
                case 1: posix.append(Int32(truncatingIfNeeded: code))   // kCFStreamErrorDomainPOSIX
                case 3: tls.append(code)                                 // kCFStreamErrorDomainSSL
                case 12: dns = true                                      // kCFStreamErrorDomainNetDB
                default: break
                }
            }
            if let path = error.userInfo["_NSURLErrorNWPathKey"] { paths.append(String(describing: path).lowercased()) }
            if depth < 8, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                collect(underlying, depth: depth + 1)
            }
        }
    }

    private static func classify(_ codes: ErrorCodes, host: String, deviceNetwork: DeviceNetwork) -> ConnectionFailure {
        if codes.localNetworkProhibited { return .localNetworkDenied }
        if codes.paths.contains(where: { $0.hasPrefix("unsatisfied") }) { return noUsableNetwork(host, deviceNetwork) }
        for code in codes.posix {
            switch code {
            case ECONNREFUSED: return .refused
            case ENETUNREACH, EHOSTUNREACH: return .noRoute
            case ETIMEDOUT: return .timedOut
            case ENETDOWN: return noUsableNetwork(host, deviceNetwork)
            case EMSGSIZE: return .protocolViolation(messageTooLarge)
            case ECONNRESET, EPIPE, ECONNABORTED, ENETRESET: return .networkLost
            // URLSessionWebSocketTask's end-of-stream: the host closed the connection without a close frame.
            case ENOTCONN: return .hostClosed
            default: continue
            }
        }
        if let status = codes.tls.first { return .tlsFailed(tlsDetail(status: status)) }
        if codes.dns { return .hostNotFound }
        for code in codes.url {
            switch code {
            case NSURLErrorCannotConnectToHost: return .refused
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .hostNotFound
            case NSURLErrorNotConnectedToInternet: return noUsableNetwork(host, deviceNetwork)
            case NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive: return .offline
            case NSURLErrorNetworkConnectionLost, NSURLErrorCancelled: return .networkLost
            case NSURLErrorSecureConnectionFailed: return .tlsFailed("secure connection failed")
            case NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
                return .tlsFailed("certificate rejected")
            case NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
                return .tlsFailed("the host asked for a client certificate")
            case NSURLErrorAppTransportSecurityRequiresSecureConnection: return .tlsFailed("blocked by App Transport Security")
            case NSURLErrorBadServerResponse: return .protocolViolation("an invalid WebSocket handshake or frame")
            case NSURLErrorCannotParseResponse: return .protocolViolation("an unreadable response")
            case NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation: return .protocolViolation(redirectRefused)
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return .invalidAddress
            default: continue
            }
        }
        return .networkLost
    }

    /// "No usable network" for this destination, split by the device's own path (see the type's documentation).
    private static func noUsableNetwork(_ host: String, _ device: DeviceNetwork) -> ConnectionFailure {
        switch device {
        case .unavailable: return .offline
        case .available: return isLocalNetworkHost(host) ? .localNetworkDenied : .noRoute
        case .unknown: return isLocalNetworkHost(host) ? .localNetworkDenied : .offline
        }
    }

    private static func tlsDetail(status: Int) -> String {
        switch status {
        // errSSLClosedAbort: the host dropped the handshake, e.g. its lockout after repeated wrong passwords.
        case -9806: return "the host ended the handshake"
        default: return "TLS error \(status)"
        }
    }
}
