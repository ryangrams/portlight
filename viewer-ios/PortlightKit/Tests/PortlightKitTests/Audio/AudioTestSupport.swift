import AVFoundation
import Foundation
@testable import PortlightKit

/// Manually advanced monotonic clock, in seconds. The audio pipeline only reads `now()`; it sets no timers.
final class AudioTestClock: SessionClock, @unchecked Sendable {
    // Invariant: `value` is only read or written while holding `lock`.
    private let lock = NSLock()
    private var value: TimeInterval
    init(_ start: TimeInterval = 100) { value = start }
    func now() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value += seconds
    }
    /// Never fires: nothing under test schedules work on this clock.
    func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> Cancellable {
        AudioTestCancellable()
    }
}

private final class AudioTestCancellable: Cancellable {
    func cancel() {}
}

/// Thread-safe counter that tests can wait on without long sleeps.
final class AudioTestCounter: @unchecked Sendable {
    // Invariant: `value` is only read or written while holding `lock`.
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    /// Polls in 2 ms steps until `count >= target` or `timeout` passes.
    func wait(for target: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while count < target, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        return count >= target
    }
}

/// Records what the pipeline asks of the device. Tests "play" audio by consuming scheduled blocks.
final class FakeAudioOutput: AudioOutput, @unchecked Sendable {
    // Invariant: every stored `var` is only touched while holding `lock` (the pipeline calls in on its
    // audio queue; tests inspect and drive it from theirs). Completions are invoked outside the lock.
    struct Scheduled: Equatable {
        var format: PCMFormat
        var frames: Int
    }

    private let lock = NSLock()
    private var startedFormats: [PCMFormat] = []
    private var startCalls = 0
    private var running: PCMFormat?
    private var scheduledBlocks: [Scheduled] = []
    private var refusedBlocks = 0
    private var stopCalls = 0
    private var pending: [@Sendable () -> Void] = []
    private var discarded: [@Sendable () -> Void] = []
    private var shouldFailStart = false
    private var unexpectedStopHandler: (@Sendable () -> Void)?

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // MARK: AudioOutput

    var onUnexpectedStop: (@Sendable () -> Void)? {
        get { locked { unexpectedStopHandler } }
        set { locked { unexpectedStopHandler = newValue } }
    }

    func start(format: PCMFormat) throws {
        try locked {
            startCalls += 1
            if shouldFailStart { throw AudioOutputError.unsupportedFormat(format) }
            discarded += pending
            pending = []
            running = format
            startedFormats.append(format)
        }
    }

    func schedule(_ block: PCMBlock, consumed: @escaping @Sendable () -> Void) -> Bool {
        locked {
            guard block.format == running else { refusedBlocks += 1; return false }
            scheduledBlocks.append(Scheduled(format: block.format, frames: block.frameCount))
            pending.append(consumed)
            return true
        }
    }

    func stop() {
        locked {
            stopCalls += 1
            running = nil
            discarded += pending
            pending = []
        }
    }

    // MARK: Test controls

    var failStarts: Bool {
        get { locked { shouldFailStart } }
        set { locked { shouldFailStart = newValue } }
    }
    var starts: [PCMFormat] { locked { startedFormats } }
    var startAttempts: Int { locked { startCalls } }
    var runningFormat: PCMFormat? { locked { running } }
    var scheduled: [Scheduled] { locked { scheduledBlocks } }
    var refused: Int { locked { refusedBlocks } }
    var stops: Int { locked { stopCalls } }
    var pendingCount: Int { locked { pending.count } }

    /// Plays the oldest scheduled block. Returns false when nothing is scheduled.
    @discardableResult
    func consumeOldest() -> Bool {
        let completion: (@Sendable () -> Void)? = locked { pending.isEmpty ? nil : pending.removeFirst() }
        completion?()
        return completion != nil
    }

    /// Fires the completions of blocks discarded by `start`/`stop`, as AVAudioPlayerNode does late.
    func fireDiscarded() {
        let completions = locked { () -> [@Sendable () -> Void] in
            defer { discarded = [] }
            return discarded
        }
        completions.forEach { $0() }
    }

    /// The device stops on its own (e.g. an engine configuration change).
    func simulateUnexpectedStop() {
        let handler = locked { () -> (@Sendable () -> Void)? in
            running = nil
            discarded += pending
            pending = []
            return unexpectedStopHandler
        }
        handler?()
    }
}

