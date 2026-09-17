import Testing
@testable import PortlightKit

@Suite("RenderBudget")
struct RenderBudgetTests {
    private static let gib: UInt64 = 1 << 30

    private func display(_ id: String, _ width: Int, _ height: Int, x: Double = 0, scale: Double = 2) -> HostDisplay {
        HostDisplay(id: id, name: id, number: 1, nativeSize: PixelSize(width: width, height: height),
                    logicalFrame: LogicalRect(x: x, y: 0, width: Double(width) / scale, height: Double(height) / scale), scale: scale, isPrimary: false)
    }

    /// Flattens the result so `#expect` compares plain values.
    private func choose(_ displays: [HostDisplay], _ requested: ResolutionPreset, budget: Int) -> String {
        let result = RenderBudget.highestPreset(displays: displays, requested: requested, budget: budget)
        return "\(result.preset.rawValue)\(result.limitedByBudget ? " limited" : "")"
    }

    @Test func pixelBudgetStepsWithPhysicalMemory() {
        #expect(RenderBudget.pixelBudget(physicalMemory: 3 * Self.gib) == 8_294_400)
        #expect(RenderBudget.pixelBudget(physicalMemory: 4 * Self.gib) == 8_294_400)
        #expect(RenderBudget.pixelBudget(physicalMemory: 4 * Self.gib + 1) == 16_588_800)
        #expect(RenderBudget.pixelBudget(physicalMemory: 6 * Self.gib) == 16_588_800)
        #expect(RenderBudget.pixelBudget(physicalMemory: 6 * Self.gib + 1) == 33_177_600)
        #expect(RenderBudget.pixelBudget(physicalMemory: 12 * Self.gib) == 33_177_600)
    }

    @Test func threeUHDDisplaysLowerTheResolutionNotTheDisplayCount() {
        let displays = [display("a", 3840, 2160), display("b", 3840, 2160, x: 1920), display("c", 3840, 2160, x: 3840)]
        // HD: 3 × 921,600 × 2 = 5,529,600 fits one UHD budget; FHD (12,441,600) does not.
        #expect(choose(displays, .uhd, budget: 8_294_400) == "hd limited")
        // QHD: 3 × 3,686,400 × 2 = 22,118,400 fits four UHD; UHD (49,766,400) does not.
        #expect(choose(displays, .uhd, budget: 33_177_600) == "qhd limited")
        #expect(choose(displays, .fhd, budget: 33_177_600) == "fhd")
        #expect(choose(displays, .hd, budget: 1_000) == "hd limited")
    }

    @Test func predictionFollowsHostCommonPresetAndNativeRules() {
        // Fixture topology: a 1080p display caps every selected display at FHD (host `commonResolution`).
        let fixture = [display("fixture-1", 3840, 2160), display("fixture-2", 1920, 1080, x: 1920, scale: 1), display("fixture-3", 3840, 2160, x: 3840)]
        #expect(RenderBudget.predictedPixels(displays: fixture, preset: .uhd) == 3 * 1920 * 1080)
        #expect(choose(fixture, .uhd, budget: 16_588_800) == "uhd")
        // A display below HD makes the host stream every display at native size, whatever the preset.
        let native = [display("small", 1024, 768, scale: 1), display("5k", 5120, 2880, x: 1024)]
        #expect(RenderBudget.predictedPixels(displays: native, preset: .hd) == 1024 * 768 + 5120 * 2880)
        #expect(choose(native, .uhd, budget: 33_177_600) == "uhd")
        #expect(choose(native, .uhd, budget: 16_588_800) == "hd limited")
        // Portrait displays swap the box axes.
        #expect(RenderBudget.predictedPixels(displays: [display("portrait", 2160, 3840)], preset: .hd) == 720 * 1280)
    }

    @Test func emptySelectionIsNeverLimited() {
        #expect(choose([], .fhd, budget: 0) == "fhd")
    }
}
