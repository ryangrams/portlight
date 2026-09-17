import Foundation
import CoreGraphics
import ImageIO
@testable import PortlightKit

// Real-component helpers for RENDER-02: host-style PNG/JPEG tiles with the exact pixels they must decode to,
// the production `ImageTileDecoder` behind `TileDecoding`, a recording `SoftwareFramebuffer`, and a CPU golden
// model. Foundation-typed, so they live apart from the @Test file. Self-contained on purpose: nothing here
// depends on another module's test fixtures.

/// Deterministic SplitMix64 (fixed seeds only).
struct EngineRandom {
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

/// Session-wide sequence numbers shared by images and audio; gaps are normal.
struct EngineSequencer {
    private(set) var last = 0
    mutating func next(skipping gap: Bool = false) -> Int {
        last += gap ? 2 : 1
        return last
    }
}

/// Encodes images the way the host's TileEncoder does: the same layouts and color spaces, CGImageDestination.
enum EngineTileEncoder {
    /// color256 palette entry i = ((i>>5)·255/7, ((i>>2)&7)·255/7, (i&3)·255/3), integer math.
    static let palette: [UInt8] = {
        var table: [UInt8] = []
        for i in 0..<256 {
            let red: Int = (i >> 5) * 255 / 7, green: Int = ((i >> 2) & 7) * 255 / 7, blue: Int = (i & 3) * 255 / 3
            table += [UInt8(red), UInt8(green), UInt8(blue)]
        }
        return table
    }()

