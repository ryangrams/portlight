// AVFoundation (which re-exports Foundation) rather than `import Foundation`: see AACDecodingTests.swift.
import AVFoundation
import Testing
@testable import PortlightKit

private let aac96 = AudioConfiguration(codec: .aac, bitrate: 96_000)
private let aac160 = AudioConfiguration(codec: .aac, bitrate: 160_000)
private let aac48 = AudioConfiguration(codec: .aac, bitrate: 48_000)
private let mulaw = AudioConfiguration(codec: .mulaw, bitrate: 192_000)

private func aacHeader(revision: Int, bitrate: Int? = 96_000, channels: Int = 2, sampleRate: Int = 48_000,
                       samples: Int = 1024, cookie: Data? = Data([0x03, 0x80, 0x80, 0x80])) -> AudioHeader {
    AudioHeader(revision: revision, codec: .aac, sampleRate: sampleRate, channels: channels, samples: samples,
                sequence: 1, bitrate: bitrate, cookie: cookie)
}

private func mulawHeader(revision: Int, sampleRate: Int = 24_000, channels: Int = 1, samples: Int = 480) -> AudioHeader {
    AudioHeader(revision: revision, codec: .mulaw, sampleRate: sampleRate, channels: channels, samples: samples,
                sequence: 1, bitrate: nil, cookie: nil)
}

@Suite("Audio · epoch gate")
struct AudioEpochGateTests {
    @Test("rejects everything while audio is off")
    func offByDefault() {
        var gate = AudioEpochGate()
        #expect(!gate.isEnabled)
        #expect(!gate.accept(aacHeader(revision: 0)))
        #expect(gate.acknowledged(nil, revision: 1) == .unchanged)
        #expect(!gate.accept(aacHeader(revision: 1)))
    }

    @Test("Off then On with the same codec rejects the old stream's late packets")
    func offOnSameCodec() {
        var gate = AudioEpochGate()
        #expect(gate.acknowledged(aac96, revision: 1) == .started)
        #expect(gate.accept(aacHeader(revision: 1)))
        #expect(gate.acknowledged(nil, revision: 2) == .stopped)
        #expect(!gate.accept(aacHeader(revision: 1)))
        #expect(gate.acknowledged(aac96, revision: 3) == .started)
        #expect(gate.epochStartRevision == 3)
        // Identical format and a revision below the newest one: the Mac viewer's `revision <= sent`
        // rule would play this. The epoch rejects it.
        #expect(!gate.accept(aacHeader(revision: 1)))
        #expect(!gate.accept(aacHeader(revision: 2)))
        #expect(gate.accept(aacHeader(revision: 3)))
    }

    @Test("a codec change starts a new epoch and rejects the old codec")
    func codecChange() {
        var gate = AudioEpochGate()
        gate.acknowledged(aac96, revision: 1)
        #expect(gate.acknowledged(mulaw, revision: 2) == .started)
        #expect(!gate.accept(aacHeader(revision: 1)))
        #expect(!gate.accept(aacHeader(revision: 2)))
        #expect(!gate.accept(mulawHeader(revision: 1)))
        #expect(gate.accept(mulawHeader(revision: 2)))
    }

    @Test("a bitrate change starts a new epoch and rejects the old bitrate")
    func bitrateChange() {
        var gate = AudioEpochGate()
        gate.acknowledged(aac96, revision: 1)
        #expect(gate.acknowledged(aac160, revision: 4) == .started)
        #expect(!gate.accept(aacHeader(revision: 4, bitrate: 96_000)))
        #expect(!gate.accept(aacHeader(revision: 3, bitrate: 160_000)))
        #expect(gate.accept(aacHeader(revision: 4, bitrate: 160_000)))
        #expect(gate.accept(aacHeader(revision: 4, bitrate: nil)))
    }

    @Test("video-only revisions keep the epoch and keep accepting earlier revisions")
    func videoOnlyRevisions() {
        var gate = AudioEpochGate()
        #expect(gate.acknowledged(aac96, revision: 1) == .started)
        #expect(gate.acknowledged(aac96, revision: 2) == .unchanged)
        #expect(gate.acknowledged(aac96, revision: 3) == .unchanged)
        #expect(gate.epochStartRevision == 1)
        #expect(gate.latestRevision == 3)
        for revision in 1...3 { #expect(gate.accept(aacHeader(revision: revision))) }
        // Not yet acknowledged: its configuration is unknown.
        #expect(!gate.accept(aacHeader(revision: 4)))
    }

    @Test("rejects packets whose channels, rate, frame count, cookie or bitrate mismatch the configuration")
    func formatMismatches() {
        var gate = AudioEpochGate()
        gate.acknowledged(aac48, revision: 1)
        #expect(gate.accept(aacHeader(revision: 1, bitrate: 48_000, channels: 1)))
        #expect(!gate.accept(aacHeader(revision: 1, bitrate: 48_000, channels: 2)))

        gate.acknowledged(aac96, revision: 2)
        #expect(gate.accept(aacHeader(revision: 2)))
        #expect(!gate.accept(aacHeader(revision: 2, channels: 1)))
        #expect(!gate.accept(aacHeader(revision: 2, sampleRate: 44_100)))
        #expect(!gate.accept(aacHeader(revision: 2, sampleRate: 24_000)))
        #expect(!gate.accept(aacHeader(revision: 2, samples: 2048)))
        #expect(!gate.accept(aacHeader(revision: 2, cookie: nil)))
        #expect(!gate.accept(aacHeader(revision: 2, cookie: Data())))
        #expect(!gate.accept(aacHeader(revision: 2, cookie: Data(count: 4097))))
        #expect(!gate.accept(aacHeader(revision: 2, bitrate: 320_000)))
        #expect(!gate.accept(mulawHeader(revision: 2)))

        gate.acknowledged(mulaw, revision: 3)
        #expect(gate.accept(mulawHeader(revision: 3)))
        #expect(!gate.accept(mulawHeader(revision: 3, sampleRate: 48_000)))
        #expect(!gate.accept(mulawHeader(revision: 3, channels: 2)))
        #expect(!gate.accept(mulawHeader(revision: 3, samples: 0)))
        #expect(!gate.accept(mulawHeader(revision: 3, samples: AudioEpochGate.maxMuLawSamples + 1)))
    }

    @Test("reset and a lower revision (new connection) never continue the old epoch")
    func newConnection() {
        var gate = AudioEpochGate()
        gate.acknowledged(aac96, revision: 7)
        gate.reset()
        #expect(!gate.accept(aacHeader(revision: 7)))
        #expect(gate.acknowledged(aac96, revision: 1) == .started)
        #expect(gate.accept(aacHeader(revision: 1)))

        var continued = AudioEpochGate()
        continued.acknowledged(aac96, revision: 7)
        #expect(continued.acknowledged(aac96, revision: 1) == .started)
        #expect(continued.epochStartRevision == 1)
        #expect(!continued.accept(aacHeader(revision: 7)))
        #expect(continued.accept(aacHeader(revision: 1)))
    }
}
