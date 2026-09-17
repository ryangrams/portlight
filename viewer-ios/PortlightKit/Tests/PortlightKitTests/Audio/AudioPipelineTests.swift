// Dispatch rather than Foundation next to Testing: see AACDecodingTests.swift.
import Dispatch
import Testing
@testable import PortlightKit

private let aac96 = AudioTestPackets.aac96Configuration
private let aac160 = AudioTestPackets.aac160Configuration
private let mulaw = AudioTestPackets.mulawConfiguration
private let stereo48k = PCMFormat(sampleRate: 48_000, channels: 2)
private let mono24k = PCMFormat(sampleRate: 24_000, channels: 1)

@Suite("Audio · pipeline")
struct AudioPipelineTests {
    @Test("starts the output once three AAC packets are queued")
    func startsAfterThreshold() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<2, revision: 1)
        rig.settle()
        #expect(rig.output.starts.isEmpty)
        #expect(!rig.pipeline.metrics.isPlaying)
        rig.submitAAC(2..<3, revision: 1)
        rig.settle()
        #expect(rig.output.starts == [stereo48k])
        #expect(rig.output.scheduled.count == 3)
        #expect(rig.output.scheduled.allSatisfy { $0 == .init(format: stereo48k, frames: 1024) })
        let metrics = rig.pipeline.metrics
        #expect(metrics.isPlaying)
        #expect(metrics.configuration == aac96)
        #expect(metrics.acceptedPackets == 3)
        #expect(abs(metrics.queuedMilliseconds - 64) < 0.01)
        #expect(metrics.startupMilliseconds == 0)
    }

    @Test("stopAudio stops the output immediately and flushes queued audio")
    func stopFlushes() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<5, revision: 1)
        rig.settle()
        #expect(rig.output.scheduled.count == 3)
        #expect(abs(rig.pipeline.metrics.queuedMilliseconds - 106.67) < 0.01)
        rig.pipeline.stopAudio()
        rig.settle()
        #expect(rig.output.stops == 1)
        var metrics = rig.pipeline.metrics
        #expect(metrics.queuedMilliseconds == 0)
        #expect(!metrics.isPlaying)
        #expect(metrics.configuration == nil)
        // Late completions for the discarded blocks change nothing.
        rig.output.fireDiscarded()
        rig.settle()
        metrics = rig.pipeline.metrics
        #expect(metrics.underruns == 0)
        #expect(metrics.queuedMilliseconds == 0)
    }

    @Test("nothing is accepted after stopAudio until a new acknowledgement")
    func nothingAcceptedAfterStop() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<3, revision: 1)
        rig.settle()  // processed before the stop (unprocessed ones are voided; see the next test)
        rig.pipeline.stopAudio()
        rig.submitAAC(3..<8, revision: 1)
        rig.settle()
        #expect(rig.pipeline.metrics.acceptedPackets == 3)
        #expect(rig.pipeline.metrics.rejectedPackets == 5)
        #expect(rig.output.starts.count == 1)
        // A new connection starts again at revision 1.
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<3, revision: 1)
        rig.settle()
        #expect(rig.pipeline.metrics.acceptedPackets == 6)
        #expect(rig.output.starts.count == 2)
    }

    @Test("packets submitted before stopAudio but not yet processed never play")
    func stopVoidsQueuedSubmissions() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.settle()
        rig.pipeline.withQueueHeld {
            rig.submitAAC(0..<5, revision: 1)
            rig.pipeline.stopAudio()
        }
        rig.settle()
        #expect(rig.output.starts.isEmpty)
        #expect(rig.output.scheduled.isEmpty)
        #expect(rig.pipeline.metrics.acceptedPackets == 0)
    }

    @Test("after Off/On with the same codec, the old stream's packets are rejected")
    func offOnRejectsOldEpoch() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<3, revision: 1)
        rig.acknowledge(nil, revision: 2)
        rig.settle()
        #expect(rig.output.stops == 1)
        #expect(!rig.pipeline.metrics.isPlaying)
        rig.acknowledge(aac96, revision: 3)
        rig.submitAAC(3..<6, revision: 1)
        rig.settle()
        #expect(rig.pipeline.metrics.rejectedPackets == 3)
        #expect(rig.output.starts.count == 1)
        rig.submitAAC(6..<9, revision: 3)
        rig.settle()
        #expect(rig.pipeline.metrics.acceptedPackets == 6)
        #expect(rig.output.starts.count == 2)
    }

    @Test("a codec change reconnects the output and never schedules a mismatched format")
    func codecChangeFormats() {
        let rig = AudioPipelineRig()
        rig.acknowledge(mulaw, revision: 1)
        for index in 0..<3 { rig.submit(AudioTestPackets.mulaw(index, revision: 1)) }
        rig.settle()
        #expect(rig.output.starts == [mono24k])
        rig.acknowledge(aac96, revision: 2)
        rig.submit(AudioTestPackets.mulaw(3, revision: 1))
        rig.submitAAC(0..<3, revision: 2)
        rig.settle()
        #expect(rig.output.starts == [mono24k, stereo48k])
        #expect(rig.output.refused == 0)
        #expect(rig.output.scheduled.map(\.format) == [mono24k, mono24k, mono24k, stereo48k, stereo48k, stereo48k])
        #expect(rig.pipeline.metrics.rejectedPackets == 1)
        // A codec change keeps the device; the new run reconnects instead of tearing down.
        #expect(rig.output.stops == 0)
    }

    @Test("video-only revisions keep audio playing without a restart")
    func videoOnlyRevisions() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<3, revision: 1)
        rig.acknowledge(aac96, revision: 2)
        rig.acknowledge(aac96, revision: 3)
        rig.submitAAC(3..<4, revision: 1)
        rig.submitAAC(4..<5, revision: 2)
        rig.submitAAC(5..<6, revision: 3)
        rig.settle()
        let metrics = rig.pipeline.metrics
        #expect(metrics.acceptedPackets == 6)
        #expect(metrics.rejectedPackets == 0)
        #expect(rig.output.starts.count == 1)
        #expect(rig.output.stops == 0)
        #expect(abs(metrics.queuedMilliseconds - 128) < 0.01)
    }

    @Test("suspending output stops it without losing the enabled state")
    func suspension() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<3, revision: 1)
        let suspended = AudioTestCounter()
        rig.pipeline.setOutputSuspended(true) { suspended.increment() }
        rig.settle()
        #expect(suspended.count == 1)
        #expect(rig.output.stops == 1)
        #expect(rig.pipeline.metrics.isSuspended)
        #expect(rig.pipeline.metrics.queuedMilliseconds == 0)
        rig.submitAAC(3..<6, revision: 1)
        rig.settle()
        #expect(rig.output.starts.count == 1)
        #expect(rig.pipeline.metrics.configuration == aac96)
        rig.pipeline.setOutputSuspended(false)
        rig.submitAAC(6..<9, revision: 1)
        rig.settle()
        #expect(rig.output.starts.count == 2)
        #expect(!rig.pipeline.metrics.isSuspended)
        #expect(rig.pipeline.metrics.isPlaying)
    }

    @Test("an underrun re-prebuffers without restarting the output")
    func underrun() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<3, revision: 1)
        rig.settle()
        rig.consume(3)
        #expect(rig.pipeline.metrics.underruns == 1)
        #expect(!rig.pipeline.metrics.isPlaying)
        rig.submitAAC(3..<5, revision: 1)
        rig.settle()
        #expect(rig.output.scheduled.count == 3)
        rig.submitAAC(5..<6, revision: 1)
        rig.settle()
        #expect(rig.output.scheduled.count == 6)
        #expect(rig.output.starts.count == 1)
        #expect(rig.pipeline.metrics.isPlaying)
    }

    @Test("steady consumption keeps three blocks scheduled with no underruns")
    func steadyState() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<3, revision: 1)
        for index in 3..<40 {
            rig.submitAAC(index..<(index + 1), revision: 1)
            rig.settle()
            rig.consume(1)
            #expect(rig.output.pendingCount == 3)
        }
        let metrics = rig.pipeline.metrics
        #expect(metrics.underruns == 0)
        #expect(metrics.drops == 0)
    }

    @Test("a 100-packet burst stays within 250 ms by dropping the oldest audio")
    func burst() {
        // This exercises the jitter bound; lift the queue-backlog guard so it can't absorb the burst first.
        let rig = AudioPipelineRig(maxBacklogPackets: 200)
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<100, revision: 1)
        rig.settle()
        let metrics = rig.pipeline.metrics
        #expect(metrics.acceptedPackets == 100)
        #expect(metrics.queuedMilliseconds <= 250)
        #expect(metrics.drops == 89)
        #expect(rig.output.scheduled.count == 3)
    }

    @Test("a failed device start backs off before retrying")
    func startFailureBacksOff() {
        let rig = AudioPipelineRig()
        rig.output.failStarts = true
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<3, revision: 1)
        rig.settle()
        #expect(rig.output.startAttempts == 1)
        #expect(rig.pipeline.metrics.outputFailures == 1)
        #expect(!rig.pipeline.metrics.isPlaying)
        rig.output.failStarts = false
        rig.submitAAC(3..<9, revision: 1)
        rig.settle()
        #expect(rig.output.startAttempts == 1)
        rig.clock.advance(by: 1.1)
        rig.submitAAC(9..<12, revision: 1)
        rig.settle()
        #expect(rig.output.startAttempts == 2)
        #expect(rig.output.starts == [stereo48k])
        #expect(rig.pipeline.metrics.isPlaying)
    }

    @Test("scheduled audio that is never consumed restarts the device")
    func stallWatchdog() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<3, revision: 1)
        rig.settle()
        rig.clock.advance(by: 0.5)
        rig.submitAAC(3..<4, revision: 1)
        rig.settle()
        #expect(rig.pipeline.metrics.outputRestarts == 0)
        rig.clock.advance(by: 1.5)
        rig.submitAAC(4..<5, revision: 1)
        rig.settle()
        #expect(rig.pipeline.metrics.outputRestarts == 1)
        #expect(rig.output.stops == 1)
        rig.submitAAC(5..<7, revision: 1)
        rig.settle()
        #expect(rig.output.starts.count == 2)
    }

    @Test("an unexpected device stop resets playback and the next packets restart it")
    func unexpectedStop() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<3, revision: 1)
        rig.settle()
        rig.output.simulateUnexpectedStop()
        rig.settle()
        #expect(rig.pipeline.metrics.outputRestarts == 1)
        #expect(rig.pipeline.metrics.queuedMilliseconds == 0)
        rig.output.fireDiscarded()
        rig.submitAAC(3..<6, revision: 1)
        rig.settle()
        #expect(rig.output.starts.count == 2)
        #expect(rig.pipeline.metrics.underruns == 0)
    }

    @Test("completions from an abandoned run are ignored")
    func staleCompletions() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        rig.submitAAC(0..<3, revision: 1)
        rig.acknowledge(aac160, revision: 2)
        rig.settle()
        #expect(rig.pipeline.metrics.queuedMilliseconds == 0)
        rig.consume(3)
        #expect(rig.pipeline.metrics.underruns == 0)
        #expect(rig.pipeline.metrics.queuedMilliseconds == 0)
        rig.submitAAC(0..<3, revision: 2, bitrate: 160_000)
        rig.settle()
        #expect(rig.output.starts == [stereo48k, stereo48k])
        #expect(abs(rig.pipeline.metrics.queuedMilliseconds - 64) < 0.01)
    }

    @Test("a backlog on the audio queue is bounded and counted")
    func backlogBound() {
        let rig = AudioPipelineRig(maxBacklogPackets: 8)
        rig.acknowledge(aac96, revision: 1)
        rig.settle()
        rig.pipeline.withQueueHeld { rig.submitAAC(0..<10, revision: 1) }
        rig.settle()
        #expect(rig.pipeline.metrics.backlogDrops == 2)
        #expect(rig.pipeline.metrics.acceptedPackets == 8)
    }

    @Test("an undecodable packet is counted and does not reach the output")
    func decodeFailure() {
        let rig = AudioPipelineRig()
        rig.acknowledge(mulaw, revision: 1)
        let packet = AudioTestPackets.mulaw(0, revision: 1)
        rig.pipeline.submit(packet.header, payload: packet.payload.dropLast())
        rig.settle()
        #expect(rig.pipeline.metrics.decodeFailures == 1)
        #expect(rig.output.scheduled.isEmpty)
    }

    @Test("metrics can be read from other threads while audio flows")
    func concurrentMetrics() {
        let rig = AudioPipelineRig()
        rig.acknowledge(aac96, revision: 1)
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            if worker == 0 {
                rig.submitAAC(0..<40, revision: 1)
            } else {
                for _ in 0..<200 { _ = rig.pipeline.metrics }
            }
        }
        rig.settle()
        #expect(rig.pipeline.metrics.acceptedPackets == 40)
    }
}
