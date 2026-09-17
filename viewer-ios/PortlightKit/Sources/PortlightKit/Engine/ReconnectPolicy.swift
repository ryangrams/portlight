import Foundation

public enum ReconnectDecision: Equatable, Sendable {
    case retry(after: TimeInterval)
    case stop
}

/// Pure foreground-reconnect ladder (URC's 0.25…8 s doubling, plus the full jitter URC lacked so a
/// fleet of phones doesn't retry in lockstep). Only automatic reconnects of a lost session retry; a
/// deliberate connect that fails shows its precise failure and lets the user choose.
public struct ReconnectPolicy: Equatable, Sendable {
    /// Base delay per retry; its count is the attempt limit.
    public var ladder: [TimeInterval]
    public var minimumDelay: TimeInterval
    /// `busy` right after a drop is usually our own zombie session still registered on the host.
    public var busyRetryInterval: TimeInterval
    public var busyWindow: TimeInterval

    public init(ladder: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 8], minimumDelay: TimeInterval = 0.1,
                busyRetryInterval: TimeInterval = 2, busyWindow: TimeInterval = 20) {
        self.ladder = ladder; self.minimumDelay = minimumDelay
        self.busyRetryInterval = busyRetryInterval; self.busyWindow = busyWindow
    }
    public static let standard = ReconnectPolicy()
    public var maxAttempts: Int { ladder.count }

    /// - Parameters:
    ///   - attempt: 1-based number of the retry being considered (values below 1 count as 1).
    ///   - automatic: true for a foreground reconnect after a transient loss; false for a user's connect.
    ///   - random: uniform in [0, 1); full jitter picks `base × random`, never below `minimumDelay`.
    public func decision(after failure: ConnectionFailure, attempt: Int, automatic: Bool,
                         elapsedSinceFirstFailure: TimeInterval, random: Double) -> ReconnectDecision {
        guard automatic else { return .stop }
        if case .busy = failure {
            // Time-bounded rather than counted: the zombie clears when the host notices the dead socket.
            return elapsedSinceFirstFailure < busyWindow ? .retry(after: busyRetryInterval) : .stop
        }
        // Never credentials, trust, certificate changes, protocol violations or bad addresses.
        guard failure.allowsAutomaticRetry else { return .stop }
        let index = max(1, attempt) - 1
        guard index < ladder.count else { return .stop }
        let unit = random.isFinite ? min(max(random, 0), 1) : 0
        return .retry(after: max(minimumDelay, ladder[index] * unit))
    }
}
