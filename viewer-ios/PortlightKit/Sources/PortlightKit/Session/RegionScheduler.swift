import Foundation

/// Region refinement bookkeeping for the diagnostics view.
public struct RegionSchedulerMetrics: Equatable, Sendable {
    /// Region refinements submitted.
    public var refinementsSent = 0
    /// Settles that had to wait because touches were down or remote input was held.
    public var deferrals = 0
    /// Subscriptions of any kind sent during the last 60 s (capture restarts on the current host).
    public var subscriptionsLastMinute = 0
    /// Last measured time from a refinement's submit until its requested regions were covered.
    public var lastTimeToFreshRegion: TimeInterval?
    public init() {}
}

/// Decides when a settled viewport is worth a new `regions` subscription.
///
/// Every accepted subscription restarts capture and releases held input on the current host, so a
/// refinement goes out only 150 ms after the last viewport change, with no touches down, nothing held,
/// not paused and connected — and only when `RegionPlanner.needsRefinement` says the host's current
/// regions no longer suit the view (planned with margin and grid snapping, so small pans never resubscribe).
/// A settle blocked by touches or held input is deferred and re-evaluated once they are released.
///
/// Pure bookkeeping: the controller owns the timer (on the injected clock) and supplies `now`.
/// Confined to the controller's actor.
final class RegionScheduler {
    static let settleDelay: TimeInterval = 0.15
    /// Clock arithmetic slack, so a timer that fires exactly at the deadline counts as settled.
    static let slack: TimeInterval = 1e-9

    struct Context {
        var connected: Bool
        var paused: Bool
        var touchesActive: Bool
        var holdingInput: Bool
        var viewport: ViewportModel
        var selection: [DisplayID]
        /// Regions of the accepted revision (omitted = full).
        var current: [DisplayID: NormalizedRect]
    }

    enum Verdict: Equatable {
        case idle
        /// Not settled yet; ask again after this long.
        case wait(TimeInterval)
        /// Settled, but touches or held input block a subscription.
        case deferred
        /// Submit these regions (every laid-out selected display, `.zero` when hidden).
        case submit([DisplayID: NormalizedRect])
    }

    private(set) var lastChange: TimeInterval?
    private(set) var isDeferred = false
    private(set) var metrics = RegionSchedulerMetrics()
    private var sentTimes: [TimeInterval] = []
    private var fresh: (submittedAt: TimeInterval, regions: [DisplayID: NormalizedRect], accepted: Bool)?

    var isPending: Bool { lastChange != nil }

    func viewportDidChange(at now: TimeInterval) {
        lastChange = now
    }

    /// Forget a pending settle (disconnect, selection or topology change resets regions to full).
    func cancel() {
        lastChange = nil
        isDeferred = false
    }

    func evaluate(at now: TimeInterval, _ context: Context) -> Verdict {
        guard let changed = lastChange else { return .idle }
        let elapsed = now - changed
        if elapsed + Self.slack < Self.settleDelay { return .wait(Self.settleDelay - elapsed) }
        guard context.connected, !context.paused, !context.selection.isEmpty,
              let visible = context.viewport.visibleDesktopRect else {
            cancel()
            return .idle
        }
        if context.touchesActive || context.holdingInput {
            if !isDeferred { isDeferred = true; metrics.deferrals += 1 }
            return .deferred
        }
        cancel()
        let wanted = Set(context.selection)
        let layout = context.viewport.layout.filter { wanted.contains($0.key) }
        let visibleNow = RegionPlanner.regions(layout: layout, visibleDesktop: visible, marginFraction: 0, grid: 0)
        let planned = RegionPlanner.regions(layout: layout, visibleDesktop: visible)
        guard RegionPlanner.needsRefinement(current: context.current, visibleNow: visibleNow, planned: planned) else { return .idle }
        return .submit(planned)
    }

    // MARK: Metrics

    /// Every subscription the engine sent (any cause).
    func recordSent(at now: TimeInterval) {
        sentTimes.append(now)
        prune(now)
    }

    func refinementSubmitted(at now: TimeInterval, regions: [DisplayID: NormalizedRect]) {
        metrics.refinementsSent += 1
        fresh = (now, regions, false)
    }

    /// An accepted revision's regions; starts the coverage wait when they are the pending refinement's.
    func accepted(regions: [DisplayID: NormalizedRect]) {
        guard let pending = fresh, !pending.accepted else { return }
        if Self.significant(pending.regions) == Self.significant(regions) { fresh?.accepted = true }
    }

    /// Records time-to-fresh-region once every non-empty requested region is covered. True when recorded.
    @discardableResult
    func checkFresh(at now: TimeInterval, isCovered: (DisplayID) -> Bool?) -> Bool {
        guard let pending = fresh, pending.accepted else { return false }
        for (display, region) in pending.regions where !region.isZero {
            guard let covered = isCovered(display) else { fresh = nil; return false } // not measurable
            if !covered { return false }
        }
        metrics.lastTimeToFreshRegion = now - pending.submittedAt
        fresh = nil
        return true
    }

    var awaitingFreshRegion: Bool { fresh?.accepted == true }

    func snapshot(at now: TimeInterval) -> RegionSchedulerMetrics {
        prune(now)
        var result = metrics
        result.subscriptionsLastMinute = sentTimes.count
        return result
    }

    /// New connection: forget pending work; counters keep accumulating for the session's diagnostics.
    func resetForConnection() {
        cancel()
        fresh = nil
    }

    private func prune(_ now: TimeInterval) {
        sentTimes.removeAll { now - $0 >= 60 }
    }

    private static func significant(_ regions: [DisplayID: NormalizedRect]) -> [DisplayID: NormalizedRect] {
        regions.filter { !$0.value.isFull }
    }
}
