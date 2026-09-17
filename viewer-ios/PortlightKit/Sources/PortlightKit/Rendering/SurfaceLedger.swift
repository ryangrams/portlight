import Foundation

/// Framebuffer bookkeeping counters (identical meaning for the software model and the Metal store).
public struct FramebufferCounters: Equatable, Sendable {
    /// Patches written into a surface (acknowledgeable as applied).
    public var committed = 0
    /// Patches discarded because their revision/canvas/display no longer matches the accepted state.
    public var stale = 0
    /// Patches that matched the accepted state but could not be applied (malformed, no surface, staging or GPU
    /// resource). Reported as `.failed`: the picture is incomplete until a fresh subscription repaints it.
    public var failed = 0
    /// Pixel bytes copied into surfaces (blit bytes for Metal).
    public var blitBytes = 0
    /// Replacement surfaces promoted to shown after their requested region was covered.
    public var swaps = 0
    /// Surfaces or staging copies that could not be allocated.
    public var allocationFailures = 0
    public init() {}
}

/// Revision, canvas and replacement rules shared by `SoftwareFramebuffer` and `MetalFramebufferStore`, so
/// the golden model and the GPU store cannot drift apart. Generic over the pixel storage.
///
/// Per display there is a *shown* surface (what the renderer draws) and, during a canvas-size change, a
/// *replacement* that receives every patch of the new revision. The old pixels stay on screen until the
/// replacement's requested region is covered, then the replacement becomes shown in one step.
///
/// Not thread-safe: each owner mutates it only while holding its own lock.
struct SurfaceLedger<Surface> {
    struct Slot {
        var surface: Surface
        var canvas: PixelSize
        var coverage: CoverageGrid
    }
    struct Entry {
        var shown: Slot?
        var replacement: Slot?
    }
    enum Target { case shown, replacement }
    /// Where a patch goes. `stale`: its revision, display or canvas is no longer the accepted one (discard, still
    /// acknowledge). `failed`: it matches the accepted state but cannot be applied (a rectangle outside the canvas,
    /// or no surface for the canvas because allocation failed), so the picture is now incomplete.
    enum Placement: Equatable { case write(Target), stale, failed }

    private(set) var acceptedRevision: Int?
    private(set) var canvases: [DisplayID: PixelSize] = [:]
    private(set) var entries: [DisplayID: Entry] = [:]
    var counters = FramebufferCounters()
    /// Bumped whenever what the renderer would draw may have changed.
    private(set) var contentGeneration: UInt64 = 0

    /// Applies an accepted `subscribed`. `makeSurface` is called for each surface that must be created.
    ///
    /// A revision that does not increase can only come from a new connection (revisions strictly increase
    /// within one). Its surfaces and pixels are kept as a frozen frame, but every cell becomes invalid so
    /// stale pixels never open the input gate before the new connection repaints them.
    mutating func accept(revision: Int, canvases newCanvases: [DisplayID: PixelSize],
                         requestedRegions: [DisplayID: NormalizedRect], makeSurface: (PixelSize) -> Surface?) {
        let newConnection = acceptedRevision.map { revision <= $0 } ?? false
        acceptedRevision = revision
        canvases = newCanvases
        entries = entries.filter { newCanvases[$0.key] != nil }
        for (display, canvas) in newCanvases.sorted(by: { $0.key < $1.key }) {
            let region = requestedRegions[display] ?? .full
            var entry = entries[display] ?? Entry()
            if newConnection {
                entry.shown?.coverage.invalidateAll()
                entry.replacement?.coverage.invalidateAll()
            }
            if var shown = entry.shown, shown.canvas == canvas {
                entry.replacement = nil
                shown.coverage.setRequestedRegion(region)
                entry.shown = shown
            } else if entry.shown != nil {
                // The old picture stays until the replacement is covered, but it is trusted only inside the region
                // now requested: nothing refreshes it outside that (anywhere, for a zero region).
                entry.shown?.coverage.setRequestedRegion(region)
                if var replacement = entry.replacement, replacement.canvas == canvas {
                    replacement.coverage.setRequestedRegion(region)
                    entry.replacement = replacement
                } else if let surface = makeSurface(canvas) {
                    entry.replacement = Slot(surface: surface, canvas: canvas, coverage: CoverageGrid(canvas: canvas, requestedRegion: region))
                } else {
                    // Nothing can receive the new revision: the old picture would freeze, so stop trusting it for input.
                    entry.replacement = nil
                    entry.shown?.coverage.invalidateAll()
                    counters.allocationFailures += 1
                }
                if let replacement = entry.replacement, replacement.coverage.isCovered {
                    entry.shown = replacement
                    entry.replacement = nil
                    counters.swaps += 1
                }
            } else if let surface = makeSurface(canvas) {
                entry.replacement = nil
                entry.shown = Slot(surface: surface, canvas: canvas, coverage: CoverageGrid(canvas: canvas, requestedRegion: region))
            } else {
                counters.allocationFailures += 1
            }
            entries[display] = entry
        }
        contentGeneration &+= 1
    }

