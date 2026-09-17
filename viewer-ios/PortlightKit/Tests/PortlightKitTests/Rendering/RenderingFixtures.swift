import Foundation
import CoreGraphics
import ImageIO
@testable import PortlightKit

/// Builds frame payloads exactly the way the host's `TileEncoder` (server-macos/Sources/Capture.swift) does:
/// the same quantization, pixel packing, CGImage layouts and color spaces, encoded with CGImageDestination.
enum HostTileEncoder {
    /// color256 palette entry i = ((i>>5)·255/7, ((i>>2)&7)·255/7, (i&3)·255/3), integer math.
    static let palette: [UInt8] = {
        var table: [UInt8] = []
        for i in 0..<256 {
            let red: Int = (i >> 5) * 255 / 7, green: Int = ((i >> 2) & 7) * 255 / 7, blue: Int = (i & 3) * 255 / 3
            table += [UInt8(red), UInt8(green), UInt8(blue)]
        }
        return table
    }()

    /// Host luminance (vImage matrix [77,150,29,0], divisor 256, post-bias 128), then nibble = L / 17 (no dither).
    static func gray16Nibble(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        let weighted: Int = 77 * Int(r) + 150 * Int(g) + 29 * Int(b) + 128
        return UInt8(weighted >> 8) / 17
    }

    /// Host color256 index: (r>>5)<<5 | (g>>5)<<2 | (b>>6).
    static func color256Index(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        (r >> 5) << 5 | (g >> 5) << 2 | (b >> 6)
    }

    /// 4-bit DeviceGray PNG: two samples per byte, first pixel in the high nibble, bytesPerRow (w+1)/2.
    static func gray16PNG(width: Int, height: Int, nibble: (Int, Int) -> UInt8) -> Data {
        let rowBytes = (width + 1) / 2
        var packed = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = nibble(x, y) & 15
                packed[y * rowBytes + x / 2] |= x % 2 == 0 ? value << 4 : value
            }
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 4, bitsPerPixel: 4, bytesPerRow: rowBytes,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: CGDataProvider(data: Data(packed) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return encode(image, type: "public.png")
    }

    /// 8-bit indexed PNG over `CGColorSpace(indexedBaseSpace: DeviceRGB, last: 255, colorTable: palette)`.
    static func color256PNG(width: Int, height: Int, index: (Int, Int) -> UInt8) -> Data {
        var indices = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { indices[y * width + x] = index(x, y) } }
        let space = CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 255, colorTable: palette)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: space,
                            bitmapInfo: [], provider: CGDataProvider(data: Data(indices) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return encode(image, type: "public.png")
    }

    /// Full color: DeviceRGB, 8 bpc, 32 bpp `noneSkipLast` (R,G,B,X), as PNG or JPEG.
    static func rgbImage(width: Int, height: Int, rgb: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = rgb(x, y)
                let at = (y * width + x) * 4
                pixels[at] = r; pixels[at + 1] = g; pixels[at + 2] = b
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func rgbPNG(width: Int, height: Int, rgb: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Data {
        encode(rgbImage(width: width, height: height, rgb: rgb), type: "public.png")
    }

    /// Host JPEG quality: 0.7 (0.4 below 1500 kbps).
    static func jpeg(width: Int, height: Int, quality: Double = 0.7, rgb: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Data {
        encode(rgbImage(width: width, height: height, rgb: rgb), type: "public.jpeg", quality: quality)
    }

    private static func encode(_ image: CGImage, type: String, quality: Double? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
        let properties: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// Deterministic generator for fixture content (SplitMix64; fixed seeds only).
struct RenderingFixtureRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
}

/// Frame payload bytes, named so test files need not import Foundation (see ImageTileDecoderTests).
typealias RenderingPayload = Data

enum RenderingFixtures {
    static func header(revision: Int = 1, display: DisplayID = "d1", rect: PixelRect, canvas: PixelSize,
                       codec: ImageCodec = .png, sequence: Int = 1) -> FrameHeader {
        FrameHeader(revision: revision, display: display, rect: rect, canvas: canvas, codec: codec, sequence: sequence)
    }

    /// A patch whose every pixel is `color` (B, G, R, A), in a buffer from `allocate`.
    static func solidPatch(_ header: FrameHeader, bgra color: (UInt8, UInt8, UInt8, UInt8),
                           allocate: (Int) -> PatchBuffer? = { HeapPatchBuffer(byteCount: $0) }) -> DecodedPatch {
        patch(header, allocate: allocate) { _, _ in color }
    }

    /// A patch with a per-pixel pattern; `pixel(x, y)` gets patch-local coordinates.
    static func patch(_ header: FrameHeader, allocate: (Int) -> PatchBuffer? = { HeapPatchBuffer(byteCount: $0) },
                      pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> DecodedPatch {
        let rowBytes = header.rect.width * 4
        let buffer = allocate(rowBytes * header.rect.height)!
        let bytes = buffer.contents.assumingMemoryBound(to: UInt8.self)
        for y in 0..<header.rect.height {
            for x in 0..<header.rect.width {
                let (b, g, r, a) = pixel(x, y)
                let at = y * rowBytes + x * 4
                bytes[at] = b; bytes[at + 1] = g; bytes[at + 2] = r; bytes[at + 3] = a
            }
        }
        return DecodedPatch(header: header, buffer: buffer, bytesPerRow: rowBytes)
    }

    /// BGRA of one pixel in a tightly packed snapshot.
    static func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        let at = (y * width + x) * 4
        return Array(bytes[at..<at + 4])
    }
}

/// Counts allocation requests so tests can prove validation happened before any memory was requested.
final class AllocationProbe {
    private(set) var requests: [Int] = []
    var fails = false
    func allocate(_ byteCount: Int) -> PatchBuffer? {
        requests.append(byteCount)
        return fails ? nil : HeapPatchBuffer(byteCount: byteCount)
    }
}

extension RenderingFixtures {
    /// Runs `ImageTileDecoder.expand` on a packed 1/2/4-bit image (gray, or indexed over DeviceRGB with `palette`), first
    /// sample in the most significant bits. ImageIO widens such PNGs itself, so only this reaches the decoder's own path.
    static func expandPacked(bits: Int, width: Int, height: Int, palette: [UInt8]? = nil, sample: (Int, Int) -> UInt8) throws -> [UInt8] {
        let rowBytes = (width * bits + 7) / 8
        var packed = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let bit = x * bits
                packed[y * rowBytes + bit / 8] |= (sample(x, y) & UInt8((1 << bits) - 1)) << (8 - bits - bit % 8)
            }
        }
        let space = palette.map { CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: $0.count / 3 - 1, colorTable: $0)! }
            ?? CGColorSpaceCreateDeviceGray()
        let image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits, bytesPerRow: rowBytes, space: space,
                            bitmapInfo: [], provider: CGDataProvider(data: Data(packed) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        var output = [UInt8](repeating: 0, count: width * height * 4)
        try output.withUnsafeMutableBytes { try ImageTileDecoder.expand(image, into: $0.baseAddress!, bytesPerRow: width * 4) }
        return output
    }
}
