// No `import Foundation` here: with Command Line Tools, Foundation + Testing in one file needs the missing
// `_Testing_Foundation` overlay. Foundation-typed helpers live in RenderingFixtures.swift.
import Testing
@testable import PortlightKit

/// RENDER-01: PNG4 gray, indexed PNG8 and full-color PNG decode to exact pixels; JPEG within tolerance;
/// lying headers are rejected before any memory is requested.
@Suite("ImageTileDecoder")
struct ImageTileDecoderTests {
    private let canvas = PixelSize(width: 1280, height: 720)

    private func decode(_ payload: RenderingPayload, codec: ImageCodec, width: Int, height: Int, probe: AllocationProbe = AllocationProbe()) throws -> DecodedPatch {
        let header = RenderingFixtures.header(rect: PixelRect(x: 256, y: 512, width: width, height: height), canvas: canvas, codec: codec)
        return try ImageTileDecoder.decode(header: header, payload: payload, allocate: probe.allocate)
    }

    private func bytes(_ patch: DecodedPatch) -> [UInt8] {
        [UInt8](UnsafeRawBufferPointer(start: patch.buffer.contents, count: patch.bytesPerRow * patch.header.rect.height))
    }

    @Test func gray16PNG4ExpandsEveryNibbleToNTimes17() throws {
        let width = 37, height = 21 // odd width: the last byte of each row holds one sample
        var random = RenderingFixtureRandom(seed: 16)
        var source = (0..<(width * height)).map { _ in (random.byte(), random.byte(), random.byte()) }
        for level in 0..<16 { let v = UInt8(level * 17); source[level] = (v, v, v) } // every nibble appears
        let nibbles = source.map { HostTileEncoder.gray16Nibble(r: $0.0, g: $0.1, b: $0.2) }
        #expect(Set(nibbles).count == 16)
        let png = HostTileEncoder.gray16PNG(width: width, height: height) { x, y in nibbles[y * width + x] }
        #expect(Array(png[24...25]) == [4, 0]) // IHDR: bit depth 4, color type 0 (grayscale), as the host e2e asserts

        let probe = AllocationProbe()
        let patch = try decode(png, codec: .png, width: width, height: height, probe: probe)
        #expect(probe.requests == [width * height * 4])
        #expect(patch.bytesPerRow == width * 4)
        let expected = nibbles.flatMap { n -> [UInt8] in let v = n * 17; return [v, v, v, 255] }
        #expect(bytes(patch) == expected)
    }

    @Test func color256PNG8ReproducesThePaletteExactly() throws {
        // Every index once, then host-quantized random colors on an odd-sized tile.
        var random = RenderingFixtureRandom(seed: 256)
        let cases: [(width: Int, height: Int, index: (Int, Int) -> UInt8)] = [
            (16, 16, { x, y in UInt8(y * 16 + x) }),
            (33, 7, { _, _ in HostTileEncoder.color256Index(r: random.byte(), g: random.byte(), b: random.byte()) }),
        ]
        for testCase in cases {
            var indices: [UInt8] = []
            for y in 0..<testCase.height { for x in 0..<testCase.width { indices.append(testCase.index(x, y)) } }
            let png = HostTileEncoder.color256PNG(width: testCase.width, height: testCase.height) { x, y in indices[y * testCase.width + x] }
            #expect(Array(png[24...25]) == [8, 3]) // IHDR: bit depth 8, color type 3 (palette)
            let patch = try decode(png, codec: .png, width: testCase.width, height: testCase.height)
            let expected = indices.flatMap { i -> [UInt8] in
                let p = Int(i) * 3
                return [HostTileEncoder.palette[p + 2], HostTileEncoder.palette[p + 1], HostTileEncoder.palette[p], 255]
            }
            #expect(bytes(patch) == expected)
        }
        // The palette formula itself (host.md §1): R/G levels 0,36,72,109,145,182,218,255; B levels 0,85,170,255.
        let redLevels: [UInt8] = stride(from: 0, to: 256, by: 32).map { (i: Int) -> UInt8 in HostTileEncoder.palette[i * 3] }
        let blueLevels: [UInt8] = (0..<4).map { (i: Int) -> UInt8 in HostTileEncoder.palette[i * 3 + 2] }
        let expectedRed: [UInt8] = [0, 36, 72, 109, 145, 182, 218, 255], expectedBlue: [UInt8] = [0, 85, 170, 255]
        #expect(redLevels == expectedRed)
        #expect(blueLevels == expectedBlue)
    }

    @Test func fullColorPNGKeepsRGBBytesUnchanged() throws {
        let width = 29, height = 13
        var random = RenderingFixtureRandom(seed: 3)
        let pixels = (0..<(width * height)).map { _ in (random.byte(), random.byte(), random.byte()) }
        let png = HostTileEncoder.rgbPNG(width: width, height: height) { x, y in pixels[y * width + x] }
        #expect(Array(png[24...25]) == [8, 2]) // IHDR: bit depth 8, color type 2 (RGB)
        let patch = try decode(png, codec: .png, width: width, height: height)
        let expected: [UInt8] = pixels.flatMap { p -> [UInt8] in [p.2, p.1, p.0, 255] }
        #expect(bytes(patch) == expected)
    }

