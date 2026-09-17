import Foundation
import os

/// Lets the audio-session layer pause device output without changing whether audio is enabled.
public protocol AudioOutputSuspending: AnyObject, Sendable {
    /// Suspends output (stop now, discard queued audio, ignore packets) or allows it again. `completion`
    /// runs on the audio queue once the change has taken effect, e.g. before the session is deactivated.
    func setOutputSuspended(_ suspended: Bool, completion: (@Sendable () -> Void)?)
}

extension AudioOutputSuspending {
    public func setOutputSuspended(_ suspended: Bool) { setOutputSuspended(suspended, completion: nil) }
}

/// Audio diagnostics snapshot. Safe to read from any thread.
public struct AudioMetrics: Equatable, Sendable {
    /// Acknowledged configuration; nil while audio is off.
    public var configuration: AudioConfiguration?
    public var isSuspended = false
    /// The device is running and fed from the jitter buffer.
    public var isPlaying = false
    public var queuedMilliseconds: Double = 0
    public var underruns = 0
    public var drops = 0
    public var startupMilliseconds: Double?
    /// Packets that passed the epoch gate.
    public var acceptedPackets = 0
    /// Packets from another epoch or in a format that doesn't match the configuration.
    public var rejectedPackets = 0
    public var decodeFailures = 0
    /// Device start failures and refused blocks.
    public var outputFailures = 0
    /// Device restarts after it stopped on its own or stalled.
    public var outputRestarts = 0
    /// Packets refused because the audio queue fell too far behind.
    public var backlogDrops = 0
    public init() {}
}

/// Decodes and plays host audio on its own serial queue: never the main thread, never the image path.
///
/// Owns the epoch gate, the decoder, the jitter buffer and the output. The session calls the
/// `AudioPacketSink` methods in stream order from its pipeline; they run on the audio queue in that
/// order. `stopAudio()` also voids packets submitted before it that haven't been processed yet, so nothing
/// submitted before a stop can play after it. Driven only by packets and output callbacks (no timers).
public final class AudioPipeline: AudioPacketSink, AudioOutputSuspending, @unchecked Sendable {
    // @unchecked Sendable: `output` and every `var` below are touched only on `queue` (the initializer
    // runs before any work is queued). State shared across threads lives in the `admission` and
    // `published` locks; everything else is immutable.
    private let queue = DispatchQueue(label: "Portlight.Audio", qos: .userInteractive)
    private let clock: any SessionClock
    private let stallTimeout: Double
    private let retryDelay: Double
    private let maxBacklogPackets: Int
    private let admission = OSAllocatedUnfairLock(initialState: Admission())
    private let published = OSAllocatedUnfairLock(initialState: AudioMetrics())

    private let output: AudioOutput
    private var gate = AudioEpochGate()
    private var decoder = AudioPacketDecoder()
    private var buffer = JitterBuffer<PCMBlock>(policy: .standard(for: .aac))
    /// Format of everything in `buffer`.
    private var bufferFormat: PCMFormat?
    /// Counter fields of the published metrics.
    private var counters = AudioMetrics()
    private var suspended = false
    /// The output has begun a run in `bufferFormat` for the current generation.
    private var outputRunning = false
    /// The output may hold the device and needs `stop()` to release it.
    private var deviceHeld = false
    /// Bumped whenever scheduled blocks are abandoned; completions from older generations are ignored.
    private var outputGeneration: UInt64 = 0
    private var lastOutputProgress: Double?
    private var retryAt: Double?

    private struct Admission: Sendable {
        var generation: UInt64 = 0
        var backlog = 0
        var backlogDrops = 0
    }

    /// - Parameters:
    ///   - output: the device; confined to the audio queue from now on.
    ///   - clock: the session's monotonic clock (only `now()` is used; the pipeline sets no timers).
    ///   - stallTimeout: scheduled audio left unconsumed this long means the device stalled; restart it.
    ///   - retryDelay: wait after a failed device start before trying again.
    ///   - maxBacklogPackets: submitted-but-unprocessed packets beyond this are dropped and counted.
    public init(output: AudioOutput = EngineAudioOutput(),
                clock: any SessionClock = SystemSessionClock(),
                stallTimeout: Double = 1.0, retryDelay: Double = 1.0, maxBacklogPackets: Int = 64) {
        self.output = output
        self.clock = clock
        self.stallTimeout = stallTimeout
        self.retryDelay = retryDelay
        self.maxBacklogPackets = max(1, maxBacklogPackets)
        output.onUnexpectedStop = { [weak self] in self?.outputStoppedUnexpectedly() }
    }

    // MARK: AudioPacketSink

    public func audioConfigurationAcknowledged(_ configuration: AudioConfiguration?, revision: Int) {
        queue.async { self.applyAcknowledgement(configuration, revision: revision) }
    }

    public func submit(_ header: AudioHeader, payload: Data) {
        let limit = maxBacklogPackets
        let ticket: UInt64? = admission.withLock { state in
            guard state.backlog < limit else { state.backlogDrops += 1; return nil }
            state.backlog += 1
            return state.generation
        }
        guard let ticket else { return }
        queue.async { self.process(header, payload: payload, ticket: ticket) }
    }

    public func stopAudio() {
        admission.withLock { $0.generation &+= 1 }
        queue.async { self.stopNow() }
    }

    // MARK: AudioOutputSuspending

    public func setOutputSuspended(_ suspended: Bool, completion: (@Sendable () -> Void)?) {
        queue.async {
            self.applySuspension(suspended)
            completion?()
        }
    }

