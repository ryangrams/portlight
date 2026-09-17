// No `import Foundation` here: with Command Line Tools, Foundation + Testing in one file needs the missing
// `_Testing_Foundation` overlay. Foundation-typed helpers live in RenderingFixtures.swift.
import Metal
import Testing
@testable import PortlightKit

/// The same patch sequences through the golden `SoftwareFramebuffer` and the GPU `MetalFramebufferStore`
/// (read back from the texture). Metal cases fail, never skip, without a device.
@Suite("Framebuffers")
struct FramebufferTests {
    /// One sink under test plus the way to read its shown picture back.
    struct Subject {
        let name: String
        let sink: FramebufferSink
        let snapshot: (DisplayID) -> (PixelSize, [UInt8])?
        let counters: () -> FramebufferCounters
        let hasPendingReplacement: (DisplayID) -> Bool
    }

    private func subjects() throws -> [Subject] {
        let software = SoftwareFramebuffer()
        let device = try #require(MTLCreateSystemDefaultDevice(), "a Metal device is required")
        let queue = try #require(device.makeCommandQueue())
        let store = MetalFramebufferStore(device: device, commandQueue: queue)
        return [
            Subject(name: "software", sink: software, snapshot: software.snapshot, counters: { software.counters },
                    hasPendingReplacement: software.hasPendingReplacement),
            Subject(name: "metal", sink: store, snapshot: store.snapshotBGRA, counters: { store.counters },
                    hasPendingReplacement: store.hasPendingReplacement),
        ]
    }