    @Test func jpegDecodesWithinTolerance() throws {
        let width = 64, height = 48
        let color: (Int, Int) -> (UInt8, UInt8, UInt8) = { x, y in (UInt8(x * 4), UInt8(y * 5), UInt8(96 + (x + y))) }
        let jpeg = HostTileEncoder.jpeg(width: width, height: height, rgb: color)
        let patch = try decode(jpeg, codec: .jpeg, width: width, height: height)
        let decoded = bytes(patch)
        var total = 0, worst = 0
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let at = (y * width + x) * 4
                #expect(decoded[at + 3] == 255)
                let pairs: [(UInt8, UInt8)] = [(decoded[at], b), (decoded[at + 1], g), (decoded[at + 2], r)]
                for (got, want) in pairs {
                    let error = abs(Int(got) - Int(want))
                    total += error
                    worst = max(worst, error)
                }
            }
        }
        #expect(Double(total) / Double(width * height * 3) <= 3)
        #expect(worst <= 24)
    }

    @Test func sizeMismatchIsRejectedBeforeAllocation() throws {
        let png = HostTileEncoder.rgbPNG(width: 37, height: 21) { _, _ in (1, 2, 3) }
        let probe = AllocationProbe()
        #expect(throws: RenderingError.sizeMismatch(expected: PixelSize(width: 36, height: 21), actual: PixelSize(width: 37, height: 21))) {
            try decode(png, codec: .png, width: 36, height: 21, probe: probe)
        }
        #expect(throws: RenderingError.sizeMismatch(expected: PixelSize(width: 37, height: 22), actual: PixelSize(width: 37, height: 21))) {
            try decode(png, codec: .png, width: 37, height: 22, probe: probe)
        }
        #expect(probe.requests.isEmpty)
    }

    @Test func codecMismatchIsRejectedBeforeAllocation() throws {
        let png = HostTileEncoder.rgbPNG(width: 8, height: 8) { _, _ in (9, 9, 9) }
        let jpeg = HostTileEncoder.jpeg(width: 8, height: 8) { _, _ in (9, 9, 9) }
        let probe = AllocationProbe()
        #expect(throws: RenderingError.codecMismatch(expected: .jpeg, actual: "public.png")) {
            try decode(png, codec: .jpeg, width: 8, height: 8, probe: probe)
        }
        #expect(throws: RenderingError.codecMismatch(expected: .png, actual: "public.jpeg")) {
            try decode(jpeg, codec: .png, width: 8, height: 8, probe: probe)
        }
        #expect(probe.requests.isEmpty)
    }

    @Test func garbageAndTruncatedPayloadsFailWithoutAllocation() throws {
        var random = RenderingFixtureRandom(seed: 99)
        let png = HostTileEncoder.rgbPNG(width: 16, height: 16) { x, y in (UInt8(x * 16), UInt8(y * 16), 7) }
        let jpeg = HostTileEncoder.jpeg(width: 16, height: 16) { x, y in (UInt8(x * 16), UInt8(y * 16), 7) }
        let payloads: [(RenderingPayload, ImageCodec)] = [
            (RenderingPayload((0..<400).map { _ in random.byte() }), .png),
            (RenderingPayload(), .png),
            (png.prefix(png.count / 2), .png),
            (png.prefix(png.count - 20), .png), // IDAT damaged
            (png.prefix(png.count - 12), .png), // only IEND missing: ImageIO alone would accept it
            (jpeg.prefix(jpeg.count - 30), .jpeg),
        ]
        let probe = AllocationProbe()
        for (payload, codec) in payloads {
            let error = #expect(throws: RenderingError.self) { try decode(payload, codec: codec, width: 16, height: 16, probe: probe) }
            if case .decodeFailed = error {} else { Issue.record("expected decodeFailed, got \(String(describing: error))") }
        }
        #expect(probe.requests.isEmpty)
    }

    @Test func corruptCompressedDataIsRejected() throws {
        var random = RenderingFixtureRandom(seed: 5)
        var png = HostTileEncoder.rgbPNG(width: 64, height: 64) { _, _ in (random.byte(), random.byte(), random.byte()) }
        let idat = try #require(png.firstRange(of: RenderingPayload("IDAT".utf8)))
        // Overwrite a run in the middle of the compressed stream; length fields and the IEND trailer stay intact.
        let start = idat.upperBound + 200
        for offset in start..<(start + 64) { png[offset] = 0xFF }
        let probe = AllocationProbe()
        let error = #expect(throws: RenderingError.self) { try decode(png, codec: .png, width: 64, height: 64, probe: probe) }
        if case .decodeFailed = error {} else { Issue.record("expected decodeFailed, got \(String(describing: error))") }
        #expect(probe.requests.isEmpty) // ImageIO would have decoded it; the chunk CRC walk rejects it first
    }

    @Test func allocationFailureIsReported() throws {
        let png = HostTileEncoder.gray16PNG(width: 16, height: 16) { x, _ in UInt8(x) }
        let probe = AllocationProbe()
        probe.fails = true
        #expect(throws: RenderingError.allocationFailed(byteCount: 16 * 16 * 4)) {
            try decode(png, codec: .png, width: 16, height: 16, probe: probe)
        }
        #expect(probe.requests == [1024])
        let header = RenderingFixtures.header(rect: PixelRect(x: 0, y: 0, width: 16, height: 16), canvas: canvas)
        #expect(throws: RenderingError.allocationFailed(byteCount: 1024)) {
            try ImageTileDecoder.decode(header: header, payload: png) { _ in HeapPatchBuffer(byteCount: 1000) } // too small
        }
    }

    @Test func singlePixelAndHeaderOriginDoNotAffectPixels() throws {
        let png = HostTileEncoder.gray16PNG(width: 1, height: 1) { _, _ in 15 }
        let patch = try decode(png, codec: .png, width: 1, height: 1)
        #expect(bytes(patch) == [255, 255, 255, 255])
        #expect(patch.header.rect == PixelRect(x: 256, y: 512, width: 1, height: 1))
    }
}
