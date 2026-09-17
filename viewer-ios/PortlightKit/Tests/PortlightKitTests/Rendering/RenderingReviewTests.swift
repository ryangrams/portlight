// No `import Foundation` here: with Command Line Tools, Foundation + Testing in one file needs the missing
// `_Testing_Foundation` overlay. Foundation-typed helpers live in RenderingFixtures.swift.
import Metal
import Testing
@testable import PortlightKit

/// Regressions from the adversarial review of the Rendering module, plus RENDER-02 evidence at the framebuffer and
/// presentation level. Metal cases fail, never skip, without a device.
@Suite("Rendering review regressions")
struct RenderingReviewTests {
    private let canvas = PixelSize(width: 64, height: 48)
    private let red: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 255, 255)
    private let green: (UInt8, UInt8, UInt8, UInt8) = (0, 255, 0, 255)
    private let blue: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 0, 255)

    private func renderingDevice() throws -> MTLDevice { try #require(MTLCreateSystemDefaultDevice(), "a Metal device is required") }

    /// Both sinks, each with its counters.
    private func renderingSinks() throws -> [(name: String, sink: FramebufferSink, counters: () -> FramebufferCounters)] {
        let device = try renderingDevice()
        let software = SoftwareFramebuffer()
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()))
        return [("software", software, { software.counters }), ("metal", store, { store.counters })]
    }

    private func solid(_ sink: FramebufferSink, revision: Int = 1, display: DisplayID = "d1", _ rect: PixelRect, canvas: PixelSize? = nil,
                       _ color: (UInt8, UInt8, UInt8, UInt8)) -> PatchCommitResult {
        let header = RenderingFixtures.header(revision: revision, display: display, rect: rect, canvas: canvas ?? self.canvas)
        return sink.commit(RenderingFixtures.solidPatch(header, bgra: color, allocate: sink.makePatchBuffer))
    }

    /// A patch whose rows claim fewer bytes than the rectangle needs. `PortlightKit.` because the Engine test fakes
    /// declare their own `HeapPatchBuffer` in this shared target.
    private func malformed(revision: Int = 1, _ rect: PixelRect, canvas: PixelSize? = nil) -> DecodedPatch {
        let header = RenderingFixtures.header(revision: revision, rect: rect, canvas: canvas ?? self.canvas)
        return DecodedPatch(header: header, buffer: PortlightKit.HeapPatchBuffer(byteCount: rect.pixelCount * 4)!, bytesPerRow: rect.width * 4 - 4)
    }

    private func renderingTarget(_ renderer: MetalRenderer, _ size: PixelSize) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        return try #require(renderer.device.makeTexture(descriptor: descriptor))
    }

    /// One display-link tick: encode if needed, commit, wait.
    private func renderingTick(_ renderer: MetalRenderer, _ scene: RenderScene, _ target: MTLTexture) throws -> Bool {
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        let drew = renderer.encodeIfNeeded(scene: scene, into: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return drew
    }

    /// Tightly packed BGRA rows of a private texture (waits for the GPU).
    private func renderingReadBack(_ renderer: MetalRenderer, _ texture: MTLTexture) throws -> [UInt8] {
        let rowBytes = texture.width * 4
        let buffer = try #require(renderer.device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared))
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return [UInt8](UnsafeRawBufferPointer(start: buffer.contents(), count: rowBytes * texture.height))
    }

    // MARK: .failed versus .stale

    @Test func malformedPatchesFailWhileMismatchedRevisionsStayStale() throws {
        for (name, sink, counters) in try renderingSinks() {
            sink.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:])
            #expect(sink.commit(malformed(PixelRect(x: 0, y: 0, width: 16, height: 16))) == .failed, "\(name)")
            let short = RenderingFixtures.header(rect: PixelRect(x: 0, y: 0, width: 16, height: 16), canvas: canvas)
            #expect(sink.commit(DecodedPatch(header: short, buffer: PortlightKit.HeapPatchBuffer(byteCount: 100)!, bytesPerRow: 64)) == .failed, "\(name)")
            // The accepted revision and canvas, but a rectangle that leaves the canvas: malformed, not stale.
            let outside = RenderingFixtures.header(rect: PixelRect(x: 60, y: 0, width: 16, height: 16), canvas: canvas)
            #expect(sink.commit(RenderingFixtures.solidPatch(outside, bgra: red)) == .failed, "\(name)")
            // Malformed but also stale: there is nothing to recover, so it stays .stale.
            #expect(sink.commit(malformed(revision: 9, PixelRect(x: 0, y: 0, width: 16, height: 16))) == .stale, "\(name)")
            #expect(counters().failed == 3, "\(name)")
            #expect(counters().stale == 1, "\(name)")
            #expect(counters().committed == 0, "\(name)")
        }
    }

    @Test func metalSurfaceAllocationFailureFailsItsPatches() throws {
        let device = try renderingDevice()
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()))
        let huge = PixelSize(width: 20_000, height: 16) // beyond the 16384 texture limit: no surface can exist
        store.acceptRevision(1, canvases: ["d1": huge], requestedRegions: [:])
        #expect(store.counters.allocationFailures == 1)
        #expect(solid(store, PixelRect(x: 0, y: 0, width: 16, height: 16), canvas: huge, red) == .failed)
        // A replacement that cannot be allocated fails the new revision's patches too.
        store.acceptRevision(2, canvases: ["d1": canvas], requestedRegions: [:])
        #expect(solid(store, revision: 2, PixelRect(x: 0, y: 0, width: 64, height: 48), red) == .committed)
        store.acceptRevision(3, canvases: ["d1": huge], requestedRegions: [:])
        #expect(!store.hasValidPixels(display: "d1", x: 0.5, y: 0.5))
        #expect(solid(store, revision: 3, PixelRect(x: 0, y: 0, width: 16, height: 16), canvas: huge, green) == .failed)
        #expect(store.counters.failed == 2)
        #expect(store.counters.stale == 0)
    }

    @Test func metalForeignPatchWithoutStagingFails() throws {
        let device = try renderingDevice()
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()),
                                          stagingBudgetBytes: 64 * 1024, stagingWaitTimeout: 0.01)
        let large = PixelSize(width: 256, height: 256)
        store.acceptRevision(1, canvases: ["d1": large], requestedRegions: [:])
        let header = RenderingFixtures.header(rect: PixelRect(x: 0, y: 0, width: 256, height: 256), canvas: large)
        #expect(store.commit(RenderingFixtures.solidPatch(header, bgra: red)) == .failed) // 256 KiB heap patch, 64 KiB budget
        #expect(store.counters.allocationFailures == 1)
        #expect(store.counters.failed == 1)
    }

    @Test func staleForeignPatchNeverTouchesStaging() throws {
        let device = try renderingDevice()
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()))
        store.acceptRevision(2, canvases: ["d1": canvas], requestedRegions: [:])
        let old = RenderingFixtures.header(revision: 1, rect: PixelRect(x: 0, y: 0, width: 64, height: 48), canvas: canvas)
        #expect(store.commit(RenderingFixtures.solidPatch(old, bgra: red)) == .stale)
        #expect(store.stagingBytesAllocated == 0)
    }

    // MARK: Coverage after failures and during replacements

    @Test func failedPatchInvalidatesTheCellsItShouldHaveRepainted() throws {
        for (name, sink, _) in try renderingSinks() {
            sink.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:])
            #expect(solid(sink, PixelRect(x: 0, y: 0, width: 64, height: 48), red) == .committed)
            #expect(sink.commit(malformed(PixelRect(x: 0, y: 0, width: 16, height: 16))) == .failed)
            // The host believes (0,0)–(16,16) shows the lost patch: those pixels are stale and must not be trusted.
            #expect(!sink.hasValidPixels(display: "d1", x: 0.1, y: 0.1), "\(name)")
            #expect(sink.hasValidPixels(display: "d1", x: 0.5, y: 0.5), "\(name)")
            #expect(solid(sink, PixelRect(x: 0, y: 0, width: 16, height: 16), green) == .committed) // a repaint restores them
            #expect(sink.hasValidPixels(display: "d1", x: 0.1, y: 0.1), "\(name)")
        }
    }

    @Test func replacementDoesNotSwapInOverAFailedPatch() throws {
        let small = PixelSize(width: 32, height: 32)
        let device = try renderingDevice()
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()))
        let software = SoftwareFramebuffer()
        for (name, sink, pending) in [("software", software as FramebufferSink, software.hasPendingReplacement),
                                      ("metal", store as FramebufferSink, store.hasPendingReplacement)] {
            sink.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:])
            _ = solid(sink, PixelRect(x: 0, y: 0, width: 64, height: 48), red)
            sink.acceptRevision(2, canvases: ["d1": small], requestedRegions: [:])
            #expect(solid(sink, revision: 2, PixelRect(x: 0, y: 0, width: 32, height: 16), canvas: small, blue) == .committed)
            #expect(sink.commit(malformed(revision: 2, PixelRect(x: 0, y: 0, width: 32, height: 16), canvas: small)) == .failed)
            #expect(solid(sink, revision: 2, PixelRect(x: 0, y: 16, width: 32, height: 16), canvas: small, green) == .committed)
            #expect(pending("d1"), "\(name): the top half lost its latest patch, so the replacement is not complete")
            #expect(solid(sink, revision: 2, PixelRect(x: 0, y: 0, width: 32, height: 16), canvas: small, blue) == .committed)
            #expect(!pending("d1"), "\(name)")
        }
    }

    @Test func pendingReplacementAppliesTheNewRegionToTheShownPicture() throws {
        for (name, sink, _) in try renderingSinks() {
            sink.acceptRevision(1, canvases: ["d1": canvas, "d2": canvas], requestedRegions: [:])
            _ = solid(sink, PixelRect(x: 0, y: 0, width: 64, height: 48), red)
            _ = solid(sink, display: "d2", PixelRect(x: 0, y: 0, width: 64, height: 48), red)
            let larger = PixelSize(width: 128, height: 96)
            // d1 now streams only its left half and d2 is offscreen: neither old picture is maintained outside that.
            sink.acceptRevision(2, canvases: ["d1": larger, "d2": larger],
                                requestedRegions: ["d1": NormalizedRect(x: 0, y: 0, width: 0.5, height: 1), "d2": .zero])
            #expect(sink.hasValidPixels(display: "d1", x: 0.25, y: 0.5), "\(name): the old picture is still trusted where requested")
            #expect(!sink.hasValidPixels(display: "d1", x: 0.75, y: 0.5), "\(name)")
            #expect(!sink.hasValidPixels(display: "d2", x: 0.5, y: 0.5), "\(name)")
            #expect(solid(sink, revision: 2, PixelRect(x: 0, y: 0, width: 64, height: 96), canvas: larger, blue) == .committed)
            #expect(sink.hasValidPixels(display: "d1", x: 0.25, y: 0.5), "\(name): swapped")
            #expect(!sink.hasValidPixels(display: "d1", x: 0.75, y: 0.5), "\(name)")
        }
    }

    @Test func invalidatingARectForgetsEveryCellItTouches() {
        var grid = CoverageGrid(canvas: canvas) // 4 × 3 cells
        grid.markPainted(PixelRect(x: 0, y: 0, width: 64, height: 48))
        #expect(grid.validCellCount == 12)
        grid.invalidate(PixelRect(x: 8, y: 8, width: 16, height: 1)) // touches cells (0,0) and (1,0), covers neither
        #expect(grid.validCellCount == 10)
        #expect(!grid.isValid(normalizedX: 1.0 / 64, y: 1.0 / 48))
        #expect(!grid.isValid(normalizedX: 17.0 / 64, y: 1.0 / 48))
        #expect(grid.isValid(normalizedX: 33.0 / 64, y: 1.0 / 48))
        grid.invalidate(PixelRect(x: Int.max - 4, y: 0, width: 8, height: 8)) // outside the canvas: ignored, no overflow
        #expect(grid.validCellCount == 10)
        #expect(!grid.isCovered)
    }

    // MARK: Decoder

    /// RENDER-01: the decoder's packed-sample path. ImageIO widens 4-bit PNGs to 8 bits on its own, so the gray16 PNG
    /// golden test never reached this code: a wrong n×16 scale here survived every test before this one.
    @Test func packedSubByteSamplesExpandExactly() throws {
        for bits in [1, 2, 4] {
            let width = 37, height = 3, maximum = (1 << bits) - 1 // odd width: the last byte of each row is partly padding
            var samples: [UInt8] = []
            for y in 0..<height { for x in 0..<width { samples.append(UInt8((x * 7 + y * 3) % (maximum + 1))) } }
            var palette: [UInt8] = []
            for index in 0...maximum { palette += [UInt8(index * 16 % 256), UInt8(255 - index), UInt8(index * 5)] }
            var expectedGray: [UInt8] = [], expectedIndexed: [UInt8] = []
            for sample in samples {
                let level = UInt8(Int(sample) * 255 / maximum) // 4-bit: n × 17
                expectedGray += [level, level, level, 255]
                let entry = Int(sample) * 3
                expectedIndexed += [palette[entry + 2], palette[entry + 1], palette[entry], 255]
            }
            let gray = try RenderingFixtures.expandPacked(bits: bits, width: width, height: height) { x, y in samples[y * width + x] }
            #expect(gray == expectedGray, "\(bits)-bit gray")
            let indexed = try RenderingFixtures.expandPacked(bits: bits, width: width, height: height, palette: palette) { x, y in samples[y * width + x] }
            #expect(indexed == expectedIndexed, "\(bits)-bit indexed")
        }
    }

    // MARK: Budget and staging

    @Test func predictedPixelsSaturatesInsteadOfWrapping() {
        let small = HostDisplay(id: "small", name: "small", number: 1, nativeSize: PixelSize(width: 1024, height: 768),
                                logicalFrame: LogicalRect(x: 0, y: 0, width: 1024, height: 768), scale: 1, isPrimary: true)
        let absurd = HostDisplay(id: "absurd", name: "absurd", number: 2, nativeSize: PixelSize(width: 1 << 32, height: 1 << 32),
                                 logicalFrame: LogicalRect(x: 1024, y: 0, width: 1024, height: 768), scale: 1, isPrimary: false)
        #expect(RenderBudget.predictedPixels(displays: [small, absurd], preset: .hd) == Int.max)
        let choice = RenderBudget.highestPreset(displays: [small, absurd], requested: .uhd, budget: 33_177_600)
        #expect(choice.preset == .hd && choice.limitedByBudget)
    }

    @Test func stagingCanBeTrimmedWithoutDroppingTheFrozenFrame() throws {
        let device = try renderingDevice()
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()),
                                          stagingBudgetBytes: 1 << 20, stagingWaitTimeout: 1)
        #expect(store.stagingBudgetBytes == 1 << 20)
        var buffer: PatchBuffer? = store.makePatchBuffer(byteCount: 4096)
        #expect(buffer != nil)
        buffer = nil // discarded before commit: back in the pool at once
        #expect(store.stagingBytesAllocated == 64 * 1024)
        store.trimStaging()
        #expect(store.stagingBytesAllocated == 0)
        store.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:])
        #expect(solid(store, PixelRect(x: 0, y: 0, width: 64, height: 48), red) == .committed)
        let frozen = try #require(store.snapshotBGRA(display: "d1"))
        store.trimStaging()
        #expect(store.snapshotBGRA(display: "d1")?.1 == frozen.1)
        #expect(store.hasValidPixels(display: "d1", x: 0.5, y: 0.5))
    }

    // MARK: RENDER-02

    /// RENDER-02: decoded patches applied between two display-link ticks all appear in the one presentation that follows.
    @Test func coalescedPresentationShowsEveryAppliedPatch() throws {
        let renderer = try MetalRenderer(device: try renderingDevice())
        let store = renderer.framebuffers
        let software = SoftwareFramebuffer()
        for sink in [store as FramebufferSink, software] { sink.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:]) }
        // Two drawable pixels per texel: nearest filtering, so drawable pixel (2x, 2y) is exactly texel (x, y).
        let size = PixelSize(width: 128, height: 96)
        let scene = RenderScene(transform: ViewportTransform(scale: 2, tx: 0, ty: 0), drawableSize: size,
                                quads: [RenderScene.Quad(display: "d1", frame: LogicalRect(x: 0, y: 0, width: 64, height: 48))])
        let target = try renderingTarget(renderer, size)
        #expect(try renderingTick(renderer, scene, target))
        var random = RenderingFixtureRandom(seed: 2)
        let burst: [(RenderingPayload, PixelRect, ImageCodec)] = [
            (HostTileEncoder.rgbPNG(width: 64, height: 48) { x, y in (UInt8(x * 3), UInt8(y * 5), 40) }, PixelRect(x: 0, y: 0, width: 64, height: 48), .png),
            (HostTileEncoder.gray16PNG(width: 21, height: 13) { x, y in UInt8((x * 3 + y) % 16) }, PixelRect(x: 0, y: 0, width: 21, height: 13), .png),
            (HostTileEncoder.color256PNG(width: 30, height: 18) { _, _ in
                HostTileEncoder.color256Index(r: random.byte(), g: random.byte(), b: random.byte())
            }, PixelRect(x: 10, y: 6, width: 30, height: 18), .png),
            (HostTileEncoder.jpeg(width: 32, height: 16) { x, y in (UInt8(200 - x), UInt8(y * 9), 90) }, PixelRect(x: 16, y: 20, width: 32, height: 16), .jpeg),
            (HostTileEncoder.rgbPNG(width: 21, height: 13) { x, y in (9, UInt8(x * 11), UInt8(y * 17)) }, PixelRect(x: 43, y: 35, width: 21, height: 13), .png),
        ]
        for (index, (payload, rect, codec)) in burst.enumerated() {
            let header = RenderingFixtures.header(rect: rect, canvas: canvas, codec: codec, sequence: index)
            let gpuPatch = try ImageTileDecoder.decode(header: header, payload: payload, allocate: store.makePatchBuffer)
            let cpuPatch = try ImageTileDecoder.decode(header: header, payload: payload, allocate: software.makePatchBuffer)
            #expect(store.commit(gpuPatch) == .committed)
            #expect(software.commit(cpuPatch) == .committed)
        }
        #expect(try renderingTick(renderer, scene, target))  // one draw for the whole burst
        #expect(try !renderingTick(renderer, scene, target)) // nothing new since
        let drawn = try renderingReadBack(renderer, target)
        let golden = try #require(software.snapshot(display: "d1")).1
        let sampled = (0..<48).flatMap { y in (0..<64).flatMap { x in RenderingFixtures.pixel(drawn, width: 128, x: 2 * x, y: 2 * y) } }
        #expect(sampled == golden)
        #expect(renderer.presentation.presented == 2)
        #expect(renderer.presentation.skipped == 1)
        #expect(store.counters.committed == burst.count)
    }

    /// RENDER-02: a flood far larger than the staging budget commits every patch, in order, without exceeding the budget.
    @Test func stagingFloodStaysBoundedAndLosesNoPatch() throws {
        let device = try renderingDevice()
        let budget = 512 * 1024
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()),
                                          stagingBudgetBytes: budget, stagingWaitTimeout: 1)
        let software = SoftwareFramebuffer()
        let size = PixelSize(width: 256, height: 256)
        for sink in [store as FramebufferSink, software] { sink.acceptRevision(1, canvases: ["d1": size], requestedRegions: [:]) }
        var random = RenderingFixtureRandom(seed: 512)
        var peak = 0
        for index in 0..<160 {
            let side = index % 5 == 0 ? 128 : 64 // 64 KiB of staging each (16 KiB rounds up): eight fit the budget
            let rect = PixelRect(x: random.int(0..<(256 - side + 1)), y: random.int(0..<(256 - side + 1)), width: side, height: side)
            let color = (random.byte(), random.byte(), random.byte(), UInt8(255))
            let header = RenderingFixtures.header(rect: rect, canvas: size, sequence: index)
            #expect(store.commit(RenderingFixtures.solidPatch(header, bgra: color, allocate: store.makePatchBuffer)) == .committed)
            #expect(software.commit(RenderingFixtures.solidPatch(header, bgra: color)) == .committed)
            peak = max(peak, store.stagingBytesAllocated)
        }
        #expect(peak <= budget)
        #expect(store.snapshotBGRA(display: "d1")?.1 == software.snapshot(display: "d1")?.1)
        #expect(store.counters.committed == 160)
        #expect(store.counters.failed == 0)
        #expect(store.counters.allocationFailures == 0)
    }

    // MARK: Ordering of overlapping blits

    @Test func overlappingPatchesInOneBatchLandInArrivalOrder() throws {
        let device = try renderingDevice()
        let store = MetalFramebufferStore(device: device, commandQueue: try #require(device.makeCommandQueue()))
        let software = SoftwareFramebuffer()
        let size = PixelSize(width: 256, height: 256)
        for sink in [store as FramebufferSink, software] { sink.acceptRevision(1, canvases: ["d1": size], requestedRegions: [:]) }
        // 40 whole-surface patches (10 MiB) stay inside one batch; every one overwrites the last.
        for index in 0..<40 {
            let header = RenderingFixtures.header(rect: PixelRect(x: 0, y: 0, width: 256, height: 256), canvas: size, sequence: index)
            let color = (UInt8(index), UInt8(255 - index), UInt8(7), UInt8(255))
            #expect(store.commit(RenderingFixtures.solidPatch(header, bgra: color, allocate: store.makePatchBuffer)) == .committed)
            #expect(software.commit(RenderingFixtures.solidPatch(header, bgra: color)) == .committed)
        }
        #expect(store.snapshotBGRA(display: "d1")?.1.prefix(8) == [39, 216, 7, 255, 39, 216, 7, 255])
        // Large random overlaps against the golden model, again within single batches.
        var random = RenderingFixtureRandom(seed: 7)
        for index in 0..<60 {
            let width = random.int(96..<257), height = random.int(96..<257)
            let rect = PixelRect(x: random.int(0..<(256 - width + 1)), y: random.int(0..<(256 - height + 1)), width: width, height: height)
            let color = (random.byte(), random.byte(), random.byte(), UInt8(255))
            let header = RenderingFixtures.header(rect: rect, canvas: size, sequence: 100 + index)
            #expect(store.commit(RenderingFixtures.solidPatch(header, bgra: color, allocate: store.makePatchBuffer)) == .committed)
            #expect(software.commit(RenderingFixtures.solidPatch(header, bgra: color)) == .committed)
        }
        #expect(store.snapshotBGRA(display: "d1")?.1 == software.snapshot(display: "d1")?.1)
        #expect(store.gpuErrorCount == 0)
    }
}