    /// DeviceRGB, 8 bpc, 32 bpp `noneSkipLast` (R, G, B, X).
    static func rgbImage(width: Int, height: Int, rgbx: [UInt8]) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: CGDataProvider(data: Data(rgbx) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// 4-bit DeviceGray: two samples per byte, the first pixel in the high nibble.
    static func grayImage(width: Int, height: Int, nibbles: [UInt8]) -> CGImage {
        let rowBytes = (width + 1) / 2
        var packed = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = nibbles[y * width + x] & 15
                packed[y * rowBytes + x / 2] |= x % 2 == 0 ? value << 4 : value
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 4, bitsPerPixel: 4, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: CGDataProvider(data: Data(packed) as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// 8-bit indexed over DeviceRGB with the host palette.
    static func indexedImage(width: Int, height: Int, indices: [UInt8]) -> CGImage {
        let space = CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 255, colorTable: palette)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: space,
                       bitmapInfo: [], provider: CGDataProvider(data: Data(indices) as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// PNG, or JPEG at the host's quality 0.7.
    static func encode(_ image: CGImage, as codec: ImageCodec) -> Data {
        let data = NSMutableData()
        let type = (codec == .png ? "public.png" : "public.jpeg") as CFString
        let destination = CGImageDestinationCreateWithData(data, type, 1, nil)!
        let properties: [CFString: Any] = codec == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.7] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// One encoded tile and the BGRA pixels (tightly packed rows, alpha 255) it must decode to.
struct EngineTile {
    enum Kind: CaseIterable { case rgb, gray16, color256, jpeg }
    let display: DisplayID
    let rect: PixelRect
    let codec: ImageCodec
    let payload: Data
    let bgra: [UInt8]

    /// Random content of `kind`: full-color PNG, 4-bit gray PNG, 8-bit indexed PNG, or JPEG.
    static func random(_ kind: Kind, display: DisplayID, rect: PixelRect, using random: inout EngineRandom) -> EngineTile {
        let count = rect.pixelCount
        var bgra = [UInt8](repeating: 255, count: count * 4)
        switch kind {
        case .rgb, .jpeg:
            var rgbx = [UInt8](repeating: 0, count: count * 4)
            for index in 0..<count {
                let r = random.byte(), g = random.byte(), b = random.byte()
                rgbx[index * 4] = r; rgbx[index * 4 + 1] = g; rgbx[index * 4 + 2] = b
                bgra[index * 4] = b; bgra[index * 4 + 1] = g; bgra[index * 4 + 2] = r
            }
            let codec: ImageCodec = kind == .rgb ? .png : .jpeg
            let payload = EngineTileEncoder.encode(EngineTileEncoder.rgbImage(width: rect.width, height: rect.height, rgbx: rgbx), as: codec)
            // JPEG is lossy: expect the decoder's own deterministic output for exactly these bytes.
            let expected = kind == .jpeg ? decodedPixels(payload, codec: .jpeg, rect: rect) : bgra
            return EngineTile(display: display, rect: rect, codec: codec, payload: payload, bgra: expected)
        case .gray16:
            var nibbles = [UInt8](repeating: 0, count: count)
            for index in 0..<count {
                let nibble = random.byte() & 15, value = nibble * 17 // PNG bit-depth scaling
                nibbles[index] = nibble
                bgra[index * 4] = value; bgra[index * 4 + 1] = value; bgra[index * 4 + 2] = value
            }
            let image = EngineTileEncoder.grayImage(width: rect.width, height: rect.height, nibbles: nibbles)
            return EngineTile(display: display, rect: rect, codec: .png, payload: EngineTileEncoder.encode(image, as: .png), bgra: bgra)
        case .color256:
            var indices = [UInt8](repeating: 0, count: count)
            let palette = EngineTileEncoder.palette
            for index in 0..<count {
                let entry = random.byte(), at = Int(entry) * 3
                indices[index] = entry
                bgra[index * 4] = palette[at + 2]; bgra[index * 4 + 1] = palette[at + 1]; bgra[index * 4 + 2] = palette[at]
            }
            let image = EngineTileEncoder.indexedImage(width: rect.width, height: rect.height, indices: indices)
            return EngineTile(display: display, rect: rect, codec: .png, payload: EngineTileEncoder.encode(image, as: .png), bgra: bgra)
        }
    }

    /// A smooth full-canvas keyframe (it compresses like a desktop), full-color PNG.
    static func keyframe(display: DisplayID, canvas: PixelSize, seed: Int) -> EngineTile {
        let width = canvas.width, height = canvas.height
        var rgbx = [UInt8](repeating: 0, count: canvas.pixelCount * 4)
        var bgra = [UInt8](repeating: 255, count: canvas.pixelCount * 4)
        rgbx.withUnsafeMutableBufferPointer { rgbx in
            bgra.withUnsafeMutableBufferPointer { bgra in
                for y in 0..<height {
                    for x in 0..<width {
                        let at = (y * width + x) * 4
                        let r = UInt8(truncatingIfNeeded: x * 255 / max(1, width - 1) + seed)
                        let g = UInt8(truncatingIfNeeded: y * 255 / max(1, height - 1) + seed * 3)
                        let b = UInt8(truncatingIfNeeded: (x / 32 + y / 32) * 11 + seed * 5)
                        rgbx[at] = r; rgbx[at + 1] = g; rgbx[at + 2] = b
                        bgra[at] = b; bgra[at + 1] = g; bgra[at + 2] = r
                    }
                }
            }
        }
        let image = EngineTileEncoder.rgbImage(width: width, height: height, rgbx: rgbx)
        return EngineTile(display: display, rect: PixelRect(x: 0, y: 0, width: width, height: height), codec: .png,
                          payload: EngineTileEncoder.encode(image, as: .png), bgra: bgra)
    }

    /// The same tile with one byte flipped mid-payload, so a PNG chunk CRC no longer matches.
    func corrupted() -> EngineTile {
        var broken = payload
        broken[broken.startIndex + broken.count / 2] ^= 0xFF
        return EngineTile(display: display, rect: rect, codec: codec, payload: broken, bgra: bgra)
    }

    /// The pixels the production decoder produces for `payload`.
    static func decodedPixels(_ payload: Data, codec: ImageCodec, rect: PixelRect) -> [UInt8] {
        let header = FrameHeader(revision: 1, display: "decode", rect: rect,
                                 canvas: PixelSize(width: rect.maxX, height: rect.maxY), codec: codec, sequence: 0)
        let patch = try! ImageTileDecoder.decode(header: header, payload: payload) { HeapPatchBuffer(byteCount: $0) }
        return Array(UnsafeRawBufferPointer(start: patch.buffer.contents, count: rect.pixelCount * 4))
    }
}

/// CPU model of one display's picture: opaque black, then the accepted patches applied in order.
struct EngineGoldenCanvas {
    let size: PixelSize
    private(set) var pixels: [UInt8]

    init(size: PixelSize) {
        self.size = size
        var pixels = [UInt8](repeating: 0, count: size.pixelCount * 4)
        pixels.withUnsafeMutableBufferPointer { bytes in
            for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        }
        self.pixels = pixels
    }

    mutating func apply(_ tile: EngineTile) {
        let rowBytes = tile.rect.width * 4
        for row in 0..<tile.rect.height {
            let start = ((tile.rect.y + row) * size.width + tile.rect.x) * 4
            pixels.replaceSubrange(start..<start + rowBytes, with: tile.bgra[row * rowBytes..<(row + 1) * rowBytes])
        }
    }

    /// nil when `snapshot` matches byte for byte; otherwise where it first differs.
    func mismatch(_ snapshot: (PixelSize, [UInt8])?) -> String? {
        guard let (shownSize, bytes) = snapshot else { return "no shown surface" }
        guard shownSize == size else { return "shown \(shownSize), expected \(size)" }
        guard bytes.count == pixels.count else { return "\(bytes.count) bytes, expected \(pixels.count)" }
        if bytes == pixels { return nil }
        let index = bytes.indices.first { bytes[$0] != pixels[$0] } ?? 0
        let pixel = index / 4
        return "first difference at (\(pixel % size.width), \(pixel / size.width)) byte \(index % 4): \(bytes[index]), expected \(pixels[index])"
    }
}

/// The production decoder behind `TileDecoding`. It can park the decode of one sequence (before any work) so a
/// test can accept a newer revision while that patch is mid-decode.
final class EngineImageDecoder: TileDecoding, @unchecked Sendable {
    // Invariant: `heldSequence` is only touched while holding `lock`; waiting happens outside it.
    private let lock = NSLock()
    private var heldSequence: Int?
    private let started = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func hold(sequence: Int) { lock.withLock { heldSequence = sequence } }
    /// Bounded wait until the held decode has parked; not a sleep.
    func waitUntilHeld() -> Bool { started.wait(timeout: .now() + 5) == .success }
    func release() {
        lock.withLock { heldSequence = nil }
        resume.signal()
    }

    func decode(_ header: FrameHeader, payload: Data, allocate: (Int) -> PatchBuffer?) throws -> DecodedPatch {
        if lock.withLock({ heldSequence == header.sequence }) {
            started.signal()
            _ = resume.wait(timeout: .now() + 5)
        }
        return try ImageTileDecoder.decode(header: header, payload: payload, allocate: allocate)
    }
}

/// `SoftwareFramebuffer` plus an ordered record of what the engine asked of it and what it answered.
final class EngineRecordingFramebuffer: FramebufferSink, @unchecked Sendable {
    // Invariant: `storage` is only touched while holding `lock`. The engine calls acceptRevision and commit under
    // its commit gate, so the recorded order is the order in which they took effect.
    enum Event: Equatable {
        case accept(revision: Int)
        case commit(sequence: Int, PatchCommitResult)
    }
    let software: SoftwareFramebuffer
    private let log: EventLog
    private let lock = NSLock()
    private var storage: [Event] = []

    init(log: EventLog, patchByteLimit: Int) {
        software = SoftwareFramebuffer(patchByteLimit: patchByteLimit)
        self.log = log
    }

    var events: [Event] { lock.withLock { storage } }
    /// Sequences whose commit returned `result`, in commit order.
    func sequences(_ result: PatchCommitResult) -> [Int] {
        events.compactMap { event in
            if case .commit(let sequence, let outcome) = event, outcome == result { return sequence }
            return nil
        }
    }

    func acceptRevision(_ revision: Int, canvases: [DisplayID: PixelSize], requestedRegions: [DisplayID: NormalizedRect]) {
        software.acceptRevision(revision, canvases: canvases, requestedRegions: requestedRegions)
        lock.withLock { storage.append(.accept(revision: revision)) }
        log.append(.accept(revision: revision))
    }
    func makePatchBuffer(byteCount: Int) -> PatchBuffer? { software.makePatchBuffer(byteCount: byteCount) }
    func commit(_ patch: DecodedPatch) -> PatchCommitResult {
        let result = software.commit(patch)
        lock.withLock { storage.append(.commit(sequence: patch.header.sequence, result)) }
        if result == .committed { log.append(.commit(revision: patch.header.revision, sequence: patch.header.sequence)) }
        return result
    }
    func hasValidPixels(display: DisplayID, x: Double, y: Double) -> Bool { software.hasValidPixels(display: display, x: x, y: y) }
    func removeAll() { software.removeAll() }
}

/// One engine on the production decoder and the software framebuffer, with a fake transport, clock and audio.
final class EngineRealPipeline {
    let log: EventLog
    let framebuffer: EngineRecordingFramebuffer
    let decoder: EngineImageDecoder
    let audio: FakeAudioSink
    let delegate: RecordingDelegate
    let registry: TransportRegistry
    let delegateQueue: DispatchQueue
    let engine: SessionEngine

    init(patchByteLimit: Int = 64 * 1024 * 1024) {
        let log = EventLog(), registry = TransportRegistry(log: log)
        let framebuffer = EngineRecordingFramebuffer(log: log, patchByteLimit: patchByteLimit)
        let decoder = EngineImageDecoder(), audio = FakeAudioSink(), delegate = RecordingDelegate()
        let delegateQueue = DispatchQueue(label: "test.engine.real.delegate")
        let engine = SessionEngine(transportFactory: { registry.make() }, clock: ManualClock(), framebuffer: framebuffer,
                                   audio: audio, decoder: decoder, delegateQueue: delegateQueue)
        delegateQueue.sync { engine.delegate = delegate }
        self.log = log; self.framebuffer = framebuffer; self.decoder = decoder; self.audio = audio
        self.delegate = delegate; self.registry = registry; self.delegateQueue = delegateQueue; self.engine = engine
    }

    var transport: FakeTransport { registry.all.last! }
    var software: SoftwareFramebuffer { framebuffer.software }
    var diagnostics: EngineDiagnostics { engine.diagnosticsForTesting }

    func drain() {
        engine.drainForTesting()
        delegateQueue.sync {}
    }
    /// Engine and delegate queues only: safe while a decode is parked.
    func syncEngine() {
        engine.queue.sync {}
        delegateQueue.sync {}
    }

    /// Connect → trusted open → welcome, as a reconnect that keeps `displays`; revision 1 goes out.
    func connect(displays: [DisplayID]) {
        engine.connect(ConnectRequest(endpoint: Fixture.endpoint, pin: Fixture.pin, password: Fixture.password,
                                      planner: FakePlanner(), previousSelection: displays))
        drain()
        transport.emit(.identityVerified(Fixture.pin))
        transport.emit(.opened)
        transport.emit(.welcome(Fixture.welcome))
        drain()
    }
    /// Resubmits the newest request with `change` applied, then drains.
    func submit(force: Bool = false, _ change: (inout SubscriptionRequest) -> Void = { _ in }) {
        var request = transport.subscribes.last!
        change(&request)
        engine.submit(request, force: force)
        drain()
    }
    /// The host's `subscribed` for the newest sent revision with these canvases. Not drained: a decode may be parked.
    func acknowledge(_ canvases: [DisplayID: PixelSize]) {
        let request = transport.subscribes.last!
        transport.emit(.subscribed(SubscribedMessage(
            revision: request.revision, canvases: request.displays.map { .init(display: $0, size: canvases[$0]!) },
            paused: request.paused, audio: false, audioCodec: nil, audioBitrate: nil,
            resolution: .preset(request.resolution), notice: nil)))
    }
    func send(_ tile: EngineTile, revision: Int, sequence: Int, canvas: PixelSize) {
        transport.emit(.frame(FrameHeader(revision: revision, display: tile.display, rect: tile.rect, canvas: canvas,
                                          codec: tile.codec, sequence: sequence), payload: tile.payload))
    }
}
