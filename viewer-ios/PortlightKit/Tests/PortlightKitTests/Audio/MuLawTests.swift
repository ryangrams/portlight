// AVFoundation (which re-exports Foundation) rather than `import Foundation`: see AACDecodingTests.swift.
import AVFoundation
import Testing
@testable import PortlightKit

@Suite("Audio · μ-law")
struct MuLawTests {
    @Test("matches the Mac viewer's reference vectors")
    func referenceVectors() {
        #expect(MuLaw.decode(0xFF) == 0)
        #expect(MuLaw.decode(0x7F) == 0)
        #expect(MuLaw.decode(0x00) == -32124)
        #expect(MuLaw.decode(0x80) == 32124)
    }

    @Test("table matches the formula; expansion is sign-symmetric and monotonic")
    func tableProperties() {
        #expect(MuLaw.table.count == 256)
        #expect((0...255).allSatisfy { MuLaw.table[$0] == MuLaw.decode(UInt8($0)) })
        #expect((0...255).allSatisfy { MuLaw.decode(UInt8($0)) == -MuLaw.decode(UInt8($0) ^ 0x80) })
        // Positive codes run from 0x80 (loudest) to 0xFF (zero).
        #expect((0x80..<0xFF).allSatisfy { MuLaw.decode(UInt8($0)) > MuLaw.decode(UInt8($0 + 1)) })
    }

    @Test("every code round-trips through the host's encoder")
    func roundTripsHostEncoder() {
        // 0x7F is μ-law's negative zero; the host encodes 0 as 0xFF.
        let mismatches = (0...255).filter { $0 != 0x7F && hostMuLawEncode(MuLaw.decode(UInt8($0))) != UInt8($0) }
        #expect(mismatches.isEmpty)
        #expect(hostMuLawEncode(MuLaw.decode(0x7F)) == 0xFF)
    }

    @Test("a packet becomes a 24 kHz mono Float32 buffer")
    func pcmBuffer() throws {
        let buffer = try #require(MuLaw.pcmBuffer(Data([0xFF, 0x80, 0x00, 0x7F])))
        #expect(buffer.format.sampleRate == 24_000)
        #expect(buffer.format.channelCount == 1)
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer.frameLength == 4)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect(samples[0] == 0)
        #expect(samples[1] == Float(32124) / 32768)
        #expect(samples[2] == Float(-32124) / 32768)
        #expect(samples[3] == 0)
        #expect(MuLaw.pcmBuffer(Data()) == nil)
    }

    @Test("the packet decoder requires the payload length to equal the declared samples")
    func packetLength() {
        var decoder = AudioPacketDecoder()
        let packet = AudioTestPackets.mulaw(0, revision: 1)
        let block = decoder.decode(packet.header, payload: packet.payload)
        #expect(block?.format == PCMFormat(sampleRate: 24_000, channels: 1))
        #expect(block?.frameCount == 480)
        #expect(block.map { abs($0.milliseconds - 20) < 1e-9 } == true)
        let short = decoder.decode(packet.header, payload: packet.payload.dropLast())
        #expect(short == nil)
    }
}