    // MARK: Diagnostics

    public var metrics: AudioMetrics {
        var snapshot = published.withLock { $0 }
        snapshot.backlogDrops = admission.withLock { $0.backlogDrops }
        return snapshot
    }

    /// Returns once everything queued so far has run (tests and orderly teardown).
    func waitUntilIdle() { queue.sync {} }

    /// Holds the audio queue while `body` runs so tests can line up work behind it deterministically.
    func withQueueHeld(_ body: () -> Void) {
        queue.suspend()
        body()
        queue.resume()
    }

    // MARK: Audio queue

    private func applyAcknowledgement(_ configuration: AudioConfiguration?, revision: Int) {
        switch gate.acknowledged(configuration, revision: revision) {
        case .unchanged:
            break
        case .started:
            // New codec/bitrate or audio just enabled: old-format audio never plays into the new epoch.
            // The device stays up; the next run reconnects the node if the PCM format changed.
            resetPlayback(releaseDevice: false)
            decoder.reset()
            retryAt = nil
            if let codec = configuration?.codec { buffer.policy = .standard(for: codec) }
        case .stopped:
            resetPlayback(releaseDevice: true)
            decoder.reset()
            retryAt = nil
        }
        publish()
    }

    private func process(_ header: AudioHeader, payload: Data, ticket: UInt64) {
        let current = admission.withLock { state -> UInt64 in
            state.backlog -= 1
            return state.generation
        }
        guard ticket == current else { return }
        guard gate.accept(header) else {
            counters.rejectedPackets += 1
            publish()
            return
        }
        counters.acceptedPackets += 1
        let now = clock.now()
        restartIfStalled(now: now)
        if suspended || (retryAt.map { now < $0 } ?? false) {
            publish()
            return
        }
        guard let block = decoder.decode(header, payload: payload) else {
            counters.decodeFailures += 1
            publish()
            return
        }
        if let bufferFormat, bufferFormat != block.format { resetPlayback(releaseDevice: false) }
        bufferFormat = block.format
        buffer.push(block, milliseconds: block.milliseconds, now: now)
        pump(now: now)
        publish()
    }

    /// Starts the output when the buffer is ready and keeps it fed up to the schedule-ahead limit.
    private func pump(now: Double) {
        guard !suspended, buffer.state == .playing, let format = bufferFormat else { return }
        if !outputRunning {
            do {
                try output.start(format: format)
            } catch {
                counters.outputFailures += 1
                resetPlayback(releaseDevice: false)
                output.stop()
                deviceHeld = false
                retryAt = now + retryDelay
                return
            }
            outputRunning = true
            deviceHeld = true
            retryAt = nil
        }
        let wasIdle = buffer.scheduledCount == 0
        let blocks = buffer.takeForOutput()
        guard !blocks.isEmpty else { return }
        if wasIdle { lastOutputProgress = now }
        let generation = outputGeneration
        for block in blocks {
            let scheduled = output.schedule(block) { [weak self] in self?.blockConsumed(generation: generation) }
            guard scheduled else {
                counters.outputFailures += 1
                resetPlayback(releaseDevice: false)
                return
            }
        }
    }

    /// Output callback (any thread).
    private func blockConsumed(generation: UInt64) {
        queue.async {
            guard generation == self.outputGeneration else { return }
            let now = self.clock.now()
            self.buffer.outputConsumedBlock()
            self.lastOutputProgress = now
            self.pump(now: now)
            self.publish()
        }
    }

    /// Output callback (any thread): the device stopped on its own, e.g. an engine configuration change.
    private func outputStoppedUnexpectedly() {
        queue.async {
            guard self.deviceHeld else { return }
            self.counters.outputRestarts += 1
            self.resetPlayback(releaseDevice: true)
            self.publish()
        }
    }

    /// Scheduled audio that stops being consumed (lost callbacks, a wedged device) would otherwise leave
    /// the buffer full and silent forever.
    private func restartIfStalled(now: Double) {
        guard outputRunning, buffer.scheduledCount > 0, let last = lastOutputProgress, now - last > stallTimeout else { return }
        counters.outputRestarts += 1
        resetPlayback(releaseDevice: true)
    }

    private func stopNow() {
        gate.reset()
        decoder.reset()
        retryAt = nil
        resetPlayback(releaseDevice: true)
        publish()
    }

    private func applySuspension(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        if value {
            resetPlayback(releaseDevice: true)
            decoder.reset()
        } else {
            retryAt = nil
        }
        publish()
    }

    /// Abandons queued and scheduled audio. With `releaseDevice`, also stops the output and frees the device.
    private func resetPlayback(releaseDevice: Bool) {
        buffer.flush()
        bufferFormat = nil
        outputGeneration &+= 1
        lastOutputProgress = nil
        outputRunning = false
        if releaseDevice && deviceHeld {
            output.stop()
            deviceHeld = false
        }
    }

    private func publish() {
        var snapshot = counters
        snapshot.configuration = gate.configuration
        snapshot.isSuspended = suspended
        snapshot.isPlaying = outputRunning && buffer.state == .playing
        let jitter = buffer.metrics
        snapshot.queuedMilliseconds = jitter.queuedMilliseconds
        snapshot.underruns = jitter.underruns
        snapshot.drops = jitter.drops
        snapshot.startupMilliseconds = jitter.startupMilliseconds
        let value = snapshot
        published.withLock { $0 = value }
    }
}
