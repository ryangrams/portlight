import Foundation
import Metal

/// GPU framebuffer: one persistent `.bgra8Unorm`, `.private` texture per display, updated only by blits
/// from pooled staging buffers on the command queue shared with rendering.
///
/// Why this shape: the CPU never writes a texture the GPU may be sampling. Decoders fill shared
/// `MTLBuffer`s; `commit` encodes a blit into the texture on the one `MTLCommandQueue` the renderer also
/// uses, so queue order (plus Metal's hazard tracking) puts every draw after the blits it can observe.
/// Consecutive commits are batched into one command buffer, which is committed before anyone can observe
/// the textures (`texturesForRendering`, snapshots, revisions) or when the batch or pool fills up.
/// Staging buffers return to the pool from the command buffer's completion handler.
///
/// Textures outlive connections (the frozen frame) until `removeAll`.
public final class MetalFramebufferStore: FramebufferSink, @unchecked Sendable {
    public static let defaultStagingBudget = 96 * 1024 * 1024
    /// Largest texture side accepted (Apple GPUs from A11 support 16384).
    static let maximumTextureSide = 16_384

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue

    // Sendable invariant: `ledger`, `batch` and the Metal encoders they reference are only touched while `lock`
    // is held. Metal devices/queues/command buffers are thread-safe for create/commit. Completion handlers never
    // take `lock` (a thread waiting on the GPU may hold it), only `pool` and `gpuErrorCount`'s own lock.
    private let lock = NSLock()
    private var ledger = SurfaceLedger<MTLTexture>()
    private var batch: BlitBatch?
    private let pool: StagingBufferPool
    private let stagingWaitTimeout: TimeInterval
    private let gpuErrors = GPUErrorCounter()

    private static let maximumBatchPatches = 64
    private static let maximumBatchBytes = 32 * 1024 * 1024

    /// - Parameters:
    ///   - commandQueue: the queue the renderer draws on (see `MetalRenderer.framebuffers`).
    ///   - stagingBudgetBytes: total bytes of staging buffers, in use or pooled.
    public convenience init(device: MTLDevice, commandQueue: MTLCommandQueue, stagingBudgetBytes: Int = MetalFramebufferStore.defaultStagingBudget) {
        self.init(device: device, commandQueue: commandQueue, stagingBudgetBytes: stagingBudgetBytes, stagingWaitTimeout: 2)
    }

    /// `stagingWaitTimeout` is injectable so tests can exercise exhaustion without waiting two seconds.
    init(device: MTLDevice, commandQueue: MTLCommandQueue, stagingBudgetBytes: Int, stagingWaitTimeout: TimeInterval) {
        self.device = device
        self.commandQueue = commandQueue
        self.stagingWaitTimeout = stagingWaitTimeout
        pool = StagingBufferPool(device: device, budget: stagingBudgetBytes)
    }

    deinit {
        lock.withLock { flushLocked() }
    }

    // MARK: FramebufferSink

    public func acceptRevision(_ revision: Int, canvases: [DisplayID: PixelSize], requestedRegions: [DisplayID: NormalizedRect]) {
        lock.withLock {
            flushLocked()
            var created: [MTLTexture] = []
            ledger.accept(revision: revision, canvases: canvases, requestedRegions: requestedRegions) { size in
                guard let texture = makeTexture(size) else { return nil }
                created.append(texture)
                return texture
            }
            clearLocked(created)
        }
    }

    /// Hands out a pooled staging buffer. Called on the decode queue: when the budget is exhausted it waits
    /// (up to two seconds) for GPU work to return buffers, then gives up with nil.
    public func makePatchBuffer(byteCount: Int) -> PatchBuffer? {
        if let buffer = pool.checkout(byteCount: byteCount, deadline: nil) { return buffer }
        guard byteCount > 0, byteCount <= pool.budget else { return nil }
        // Our own open batch may be what holds the budget: submit it so its buffers can come back.
        lock.withLock { flushLocked() }
        return pool.checkout(byteCount: byteCount, deadline: Date(timeIntervalSinceNow: stagingWaitTimeout))
    }

