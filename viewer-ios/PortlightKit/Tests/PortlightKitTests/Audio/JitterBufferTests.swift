import Testing
@testable import PortlightKit

/// One AAC access unit: 1024 frames at 48 kHz.
private let aacBlock = 1024.0 / 48.0

@Suite("Audio · jitter buffer")
struct JitterBufferTests {
    @Test("waits for the start threshold, then hands blocks to the output (AAC ≈ 64 ms)")
    func startThreshold() {
        var buffer = JitterBuffer<Int>(policy: .standard(for: .aac))
        buffer.push(0, milliseconds: aacBlock, now: 10.000)
        buffer.push(1, milliseconds: aacBlock, now: 10.021)
        #expect(buffer.state == .prebuffering)
        #expect(buffer.takeForOutput().isEmpty)
        #expect(buffer.metrics.startupMilliseconds == nil)
        buffer.push(2, milliseconds: aacBlock, now: 10.043)
        #expect(buffer.state == .playing)
        #expect(abs(buffer.queuedMilliseconds - 64) < 0.001)
        #expect(abs((buffer.metrics.startupMilliseconds ?? 0) - 43) < 0.001)
        #expect(buffer.takeForOutput() == [0, 1, 2])
        #expect(buffer.scheduledCount == 3)
        // Scheduled audio still counts as queued until the output consumes it.
        #expect(abs(buffer.queuedMilliseconds - 64) < 0.001)
    }

    @Test("μ-law starts after three 20 ms packets = 60 ms")
    func muLawThreshold() {
        var buffer = JitterBuffer<Int>(policy: .standard(for: .mulaw))
        buffer.push(0, milliseconds: 20, now: 0)
        buffer.push(1, milliseconds: 20, now: 0.02)
        #expect(buffer.state == .prebuffering)
        buffer.push(2, milliseconds: 20, now: 0.04)
        #expect(buffer.state == .playing)
        #expect(buffer.queuedMilliseconds == 60)
    }

    @Test("stays bounded under a 100-packet burst by dropping the oldest blocks")
    func burstWithoutConsumer() {
        var buffer = JitterBuffer<Int>(policy: .standard(for: .aac))
        for index in 0..<100 { buffer.push(index, milliseconds: aacBlock, now: 1) }
        #expect(buffer.queuedMilliseconds <= 250)
        #expect(buffer.pendingCount == 11)
        #expect(buffer.metrics.drops == 89)
        #expect(buffer.takeForOutput() == [89, 90, 91])
    }

    @Test("counts scheduled blocks toward the bound during a burst")
    func burstWhilePlaying() {
        var buffer = JitterBuffer<Int>(policy: .standard(for: .aac))
        for index in 0..<3 { buffer.push(index, milliseconds: aacBlock, now: 0) }
        #expect(buffer.takeForOutput() == [0, 1, 2])
        for index in 3..<103 { buffer.push(index, milliseconds: aacBlock, now: 0.1) }
        #expect(buffer.scheduledCount == 3)
        #expect(buffer.pendingCount == 8)
        #expect(buffer.metrics.drops == 92)
        #expect(buffer.queuedMilliseconds <= 250)
        #expect(buffer.takeForOutput().isEmpty)
        buffer.outputConsumedBlock()
        #expect(buffer.takeForOutput() == [95])
    }

    @Test("an underrun is counted, then the buffer re-prebuffers before feeding the output again")
    func underrun() {
        var buffer = JitterBuffer<Int>(policy: .standard(for: .aac))
        for index in 0..<3 { buffer.push(index, milliseconds: aacBlock, now: 0) }
        #expect(buffer.takeForOutput().count == 3)
        buffer.outputConsumedBlock()
        buffer.outputConsumedBlock()
        #expect(buffer.metrics.underruns == 0)
        buffer.outputConsumedBlock()
        #expect(buffer.metrics.underruns == 1)
        #expect(buffer.state == .prebuffering)
        #expect(buffer.queuedMilliseconds == 0)
        buffer.push(3, milliseconds: aacBlock, now: 1)
        buffer.push(4, milliseconds: aacBlock, now: 1.02)
        #expect(buffer.takeForOutput().isEmpty)
        buffer.push(5, milliseconds: aacBlock, now: 1.04)
        #expect(buffer.takeForOutput() == [3, 4, 5])
        // Startup measures cold starts only.
        #expect(buffer.metrics.startupMilliseconds == 0)
    }

    @Test("keeps the output fed while blocks are pending; no underrun")
    func steadyState() {
        var buffer = JitterBuffer<Int>(policy: .standard(for: .aac))
        for index in 0..<4 { buffer.push(index, milliseconds: aacBlock, now: 0) }
        #expect(buffer.takeForOutput() == [0, 1, 2])
        for index in 4..<50 {
            buffer.outputConsumedBlock()
            #expect(buffer.takeForOutput() == [index - 1])
            buffer.push(index, milliseconds: aacBlock, now: Double(index) * aacBlock / 1000)
        }
        #expect(buffer.metrics.underruns == 0)
        #expect(buffer.metrics.drops == 0)
    }

    @Test("flush empties the queue, keeps counters and measures the next cold start")
    func flush() {
        var buffer = JitterBuffer<Int>(policy: .standard(for: .aac))
        for index in 0..<20 { buffer.push(index, milliseconds: aacBlock, now: 0) }
        _ = buffer.takeForOutput()
        buffer.flush()
        #expect(buffer.queuedMilliseconds == 0)
        #expect(buffer.pendingCount == 0 && buffer.scheduledCount == 0)
        #expect(buffer.state == .prebuffering)
        #expect(buffer.metrics.drops == 9)
        buffer.outputConsumedBlock()  // a late consumption after a flush is ignored
        #expect(buffer.metrics.underruns == 0)
        buffer.push(0, milliseconds: aacBlock, now: 5)
        buffer.push(1, milliseconds: aacBlock, now: 5.05)
        buffer.push(2, milliseconds: aacBlock, now: 5.1)
        #expect(abs((buffer.metrics.startupMilliseconds ?? 0) - 100) < 0.001)
    }

    @Test("a threshold larger than the bound still starts once the queue is full")
    func oversizedThreshold() {
        var buffer = JitterBuffer<Int>(policy: JitterBufferPolicy(startPackets: 50, maxQueuedMilliseconds: 100, scheduleAheadPackets: 2))
        for index in 0..<5 { buffer.push(index, milliseconds: aacBlock, now: 0) }
        #expect(buffer.state == .playing)
        #expect(buffer.takeForOutput() == [1, 2])
        let clamped = JitterBufferPolicy(startPackets: 0, maxQueuedMilliseconds: -5, scheduleAheadPackets: 0)
        #expect(clamped.startPackets == 1 && clamped.scheduleAheadPackets == 1 && clamped.maxQueuedMilliseconds == 1)
    }
}