    private let canvas = PixelSize(width: 64, height: 48)
    private let red: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 255, 255)
    private let green: (UInt8, UInt8, UInt8, UInt8) = (0, 255, 0, 255)
    private let blue: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 0, 255)

    private func commitSolid(_ sink: FramebufferSink, revision: Int = 1, display: DisplayID = "d1", _ rect: PixelRect,
                             canvas: PixelSize? = nil, _ color: (UInt8, UInt8, UInt8, UInt8)) -> PatchCommitResult {
        let header = RenderingFixtures.header(revision: revision, display: display, rect: rect, canvas: canvas ?? self.canvas)
        return sink.commit(RenderingFixtures.solidPatch(header, bgra: color, allocate: sink.makePatchBuffer))
    }

    /// CPU reference: apply patches in order onto opaque black.
    private func reference(_ size: PixelSize, _ patches: [(PixelRect, (Int, Int) -> (UInt8, UInt8, UInt8, UInt8))]) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size.pixelCount * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        for (rect, color) in patches {
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let (b, g, r, a) = color(x, y)
                    let at = ((rect.y + y) * size.width + rect.x + x) * 4
                    pixels[at] = b; pixels[at + 1] = g; pixels[at + 2] = r; pixels[at + 3] = a
                }
            }
        }
        return pixels
    }

    @Test func overlappingPartialUpdatesPreserveUntouchedAreasIdentically() throws {
        let gradient: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { x, y in (UInt8(x * 4), UInt8(y * 5), UInt8((x + y) % 256), 255) }
        let checker: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { x, y in (x + y) % 2 == 0 ? (250, 250, 250, 255) : (5, 5, 5, 255) }
        let sequence: [(PixelRect, (Int, Int) -> (UInt8, UInt8, UInt8, UInt8))] = [
            (PixelRect(x: 0, y: 0, width: 40, height: 30), gradient),        // partial first patch
            (PixelRect(x: 8, y: 8, width: 24, height: 16), { _, _ in (0, 0, 255, 255) }),
            (PixelRect(x: 20, y: 12, width: 30, height: 20), checker),       // overlaps both
            (PixelRect(x: 0, y: 40, width: 64, height: 8), { _, _ in (9, 99, 199, 255) }),
            (PixelRect(x: 63, y: 0, width: 1, height: 48), { _, y in (UInt8(y), 1, 2, 255) }),
        ]
        let expected = reference(canvas, sequence)
        var results: [[UInt8]] = []
        for subject in try subjects() {
            subject.sink.acceptRevision(1, canvases: ["d1": canvas, "d2": PixelSize(width: 16, height: 16)], requestedRegions: [:])
            for (rect, color) in sequence {
                let header = RenderingFixtures.header(rect: rect, canvas: canvas)
                #expect(subject.sink.commit(RenderingFixtures.patch(header, allocate: subject.sink.makePatchBuffer, pixel: color)) == .committed)
            }
            let (size, pixels) = try #require(subject.snapshot("d1"), "\(subject.name)")
            #expect(size == canvas)
            #expect(pixels == expected, "\(subject.name) differs from the in-order reference")
            // The other display was never painted: opaque black, untouched by d1's patches.
            #expect(subject.snapshot("d2")?.1 == reference(PixelSize(width: 16, height: 16), []))
            #expect(subject.counters().committed == sequence.count)
            let expectedBytes: Int = sequence.reduce(0) { (total: Int, entry) in total + entry.0.pixelCount * 4 }
            #expect(subject.counters().blitBytes == expectedBytes)
            results.append(pixels)
        }
        #expect(results.count == 2 && results[0] == results[1])
    }

    @Test func partialFirstPatchGatesInputToPaintedCells() throws {
        for subject in try subjects() {
            subject.sink.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:])
            #expect(!subject.sink.hasValidPixels(display: "d1", x: 0.1, y: 0.1))
            #expect(commitSolid(subject.sink, PixelRect(x: 0, y: 0, width: 32, height: 48), red) == .committed)
            #expect(subject.sink.hasValidPixels(display: "d1", x: 0.1, y: 0.5))
            #expect(!subject.sink.hasValidPixels(display: "d1", x: 0.75, y: 0.5))
            #expect(!subject.sink.hasValidPixels(display: "unknown", x: 0.1, y: 0.5))
        }
    }

    @Test func sizeChangingRevisionKeepsOldPixelsUntilCoverageCompletes() throws {
        let small = PixelSize(width: 32, height: 24)
        var snapshots: [[UInt8]] = []
        for subject in try subjects() {
            subject.sink.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:])
            #expect(commitSolid(subject.sink, PixelRect(x: 0, y: 0, width: 64, height: 48), red) == .committed)
            let old = try #require(subject.snapshot("d1"))

            subject.sink.acceptRevision(2, canvases: ["d1": small], requestedRegions: [:])
            #expect(subject.hasPendingReplacement("d1"))
            #expect(subject.snapshot("d1")?.1 == old.1, "\(subject.name): the old picture must stay until the replacement is covered")
            #expect(subject.sink.hasValidPixels(display: "d1", x: 0.5, y: 0.5)) // the shown (old) picture is still trusted
            #expect(commitSolid(subject.sink, revision: 2, PixelRect(x: 0, y: 0, width: 32, height: 16), canvas: small, blue) == .committed)
            #expect(subject.snapshot("d1")?.0 == canvas)
            #expect(commitSolid(subject.sink, revision: 1, PixelRect(x: 0, y: 0, width: 64, height: 48), green) == .stale)
            #expect(commitSolid(subject.sink, revision: 2, PixelRect(x: 0, y: 16, width: 32, height: 8), canvas: small, green) == .committed)

            let (size, pixels) = try #require(subject.snapshot("d1"))
            #expect(size == small)
            #expect(pixels == reference(small, [(PixelRect(x: 0, y: 0, width: 32, height: 16), { _, _ in (255, 0, 0, 255) }),
                                                (PixelRect(x: 0, y: 16, width: 32, height: 8), { _, _ in (0, 255, 0, 255) })]))
            #expect(!subject.hasPendingReplacement("d1"))
            #expect(subject.counters().swaps == 1)
            #expect(subject.counters().stale == 1)
            snapshots.append(pixels)
        }
        #expect(snapshots[0] == snapshots[1])
    }

    @Test func requestedRegionDecidesWhenTheReplacementIsCovered() throws {
        let large = PixelSize(width: 128, height: 96)
        for subject in try subjects() {
            subject.sink.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:])
            _ = commitSolid(subject.sink, PixelRect(x: 0, y: 0, width: 64, height: 48), red)
            // Only the left half is requested: covering it is enough to swap.
            subject.sink.acceptRevision(2, canvases: ["d1": large], requestedRegions: ["d1": NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)])
            _ = commitSolid(subject.sink, revision: 2, PixelRect(x: 0, y: 0, width: 64, height: 96), canvas: large, blue)
            #expect(subject.snapshot("d1")?.0 == large, "\(subject.name)")
            #expect(subject.sink.hasValidPixels(display: "d1", x: 0.25, y: 0.5))
            #expect(!subject.sink.hasValidPixels(display: "d1", x: 0.75, y: 0.5))
        }
    }

    @Test func staleCommitsAfterANewRevisionLeavePixelsUntouched() throws {
        for subject in try subjects() {
            subject.sink.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:])
            _ = commitSolid(subject.sink, PixelRect(x: 0, y: 0, width: 64, height: 48), red)
            let before = try #require(subject.snapshot("d1"))
            subject.sink.acceptRevision(2, canvases: ["d1": canvas], requestedRegions: [:]) // same size: surface kept
            #expect(subject.snapshot("d1")?.1 == before.1)
            #expect(!subject.hasPendingReplacement("d1"))
            #expect(commitSolid(subject.sink, revision: 1, PixelRect(x: 0, y: 0, width: 8, height: 8), green) == .stale)
            #expect(commitSolid(subject.sink, revision: 3, PixelRect(x: 0, y: 0, width: 8, height: 8), green) == .stale)
            #expect(commitSolid(subject.sink, revision: 2, PixelRect(x: 0, y: 0, width: 8, height: 8), canvas: PixelSize(width: 32, height: 24), green) == .stale)
            #expect(commitSolid(subject.sink, revision: 2, display: "other", PixelRect(x: 0, y: 0, width: 8, height: 8), green) == .stale)
            #expect(subject.snapshot("d1")?.1 == before.1, "\(subject.name): stale patches must not reach the surface")
            #expect(commitSolid(subject.sink, revision: 2, PixelRect(x: 0, y: 0, width: 8, height: 8), green) == .committed)
            #expect(subject.counters().stale == 4)
            #expect(subject.counters().failed == 0) // an old revision is acknowledged and dropped, never a failure needing recovery
            #expect(subject.counters().committed == 2)
        }
    }

    @Test func releasedDisplaysAndRemoveAll() throws {
        for subject in try subjects() {
            subject.sink.acceptRevision(1, canvases: ["d1": canvas, "d2": canvas], requestedRegions: [:])
            _ = commitSolid(subject.sink, display: "d2", PixelRect(x: 0, y: 0, width: 64, height: 48), red)
            subject.sink.acceptRevision(2, canvases: ["d1": canvas], requestedRegions: [:])
            #expect(subject.snapshot("d2") == nil)
            #expect(subject.snapshot("d1") != nil)
            subject.sink.removeAll()
            #expect(subject.snapshot("d1") == nil)
            #expect(!subject.sink.hasValidPixels(display: "d1", x: 0.5, y: 0.5))
        }
    }

    @Test func newConnectionKeepsTheFrozenFrameButNotItsInputValidity() throws {
        for subject in try subjects() {
            subject.sink.acceptRevision(5, canvases: ["d1": canvas], requestedRegions: [:])
            _ = commitSolid(subject.sink, revision: 5, PixelRect(x: 0, y: 0, width: 64, height: 48), red)
            let frozen = try #require(subject.snapshot("d1"))
            subject.sink.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:]) // revisions restart: new connection
            #expect(subject.snapshot("d1")?.1 == frozen.1)
            #expect(!subject.sink.hasValidPixels(display: "d1", x: 0.5, y: 0.5))
            _ = commitSolid(subject.sink, revision: 1, PixelRect(x: 0, y: 0, width: 64, height: 48), blue)
            #expect(subject.sink.hasValidPixels(display: "d1", x: 0.5, y: 0.5))
        }
    }

    @Test func decodedHostTilesLandIdentically() throws {
        let tile = PixelSize(width: 21, height: 13)
        let payloads: [(Data, PixelRect)] = [
            (HostTileEncoder.gray16PNG(width: 21, height: 13) { x, y in UInt8((x + y) % 16) }, PixelRect(x: 0, y: 0, width: 21, height: 13)),
            (HostTileEncoder.color256PNG(width: 21, height: 13) { x, y in UInt8((x * 13 + y * 7) % 256) }, PixelRect(x: 10, y: 6, width: 21, height: 13)),
            (HostTileEncoder.rgbPNG(width: 21, height: 13) { x, y in (UInt8(x * 12), UInt8(y * 19), 77) }, PixelRect(x: 43, y: 35, width: 21, height: 13)),
        ]
        var results: [[UInt8]] = []
        for subject in try subjects() {
            subject.sink.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:])
            for (payload, rect) in payloads {
                #expect(rect.width == tile.width)
                let header = RenderingFixtures.header(rect: rect, canvas: canvas)
                let patch = try ImageTileDecoder.decode(header: header, payload: payload, allocate: subject.sink.makePatchBuffer)
                #expect(subject.sink.commit(patch) == .committed)
            }
            results.append(try #require(subject.snapshot("d1")).1)
        }
        #expect(results[0] == results[1])
        // Spot checks against the formulas: gray nibble n → n×17; palette entry; RGB unchanged.
        #expect(RenderingFixtures.pixel(results[0], width: 64, x: 3, y: 2) == [85, 85, 85, 255]) // tile 1, nibble 5
        let p = ((12 * 13 + 1 * 7) % 256) * 3 // canvas (22, 7) is tile 2's local (12, 1); it overwrote tile 1 there
        #expect(RenderingFixtures.pixel(results[0], width: 64, x: 22, y: 7)
                == [HostTileEncoder.palette[p + 2], HostTileEncoder.palette[p + 1], HostTileEncoder.palette[p], 255])
        #expect(RenderingFixtures.pixel(results[0], width: 64, x: 63, y: 47) == [77, UInt8(12 * 19), UInt8(20 * 12), 255]) // tile 3, local (20, 12)
    }
}