    public func commit(_ patch: DecodedPatch) -> PatchCommitResult {
        let header = patch.header
        // Stale and unplaceable patches are settled before any staging copy; the placement is re-checked under the lock below.
        let settled: PatchCommitResult? = lock.withLock {
            switch ledger.placement(for: header) {
            case .stale:
                ledger.recordStale()
                return .stale
            case .failed:
                ledger.recordFailure(header)
                return .failed
            case .write:
                guard PatchRows.isWellFormed(patch) else {
                    ledger.recordFailure(header)
                    return .failed
                }
                return nil
            }
        }
        if let settled { return settled }
        // Blits read our own staging buffers directly; any other PatchBuffer is first copied into one (outside the lock).
        let source: StagingBuffer, sourceRowBytes: Int
        if let own = patch.buffer as? StagingBuffer, own.pool === pool {
            source = own
            sourceRowBytes = patch.bytesPerRow
        } else {
            let rowBytes = header.rect.width * 4
            guard let copy = makePatchBuffer(byteCount: rowBytes * header.rect.height) as? StagingBuffer else {
                return lock.withLock { failLocked(header, allocationFailed: true) }
            }
            for row in 0..<header.rect.height {
                (copy.contents + row * rowBytes).copyMemory(from: patch.buffer.contents + row * patch.bytesPerRow, byteCount: rowBytes)
            }
            source = copy
            sourceRowBytes = rowBytes
        }
        return lock.withLock {
            let target: SurfaceLedger<MTLTexture>.Target
            switch ledger.placement(for: header) {
            case .stale:
                ledger.recordStale()
                return .stale
            case .failed:
                ledger.recordFailure(header)
                return .failed
            case .write(let placed):
                target = placed
            }
            guard let texture = ledger.surface(display: header.display, target: target) else { return failLocked(header, allocationFailed: false) }
            guard let encoder = openBatchLocked() else { return failLocked(header, allocationFailed: true) }
            let rect = header.rect
            encoder.copy(from: source.buffer, sourceOffset: 0, sourceBytesPerRow: sourceRowBytes,
                         sourceBytesPerImage: sourceRowBytes * rect.height, sourceSize: MTLSize(width: rect.width, height: rect.height, depth: 1),
                         to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: rect.x, y: rect.y, z: 0))
            let bytes = rect.pixelCount * 4
            batch?.retain(source, bytes: bytes)
            ledger.didPaint(rect, display: header.display, target: target, bytes: bytes)
            if let batch, batch.patches >= Self.maximumBatchPatches || batch.bytes >= Self.maximumBatchBytes { flushLocked() }
            return .committed
        }
    }

    public func hasValidPixels(display: DisplayID, x: Double, y: Double) -> Bool {
        lock.withLock { ledger.hasValidPixels(display: display, x: x, y: y) }
    }

    public func removeAll() {
        lock.withLock {
            flushLocked()
            ledger.removeAll()
        }
        pool.trim()
    }

    // MARK: Rendering and inspection

    /// The shown texture of every display. Submits pending blits first, so a draw encoded after this call on
    /// the shared queue sees every committed patch.
    public func texturesForRendering() -> [DisplayID: MTLTexture] {
        renderState().textures
    }

    /// Textures plus the content generation they correspond to, read atomically.
    func renderState() -> (textures: [DisplayID: MTLTexture], generation: UInt64) {
        lock.withLock {
            flushLocked()
            return (ledger.shownSurfaces, ledger.contentGeneration)
        }
    }

    /// Bumped by commits, swaps, revisions and removal: when unchanged, redrawing an unchanged scene is pointless.
    public var contentGeneration: UInt64 { lock.withLock { ledger.contentGeneration } }

    public var counters: FramebufferCounters { lock.withLock { ledger.counters } }

    /// Command buffers that finished with an error (a device fault; the session should treat pixels as suspect).
    public var gpuErrorCount: Int { gpuErrors.value }

    /// Bytes of staging buffers currently allocated (in use or pooled); never above the budget.
    public var stagingBytesAllocated: Int { pool.allocatedBytes }

    /// The staging budget. A patch larger than this can never be staged, so a canvas whose full-area keyframe
    /// (`width × height × 4`) exceeds it can only be painted through smaller regions.
    public var stagingBudgetBytes: Int { pool.budget }

    /// Releases pooled staging buffers that are not in use (memory warning, background) without touching the
    /// textures, so a frozen frame survives. Buffers still held by decoders or in-flight blits return later.
    public func trimStaging() {
        pool.trim()
    }

    public func coverage(display: DisplayID) -> CoverageGrid? {
        lock.withLock { ledger.shownSlot(display)?.coverage }
    }

    public func hasPendingReplacement(display: DisplayID) -> Bool {
        lock.withLock { ledger.replacementSlot(display) != nil }
    }

    /// Submits any batched blits now.
    public func flush() {
        lock.withLock { flushLocked() }
    }

    /// Reads the shown texture back as tightly packed BGRA rows (tests and diagnostics; waits for the GPU).
    public func snapshotBGRA(display: DisplayID) -> (PixelSize, [UInt8])? {
        let pending: (PixelSize, MTLCommandBuffer, MTLBuffer)? = lock.withLock {
            flushLocked()
            guard let texture = ledger.shownSurfaces[display] else { return nil }
            let size = PixelSize(width: texture.width, height: texture.height)
            let rowBytes = size.width * 4
            guard let buffer = device.makeBuffer(length: rowBytes * size.height, options: .storageModeShared),
                  let commandBuffer = commandQueue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: size.width, height: size.height, depth: 1), to: buffer,
                      destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * size.height)
            blit.endEncoding()
            commandBuffer.commit()
            return (size, commandBuffer, buffer)
        }
        guard let (size, commandBuffer, buffer) = pending else { return nil }
        commandBuffer.waitUntilCompleted() // outside the lock: completion handlers must never wait on it
        guard commandBuffer.status == .completed else { return nil }
        let bytes = UnsafeRawBufferPointer(start: buffer.contents(), count: size.pixelCount * 4)
        return (size, [UInt8](bytes))
    }

    // MARK: Private (call with `lock` held)

    private func makeTexture(_ size: PixelSize) -> MTLTexture? {
        guard (1...Self.maximumTextureSide).contains(size.width), (1...Self.maximumTextureSide).contains(size.height) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
        descriptor.storageMode = .private
        // `.renderTarget` only so a new surface can be cleared to opaque black on the GPU (private memory starts undefined).
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "Portlight display \(size)"
        return texture
    }

    private func clearLocked(_ textures: [MTLTexture]) {
        guard !textures.isEmpty, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        for texture in textures {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        observeErrors(commandBuffer)
        commandBuffer.commit()
    }

    /// A patch that matched the accepted state could not be applied. If the revision moved on meanwhile it is only stale.
    private func failLocked(_ header: FrameHeader, allocationFailed: Bool) -> PatchCommitResult {
        if ledger.placement(for: header) == .stale {
            ledger.recordStale()
            return .stale
        }
        if allocationFailed { ledger.counters.allocationFailures += 1 }
        ledger.recordFailure(header)
        return .failed
    }

    private func openBatchLocked() -> MTLBlitCommandEncoder? {
        if let batch { return batch.encoder }
        guard let commandBuffer = commandQueue.makeCommandBuffer(), let encoder = commandBuffer.makeBlitCommandEncoder() else { return nil }
        commandBuffer.label = "Portlight patches"
        batch = BlitBatch(commandBuffer: commandBuffer, encoder: encoder)
        return encoder
    }

    private func flushLocked() {
        guard let batch else { return }
        self.batch = nil
        batch.encoder.endEncoding()
        let staging = batch.staging
        observeErrors(batch.commandBuffer)
        // Holding the staging buffers until the GPU has read them; releasing them returns them to the pool.
        batch.commandBuffer.addCompletedHandler { _ in withExtendedLifetime(staging) {} }
        batch.commandBuffer.commit()
    }

    private func observeErrors(_ commandBuffer: MTLCommandBuffer) {
        let errors = gpuErrors
        commandBuffer.addCompletedHandler { buffer in
            if buffer.status == .error { errors.increment() }
        }
    }
}

