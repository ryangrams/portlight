// No direct `import Foundation` next to Testing: the Command Line Tools ship `_Testing_Foundation`
// without its module, so that cross-import fails. AVFoundation re-exports Foundation instead.
import AVFoundation
import Testing
@testable import PortlightKit

@Suite("Audio · AAC fixtures")
struct AACDecodingTests {
    @Test("the embedded fixture set is complete and consistent with the host's channel rule")
    func fixtureSetIsComplete() throws {
        let fixtures = AudioAACFixture.all
        #expect(fixtures.map(\.bitrate) == [48_000, 96_000, 160_000, 320_000])
        for fixture in fixtures {
            #expect(fixture.channels == AudioEpochGate.aacChannels(forBitrate: fixture.bitrate))
            #expect(fixture.packetData.count == 12)
            #expect(fixture.cookieData.count == 39)
        }
    }

    @Test("decodes every packet of every case with zero failures", arguments: [48_000, 96_000, 160_000, 320_000])
    func decodesCase(bitrate: Int) throws {
        let fixture = try #require(AudioAACFixture.named(bitrate: bitrate))
        let decoder = try #require(AACAccessUnitDecoder(channels: fixture.channels, cookie: fixture.cookieData))
        var frames = 0
        var failures = 0
        var channelSamples = Array(repeating: [Float](), count: fixture.channels)
        for packet in fixture.packetData {
            guard let pcm = decoder.decode(packet), let data = pcm.floatChannelData else { failures += 1; continue }
            #expect(pcm.format.sampleRate == 48_000)
            #expect(Int(pcm.format.channelCount) == fixture.channels)
            frames += Int(pcm.frameLength)
            for channel in 0..<fixture.channels {
                channelSamples[channel] += UnsafeBufferPointer(start: data[channel], count: Int(pcm.frameLength))
            }
        }
        #expect(failures == 0)
        #expect(frames >= 8192)
        #expect(frames <= fixture.decodedSamplesOnMac)
        // The decoded audio is the encoded tone, not silence: 440 Hz left, 660 Hz right, amplitude 4000/32768.
        for (channel, expected) in zip(0..<fixture.channels, [440.0, 660.0]) {
            let tail = channelSamples[channel].suffix(8192)
            let frequency = Self.positiveZeroCrossingRate(tail, sampleRate: 48_000)
            #expect(abs(frequency - expected) < expected * 0.05, "channel \(channel): \(frequency) Hz")
            let peak = tail.map(abs).max() ?? 0
            #expect(peak > 0.08 && peak < 0.2, "channel \(channel) peak \(peak)")
        }
    }

    @Test("the packet decoder yields 48 kHz blocks of 1024 frames and swaps decoders when the cookie changes")
    func packetDecoderPath() throws {
        var decoder = AudioPacketDecoder()
        for bitrate in [96_000, 160_000, 48_000] {
            let fixture = try #require(AudioAACFixture.named(bitrate: bitrate))
            for index in 0..<fixture.packetData.count {
                let packet = AudioTestPackets.aac(index, revision: 1, bitrate: bitrate)
                let decoded = decoder.decode(packet.header, payload: packet.payload)
                let block = try #require(decoded)
                #expect(block.format == PCMFormat(sampleRate: 48_000, channels: fixture.channels))
                #expect(block.frameCount == 1024)
                #expect(abs(block.milliseconds - 21.333) < 0.01)
            }
        }
    }

    @Test("rejects out-of-bounds access units, cookies and channel counts")
    func bounds() throws {
        let fixture = try #require(AudioAACFixture.named(bitrate: 96_000))
        let decoder = try #require(AACAccessUnitDecoder(channels: 2, cookie: fixture.cookieData))
        #expect(decoder.decode(Data()) == nil)
        #expect(decoder.decode(Data(count: AACAccessUnitDecoder.maxAccessUnitBytes + 1)) == nil)
        #expect(AACAccessUnitDecoder(channels: 3, cookie: fixture.cookieData) == nil)
        #expect(AACAccessUnitDecoder(channels: 0, cookie: fixture.cookieData) == nil)
        #expect(AACAccessUnitDecoder(channels: 2, cookie: Data()) == nil)
        #expect(AACAccessUnitDecoder(channels: 2, cookie: Data(count: AACAccessUnitDecoder.maxCookieBytes + 1)) == nil)

        var packets = AudioPacketDecoder()
        var missingCookie = AudioTestPackets.aac(1, revision: 1)
        missingCookie.header.cookie = nil
        let undecodable = packets.decode(missingCookie.header, payload: missingCookie.payload)
        #expect(undecodable == nil)
    }

    private static func positiveZeroCrossingRate(_ samples: ArraySlice<Float>, sampleRate: Double) -> Double {
        var crossings = 0
        var previous = samples.first ?? 0
        for sample in samples.dropFirst() {
            if previous < 0 && sample >= 0 { crossings += 1 }
            previous = sample
        }
        return Double(crossings) / (Double(samples.count) / sampleRate)
    }
}
