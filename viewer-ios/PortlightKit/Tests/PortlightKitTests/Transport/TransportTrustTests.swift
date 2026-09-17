import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// The pin rule and the real URLSession challenge delegate, with a real SecTrust and no network (NET-01).
@Suite struct TransportTrustTests {
    static let pin = TransportTestCertificate.fingerprint

    @Test func fingerprintIsTheSHA256OfTheDERInTheHostFormat() {
        #expect(ServerTrustPolicy.fingerprint(ofCertificateDER: TransportTestCertificate.abc).value
                == "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD")
        // Matches `openssl x509 -fingerprint -sha256`, the same computation as the host's "TLS SHA256" line.
        #expect(ServerTrustPolicy.fingerprint(ofCertificateDER: TransportTestCertificate.der) == Self.pin)
    }

    @Test func onlyAnExactPinMatches() {
        let other = CertificateFingerprint(digest: [UInt8](repeating: 0x3D, count: 32))
        let der = TransportTestCertificate.der
        #expect(ServerTrustPolicy.verdict(leafCertificateDER: der, pin: Self.pin) == .matchesPin(Self.pin))
        #expect(ServerTrustPolicy.verdict(leafCertificateDER: der, pin: nil) == .needsApproval(Self.pin))
        #expect(ServerTrustPolicy.verdict(leafCertificateDER: der, pin: other) == .needsApproval(Self.pin))
        #expect(ServerTrustPolicy.verdict(leafCertificateDER: nil, pin: Self.pin) == .noCertificate)
        #expect(ServerTrustPolicy.verdict(leafCertificateDER: TransportTestCertificate.empty, pin: nil) == .noCertificate)
    }

    @Test func leafDERComesFromTheTrustObject() throws {
        let trust = try #require(TransportTestCertificate.trust())
        #expect(ServerTrustPolicy.leafCertificateDER(of: trust) == TransportTestCertificate.der)
    }

    @Test(arguments: [false, true])
    func pinnedCertificateIsAcceptedThroughTheDelegate(taskLevel: Bool) throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        let trust = try #require(TransportTestCertificate.trust())
        #expect(socket.presentChallenge(.serverTrust, trust: trust, taskLevel: taskLevel) == [.useCredential(hasCredential: true)])
        #expect(probe.events == [.identityVerified(Self.pin)])
    }

    @Test(arguments: [false, true])
    func unknownCertificateIsCancelledThroughTheDelegate(taskLevel: Bool) throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: nil)
        let socket = try #require(probe.socket(0))
        let trust = try #require(TransportTestCertificate.trust())
        #expect(socket.presentChallenge(.serverTrust, trust: trust, taskLevel: taskLevel) == [.cancel])
        #expect(probe.events == [.trustRequired(TrustPrompt(endpoint: TransportUnitProbe.endpoint, fingerprint: Self.pin, previousFingerprint: nil))])
        #expect(socket.shutdownCount == 1)
    }

    @Test func serverTrustChallengeWithoutATrustObjectIsCancelled() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        #expect(socket.presentChallenge(.serverTrust, trust: nil) == [.cancel])
        #expect(probe.events == [.closed(.tlsFailed("the host presented no certificate"))])
    }

    @Test func otherChallengeTypesGetDefaultHandling() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        #expect(socket.presentChallenge(.httpBasic, trust: nil) == [.performDefaultHandling])
        #expect(socket.presentChallenge(.httpBasic, trust: nil, taskLevel: true) == [.performDefaultHandling])
        #expect(probe.events.isEmpty)
    }

    @Test func challengesForAClosedAttemptAreCancelled() throws {
        let probe = TransportUnitProbe()
        probe.connect(generation: 1, pin: Self.pin)
        let socket = try #require(probe.socket(0))
        probe.close()
        let trust = try #require(TransportTestCertificate.trust())
        #expect(socket.presentChallenge(.serverTrust, trust: trust) == [.cancel])
        #expect(probe.events.isEmpty)
    }
}