@Suite("MetalFramebufferStore")
struct MetalFramebufferStoreTests {
    private func device() throws -> MTLDevice { try #require(MTLCreateSystemDefaultDevice(), "a Metal device is required") }

    @Test func stagingPoolIsBoundedWaitsBrieflyAndRecycles() throws {
        let device = try device()
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()),
                                          stagingBudgetBytes: 256 * 1024, stagingWaitTimeout: 0.02)
        #expect(store.makePatchBuffer(byteCount: 256 * 1024 + 1) == nil) // can never fit
        #expect(store.makePatchBuffer(byteCount: 0) == nil)
        var first: PatchBuffer? = store.makePatchBuffer(byteCount: 200 * 1024)
        #expect(first?.byteCount == 200 * 1024)
        #expect(store.makePatchBuffer(byteCount: 100 * 1024) == nil) // budget held by `first`; waits 20 ms, then gives up
        #expect(store.stagingBytesAllocated <= 256 * 1024)
        first = nil // a discarded patch returns its buffer
        let second = try #require(store.makePatchBuffer(byteCount: 100 * 1024))
        #expect(second.byteCount == 100 * 1024)
        #expect(store.stagingBytesAllocated <= 256 * 1024)
    }

    @Test func committedStagingReturnsAfterTheGPUBlit() throws {
        let device = try device()
        let budget = 64 * 64 * 4
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()),
                                          stagingBudgetBytes: budget, stagingWaitTimeout: 1)
        let canvas = PixelSize(width: 64, height: 64)
        store.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:])
        for round in 0..<4 {
            // Each patch needs the whole budget, so every round depends on the previous blit's completion handler.
            let header = RenderingFixtures.header(rect: PixelRect(x: 0, y: 0, width: 64, height: 64), canvas: canvas, sequence: round)
            let patch = RenderingFixtures.solidPatch(header, bgra: (UInt8(round), 0, 0, 255), allocate: store.makePatchBuffer)
            #expect(store.commit(patch) == .committed)
            store.flush()
        }
        #expect(store.snapshotBGRA(display: "d1")?.1.prefix(4) == [3, 0, 0, 255])
        #expect(store.counters.committed == 4)
        #expect(store.stagingBytesAllocated <= budget)
    }

    @Test func batchesLargerThanTheBatchLimitAndForeignBuffersApplyInOrder() throws {
        let device = try device()
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()))
        let software = SoftwareFramebuffer()
        let canvas = PixelSize(width: 40, height: 40)
        for sink in [store as FramebufferSink, software] { sink.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:]) }
        var random = RenderingFixtureRandom(seed: 150)
        for index in 0..<150 {
            let width = random.int(1..<20), height = random.int(1..<20)
            let rect = PixelRect(x: random.int(0..<(40 - width + 1)), y: random.int(0..<(40 - height + 1)), width: width, height: height)
            let color = (random.byte(), random.byte(), random.byte(), UInt8(255))
            let header = RenderingFixtures.header(rect: rect, canvas: canvas, sequence: index)
            // Every third patch arrives in plain heap memory and must be staged by the store.
            let metalPatch = index % 3 == 0 ? RenderingFixtures.solidPatch(header, bgra: color)
                                            : RenderingFixtures.solidPatch(header, bgra: color, allocate: store.makePatchBuffer)
            #expect(store.commit(metalPatch) == .committed)
            #expect(software.commit(RenderingFixtures.solidPatch(header, bgra: color)) == .committed)
        }
        #expect(store.snapshotBGRA(display: "d1")?.1 == software.snapshot(display: "d1")?.1)
        #expect(store.counters.committed == 150)
        #expect(store.gpuErrorCount == 0)
    }

    @Test func texturesFollowSwapsAndPersistUntilRemoveAll() throws {
        let device = try device()
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()))
        store.acceptRevision(1, canvases: ["d1": PixelSize(width: 32, height: 32)], requestedRegions: [:])
        let first = try #require(store.texturesForRendering()["d1"])
        #expect(first.pixelFormat == .bgra8Unorm)
        #expect(first.storageMode == .private)
        #expect(first.usage.contains(.shaderRead))
        let generation = store.contentGeneration
        store.acceptRevision(2, canvases: ["d1": PixelSize(width: 16, height: 16)], requestedRegions: [:])
        #expect(store.texturesForRendering()["d1"] === first) // old texture shown while the replacement paints
        let header = RenderingFixtures.header(revision: 2, rect: PixelRect(x: 0, y: 0, width: 16, height: 16), canvas: PixelSize(width: 16, height: 16))
        #expect(store.commit(RenderingFixtures.solidPatch(header, bgra: (1, 2, 3, 255), allocate: store.makePatchBuffer)) == .committed)
        let swapped = try #require(store.texturesForRendering()["d1"])
        #expect(swapped !== first)
        #expect(swapped.width == 16)
        #expect(store.contentGeneration > generation)
        // No disconnect API touches textures: the frozen frame stays until removeAll.
        #expect(store.texturesForRendering().count == 1)
        store.removeAll()
        #expect(store.texturesForRendering().isEmpty)
    }
}
