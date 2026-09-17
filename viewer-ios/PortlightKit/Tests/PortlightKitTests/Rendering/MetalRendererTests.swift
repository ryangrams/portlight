// No `import Foundation` here: with Command Line Tools, Foundation + Testing in one file needs the missing
// `_Testing_Foundation` overlay. Foundation-typed helpers live in RenderingFixtures.swift.
import Metal
import Testing
@testable import PortlightKit

/// Offscreen renders read back from the GPU. Fails, never skips, without a Metal device.
@Suite("MetalRenderer")
struct MetalRendererTests {
    private let letterbox: [UInt8] = [MetalRenderer.letterbox.blue, MetalRenderer.letterbox.green, MetalRenderer.letterbox.red, 255]

    private func makeRenderer() throws -> MetalRenderer {
        let device = try #require(MTLCreateSystemDefaultDevice(), "a Metal device is required")
        return try MetalRenderer(device: device)
    }

    /// A private texture cleared to one color on the renderer's queue (ordered before the draw).
    private func solid(_ renderer: MetalRenderer, _ width: Int, _ height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        commandBuffer.commit()
        return texture
    }

    /// A private texture with explicit BGRA contents, uploaded by blit.
    private func texture(_ renderer: MetalRenderer, width: Int, height: Int, bgra: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let buffer = try #require(renderer.device.makeBuffer(bytes: bgra, length: bgra.count, options: .storageModeShared))
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: width * 4, sourceBytesPerImage: bgra.count,
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        return texture
    }

    private func pixel(_ bytes: [UInt8], width: Int, _ x: Int, _ y: Int) -> [UInt8] {
        RenderingFixtures.pixel(bytes, width: width, x: x, y: y)
    }

    private func quads(_ frames: [(DisplayID, Double, Double)]) -> [RenderScene.Quad] {
        frames.map { RenderScene.Quad(display: $0.0, frame: LogicalRect(x: $0.1, y: $0.2, width: 1920, height: 1080)) }
    }

    @Test func threeDisplayCompactLayoutSamplesTheRightColorsAndLetterbox() throws {
        let renderer = try makeRenderer()
        let textures = ["a": try solid(renderer, 1280, 720, r: 220, g: 30, b: 40),
                        "b": try solid(renderer, 1280, 720, r: 20, g: 200, b: 60),
                        "c": try solid(renderer, 1280, 720, r: 30, g: 40, b: 210)]
        // Fit 5760×1080 points into 600×200 pixels: scale 600/5760, centered vertically (ty = 43.75).
        let scale = 600.0 / 5760
        let scene = RenderScene(transform: ViewportTransform(scale: scale, tx: 0, ty: (200 - 1080 * scale) / 2),
                                drawableSize: PixelSize(width: 600, height: 200), quads: quads([("a", 0, 0), ("b", 1920, 0), ("c", 3840, 0)]))
        let image = try renderer.renderOffscreen(scene: scene, size: PixelSize(width: 600, height: 200), textures: textures)
        #expect(pixel(image, width: 600, 100, 100) == [40, 30, 220, 255])
        #expect(pixel(image, width: 600, 300, 100) == [60, 200, 20, 255])
        #expect(pixel(image, width: 600, 500, 100) == [210, 40, 30, 255])
        #expect(pixel(image, width: 600, 300, 10) == letterbox)
        #expect(pixel(image, width: 600, 300, 190) == letterbox)
    }

    @Test func gapsAndMissingTexturesShowLetterbox() throws {
        let renderer = try makeRenderer()
        let textures = ["a": try solid(renderer, 640, 360, r: 200, g: 0, b: 0), "b": try solid(renderer, 640, 360, r: 0, g: 0, b: 200)]
        // b sits half a display lower; the band under a and above b is a gap. "c" has no texture yet.
        let scale = 0.1
        let scene = RenderScene(transform: ViewportTransform(scale: scale, tx: 0, ty: 0), drawableSize: PixelSize(width: 576, height: 162),
                                quads: quads([("a", 0, 0), ("b", 1920, 540), ("c", 3840, 0)]))
        let image = try renderer.renderOffscreen(scene: scene, size: PixelSize(width: 576, height: 162), textures: textures)
        #expect(pixel(image, width: 576, 96, 50) == [0, 0, 200, 255])
        #expect(pixel(image, width: 576, 288, 120) == [200, 0, 0, 255])
        #expect(pixel(image, width: 576, 96, 140) == letterbox)  // below a
        #expect(pixel(image, width: 576, 288, 20) == letterbox)  // above b
        #expect(pixel(image, width: 576, 480, 50) == letterbox)  // c: no texture
    }