/// Host μ-law encoder, copied from app/server-macos/Sources/Server.swift (`muLaw`), to round-trip the decoder.
func hostMuLawEncode(_ value: Int16) -> UInt8 {
    var sample = Int(value)
    let sign = sample < 0 ? 0x80 : 0
    if sample < 0 { sample = -sample }
    sample = min(32635, sample) + 0x84
    var exponent = 7
    var mask = 0x4000
    while exponent > 0 && sample & mask == 0 { exponent -= 1; mask >>= 1 }
    let mantissa = (sample >> (exponent + 3)) & 0x0f
    return UInt8(truncatingIfNeeded: ~(sign | exponent << 4 | mantissa))
}

/// Wire-shaped packets built from the embedded fixtures.
enum AudioTestPackets {
    static let aac96Configuration = AudioConfiguration(codec: .aac, bitrate: 96_000)
    static let aac160Configuration = AudioConfiguration(codec: .aac, bitrate: 160_000)
    /// The host acknowledges μ-law with `audioBitrate: 192000`.
    static let mulawConfiguration = AudioConfiguration(codec: .mulaw, bitrate: 192_000)

    /// Packet `index` (cycling through the fixture's 12) of the fixture stream at `bitrate`.
    static func aac(_ index: Int, revision: Int, bitrate: Int = 96_000) -> (header: AudioHeader, payload: Data) {
        guard let fixture = AudioAACFixture.named(bitrate: bitrate), !fixture.packetData.isEmpty else {
            return (AudioHeader(revision: revision, codec: .aac, sampleRate: 48_000, channels: 2, samples: 1024,
                                sequence: index, bitrate: bitrate, cookie: nil), Data())
        }
        let packets = fixture.packetData
        let header = AudioHeader(revision: revision, codec: .aac, sampleRate: 48_000, channels: fixture.channels, samples: 1024,
                                 sequence: index, bitrate: fixture.bitrate, cookie: fixture.cookieData)
        return (header, packets[index % packets.count])
    }

    /// 480 samples (20 ms) of a 440 Hz sine, μ-law encoded like the host.
    static func mulaw(_ index: Int, revision: Int, samples: Int = 480) -> (header: AudioHeader, payload: Data) {
        let bytes = (0..<samples).map { n -> UInt8 in
            let t = Double(index * samples + n) / 24_000
            return hostMuLawEncode(Int16(sin(t * 2 * .pi * 440) * 12_000))
        }
        let header = AudioHeader(revision: revision, codec: .mulaw, sampleRate: 24_000, channels: 1, samples: samples,
                                 sequence: index, bitrate: nil, cookie: nil)
        return (header, Data(bytes))
    }
}

/// A pipeline wired to a fake output and a manual clock.
struct AudioPipelineRig {
    let clock: AudioTestClock
    let output: FakeAudioOutput
    let pipeline: AudioPipeline

    init(maxBacklogPackets: Int = 64) {
        let clock = AudioTestClock()
        let output = FakeAudioOutput()
        self.clock = clock
        self.output = output
        pipeline = AudioPipeline(output: output, clock: clock, maxBacklogPackets: maxBacklogPackets)
    }

    func acknowledge(_ configuration: AudioConfiguration?, revision: Int) {
        pipeline.audioConfigurationAcknowledged(configuration, revision: revision)
    }

    func submit(_ packet: (header: AudioHeader, payload: Data)) {
        pipeline.submit(packet.header, payload: packet.payload)
    }

    /// Submits AAC fixture packets `range` stamped with `revision`.
    func submitAAC(_ range: Range<Int>, revision: Int, bitrate: Int = 96_000) {
        for index in range { submit(AudioTestPackets.aac(index, revision: revision, bitrate: bitrate)) }
    }

    func settle() { pipeline.waitUntilIdle() }

    /// Plays `count` scheduled blocks, letting the pipeline react after each.
    func consume(_ count: Int) {
        for _ in 0..<count {
            output.consumeOldest()
            settle()
        }
    }
}

/// Largest absolute sample across all channels.
func audioPeak(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData else { return 0 }
    var peak: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[channel][frame])) }
    }
    return peak
}
