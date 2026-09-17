import Foundation

/// Phone-sized limits for framebuffer memory. The Mac viewer's four-UHD budget (33,177,600 pixels ≈ 127 MiB
/// of BGRA before staging and replacement surfaces) is only granted to devices with enough RAM; smaller
/// phones get a lower stream resolution instead of fewer displays.
public enum RenderBudget {
    /// Total stream pixels (all displays) allowed for this much physical memory.
    public static func pixelBudget(physicalMemory: UInt64) -> Int {
        let gib: UInt64 = 1 << 30
        if physicalMemory <= 4 * gib { return 8_294_400 }   // one UHD canvas
        if physicalMemory <= 6 * gib { return 16_588_800 }  // two
        return 33_177_600                                   // four
    }

    /// `pixelBudget` for the running device.
    public static var devicePixelBudget: Int { pixelBudget(physicalMemory: ProcessInfo.processInfo.physicalMemory) }

    /// The highest preset not above `requested` whose predicted canvases, doubled for a pending replacement
    /// during a resolution change, fit `budget`. Never drops displays: when even HD does not fit, returns
    /// `.hd` with `limitedByBudget` true so the UI can say so.
    public static func highestPreset(displays: [HostDisplay], requested: ResolutionPreset, budget: Int) -> (preset: ResolutionPreset, limitedByBudget: Bool) {
        guard !displays.isEmpty else { return (requested, false) }
        for candidate in ResolutionPreset.allCases.reversed() where candidate <= requested {
            let (doubled, overflow) = predictedPixels(displays: displays, preset: candidate).multipliedReportingOverflow(by: 2)
            if !overflow, doubled <= budget { return (candidate, candidate != requested) }
        }
        return (.hd, true)
    }

    /// Stream pixels the host would allocate for `preset`. Mirrors `commonResolution`: one preset for every
    /// selected display (the highest ≤ `preset` that all of them support), or each display's native size when
    /// one of them is smaller than HD. Sizes come from `ResolutionPreset.streamSize(forNative:)`.
    public static func predictedPixels(displays: [HostDisplay], preset: ResolutionPreset) -> Int {
        let common = ResolutionPreset.allCases.reversed().first { candidate in
            candidate <= preset && displays.allSatisfy { candidate.isSupported(byNative: $0.nativeSize) }
        }
        return displays.reduce(0) { total, display in
            let size = common.map { $0.streamSize(forNative: display.nativeSize) } ?? display.nativeSize
            // Saturate: a wrapped product would make an impossible topology look cheap.
            let pixels = max(0, size.width).multipliedReportingOverflow(by: max(0, size.height))
            let sum = total.addingReportingOverflow(pixels.partialValue)
            return pixels.overflow || sum.overflow ? Int.max : sum.partialValue
        }
    }
}
