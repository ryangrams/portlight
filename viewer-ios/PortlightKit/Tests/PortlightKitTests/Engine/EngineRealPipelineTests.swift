import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// RENDER-02 end to end with the production pieces: real PNG and JPEG tiles through the engine, `ImageTileDecoder`
/// and `SoftwareFramebuffer`, across a resolution-changing revision, compared byte for byte with a golden model
/// built by applying the accepted patches in arrival order.
@Suite struct EngineRealPipelineTests {
    private let d1: DisplayID = "fixture-1", d2: DisplayID = "fixture-2"
    private let hd = PixelSize(width: 1280, height: 720), fhd = PixelSize(width: 1920, height: 1080)
    /// Frames sent between drains: well inside the host's 32-packet window and the engine's 48-job bound.
    private let window = 16

    private func randomTile(_ random: inout EngineRandom, _ display: DisplayID, in canvas: PixelSize) -> EngineTile {
        let width = random.int(8..<161), height = random.int(8..<121)
        let rect = PixelRect(x: random.int(0..<(canvas.width - width + 1)), y: random.int(0..<(canvas.height - height + 1)),
                             width: width, height: height)
        let kind = EngineTile.Kind.allCases[random.int(0..<EngineTile.Kind.allCases.count)]
        return EngineTile.random(kind, display: display, rect: rect, using: &random)
    }

    @Test func tileFloodAcrossAResolutionChangeMatchesTheGoldenModel() throws { // RENDER-02
        let p = EngineRealPipeline()
        var random = EngineRandom(seed: 0x5EED_0002)
        var sequencer = EngineSequencer()
        var frames: [Int] = [], audio: [Int] = [], committed: [Int] = []
        var revisionOf: [Int: Int] = [:]
        p.connect(displays: [d1, d2])
        p.acknowledge([d1: hd, d2: hd])
        p.drain()

        // Revision 1: a keyframe per display, then overlapping tiles of every codec with audio interleaved.
        var golden = [d1: EngineGoldenCanvas(size: hd), d2: EngineGoldenCanvas(size: hd)]
        var revision1 = [EngineTile.keyframe(display: d1, canvas: hd, seed: 1), EngineTile.keyframe(display: d2, canvas: hd, seed: 2)]
        for index in 0..<60 { revision1.append(randomTile(&random, index % 3 == 0 ? d1 : d2, in: hd)) }
        for (index, patch) in revision1.enumerated() {
            let sequence = sequencer.next(skipping: random.int(0..<4) == 0)
            p.send(patch, revision: 1, sequence: sequence, canvas: hd)
            frames.append(sequence); committed.append(sequence); revisionOf[sequence] = 1
            golden[patch.display]!.apply(patch)
            if random.int(0..<5) == 0 {
                let packet = sequencer.next()
                p.transport.emit(Fixture.audio(revision: 1, sequence: packet))
                audio.append(packet)
            }
            if index % window == window - 1 { p.drain() }
        }
        p.drain()
        let beforeChange = golden

        // The controller raises the resolution: FHD for d1, while d2 stays HD (a display smaller than the box).
        p.submit { $0.resolution = .fhd }

        // Revision 1 tiles already queued for decode when revision 2 lands; the first is parked mid-decode.
        let queued = (0..<5).map { index in randomTile(&random, index % 2 == 0 ? d2 : d1, in: hd) }
        let queuedSequences = queued.map { _ in sequencer.next() }
        p.decoder.hold(sequence: queuedSequences[0])
        for (patch, sequence) in zip(queued, queuedSequences) {
            p.send(patch, revision: 1, sequence: sequence, canvas: hd)
            frames.append(sequence)
        }
        #expect(p.decoder.waitUntilHeld())
        p.acknowledge([d1: fhd, d2: hd]) // acceptRevision(2) while that decode is parked

        // Revision 1 tiles arriving after `subscribed` are stale on arrival: ACKed at once, never decoded.
        var lateSequences: [Int] = []
        for _ in 0..<3 {
            let sequence = sequencer.next()
            p.send(randomTile(&random, d1, in: hd), revision: 1, sequence: sequence, canvas: hd)
            frames.append(sequence); lateSequences.append(sequence)
        }
        p.syncEngine()
        #expect(Array(p.transport.acks.suffix(3)) == lateSequences)
        #expect(!p.transport.acks.contains(queuedSequences[0]))
        // d1's old picture stays shown while its FHD replacement is painted behind it.
        #expect(p.software.hasPendingReplacement(display: d1))
        #expect(beforeChange[d1]!.mismatch(p.software.snapshot(display: d1)) == nil)
        #expect(beforeChange[d2]!.mismatch(p.software.snapshot(display: d2)) == nil)

        // Revision 2: d1's full keyframe, then partial tiles for both; d2 keeps its surface and its pixels.
        golden[d1] = EngineGoldenCanvas(size: fhd)
        var revision2 = [EngineTile.keyframe(display: d1, canvas: fhd, seed: 3)]
        for index in 0..<66 { revision2.append(randomTile(&random, index % 2 == 0 ? d1 : d2, in: index % 2 == 0 ? fhd : hd)) }
        for (index, patch) in revision2.enumerated() {
            let sequence = sequencer.next(skipping: random.int(0..<4) == 0)
            p.send(patch, revision: 2, sequence: sequence, canvas: patch.display == d1 ? fhd : hd)
            frames.append(sequence); committed.append(sequence); revisionOf[sequence] = 2
            golden[patch.display]!.apply(patch)
            if random.int(0..<5) == 0 {
                let packet = sequencer.next()
                p.transport.emit(Fixture.audio(revision: 2, sequence: packet))
                audio.append(packet)
            }
            if index == 6 {
                p.decoder.release() // 5 + 7 frames were waiting behind the parked decode
                p.drain()
            } else if index > 6, index % window == 0 {
                p.drain()
            }
        }
        p.drain()

        // Byte-identical to the golden model of the accepted patches.
        #expect(golden[d1]!.mismatch(p.software.snapshot(display: d1)) == nil)
        #expect(golden[d2]!.mismatch(p.software.snapshot(display: d2)) == nil)
        #expect(!p.software.hasPendingReplacement(display: d1))
        #expect(p.software.coverage(display: d1)?.isCovered == true)
        // Exactly the expected patches landed, in arrival order; the parked batch was discarded as stale.
        #expect(p.framebuffer.sequences(.committed) == committed)
        #expect(p.framebuffer.sequences(.stale) == queuedSequences)
        #expect(p.framebuffer.sequences(.failed).isEmpty)
        // Every image is ACKed exactly once, never before its commit; audio never is.
        let acks = p.transport.acks
        #expect(acks.sorted() == frames.sorted())
        #expect(Set(acks).count == acks.count)
        #expect(Set(acks).isDisjoint(with: audio))
        let entries = p.log.entries
        let acceptRevision2 = try #require(entries.firstIndex(of: .accept(revision: 2)))
        for sequence in committed {
            let revision = try #require(revisionOf[sequence])
            let commit = try #require(entries.firstIndex(of: .commit(revision: revision, sequence: sequence)))
            let ack = try #require(entries.firstIndex(of: .sent(transport: 1, .frameAck(sequence: sequence))))
            #expect(commit < ack)
            #expect(revision == 1 ? commit < acceptRevision2 : commit > acceptRevision2)
        }
        let d = p.diagnostics
        #expect(d.framesReceived == frames.count)
        #expect(d.framesCommitted == committed.count)
        #expect(d.framesStale == queuedSequences.count + lateSequences.count)
        #expect(d.framesRejected == 0)
        #expect(d.framesUnexpected == 0)
        #expect(d.recoveries == 0)
        #expect(d.acksSent == frames.count)
        #expect(d.decodeJobsInFlight == 0)
        #expect(p.audio.submitted.map(\.sequence) == audio)
        #expect(p.delegate.recoveries.isEmpty)
        #expect(p.delegate.phases.last == .connected)
    }