/// One open command buffer of blits. Only used under `MetalFramebufferStore.lock`.
private struct BlitBatch {
    let commandBuffer: MTLCommandBuffer
    let encoder: MTLBlitCommandEncoder
    private(set) var staging: [StagingBuffer] = []
    private(set) var patches = 0
    private(set) var bytes = 0

    init(commandBuffer: MTLCommandBuffer, encoder: MTLBlitCommandEncoder) {
        self.commandBuffer = commandBuffer
        self.encoder = encoder
    }

    mutating func retain(_ buffer: StagingBuffer, bytes count: Int) {
        staging.append(buffer)
        patches += 1
        bytes += count
    }
}

private final class GPUErrorCounter: @unchecked Sendable {
    // Sendable invariant: `count` is only accessed under `lock`.
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A pooled shared-memory staging buffer. Returns itself to the pool when the last reference goes away:
/// after the GPU blit completes, or when a decode fails or a patch is discarded before commit.
final class StagingBuffer: PatchBuffer, @unchecked Sendable {
    // Sendable invariant: one writer at a time. The decoder writes `contents` before commit; afterwards only the
    // GPU reads it, and the pool hands the memory out again only after this wrapper is deallocated.
    let buffer: MTLBuffer
    let byteCount: Int
    let pool: StagingBufferPool