    @Test func mixedDPIDisplaysWithEqualLogicalSizeDrawEqualQuads() throws {
        let renderer = try makeRenderer()
        // A 2× display streams twice the texels of a 1× display with the same 1920×1080-point workspace.
        let textures = ["retina": try solid(renderer, 2560, 1440, r: 255, g: 0, b: 0), "standard": try solid(renderer, 1280, 720, r: 0, g: 255, b: 0)]
        let scale = 400.0 / 3840
        let scene = RenderScene(transform: ViewportTransform(scale: scale, tx: 0, ty: (120 - 1080 * scale) / 2), drawableSize: PixelSize(width: 400, height: 120),
                                quads: quads([("retina", 0, 0), ("standard", 1920, 0)]))
        let image = try renderer.renderOffscreen(scene: scene, size: PixelSize(width: 400, height: 120), textures: textures)
        let row = (0..<400).map { pixel(image, width: 400, $0, 60) }
        let redWidth = row.filter { $0 == [0, 0, 255, 255] }.count
        let greenWidth = row.filter { $0 == [0, 255, 0, 255] }.count
        #expect(redWidth == 200)
        #expect(greenWidth == 200)
        let column = (0..<120).map { pixel(image, width: 400, 100, $0) }.filter { $0 == [0, 0, 255, 255] }.count
        let column2 = (0..<120).map { pixel(image, width: 400, 300, $0) }.filter { $0 == [0, 255, 0, 255] }.count
        #expect(column == column2)
    }

    @Test func dimmingDarkensThePicture() throws {
        let renderer = try makeRenderer()
        let textures = ["a": try solid(renderer, 64, 36, r: 200, g: 150, b: 100)]
        var scene = RenderScene(transform: ViewportTransform(scale: 0.05, tx: 0, ty: 0), drawableSize: PixelSize(width: 96, height: 54),
                                quads: quads([("a", 0, 0)]))
        let bright = pixel(try renderer.renderOffscreen(scene: scene, size: PixelSize(width: 96, height: 54), textures: textures), width: 96, 48, 27)
        scene.dimmed = true
        let dim = pixel(try renderer.renderOffscreen(scene: scene, size: PixelSize(width: 96, height: 54), textures: textures), width: 96, 48, 27)
        #expect(bright == [100, 150, 200, 255])
        for channel in 0..<3 {
            #expect(dim[channel] < bright[channel])
            let scaled: Float = Float(bright[channel]) * MetalRenderer.dimFactor
            let difference: Int = Int(dim[channel]) - Int(scaled.rounded())
            #expect(abs(difference) <= 1)
        }
        #expect(dim[3] == 255)
    }

    @Test func projectionUsesTheTargetTextureSizeNotTheSceneDrawableSize() throws {
        let renderer = try makeRenderer()
        let textures = ["a": try solid(renderer, 100, 100, r: 250, g: 250, b: 0)]
        // The scene still believes the drawable is 100×100 (one frame after a resize); the target is 200×200.
        let scene = RenderScene(transform: ViewportTransform(scale: 1, tx: 50, ty: 50), drawableSize: PixelSize(width: 100, height: 100),
                                quads: [RenderScene.Quad(display: "a", frame: LogicalRect(x: 0, y: 0, width: 100, height: 100))])
        let image = try renderer.renderOffscreen(scene: scene, size: PixelSize(width: 200, height: 200), textures: textures)
        #expect(pixel(image, width: 200, 100, 100) == [0, 250, 250, 255])
        #expect(pixel(image, width: 200, 51, 51) == [0, 250, 250, 255])
        #expect(pixel(image, width: 200, 25, 25) == letterbox)
        #expect(pixel(image, width: 200, 175, 175) == letterbox)
    }

    @Test func magnifiedTexelsStayCrispAndModerateScalesFilterLinearly() throws {
        let renderer = try makeRenderer()
        let textures = ["a": try texture(renderer, width: 2, height: 1, bgra: [0, 0, 0, 255, 255, 255, 255, 255])] // black | white
        let quad = [RenderScene.Quad(display: "a", frame: LogicalRect(x: 0, y: 0, width: 2, height: 1))]
        // 100 drawable pixels per texel: nearest, so the boundary is a hard edge.
        let crisp = try renderer.renderOffscreen(scene: RenderScene(transform: ViewportTransform(scale: 100, tx: 0, ty: 0), drawableSize: PixelSize(width: 200, height: 100), quads: quad),
                                                 size: PixelSize(width: 200, height: 100), textures: textures)
        #expect(pixel(crisp, width: 200, 99, 50) == [0, 0, 0, 255])
        #expect(pixel(crisp, width: 200, 100, 50) == [255, 255, 255, 255])
        // 1.5 pixels per texel: linear, so the middle pixel is an even blend.
        let smooth = try renderer.renderOffscreen(scene: RenderScene(transform: ViewportTransform(scale: 1.5, tx: 0, ty: 0), drawableSize: PixelSize(width: 3, height: 2), quads: quad),
                                                  size: PixelSize(width: 3, height: 2), textures: textures)
        let middle = pixel(smooth, width: 3, 1, 0)
        #expect((120...135).contains(middle[0]) && middle[0] == middle[1] && middle[1] == middle[2])
    }

