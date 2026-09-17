// AVFoundation (which re-exports Foundation) rather than `import Foundation`: see AACDecodingTests.swift.
import AVFoundation
import Testing
@testable import PortlightKit

/// Exercises the real AVAudioEngine output in offline manual-rendering mode: no audio hardware involved.
@Suite("Audio · engine output (offline rendering)")
struct EngineAudioOutputTests {
    private func makeOutput() throws -> EngineAudioOutput {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        return EngineAudioOutput(offline: .init(format: format, maximumFrameCount: 4096))
    }

    private func muLawBlock() throws -> PCMBlock {
        let packet = AudioTestPackets.mulaw(0, revision: 1)
        let buffer = try #require(MuLaw.pcmBuffer(packet.payload))
        return try #require(PCMBlock(buffer))
    }

    private func aacBlock() throws -> PCMBlock {
        let packet = AudioTestPackets.aac(5, revision: 1)
        var decoder = AudioPacketDecoder()
        let decoded = decoder.decode(packet.header, payload: packet.payload)
        return try #require(decoded)
    }

    /// Peak of one 1024-frame (21 ms) render.
    private func render(_ output: EngineAudioOutput) throws -> Float {
        let rendered = try output.renderOffline(frames: 1024)
        return audioPeak(try #require(rendered))
    }

    /// Renders until a chunk is louder than `threshold` or about half a second passes. The player node
    /// picks up a newly scheduled buffer asynchronously, so under load it can start a render cycle late.
    private func renderUntilAudible(_ output: EngineAudioOutput, threshold: Float) throws -> Float {
        var loudest: Float = 0
        for _ in 0..<250 {
            loudest = max(loudest, try render(output))
            if loudest > threshold { break }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return loudest
    }

    @Test("refuses blocks before start and in any format other than the running one")
    func refusesMismatchedFormats() throws {
        let output = try makeOutput()
        let mono24k = try muLawBlock()
        let stereo48k = try aacBlock()
        #expect(!output.schedule(mono24k) {})
        try output.start(format: mono24k.format)
        #expect(output.isRunning)
        #expect(output.schedule(mono24k) {})
        // 48 kHz stereo onto a node connected for 24 kHz mono: refused instead of raising.
        #expect(!output.schedule(stereo48k) {})
        output.stop()
        #expect(!output.isRunning)
        #expect(!output.schedule(mono24k) {})
    }

    @Test("reconnects the player node when the format changes and plays both formats")
    func reconnectsOnFormatChange() throws {
        let output = try makeOutput()
        let mono24k = try muLawBlock()
        let stereo48k = try aacBlock()
        let consumed = AudioTestCounter()

        try output.start(format: mono24k.format)
        #expect(output.schedule(mono24k) { consumed.increment() })
        #expect(try renderUntilAudible(output, threshold: 0.05) > 0.05)

        // A fresh run in a new format: reconnects, and discards the μ-law block if any of it is left.
        try output.start(format: stereo48k.format)
        #expect(output.runningFormat == stereo48k.format)
        #expect(!output.schedule(mono24k) {})
        #expect(output.schedule(stereo48k) { consumed.increment() })
        #expect(try renderUntilAudible(output, threshold: 0.01) > 0.01)
        _ = try render(output)  // finish the block if it straddled two renders
        #expect(consumed.wait(for: 2))
        // Everything scheduled has been consumed: the output falls silent.
        #expect(try render(output) < 0.0001)

        // Same format again: a fresh run (nothing left scheduled), no reconnect needed.
        try output.start(format: stereo48k.format)
        #expect(output.schedule(stereo48k) {})
        output.stop()
        #expect(output.runningFormat == nil)
    }

    @Test("the pipeline plays through the real engine output")
    func pipelineWithEngine() throws {
        let output = try makeOutput()
        let pipeline = AudioPipeline(output: output)
        pipeline.audioConfigurationAcknowledged(AudioTestPackets.aac96Configuration, revision: 1)
        for index in 0..<4 {
            let packet = AudioTestPackets.aac(index, revision: 1)
            pipeline.submit(packet.header, payload: packet.payload)
        }
        pipeline.waitUntilIdle()
        #expect(pipeline.metrics.isPlaying)
        #expect(pipeline.metrics.decodeFailures == 0)
        pipeline.stopAudio()
        pipeline.waitUntilIdle()
        #expect(!pipeline.metrics.isPlaying)
        #expect(pipeline.metrics.queuedMilliseconds == 0)
    }
}
