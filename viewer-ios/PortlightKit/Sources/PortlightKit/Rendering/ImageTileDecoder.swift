import Foundation
import CoreGraphics
import ImageIO

/// Decodes one `frame` payload (PNG or JPEG) into a BGRA8 patch with ImageIO.
///
/// Order matters: the container type, its integrity (PNG chunk CRCs) and the image's declared pixel size are
/// checked against the header *before* any pixel memory is requested, so a lying header can never make us allocate or copy more than
/// the header's own rectangle. Pixels are expanded from the decoded image's raw samples rather than drawn
/// through CoreGraphics, because drawing applies color matching (the decoded PNGs are tagged Gray Gamma 2.2
/// or sRGB) and the reduced-color modes must come out exact: gray nibble n → n×17, palette entries verbatim.
public enum ImageTileDecoder {
    /// Output layout: BGRA8, `premultipliedFirst | byteOrder32Little`, alpha 255, top-left origin,
    /// `bytesPerRow == rect.width × 4`.
    ///
    /// - Parameter allocate: called at most once, with the exact byte count, after validation succeeds.
    ///   Returning nil (budget exhausted) throws `.allocationFailed`.
    public static func decode(header: FrameHeader, payload: Data, allocate: (Int) -> PatchBuffer?) throws -> DecodedPatch {
        let expected = PixelSize(width: header.rect.width, height: header.rect.height)
        guard expected.width > 0, expected.height > 0 else { throw RenderingError.decodeFailed("empty rectangle") }
        guard !payload.isEmpty, payload.count <= PortlightProtocol.maxBinaryMessageBytes else {
            throw RenderingError.decodeFailed("payload size \(payload.count) is out of range")
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(payload as CFData, options),
              let type = CGImageSourceGetType(source) as String? else {
            throw RenderingError.decodeFailed("unrecognized image data")
        }
        guard type == typeIdentifier(of: header.codec) else { throw RenderingError.codecMismatch(expected: header.codec, actual: type) }
        // ImageIO ignores PNG chunk CRCs and decodes truncated or corrupt data without complaint, so container integrity is
        // checked here (a checksum walk, not a decoder). JPEG carries no checksum; require at least its end-of-image marker.
        let intact = header.codec == .png ? pngChunksAreIntact(payload) : payload.suffix(2).elementsEqual(jpegTrailer)
        guard intact else { throw RenderingError.decodeFailed("truncated or corrupt \(header.codec.rawValue) payload") }
        guard CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw RenderingError.decodeFailed("image has no readable pixel size")
        }
        let actual = PixelSize(width: width, height: height)
        guard actual == expected else { throw RenderingError.sizeMismatch(expected: expected, actual: actual) }

        let bytesPerRow = width * 4 // width ≤ canvas width, validated by the protocol layer; cannot overflow
        let (byteCount, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow else { throw RenderingError.allocationFailed(byteCount: Int.max) }
        guard let buffer = allocate(byteCount), buffer.byteCount >= byteCount else {
            throw RenderingError.allocationFailed(byteCount: byteCount)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw RenderingError.decodeFailed("ImageIO returned no image")
        }
        guard image.width == width, image.height == height else {
            throw RenderingError.sizeMismatch(expected: expected, actual: PixelSize(width: image.width, height: image.height))
        }
        try expand(image, into: buffer.contents, bytesPerRow: bytesPerRow)
        return DecodedPatch(header: header, buffer: buffer, bytesPerRow: bytesPerRow)
    }

    // MARK: - Integrity

    /// ImageIO container type for a codec.
    private static func typeIdentifier(of codec: ImageCodec) -> String {
        switch codec { case .png: return "public.png"; case .jpeg: return "public.jpeg" }
    }

    private static let jpegTrailer: [UInt8] = [0xFF, 0xD9]
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let pngEndChunk: [UInt8] = [0x49, 0x45, 0x4E, 0x44] // "IEND"

    /// PNG signature, chunks inside the payload, every chunk's CRC-32 correct, and IEND as the last bytes.
    static func pngChunksAreIntact(_ payload: Data) -> Bool {
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count >= pngSignature.count + 12, bytes.prefix(pngSignature.count).elementsEqual(pngSignature) else { return false }
            var offset = pngSignature.count
            while bytes.count - offset >= 12 {
                let length = readBigEndian32(bytes, at: offset)
                guard length <= bytes.count - offset - 12 else { return false }
                let type = offset + 4, checksum = type + 4 + length
                guard crc32(bytes, from: type, count: 4 + length) == UInt32(readBigEndian32(bytes, at: checksum)) else { return false }
                offset = checksum + 4
                if bytes[type..<(type + 4)].elementsEqual(pngEndChunk) { return offset == bytes.count }
            }
            return false
        }
    }