    /// Where a patch with this header must be written, or why it cannot be.
    func placement(for header: FrameHeader) -> Placement {
        guard header.revision == acceptedRevision, let canvas = canvases[header.display], canvas == header.canvas else { return .stale }
        guard header.rect.fits(in: canvas), let entry = entries[header.display] else { return .failed }
        if let replacement = entry.replacement, replacement.canvas == canvas { return .write(.replacement) }
        if let shown = entry.shown, shown.canvas == canvas { return .write(.shown) }
        return .failed // this canvas has no surface: its allocation failed
    }

    func surface(display: DisplayID, target: Target) -> Surface? {
        switch target {
        case .shown: return entries[display]?.shown?.surface
        case .replacement: return entries[display]?.replacement?.surface
        }
    }

    /// Records a patch written into `target`. Returns true when it completed a replacement, which is now shown.
    @discardableResult
    mutating func didPaint(_ rect: PixelRect, display: DisplayID, target: Target, bytes: Int) -> Bool {
        guard var entry = entries[display] else { return false }
        counters.committed += 1
        counters.blitBytes += bytes
        var swapped = false
        switch target {
        case .shown:
            entry.shown?.coverage.markPainted(rect)
            contentGeneration &+= 1
        case .replacement:
            entry.replacement?.coverage.markPainted(rect)
            if let replacement = entry.replacement, replacement.coverage.isCovered {
                entry.shown = replacement
                entry.replacement = nil
                counters.swaps += 1
                contentGeneration &+= 1
                swapped = true
            }
        }
        entries[display] = entry
        return swapped
    }

    mutating func recordStale() { counters.stale += 1 }

    /// Records a patch that matched the accepted state but was lost. The cells it should have repainted keep pixels
    /// the host has moved past, so they stop counting as valid (input gate, replacement swap) until repainted.
    mutating func recordFailure(_ header: FrameHeader) {
        counters.failed += 1
        guard case .write(let target) = placement(for: header), var entry = entries[header.display] else { return }
        switch target {
        case .shown: entry.shown?.coverage.invalidate(header.rect)
        case .replacement: entry.replacement?.coverage.invalidate(header.rect)
        }
        entries[header.display] = entry
    }

    /// What the renderer draws: the shown surface of every display that has one.
    var shownSurfaces: [DisplayID: Surface] { entries.compactMapValues { $0.shown?.surface } }

    func shownSlot(_ display: DisplayID) -> Slot? { entries[display]?.shown }
    func replacementSlot(_ display: DisplayID) -> Slot? { entries[display]?.replacement }

    func hasValidPixels(display: DisplayID, x: Double, y: Double) -> Bool {
        entries[display]?.shown?.coverage.isValid(normalizedX: x, y: y) ?? false
    }

    mutating func removeAll() {
        entries = [:]
        canvases = [:]
        acceptedRevision = nil
        contentGeneration &+= 1
    }
}
