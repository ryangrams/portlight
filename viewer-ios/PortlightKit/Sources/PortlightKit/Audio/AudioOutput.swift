import AVFoundation
import os

/// Layout of decoded audio. Blocks are always standard deinterleaved Float32.
public struct PCMFormat: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var sampleRate: Double
    public var channels: Int
    public init(sampleRate: Double, channels: Int) { self.sampleRate = sampleRate; self.channels = channels }
    public var description: String { "\(Int(sampleRate)) Hz × \(channels)" }

    func makeAVAudioFormat() -> AVAudioFormat? {
        guard sampleRate > 0, (1...8).contains(channels) else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
    }
}

/// One decoded block ready for playback. Created and consumed on the audio queue.
public struct PCMBlock {
    public let buffer: AVAudioPCMBuffer
    public let format: PCMFormat

    /// Nil unless `buffer` is standard deinterleaved Float32 with at least one frame.
    public init?(_ buffer: AVAudioPCMBuffer) {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved, buffer.frameLength > 0,
              format.sampleRate > 0, format.channelCount > 0 else { return nil }
        self.buffer = buffer
        self.format = PCMFormat(sampleRate: format.sampleRate, channels: Int(format.channelCount))
    }

    public var frameCount: Int { Int(buffer.frameLength) }
    public var milliseconds: Double { Double(frameCount) / format.sampleRate * 1000 }
}

public enum AudioOutputError: Error, Equatable, Sendable {
    case unsupportedFormat(PCMFormat)
}

/// The device end of the audio pipeline. Every call comes from the pipeline's serial audio queue.
public protocol AudioOutput: AnyObject {
    /// Begins a fresh playback run in `format`: discards anything still scheduled, reconnects when the
    /// format differs from the running one, and starts the device if needed. Throws when it can't start.
    func start(format: PCMFormat) throws
    /// Schedules `block` after those already scheduled. Returns false, and plays nothing, when the block's
    /// format isn't the running format. `consumed` runs at most once, on any thread, when the output no
    /// longer needs the block; calls can arrive after `start`/`stop`, so owners must filter stale ones.
    @discardableResult
    func schedule(_ block: PCMBlock, consumed: @escaping @Sendable () -> Void) -> Bool
    /// Stops immediately, discards everything scheduled and releases the device.
    func stop()
    /// Set by the owner before the first `start`. Runs on any thread when the output stopped on its own
    /// (for example an engine configuration change after a route or device change).
    var onUnexpectedStop: (@Sendable () -> Void)? { get set }
}

/// `AVAudioEngine` + `AVAudioPlayerNode` output.
///
/// Not thread-safe: confined to the owning pipeline's audio queue. The player node is reconnected
/// whenever the format changes, and `schedule` refuses a block in any other format, so a 24 kHz μ-law
/// buffer can never reach a node connected for 48 kHz AAC (the Mac viewer's latent crash).
public final class EngineAudioOutput: AudioOutput {
    public var onUnexpectedStop: (@Sendable () -> Void)?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var running: (format: PCMFormat, avFormat: AVAudioFormat)?
    private var observer: (any NSObjectProtocol)?
    /// Set from the notification thread; read on the audio queue at the next `start`.
    private let configurationLost = OSAllocatedUnfairLock(initialState: false)
    private let offline: OfflineRendering?

    public convenience init() { self.init(offline: nil) }

    /// Offline manual rendering, so tests exercise the real engine without audio hardware.
    struct OfflineRendering {
        var format: AVAudioFormat
        var maximumFrameCount: AVAudioFrameCount
    }

    init(offline: OfflineRendering?) { self.offline = offline }

    deinit { teardown() }

    public func start(format: PCMFormat) throws {
        if configurationLost.withLock({ lost in defer { lost = false }; return lost }) { teardown() }
        guard let avFormat = format.makeAVAudioFormat() else { throw AudioOutputError.unsupportedFormat(format) }
        guard let engine, let player else { return try build(format: format, avFormat: avFormat) }
        player.stop()
        if running?.format != format {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: avFormat)
        }
        running = (format, avFormat)
        if !engine.isRunning {
            do { try engine.start() } catch { teardown(); throw error }
        }
        player.play()
    }

    @discardableResult
    public func schedule(_ block: PCMBlock, consumed: @escaping @Sendable () -> Void) -> Bool {
        guard let player, let running, block.format == running.format else { return false }
        let actual = block.buffer.format
        guard actual.sampleRate == running.avFormat.sampleRate, actual.channelCount == running.avFormat.channelCount,
              actual.commonFormat == running.avFormat.commonFormat, actual.isInterleaved == running.avFormat.isInterleaved else { return false }
        // `.dataConsumed` rather than `.dataPlayedBack`: flow control must follow the node's own queue, not
        // device latency (Bluetooth can add 200 ms, which would otherwise starve the node).
        player.scheduleBuffer(block.buffer, completionCallbackType: .dataConsumed) { _ in consumed() }
        return true
    }

    public func stop() { teardown() }

    var isRunning: Bool { engine?.isRunning ?? false }
    var runningFormat: PCMFormat? { running?.format }

    /// Renders `frames` in offline mode (tests only).
    func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard let engine, engine.isInManualRenderingMode,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames) else { return nil }
        let status = try engine.renderOffline(frames, to: buffer)
        return status == .success ? buffer : nil
    }

    private func build(format: PCMFormat, avFormat: AVAudioFormat) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            if let offline {
                try engine.enableManualRenderingMode(.offline, format: offline.format, maximumFrameCount: offline.maximumFrameCount)
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: avFormat)
            engine.prepare()
            try engine.start()
        } catch {
            engine.stop()
            throw error
        }
        player.play()
        self.engine = engine
        self.player = player
        running = (format, avFormat)
        let lost = configurationLost
        let handler = onUnexpectedStop
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            // The engine has stopped itself; rebuild on the next start.
            lost.withLock { $0 = true }
            handler?()
        }
    }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        running = nil
        configurationLost.withLock { $0 = false }
    }
}
