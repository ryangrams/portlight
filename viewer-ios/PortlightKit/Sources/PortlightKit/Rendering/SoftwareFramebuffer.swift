import Foundation

/// Heap memory for one decoded patch (the software framebuffer and tests).
public final class HeapPatchBuffer: PatchBuffer, @unchecked Sendable {
    // Sendable invariant: one owner at a time. The decoder fills `contents` before the patch is handed to
    // `commit`, nothing writes it afterwards, and the memory is freed only in deinit.
    public let contents: UnsafeMutableRawPointer
    public let byteCount: Int

    public init?(byteCount: Int) {
        guard byteCount > 0 else { return nil }
        contents = .allocate(byteCount: byteCount, alignment: 16)
        self.byteCount = byteCount
    }

    deinit { contents.deallocate() }
}

/// CPU framebuffer with exactly the revision, coverage and swap rules of `MetalFramebufferStore`
/// (both use `SurfaceLedger`). It is the golden model the session tests compare against, and a
/// working sink wherever no GPU is wanted.
public final class SoftwareFramebuffer: FramebufferSink, @unchecked Sendable {
    // Sendable invariant: `ledger` (and the surfaces it references) is only touched while `lock` is held.
    private let lock = NSLock()
    private var ledger = SurfaceLedger<SoftwareSurface>()
    private let patchByteLimit: Int

    /// - Parameter patchByteLimit: largest staging buffer handed out; larger requests fail like an exhausted budget.
    public init(patchByteLimit: Int = 64 * 1024 * 1024) {
        self.patchByteLimit = patchByteLimit
    }

    public func acceptRevision(_ revision: Int, canvases: [DisplayID: PixelSize], requestedRegions: [DisplayID: NormalizedRect]) {
        lock.withLock {
            ledger.accept(revision: revision, canvases: canvases, requestedRegions: requestedRegions) { SoftwareSurface(size: $0) }
        }
    }

    public func makePatchBuffer(byteCount: Int) -> PatchBuffer? {
        guard byteCount > 0, byteCount <= patchByteLimit else { return nil }
        return HeapPatchBuffer(byteCount: byteCount)
    }

    public func commit(_ patch: DecodedPatch) -> PatchCommitResult {
        lock.withLock {
            let header = patch.header
            switch ledger.placement(for: header) {
            case .stale:
                ledger.recordStale()
                return .stale
            case .failed:
                ledger.recordFailure(header)
                return .failed
            case .write(let target):
                guard PatchRows.isWellFormed(patch), let surface = ledger.surface(display: header.display, target: target) else {
                    ledger.recordFailure(header)
                    return .failed
                }
                surface.write(patch)
                ledger.didPaint(header.rect, display: header.display, target: target, bytes: header.rect.pixelCount * 4)
                return .committed
            }
        }
    }

    public func hasValidPixels(display: DisplayID, x: Double, y: Double) -> Bool {
        lock.withLock { ledger.hasValidPixels(display: display, x: x, y: y) }
    }

    public func removeAll() {
        lock.withLock { ledger.removeAll() }
    }

    /// The shown picture of a display as tightly packed BGRA rows, or nil when it has no surface.
    public func snapshot(display: DisplayID) -> (PixelSize, [UInt8])? {
        lock.withLock { ledger.shownSurfaces[display].map { ($0.size, $0.pixels) } }
    }

    /// Coverage of the shown surface (nil when none).
    public func coverage(display: DisplayID) -> CoverageGrid? {
        lock.withLock { ledger.shownSlot(display)?.coverage }
    }

    /// True while a canvas-size change is still painting its replacement behind the old picture.
    public func hasPendingReplacement(display: DisplayID) -> Bool {
        lock.withLock { ledger.replacementSlot(display) != nil }
    }

    public var counters: FramebufferCounters { lock.withLock { ledger.counters } }

    /// Bumped whenever the shown pictures may have changed.
    public var contentGeneration: UInt64 { lock.withLock { ledger.contentGeneration } }
}

/// One display's pixels. Only accessed under `SoftwareFramebuffer.lock`.
private final class SoftwareSurface {
    let size: PixelSize
    private(set) var pixels: [UInt8]

    init(size: PixelSize) {
        self.size = size
        pixels = PatchRows.opaqueBlack(pixelCount: size.pixelCount)
    }

    /// Copies the patch rows into place: later patches overwrite, untouched pixels persist.
    func write(_ patch: DecodedPatch) {
        let rect = patch.header.rect
        let rowBytes = rect.width * 4
        pixels.withUnsafeMutableBytes { destination in
            for row in 0..<rect.height {
                let target = destination.baseAddress! + ((rect.y + row) * size.width + rect.x) * 4
                target.copyMemory(from: patch.buffer.contents + row * patch.bytesPerRow, byteCount: rowBytes)
            }
        }
    }
}

/// Patch layout checks and fills shared by both framebuffers.
enum PatchRows {
    /// The buffer really holds `rect` at `bytesPerRow` (defense in depth; the decoder guarantees it).
    static func isWellFormed(_ patch: DecodedPatch) -> Bool {
        let rect = patch.header.rect
        guard rect.width > 0, rect.height > 0 else { return false }
        let row = rect.width.multipliedReportingOverflow(by: 4)
        let body = patch.bytesPerRow.multipliedReportingOverflow(by: rect.height - 1)
        guard !row.overflow, !body.overflow, patch.bytesPerRow >= row.partialValue, patch.bytesPerRow % 4 == 0 else { return false }
        let total = body.partialValue.addingReportingOverflow(row.partialValue)
        return !total.overflow && patch.buffer.byteCount >= total.partialValue
    }

    /// `pixelCount` opaque black BGRA pixels, the initial content of every new surface.
    static func opaqueBlack(pixelCount: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: pixelCount * 4)
        pixels.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt32.self)
            let black = BGRAPixel.opaque(r: 0, g: 0, b: 0)
            for index in words.indices { words[index] = black }
        }
        return pixels
    }
}
