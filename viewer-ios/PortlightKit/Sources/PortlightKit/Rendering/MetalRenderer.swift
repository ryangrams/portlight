import Foundation
import CoreGraphics
import Metal
import simd

/// Draws a `RenderScene`: every selected display's texture as a quad placed by host logical geometry,
/// a letterbox around them, an optional dim for Paused/Reconnecting, and a fixed-size local cursor.
///
/// It owns the `MTLDevice` and the single `MTLCommandQueue` shared with `framebuffers`, so texture
/// blits and draws are ordered by the queue. The viewport transform is only ever a parameter
/// (`scene.transform`); nothing on the frame path can reach it.
public final class MetalRenderer: @unchecked Sendable {
    /// Letterbox and gaps between displays: a dark neutral, as exact bytes.
    public static let letterbox: (red: UInt8, green: UInt8, blue: UInt8) = (18, 18, 20)
    /// Brightness multiplier applied to the whole picture when `scene.dimmed`.
    public static let dimFactor: Float = 0.4
    /// Filtering switches to nearest once one texel spans at least this many drawable pixels (keeps text crisp).
    public static let nearestFilterThreshold = 2.0

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    /// The framebuffer sink the session feeds; it shares `commandQueue`.
    public let framebuffers: MetalFramebufferStore
    /// Presentation bookkeeping for the display-link path (`encodeIfNeeded`).
    public let presentation: PresentationState

    // Sendable invariant: `pipelines` and `cursorHeight` are only accessed under `lock`; every other stored
    // property is immutable after init, and Metal pipeline/sampler/texture objects are thread-safe to use.
    private let lock = NSLock()
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var cursorHeight = 36.0
    private let vertexFunction: MTLFunction
    private let fragmentFunction: MTLFunction
    private let linearSampler: MTLSamplerState
    private let nearestSampler: MTLSamplerState
    private let cursor: CursorImage