    init(buffer: MTLBuffer, byteCount: Int, pool: StagingBufferPool) {
        self.buffer = buffer
        self.byteCount = byteCount
        self.pool = pool
    }

    var contents: UnsafeMutableRawPointer { buffer.contents() }

    deinit { pool.recycle(buffer) }
}

/// Bounded set of shared `MTLBuffer`s. `allocatedBytes` (in use + pooled) never exceeds `budget`.
final class StagingBufferPool: @unchecked Sendable {
    // Sendable invariant: `free` and `allocated` are only accessed with `condition` locked. No `StagingBuffer`
    // wrapper is ever released while it is locked (its deinit locks it again).
    let budget: Int
    private let device: MTLDevice
    private let condition = NSCondition()
    private var free: [MTLBuffer] = []
    private var allocated = 0
    private static let granularity = 64 * 1024

    init(device: MTLDevice, budget: Int) {
        self.device = device
        self.budget = max(0, budget)
    }

    var allocatedBytes: Int {
        condition.lock(); defer { condition.unlock() }
        return allocated
    }

    /// A buffer of at least `byteCount` bytes, waiting until `deadline` for returns when the budget is in use.
    func checkout(byteCount: Int, deadline: Date?) -> StagingBuffer? {
        guard byteCount > 0, byteCount <= budget else { return nil }
        let rounded = (byteCount + Self.granularity - 1) / Self.granularity * Self.granularity
        let length = max(byteCount, min(rounded, budget))
        condition.lock(); defer { condition.unlock() }
        while true {
            if let buffer = attemptLocked(byteCount: byteCount, length: length) {
                return StagingBuffer(buffer: buffer, byteCount: byteCount, pool: self)
            }
            guard let deadline, Date() < deadline else { return nil }
            _ = condition.wait(until: deadline)
        }
    }

    func recycle(_ buffer: MTLBuffer) {
        condition.lock()
        free.append(buffer)
        condition.broadcast()
        condition.unlock()
    }

    /// Releases every pooled (not in-use) buffer.
    func trim() {
        condition.lock()
        allocated -= free.reduce(0) { $0 + $1.length }
        free.removeAll()
        condition.unlock()
    }

    private func attemptLocked(byteCount: Int, length: Int) -> MTLBuffer? {
        let fitting = free.indices.filter { free[$0].length >= byteCount }.min { free[$0].length < free[$1].length }
        // Reuse a pooled buffer unless it is much larger than needed and there is room for a right-sized one.
        if let index = fitting, free[index].length <= 2 * length || allocated + length > budget {
            return free.remove(at: index)
        }
        // Drop pooled buffers that are too small for this request until a new one fits.
        while allocated + length > budget, let index = free.indices.first(where: { free[$0].length < byteCount }) {
            allocated -= free.remove(at: index).length
        }
        guard allocated + length <= budget, let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        buffer.label = "Portlight staging"
        allocated += length
        return buffer
    }
}
