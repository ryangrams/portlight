import Testing
@testable import PortlightKit

/// Never retried, automatic or not: credentials, trust, certificate change, protocol, address, cancel.
let reconnectNeverRetried: [ConnectionFailure] = [
    .authenticationRejected("Incorrect password or incompatible protocol"), .trustDeclined,
    .certificateChanged(Fixture.trustPrompt), .protocolViolation("unexpected welcome"), .invalidAddress,
    .tlsFailed("handshake"), .hostNotFound, .localNetworkDenied, .canceled,
]
let reconnectTransient: [ConnectionFailure] = [.refused, .noRoute, .timedOut, .offline, .networkLost, .hostClosed, .hostTimeout("stalled")]

@Suite struct ReconnectPolicyTests {
    let policy = ReconnectPolicy.standard
    static let bases: [Double] = [0.25, 0.5, 1, 2, 4, 8]

    @Test func ladderAppliesFullJitterWithFloor() {
        for (index, base) in Self.bases.enumerated() {
            #expect(policy.decision(after: .networkLost, attempt: index + 1, automatic: true,
                                    elapsedSinceFirstFailure: 1, random: 0.5) == .retry(after: max(0.1, base * 0.5)))
            #expect(policy.decision(after: .networkLost, attempt: index + 1, automatic: true,
                                    elapsedSinceFirstFailure: 1, random: 0) == .retry(after: 0.1))
            for random in [0.0, 0.1, 0.37, 0.5, 0.9, 0.999_999] {
                guard case .retry(let delay) = policy.decision(after: .timedOut, attempt: index + 1, automatic: true,
                                                               elapsedSinceFirstFailure: 1, random: random) else {
                    Issue.record("attempt \(index + 1) should retry"); continue
                }
                #expect(delay >= 0.1)
                #expect(delay <= max(0.1, base))
            }
        }
    }

    @Test func exactJitteredValues() {
        #expect(policy.decision(after: .hostClosed, attempt: 6, automatic: true, elapsedSinceFirstFailure: 30, random: 0.75) == .retry(after: 6))
        #expect(policy.decision(after: .hostClosed, attempt: 4, automatic: true, elapsedSinceFirstFailure: 3, random: 0.25) == .retry(after: 0.5))
        // 0.25 × 0.2 = 0.05 is below the floor.
        #expect(policy.decision(after: .hostClosed, attempt: 1, automatic: true, elapsedSinceFirstFailure: 0, random: 0.2) == .retry(after: 0.1))
    }

    @Test func stopsAfterSixAttempts() {
        #expect(policy.maxAttempts == 6)
        #expect(policy.decision(after: .networkLost, attempt: 7, automatic: true, elapsedSinceFirstFailure: 20, random: 0.5) == .stop)
    }

    @Test func outOfRangeInputsAreClamped() {
        #expect(policy.decision(after: .offline, attempt: 3, automatic: true, elapsedSinceFirstFailure: 0, random: 5) == .retry(after: 1))
        #expect(policy.decision(after: .offline, attempt: 3, automatic: true, elapsedSinceFirstFailure: 0, random: -1) == .retry(after: 0.1))
        #expect(policy.decision(after: .offline, attempt: 3, automatic: true, elapsedSinceFirstFailure: 0, random: .nan) == .retry(after: 0.1))
        #expect(policy.decision(after: .offline, attempt: 0, automatic: true, elapsedSinceFirstFailure: 0, random: 0.8) == .retry(after: 0.2))
    }

    @Test func busyRetriesEveryTwoSecondsOnlyInAutomaticWindow() {
        let busy = ConnectionFailure.busy("Another viewer is connected. Disconnect it before connecting here.")
        #expect(policy.decision(after: busy, attempt: 1, automatic: true, elapsedSinceFirstFailure: 0, random: 0.3) == .retry(after: 2))
        #expect(policy.decision(after: busy, attempt: 9, automatic: true, elapsedSinceFirstFailure: 19.9, random: 0.3) == .retry(after: 2))
        #expect(policy.decision(after: busy, attempt: 2, automatic: true, elapsedSinceFirstFailure: 20, random: 0.3) == .stop)
        #expect(policy.decision(after: busy, attempt: 1, automatic: false, elapsedSinceFirstFailure: 0, random: 0.3) == .stop)
    }

    @Test(arguments: reconnectNeverRetried)
    func permanentFailuresNeverRetry(_ failure: ConnectionFailure) {
        #expect(policy.decision(after: failure, attempt: 1, automatic: true, elapsedSinceFirstFailure: 0, random: 0.5) == .stop)
        #expect(policy.decision(after: failure, attempt: 1, automatic: false, elapsedSinceFirstFailure: 0, random: 0.5) == .stop)
    }

    @Test(arguments: reconnectTransient)
    func transientFailuresRetryOnlyWhenAutomatic(_ failure: ConnectionFailure) {
        #expect(policy.decision(after: failure, attempt: 2, automatic: true, elapsedSinceFirstFailure: 1, random: 0.5) == .retry(after: 0.25))
        #expect(policy.decision(after: failure, attempt: 2, automatic: false, elapsedSinceFirstFailure: 1, random: 0.5) == .stop)
    }
}
