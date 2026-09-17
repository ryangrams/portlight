import Foundation

/// Tuning for `JitterBuffer`. The defaults are the Mac reference's starting points, to be measured on iPhone.
public struct JitterBufferPolicy: Equatable, Sendable {
    /// Blocks required before playback starts, and again after an underrun.
    public var startPackets: Int
    /// Queued plus scheduled audio never exceeds this; the oldest unscheduled blocks are dropped instead.
    public var maxQueuedMilliseconds: Double
    /// Blocks handed to the output at once. The rest stay droppable here.
    public var scheduleAheadPackets: Int

    public init(startPackets: Int = 3, maxQueuedMilliseconds: Double = 250, scheduleAheadPackets: Int = 3) {
        self.startPackets = max(1, startPackets)
        self.maxQueuedMilliseconds = max(1, maxQueuedMilliseconds)
        self.scheduleAheadPackets = max(1, scheduleAheadPackets)
    }

    /// AAC: 3 × 1024 frames at 48 kHz ≈ 64 ms. μ-law: 3 × 480 frames at 24 kHz = 60 ms.
    public static func standard(for codec: AudioCodec) -> JitterBufferPolicy {
        switch codec {
        case .aac, .mulaw: return JitterBufferPolicy(startPackets: 3, maxQueuedMilliseconds: 250, scheduleAheadPackets: 3)
        }
    }
}

public enum JitterBufferState: Equatable, Sendable {
    /// Waiting for `startPackets` blocks (initially, after a flush, or after an underrun).
    case prebuffering
    /// Feeding the output.
    case playing
}

public struct JitterBufferMetrics: Equatable, Sendable {
    /// Unscheduled plus scheduled-but-unconsumed audio.
    public var queuedMilliseconds: Double = 0
    /// Times the output ran dry while playing.
    public var underruns = 0
    /// Oldest blocks discarded to keep the queue within its bound.
    public var drops = 0
    /// First block to playback start, for the most recent cold start (creation or flush). Nil until then.
    public var startupMilliseconds: Double?
    public init() {}
}

/// A bounded playout queue between decode and the output device.
///
/// Holds decoded blocks until `startPackets` are available, hands at most `scheduleAheadPackets` to the
/// output at a time, never lets queued plus scheduled audio exceed `maxQueuedMilliseconds` (dropping the
/// oldest unscheduled blocks, which bounds latency rather than letting seconds of delay accumulate), and
/// re-prebuffers after an underrun. Pure state: time is injected and nothing here touches a device.
public struct JitterBuffer<Block> {
    public var policy: JitterBufferPolicy
    public private(set) var state: JitterBufferState = .prebuffering
    public private(set) var metrics = JitterBufferMetrics()

    private var pending: [(block: Block, milliseconds: Double)] = []
    /// Durations of blocks the output holds, oldest first (it consumes them in order).
    private var scheduled: [Double] = []
    private var coldStart = true
    private var prebufferStartedAt: Double?

    public init(policy: JitterBufferPolicy = JitterBufferPolicy()) {
        self.policy = policy
    }

    public var pendingCount: Int { pending.count }
    public var scheduledCount: Int { scheduled.count }
    public var queuedMilliseconds: Double { metrics.queuedMilliseconds }

    /// Adds a decoded block of `milliseconds` duration at time `now` (seconds).
    public mutating func push(_ block: Block, milliseconds: Double, now: Double) {
        if coldStart && prebufferStartedAt == nil { prebufferStartedAt = now }
        pending.append((block, milliseconds.isFinite ? max(0, milliseconds) : 0))
        recomputeQueued()
        var dropped = false
        while metrics.queuedMilliseconds > policy.maxQueuedMilliseconds, !pending.isEmpty {
            pending.removeFirst()
            metrics.drops += 1
            dropped = true
            recomputeQueued()
        }
        // A full queue also starts playback, so a threshold larger than the bound can't stall forever.
        if state == .prebuffering, !pending.isEmpty, pending.count + scheduled.count >= policy.startPackets || dropped {
            state = .playing
            if coldStart {
                coldStart = false
                if let started = prebufferStartedAt { metrics.startupMilliseconds = max(0, (now - started) * 1000) }
                prebufferStartedAt = nil
            }
        }
    }

    /// Blocks to hand to the output now, oldest first: none while prebuffering, otherwise enough to keep
    /// `scheduleAheadPackets` with the output. They stay counted as queued until consumed.
    public mutating func takeForOutput() -> [Block] {
        guard state == .playing else { return [] }
        var blocks: [Block] = []
        while scheduled.count < policy.scheduleAheadPackets, !pending.isEmpty {
            let next = pending.removeFirst()
            scheduled.append(next.milliseconds)
            blocks.append(next.block)
        }
        return blocks
    }

    /// The output finished with its oldest scheduled block. Running dry while playing is an underrun:
    /// it is counted and the buffer waits for `startPackets` again before feeding the output.
    public mutating func outputConsumedBlock() {
        guard !scheduled.isEmpty else { return }
        scheduled.removeFirst()
        recomputeQueued()
        if state == .playing && scheduled.isEmpty && pending.isEmpty {
            metrics.underruns += 1
            state = .prebuffering
        }
    }

    /// Discards everything, queued and scheduled. The next block begins a cold start. Counters are kept.
    public mutating func flush() {
        pending.removeAll()
        scheduled.removeAll()
        state = .prebuffering
        coldStart = true
        prebufferStartedAt = nil
        recomputeQueued()
    }

    private mutating func recomputeQueued() {
        metrics.queuedMilliseconds = pending.reduce(0) { $0 + $1.milliseconds } + scheduled.reduce(0, +)
    }
}

extension JitterBuffer: Sendable where Block: Sendable {}