    private static func readBigEndian32(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int {
        Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    /// CRC-32 (ISO 3309, the polynomial PNG uses), table-driven.
    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 { value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
            table[index] = value
        }
        return table
    }()

    private static func crc32(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, count: Int) -> UInt32 {
        crcTable.withUnsafeBufferPointer { table in
            var crc: UInt32 = 0xFFFF_FFFF
            for index in start..<(start + count) { crc = table[Int((crc ^ UInt32(bytes[index])) & 0xFF)] ^ (crc >> 8) }
            return crc ^ 0xFFFF_FFFF
        }
    }

    // MARK: - Expansion

    /// Writes the image as opaque BGRA. Recognized layouts are expanded from raw samples (exact);
    /// anything else is drawn by CoreGraphics into an sRGB context.
    static func expand(_ image: CGImage, into destination: UnsafeMutableRawPointer, bytesPerRow: Int) throws {
        // Forces the decode. A nil provider/data means ImageIO hit corrupt or truncated compressed data.
        guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else {
            throw RenderingError.decodeFailed("image data is incomplete or corrupt")
        }
        let length = CFDataGetLength(data)
        guard let layout = SampleLayout(image) else {
            try draw(image, into: destination, bytesPerRow: bytesPerRow)
            return
        }
        let width = image.width, height = image.height, sourceRowBytes = image.bytesPerRow
        let rowBits = width.multipliedReportingOverflow(by: image.bitsPerPixel)
        guard !rowBits.overflow, sourceRowBytes >= (rowBits.partialValue + 7) / 8,
              length >= sourceRowBytes * (height - 1) + (rowBits.partialValue + 7) / 8 else {
            throw RenderingError.decodeFailed("decoded image data is shorter than its declared layout")
        }
        for y in 0..<height {
            let source = base + y * sourceRowBytes
            let row = (destination + y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            layout.expandRow(source, into: row, width: width)
        }
    }

    private static func draw(_ image: CGImage, into destination: UnsafeMutableRawPointer, bytesPerRow: Int) throws {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: destination, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space, bitmapInfo: info) else {
            throw RenderingError.decodeFailed("unsupported pixel layout")
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.interpolationQuality = .none
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(bounds) // transparent pixels composite onto opaque black: alpha stays 255
        context.draw(image, in: bounds)
    }
}

/// Opaque BGRA pixels as one little-endian word: memory bytes B, G, R, 255.
enum BGRAPixel {
    @inline(__always) static func opaque(r: UInt8, g: UInt8, b: UInt8) -> UInt32 {
        (UInt32(b) | UInt32(g) << 8 | UInt32(r) << 16 | 0xFF00_0000).littleEndian
    }
}

/// How to read gray, RGB or indexed samples straight out of a decoded CGImage's bytes.
private struct SampleLayout {
    private enum Source {
        /// 8- or 16-bit components; byte offsets of each channel's most significant byte within a pixel.
        case direct(bytesPerPixel: Int, r: Int, g: Int, b: Int)
        /// 1/2/4/8-bit packed samples (gray or palette index) looked up in a 2^bits-entry table.
        case lookup(bits: Int, table: [UInt32])
    }
    private let source: Source

    init?(_ image: CGImage) {
        guard let space = image.colorSpace, image.pixelFormatInfo == .packed,
              !image.bitmapInfo.contains(.floatComponents) else { return nil }
        let bpc = image.bitsPerComponent, bpp = image.bitsPerPixel
        switch space.model {
        case .indexed:
            guard [1, 2, 4, 8].contains(bpc), bpp == bpc, image.alphaInfo == .none,
                  let base = space.baseColorSpace, let table = space.colorTable else { return nil }
            let components = base.numberOfComponents
            guard base.model == .rgb || base.model == .monochrome, components == (base.model == .rgb ? 3 : 1) else { return nil }
            var entries = [UInt32](repeating: BGRAPixel.opaque(r: 0, g: 0, b: 0), count: 1 << bpc)
            for index in 0..<min(entries.count, table.count / components) {
                let at = index * components
                entries[index] = components == 3
                    ? BGRAPixel.opaque(r: table[at], g: table[at + 1], b: table[at + 2])
                    : BGRAPixel.opaque(r: table[at], g: table[at], b: table[at])
            }
            source = .lookup(bits: bpc, table: entries)
        case .monochrome where bpc < 8:
            guard [1, 2, 4].contains(bpc), bpp == bpc, image.alphaInfo == .none else { return nil }
            let maximum = (1 << bpc) - 1
            source = .lookup(bits: bpc, table: (0...maximum).map { level in
                let value = UInt8(level * 255 / maximum) // 4-bit: n × 17, exactly as PNG bit-depth scaling
                return BGRAPixel.opaque(r: value, g: value, b: value)
            })
        case .monochrome, .rgb:
            guard bpc == 8 || bpc == 16 else { return nil }
            let colors = space.model == .rgb ? [0, 1, 2] : [0, 0, 0] // channel index per R, G, B
            let alphaFirst: Bool, hasAlpha: Bool
            switch image.alphaInfo {
            case .none: hasAlpha = false; alphaFirst = false
            case .first, .premultipliedFirst, .noneSkipFirst: hasAlpha = true; alphaFirst = true
            case .last, .premultipliedLast, .noneSkipLast: hasAlpha = true; alphaFirst = false
            default: return nil
            }
            let colorCount = space.model == .rgb ? 3 : 1
            let componentCount = colorCount + (hasAlpha ? 1 : 0)
            guard bpp == componentCount * bpc else { return nil }
            // Logical component order, then memory order: little-endian words reverse 8-bit components.
            var slots = Array(0..<componentCount).map { alphaFirst && hasAlpha ? $0 - 1 : $0 } // -1 = alpha
            let order = image.byteOrderInfo
            var highByte = 0
            if bpc == 8 {
                switch order {
                case .orderDefault, .order32Big, .order16Big: break
                case .order32Little where bpp == 32: slots.reverse()
                case .order16Little where bpp == 16: slots.reverse()
                default: return nil
                }
            } else {
                switch order {
                case .orderDefault, .order16Big: highByte = 0
                case .order16Little: highByte = 1
                default: return nil
                }
            }
            let bytesPerComponent = bpc / 8
            func offset(ofChannel channel: Int) -> Int? {
                slots.firstIndex(of: channel).map { $0 * bytesPerComponent + highByte }
            }
            guard let r = offset(ofChannel: colors[0]), let g = offset(ofChannel: colors[1]), let b = offset(ofChannel: colors[2]) else { return nil }
            source = .direct(bytesPerPixel: bpp / 8, r: r, g: g, b: b)
        default:
            return nil
        }
    }

    /// Alpha is discarded: the remote desktop is opaque and the host never sends transparency.
    func expandRow(_ row: UnsafePointer<UInt8>, into output: UnsafeMutablePointer<UInt32>, width: Int) {
        switch source {
        case let .direct(stride, r, g, b):
            var pixel = row
            for x in 0..<width {
                output[x] = BGRAPixel.opaque(r: pixel[r], g: pixel[g], b: pixel[b])
                pixel += stride
            }
        case let .lookup(bits, table):
            table.withUnsafeBufferPointer { entries in
                if bits == 8 {
                    for x in 0..<width { output[x] = entries[Int(row[x])] }
                } else {
                    let perByte = 8 / bits, mask = (1 << bits) - 1
                    for x in 0..<width {
                        let shift = 8 - bits * (x % perByte + 1) // first sample in the most significant bits
                        output[x] = entries[(Int(row[x / perByte]) >> shift) & mask]
                    }
                }
            }
        }
    }
}