    @Test func corruptTileAndExhaustedStagingRecoverWithoutTouchingThePicture() {
        let canvas = PixelSize(width: 512, height: 288)
        let p = EngineRealPipeline(patchByteLimit: 256 * 256 * 4)
        var random = EngineRandom(seed: 0xBAD)
        p.connect(displays: [d1])
        p.acknowledge([d1: canvas])
        p.drain()
        var golden = EngineGoldenCanvas(size: canvas)
        let good = EngineTile.random(.rgb, display: d1, rect: PixelRect(x: 16, y: 16, width: 64, height: 48), using: &random)
        p.send(good, revision: 1, sequence: 1, canvas: canvas)
        golden.apply(good)
        // A PNG whose chunk CRC is broken: the real decoder rejects it, the engine ACKs and asks for recovery.
        let broken = EngineTile.random(.gray16, display: d1, rect: PixelRect(x: 0, y: 0, width: 128, height: 128), using: &random)
        p.send(broken.corrupted(), revision: 1, sequence: 2, canvas: canvas)
        p.drain()
        #expect(p.delegate.recoveries == ["image decode failed"])
        // The controller's forced resubscribe closes that burst; then a keyframe larger than the staging limit.
        p.submit(force: true)
        p.acknowledge([d1: canvas])
        p.drain()
        p.send(EngineTile.keyframe(display: d1, canvas: canvas, seed: 4), revision: 2, sequence: 3, canvas: canvas)
        p.drain()
        #expect(p.delegate.recoveries == ["image decode failed", "patch buffer unavailable"])
        #expect(p.transport.acks == [1, 2, 3])
        #expect(p.framebuffer.sequences(.committed) == [1])
        #expect(p.diagnostics.framesRejected == 2)
        #expect(golden.mismatch(p.software.snapshot(display: d1)) == nil)
        #expect(p.delegate.phases.last == .connected)
    }
}