    /// Uses the system default device.
    public convenience init(stagingBudgetBytes: Int = MetalFramebufferStore.defaultStagingBudget) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderingError.metalUnavailable("no Metal device") }
        try self.init(device: device, stagingBudgetBytes: stagingBudgetBytes)
    }

    public init(device: MTLDevice, stagingBudgetBytes: Int = MetalFramebufferStore.defaultStagingBudget) throws {
        guard let queue = device.makeCommandQueue() else { throw RenderingError.metalUnavailable("no command queue") }
        queue.label = "Portlight render"
        self.device = device
        commandQueue = queue
        // Shaders compile at runtime from source: no .metal files, so `swift test` works without the Metal toolchain.
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Self.shaderSource, options: nil) } catch {
            throw RenderingError.metalUnavailable("shader compilation failed: \(error.localizedDescription)")
        }
        guard let vertex = library.makeFunction(name: "portlight_quad_vertex"),
              let fragment = library.makeFunction(name: "portlight_quad_fragment"),
              let linear = Self.makeSampler(device, filter: .linear),
              let nearest = Self.makeSampler(device, filter: .nearest) else {
            throw RenderingError.metalUnavailable("shader functions or samplers unavailable")
        }
        vertexFunction = vertex
        fragmentFunction = fragment
        linearSampler = linear
        nearestSampler = nearest
        cursor = try CursorImage(device: device, queue: queue)
        let store = MetalFramebufferStore(device: device, commandQueue: queue, stagingBudgetBytes: stagingBudgetBytes)
        framebuffers = store
        presentation = PresentationState { store.contentGeneration }
        guard pipeline(for: .bgra8Unorm) != nil else { throw RenderingError.metalUnavailable("render pipeline could not be created") }
    }

    /// On-screen cursor height in drawable pixels; set it from the view's content scale (e.g. 20 pt × scale).
    public var cursorHeightInPixels: Double {
        get { lock.withLock { cursorHeight } }
        set { lock.withLock { cursorHeight = newValue.isFinite ? max(1, newValue) : cursorHeight } }
    }

    // MARK: Drawing

    /// Encodes one presentation of `scene` into `target`. Projection uses the target texture's own size, never a
    /// layer's `drawableSize` (they disagree for a frame after a resize). Displays without a texture are left as letterbox.
    public func encode(scene: RenderScene, textures: [DisplayID: MTLTexture], into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard target.width > 0, target.height > 0, let pipeline = pipeline(for: target.pixelFormat) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(Self.letterbox.red) / 255, green: Double(Self.letterbox.green) / 255,
                                                            blue: Double(Self.letterbox.blue) / 255, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        encoder.label = "Portlight scene"
        encoder.setRenderPipelineState(pipeline)
        let transform = scene.transform
        guard transform.scale.isFinite, transform.scale > 0, transform.tx.isFinite, transform.ty.isFinite else { return }
        let targetSize = SIMD2<Double>(Double(target.width), Double(target.height))
        let dim: Float = scene.dimmed ? Self.dimFactor : 1

        for quad in scene.quads {
            guard let texture = textures[quad.display], texture.width > 0, texture.height > 0, !quad.frame.isEmpty else { continue }
            let origin = transform.toDrawable(quad.frame.origin)
            let rect = (x: origin.x, y: origin.y, width: quad.frame.width * transform.scale, height: quad.frame.height * transform.scale)
            guard Self.isVisible(rect, in: targetSize) else { continue }
            let pixelsPerTexel = min(rect.width / Double(texture.width), rect.height / Double(texture.height))
            let magnified = pixelsPerTexel >= Self.nearestFilterThreshold
            // Strong minification (Fit on a phone): four bilinear taps over the pixel footprint instead of one, to stop text shimmering.
            let taps: Float = pixelsPerTexel < 1 / 1.5 ? 2 : 1
            let parameters = SIMD4<Float>(dim, taps, Float(0.25 / rect.width), Float(0.25 / rect.height))
            drawQuad(encoder, rect: rect, target: targetSize, texture: texture, sampler: magnified ? nearestSampler : linearSampler, parameters: parameters)
        }

        if let point = scene.cursor, point.x.isFinite, point.y.isFinite {
            let tip = transform.toDrawable(point)
            let height = cursorHeightInPixels
            let width = height * cursor.aspect
            let rect = (x: tip.x - cursor.hotspot.x * width, y: tip.y - cursor.hotspot.y * height, width: width, height: height)
            if Self.isVisible(rect, in: targetSize) {
                drawQuad(encoder, rect: rect, target: targetSize, texture: cursor.texture, sampler: linearSampler,
                         parameters: SIMD4<Float>(dim, 1, 0, 0))
            }
        }
    }

    /// The display-link path: encodes only when the scene, the target size or the framebuffer content changed
    /// since the last presentation; otherwise counts a skip and returns false (do not present the drawable).
    @discardableResult
    public func encodeIfNeeded(scene: RenderScene, into target: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        let state = framebuffers.renderState()
        let key = PresentationState.Key(scene: scene, generation: state.generation,
                                        targetSize: PixelSize(width: target.width, height: target.height), cursorHeight: cursorHeightInPixels)
        guard presentation.admit(key) else { return false }
        encode(scene: scene, textures: state.textures, into: target, commandBuffer: commandBuffer)
        return true
    }

    /// Renders into an offscreen `size` texture and returns tightly packed BGRA rows (tests and diagnostics).
    /// Uses `framebuffers`' shown textures unless `textures` is given. Waits for the GPU.
    public func renderOffscreen(scene: RenderScene, size: PixelSize, textures: [DisplayID: MTLTexture]? = nil) throws -> [UInt8] {
        guard (1...MetalFramebufferStore.maximumTextureSide).contains(size.width),
              (1...MetalFramebufferStore.maximumTextureSide).contains(size.height) else {
            throw RenderingError.metalUnavailable("offscreen size \(size) is out of range")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        let rowBytes = size.width * 4
        guard let target = device.makeTexture(descriptor: descriptor),
              let readback = device.makeBuffer(length: rowBytes * size.height, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RenderingError.metalUnavailable("offscreen resources could not be created")
        }
        encode(scene: scene, textures: textures ?? framebuffers.texturesForRendering(), into: target, commandBuffer: commandBuffer)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw RenderingError.metalUnavailable("no blit encoder") }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size.width, height: size.height, depth: 1), to: readback,
                  destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * size.height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw RenderingError.gpuFailure(commandBuffer.error?.localizedDescription ?? "status \(commandBuffer.status.rawValue)")
        }
        return [UInt8](UnsafeRawBufferPointer(start: readback.contents(), count: rowBytes * size.height))
    }

    // MARK: Geometry

    /// Unit quad (u, v ∈ [0, 1], also the texture coordinates) → clip space for a rectangle in drawable pixels, y down.
    /// The y flip lives in the projection, so textures keep their top-left origin.
    // Adapted from URC Packages/URCRender/Sources/URCRender/Render/ViewportTransform.swift `textureToClip` (MIT, Copyright (c) 2026 Ryan Grams).
    static func unitQuadToClip(x: Double, y: Double, width: Double, height: Double, target: SIMD2<Double>) -> simd_float4x4 {
        simd_float4x4(SIMD4<Float>(Float(2 * width / target.x), 0, 0, 0),
                      SIMD4<Float>(0, Float(-2 * height / target.y), 0, 0),
                      SIMD4<Float>(0, 0, 1, 0),
                      SIMD4<Float>(Float(2 * x / target.x - 1), Float(1 - 2 * y / target.y), 0, 1))
    }

    private static func isVisible(_ rect: (x: Double, y: Double, width: Double, height: Double), in target: SIMD2<Double>) -> Bool {
        [rect.x, rect.y, rect.width, rect.height].allSatisfy { $0.isFinite } && rect.width > 0 && rect.height > 0
            && rect.x < target.x && rect.y < target.y && rect.x + rect.width > 0 && rect.y + rect.height > 0
    }

    private func drawQuad(_ encoder: MTLRenderCommandEncoder, rect: (x: Double, y: Double, width: Double, height: Double), target: SIMD2<Double>,
                          texture: MTLTexture, sampler: MTLSamplerState, parameters: SIMD4<Float>) {
        var matrix = Self.unitQuadToClip(x: rect.x, y: rect.y, width: rect.width, height: rect.height, target: target)
        var parameters = parameters
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 0)
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: Pipeline

    private func pipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        lock.withLock {
            if let cached = pipelines[format] { return cached }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Portlight quad"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            // Premultiplied "over": display quads are opaque (alpha 1), the cursor has soft edges.
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            let state = try? device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[format] = state
            return state
        }
    }

    private static func makeSampler(_ device: MTLDevice, filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: descriptor)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadOut {
        float4 position [[position]];
        float2 uv;
    };

    // Four vertices of a triangle strip over the unit square; the matrix places it in clip space.
    vertex QuadOut portlight_quad_vertex(uint vid [[vertex_id]], constant float4x4 &unitToClip [[buffer(0)]]) {
        float2 uv = float2(float(vid & 1u), float(vid >> 1u));
        QuadOut out;
        out.position = unitToClip * float4(uv, 0.0, 1.0);
        out.uv = uv;
        return out;
    }

    // parameters: x = dim, y = taps (1, or 2 for a 2×2 footprint), zw = a quarter drawable pixel in texture coordinates.
    fragment float4 portlight_quad_fragment(QuadOut in [[stage_in]],
                                            texture2d<float> image [[texture(0)]],
                                            sampler imageSampler [[sampler(0)]],
                                            constant float4 &parameters [[buffer(0)]]) {
        float4 color;
        if (parameters.y > 1.5) {
            float2 d = parameters.zw;
            color = 0.25 * (image.sample(imageSampler, in.uv + float2(-d.x, -d.y)) + image.sample(imageSampler, in.uv + float2(d.x, -d.y))
                          + image.sample(imageSampler, in.uv + float2(-d.x, d.y)) + image.sample(imageSampler, in.uv + float2(d.x, d.y)));
        } else {
            color = image.sample(imageSampler, in.uv);
        }
        return float4(color.rgb * parameters.x, color.a); // premultiplied: dimming scales color, not coverage
    }
    """
}

/// Decides whether a display-link tick needs a draw. Only a changed scene (transform, layout, cursor, dimming),
/// drawable size or framebuffer content generation earns one; otherwise the layer keeps its last drawable.
public final class PresentationState: @unchecked Sendable {
    struct Key: Equatable {
        var scene: RenderScene
        var generation: UInt64
        var targetSize: PixelSize
        var cursorHeight: Double
    }

    // Sendable invariant: `last`, `presentedCount` and `skippedCount` are only accessed under `lock`.
    private let lock = NSLock()
    private let generation: @Sendable () -> UInt64
    private var last: Key?
    private var presentedCount = 0
    private var skippedCount = 0

    init(generation: @escaping @Sendable () -> UInt64) {
        self.generation = generation
    }

    /// The framebuffer content generation (bumped by commits, swaps, revisions and removal).
    public var dirtyGeneration: UInt64 { generation() }

    public var presented: Int { lock.withLock { presentedCount } }
    public var skipped: Int { lock.withLock { skippedCount } }

    /// True when `scene` or the framebuffer content differs from the last presentation.
    public func needsPresentation(scene: RenderScene) -> Bool {
        let current = generation()
        return lock.withLock {
            guard let last else { return true }
            return last.scene != scene || last.generation != current
        }
    }

    /// Forces the next tick to draw (e.g. a new layer or a return to the foreground).
    public func invalidate() {
        lock.withLock { last = nil }
    }

    /// Records one tick: true (presented) when `key` differs from the last presentation, false (skipped) otherwise.
    func admit(_ key: Key) -> Bool {
        lock.withLock {
            if key == last {
                skippedCount += 1
                return false
            }
            last = key
            presentedCount += 1
            return true
        }
    }
}

/// The local cursor: an arrow drawn once with CoreGraphics into a private texture.
private struct CursorImage {
    let texture: MTLTexture
    /// Width / height of the bitmap.
    let aspect: Double
    /// Arrow tip as a fraction of the bitmap size (the point that sits on `scene.cursor`).
    let hotspot: (x: Double, y: Double)

    private static let unitsWide = 13.0, unitsHigh = 19.0, pixelsPerUnit = 4.0

    init(device: MTLDevice, queue: MTLCommandQueue) throws {
        let width = Int(Self.unitsWide * Self.pixelsPerUnit), height = Int(Self.unitsHigh * Self.pixelsPerUnit)
        let rowBytes = width * 4
        guard let staging = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: staging.contents(), width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw RenderingError.metalUnavailable("cursor bitmap could not be created")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // Draw in y-down units so memory row 0 is the top of the arrow.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(Self.pixelsPerUnit), y: -CGFloat(Self.pixelsPerUnit))
        let arrow: [CGPoint] = [(1, 1), (1, 16.5), (4.8, 13), (7.4, 18.6), (9.6, 17.6), (7, 12.2), (12, 12)].map { CGPoint(x: $0.0, y: $0.1) }
        context.addLines(between: arrow)
        context.closePath()
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.setLineWidth(1.1)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw RenderingError.metalUnavailable("cursor texture could not be created")
        }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted() // once, at renderer creation
        guard commandBuffer.status == .completed else { throw RenderingError.gpuFailure("cursor upload failed") }
        texture.label = "Portlight cursor"
        self.texture = texture
        aspect = Self.unitsWide / Self.unitsHigh
        hotspot = (1 / Self.unitsWide, 1 / Self.unitsHigh)
    }
}
