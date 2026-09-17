import Foundation
@testable import PortlightKit

// Shared fixtures for the Viewport tests. Names carry a `Viewport` prefix so they cannot collide
// with helpers other modules add to the same test target.

/// SplitMix64 (Steele, Lea & Flood): tiny, fixed-seed, identical on every platform and run.
struct ViewportSplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform integer in 0..<bound without relying on the standard library's sampling algorithm.
    mutating func below(_ bound: UInt64) -> Int { Int(next() % bound) }
}

enum ViewportFixtures {
    static func display(_ id: DisplayID, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
                        scale: Double = 1, number: Int = 1) -> HostDisplay {
        HostDisplay(id: id, name: "Display \(id)", number: number,
                    nativeSize: PixelSize(width: Int(width * scale), height: Int(height * scale)),
                    logicalFrame: LogicalRect(x: x, y: y, width: width, height: height),
                    scale: scale, isPrimary: number == 1)
    }

    /// Three horizontal 1920×1080 displays: 1 Retina (2×), 2 standard, 3 Retina.
    static let row: [HostDisplay] = [
        display("1", 0, 0, 1920, 1080, scale: 2, number: 1),
        display("2", 1920, 0, 1920, 1080, scale: 1, number: 2),
        display("3", 3840, 0, 1920, 1080, scale: 2, number: 3),
    ]

    static func scales(_ displays: [HostDisplay]) -> [DisplayID: Double] {
        Dictionary(displays.map { ($0.id, $0.scale) }, uniquingKeysWith: { first, _ in first })
    }

    /// iPhone-like surface: 390×844 pt at 3× (1170×2532 px) with portrait safe-area insets.
    static let portraitSize = PixelSize(width: 1170, height: 2532)
    static let portraitUsable = DrawableRect(x: 0, y: 141, width: 1170, height: 2289)     // 141 px top, 102 px bottom inset
    static let landscapeSize = PixelSize(width: 2532, height: 1170)
    static let landscapeUsable = DrawableRect(x: 141, y: 0, width: 2250, height: 1107)    // 141 px sides, 63 px bottom inset

    static func model(_ displays: [HostDisplay], selected: [DisplayID]? = nil,
                      size: PixelSize = portraitSize, usable: DrawableRect? = portraitUsable,
                      contentScale: Double = 3) -> ViewportModel {
        let layout = DesktopLayout.arrange(displays, selected: selected ?? displays.map(\.id), compact: true)
        return ViewportModel(layout: layout, hostScales: scales(displays), drawableSize: size,
                             usableRect: usable, contentScale: contentScale)
    }
}

extension ViewportTransform {
    /// Exact identity of the IEEE representation (no epsilon), for no-jump comparisons.
    var viewportBits: [UInt64] { [scale.bitPattern, tx.bitPattern, ty.bitPattern] }
}

func viewportClose(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}
