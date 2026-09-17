import Foundation

/// Everything the optional diagnostics view shows, merged at up to 2 Hz from the engine, the framebuffer,
/// the renderer, audio and the region scheduler. Contains no credentials, fingerprints, host names or pixels.
public struct DiagnosticsSnapshot: Equatable, Sendable {
    /// Session clock time of the merge (monotonic seconds).
    public var capturedAt: TimeInterval = 0
    public var engine = EngineDiagnostics()
    public var audio: AudioMetrics?
    public var framebuffer: FramebufferCounters?
    /// Renderer draws presented and skipped (unchanged ticks).
    public var presented: Int?
    public var skippedPresentations: Int?
    public var regions = RegionSchedulerMetrics()
    /// Image and audio payload received over the last interval, in megabits per second.
    public var receiveMbps: Double?
    /// Host-reported changed-image updates per second, summed over displays.
    public var changedImagesPerSecond: Double?
    public var requestedResolution: ResolutionPreset?
    public var effectiveResolution: EffectiveResolution?
    public var canvases: [DisplayID: PixelSize] = [:]
    /// Presses and scrolls refused because their target had no valid pixels yet.
    public var inputBlocked = 0
    /// Session clock time of the engine sample `receiveMbps` was last measured at (the next rate's baseline).
    var engineSampledAt: TimeInterval = 0
    public init() {}

    /// A new snapshot. `newEngineSample` is true when `engine` has just arrived from the engine; the receive rate
    /// is measured only between such samples of one connection generation (`previous` supplies the baseline). A
    /// merge in between (the view asking for fresh counters) keeps the last rate and its baseline, instead of
    /// measuring an interval in which the byte count couldn't change.
    static func merged(at now: TimeInterval, engine: EngineDiagnostics, newEngineSample: Bool, previous: DiagnosticsSnapshot?,
                       audio: AudioMetrics?, framebuffer: FramebufferCounters?, presentation: PresentationState?,
                       regions: RegionSchedulerMetrics, requested: ResolutionPreset?, effective: EffectiveState?,
                       inputBlocked: Int) -> DiagnosticsSnapshot {
        var snapshot = DiagnosticsSnapshot()
        snapshot.capturedAt = now
        snapshot.engine = engine
        snapshot.audio = audio
        snapshot.framebuffer = framebuffer
        snapshot.presented = presentation?.presented
        snapshot.skippedPresentations = presentation?.skipped
        snapshot.regions = regions
        snapshot.changedImagesPerSecond = engine.hostFPS
        snapshot.requestedResolution = requested
        snapshot.effectiveResolution = effective?.resolution
        snapshot.canvases = effective?.canvases ?? [:]
        snapshot.inputBlocked = inputBlocked
        guard let previous, previous.engine.generation == engine.generation else {
            // The first sample of a connection generation is only a baseline.
            snapshot.engineSampledAt = now
            return snapshot
        }
        guard newEngineSample else {
            snapshot.receiveMbps = previous.receiveMbps
            snapshot.engineSampledAt = previous.engineSampledAt
            return snapshot
        }
        snapshot.engineSampledAt = now
        let elapsed = now - previous.engineSampledAt
        if elapsed > 0, engine.bytesReceived >= previous.engine.bytesReceived {
            snapshot.receiveMbps = Double(engine.bytesReceived - previous.engine.bytesReceived) * 8 / elapsed / 1_000_000
        }
        return snapshot
    }

    /// Plain-text export for "Export Diagnostics": counters only, nothing identifying.
    public var exportText: String {
        var lines = [
            "receive Mbps: \(Self.format(receiveMbps))",
            "changed images/s: \(Self.format(changedImagesPerSecond))",
            "frames received/decoded/committed: \(engine.framesReceived)/\(engine.framesDecoded)/\(engine.framesCommitted)",
            "frames stale/rejected/unexpected: \(engine.framesStale)/\(engine.framesRejected)/\(engine.framesUnexpected)",
            "decoder jobs/bytes (peak): \(engine.decodeJobsInFlight)/\(engine.decodeBytesInFlight) (\(engine.decodeJobsPeak)/\(engine.decodeBytesPeak))",
            "frame age s: \(Self.format(engine.lastPatchAge))",
            "RTT ms: \(Self.format(engine.lastRTTMilliseconds))",
            "subscriptions sent (last minute): \(engine.subscriptionsSent) (\(regions.subscriptionsLastMinute))",
            "region refinements/deferrals: \(regions.refinementsSent)/\(regions.deferrals)",
            "time to fresh region s: \(Self.format(regions.lastTimeToFreshRegion))",
            "input sent/dropped/blocked: \(engine.inputMessagesSent)/\(engine.inputMessagesDropped)/\(inputBlocked)",
            "recoveries: \(engine.recoveries)",
        ]
        if let presented { lines.append("presented/skipped: \(presented)/\(skippedPresentations ?? 0)") }
        if let framebuffer {
            lines.append("applied/stale/swaps/allocation failures: \(framebuffer.committed)/\(framebuffer.stale)/\(framebuffer.swaps)/\(framebuffer.allocationFailures)")
        }
        if let audio {
            lines.append("audio queued ms/underruns/drops: \(Self.format(audio.queuedMilliseconds))/\(audio.underruns)/\(audio.drops)")
        }
        let requested = requestedResolution?.title ?? "–"
        let effective: String
        switch effectiveResolution {
        case .native?: effective = "native"
        case .preset(let preset)?: effective = preset.title
        case nil: effective = "–"
        }
        lines.append("resolution requested/effective: \(requested)/\(effective)")
        lines.append("canvases: " + canvases.sorted { $0.key < $1.key }.map { "\($0.value)" }.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    private static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return String(format: "%.2f", value)
    }
}