    @Test func cursorKeepsAFixedOnScreenSizeAtAnyZoom() throws {
        let renderer = try makeRenderer()
        renderer.cursorHeightInPixels = 38
        let textures = ["a": try solid(renderer, 64, 64, r: 128, g: 128, b: 128)]
        let size = PixelSize(width: 120, height: 120)
        var windows: [[[UInt8]]] = []
        for scale in [0.5, 2.0] {
            // The whole target is display; the cursor tip lands on drawable pixel (40, 30) at both zooms.
            let frame = LogicalRect(x: 0, y: 0, width: 120 / scale, height: 120 / scale)
            var scene = RenderScene(transform: ViewportTransform(scale: scale, tx: 0, ty: 0), drawableSize: size,
                                    quads: [RenderScene.Quad(display: "a", frame: frame)], cursor: LogicalPoint(x: 40 / scale, y: 30 / scale))
            let image = try renderer.renderOffscreen(scene: scene, size: size, textures: textures)
            // Inside the arrow body (2, 8 arrow units below-right of the tip) is dark; right of the diagonal and below the arrow is display.
            #expect(pixel(image, width: 120, 40 + 4, 30 + 17)[0] < 40)
            #expect(pixel(image, width: 120, 40 + 15, 30 + 4) == [128, 128, 128, 255])
            #expect(pixel(image, width: 120, 40, 30 + 45) == [128, 128, 128, 255])
            windows.append((0..<48).flatMap { dy in (0..<32).map { dx in pixel(image, width: 120, 36 + dx, 26 + dy) } })
            scene.cursor = nil
            let bare = try renderer.renderOffscreen(scene: scene, size: size, textures: textures)
            #expect(pixel(bare, width: 120, 40 + 4, 30 + 17) == [128, 128, 128, 255])
        }
        #expect(windows[0] == windows[1])
    }

    @Test func storePixelsReachTheScreenAndUnchangedScenesSkipPresentation() throws {
        let renderer = try makeRenderer()
        #expect(renderer.framebuffers.commandQueue === renderer.commandQueue)
        let store = renderer.framebuffers
        let canvas = PixelSize(width: 64, height: 48)
        store.acceptRevision(1, canvases: ["d1": canvas], requestedRegions: [:])
        let png = HostTileEncoder.rgbPNG(width: 64, height: 48) { _, _ in (10, 200, 30) }
        let header = RenderingFixtures.header(rect: PixelRect(x: 0, y: 0, width: 64, height: 48), canvas: canvas)
        #expect(store.commit(try ImageTileDecoder.decode(header: header, payload: png, allocate: store.makePatchBuffer)) == .committed)

        let scene = RenderScene(transform: .identity, drawableSize: canvas,
                                quads: [RenderScene.Quad(display: "d1", frame: LogicalRect(x: 0, y: 0, width: 64, height: 48))])
        let image = try renderer.renderOffscreen(scene: scene, size: canvas)
        #expect(pixel(image, width: 64, 32, 24) == [30, 200, 10, 255])

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 48, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget]
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        func tick(_ scene: RenderScene) throws -> Bool {
            let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
            let drew = renderer.encodeIfNeeded(scene: scene, into: target, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return drew
        }
        #expect(renderer.presentation.needsPresentation(scene: scene))
        #expect(try tick(scene))
        #expect(!renderer.presentation.needsPresentation(scene: scene))
        #expect(try !tick(scene))
        #expect(try !tick(scene))
        let generation = renderer.presentation.dirtyGeneration
        #expect(store.commit(RenderingFixtures.solidPatch(RenderingFixtures.header(rect: PixelRect(x: 0, y: 0, width: 8, height: 8), canvas: canvas),
                                                          bgra: (1, 1, 1, 255), allocate: store.makePatchBuffer)) == .committed)
        #expect(renderer.presentation.dirtyGeneration > generation)
        #expect(renderer.presentation.needsPresentation(scene: scene))
        #expect(try tick(scene))
        var moved = scene
        moved.transform = ViewportTransform(scale: 1, tx: 3, ty: 0)
        #expect(try tick(moved))
        renderer.presentation.invalidate()
        #expect(try tick(moved))
        #expect(renderer.presentation.presented == 4)
        #expect(renderer.presentation.skipped == 2)
    }
}
