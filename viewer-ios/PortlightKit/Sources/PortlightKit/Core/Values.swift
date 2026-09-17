import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Core value types shared by every PortlightKit module. Units are explicit in the type name:
// host logical points (LogicalRect/LogicalPoint), negotiated stream pixels (PixelSize/PixelRect),
// and normalized full-display coordinates (NormalizedRect, pointer x/y).

/// Opaque host display identifier. Never a monitor index.
public typealias DisplayID = String

/// A point in host logical points (or in the viewer's compact desktop, which uses the same unit).
public struct LogicalPoint: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = LogicalPoint(x: 0, y: 0)
}

/// A rectangle in host logical points, y down. Host origins may be negative.
public struct LogicalRect: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var origin: LogicalPoint { LogicalPoint(x: x, y: y) }
    public var center: LogicalPoint { LogicalPoint(x: midX, y: midY) }
    public var isEmpty: Bool { !(width > 0 && height > 0) }
    /// Half-open containment: [minX, maxX) × [minY, maxY).
    public func contains(_ point: LogicalPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
    public func intersection(_ other: LogicalRect) -> LogicalRect? {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return LogicalRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    public func union(_ other: LogicalRect) -> LogicalRect {
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        return LogicalRect(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }
    public func offsetBy(dx: Double, dy: Double) -> LogicalRect {
        LogicalRect(x: x + dx, y: y + dy, width: width, height: height)
    }
}

/// A rectangle normalized to one display's full source image, each component in 0...1.
public struct NormalizedRect: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
    /// Explicit "nothing visible" region for an offscreen selected display.
    public static let zero = NormalizedRect(x: 0, y: 0, width: 0, height: 0)
    public var isZero: Bool { width == 0 && height == 0 }
    public var isFull: Bool { x == 0 && y == 0 && width == 1 && height == 1 }
    /// Host contract: finite, non-negative, width and height zero together, x+w ≤ 1 and y+h ≤ 1.
    public var isValid: Bool {
        [x, y, width, height].allSatisfy { $0.isFinite && $0 >= 0 }
            && (width == 0) == (height == 0) && x + width <= 1 && y + height <= 1
    }
}

/// Integer size of a negotiated stream canvas (stream pixels, not host points or phone pixels).
public struct PixelSize: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var pixelCount: Int { width * height }
    public var isPortrait: Bool { height > width }
    public var description: String { "\(width)×\(height)" }
}

/// Integer rectangle in stream-canvas pixels, top-left origin.
public struct PixelRect: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var pixelCount: Int { width * height }
    /// Non-empty and fully inside `canvas`, with overflow-safe comparisons (no `x + width`).
    public func fits(in canvas: PixelSize) -> Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0
            && width <= canvas.width && height <= canvas.height
            && x <= canvas.width - width && y <= canvas.height - height
    }
    public var description: String { "(\(x),\(y) \(width)×\(height))" }
}

/// One display advertised by the host, in its real logical arrangement.
public struct HostDisplay: Equatable, Hashable, Sendable, Identifiable {
    public let id: DisplayID
    public let name: String
    /// 1-based position in the host's advertised list. Labels only; never identity.
    public let number: Int
    /// Native capture pixels.
    public let nativeSize: PixelSize
    /// Frame in host global logical points.
    public let logicalFrame: LogicalRect
    /// Native pixels per logical point.
    public let scale: Double
    public let isPrimary: Bool
    public init(id: DisplayID, name: String, number: Int, nativeSize: PixelSize, logicalFrame: LogicalRect, scale: Double, isPrimary: Bool) {
        self.id = id; self.name = name; self.number = number; self.nativeSize = nativeSize
        self.logicalFrame = logicalFrame; self.scale = scale; self.isPrimary = isPrimary
    }
    public var label: String { "\(number) · \(name)" }
}

/// The four stream-resolution ceilings offered in the UI. Wire: maxWidth × maxHeight of `box`.
public enum ResolutionPreset: String, CaseIterable, Sendable, Codable, Comparable {
    case hd, fhd, qhd, uhd
    public var box: PixelSize {
        switch self {
        case .hd: return PixelSize(width: 1280, height: 720)
        case .fhd: return PixelSize(width: 1920, height: 1080)
        case .qhd: return PixelSize(width: 2560, height: 1440)
        case .uhd: return PixelSize(width: 3840, height: 2160)
        }
    }
    public var title: String {
        switch self { case .hd: return "HD"; case .fhd: return "FHD"; case .qhd: return "QHD"; case .uhd: return "UHD" }
    }
    public var detail: String {
        switch self { case .hd: return "720p"; case .fhd: return "1080p"; case .qhd: return "1440p"; case .uhd: return "2160p" }
    }
    /// Side of the N×N grid motif used by the resolution buttons.
    public var gridSide: Int {
        switch self { case .hd: return 2; case .fhd: return 3; case .qhd: return 4; case .uhd: return 5 }
    }
    /// Host rule (`commonResolution`): long side ≥ box width and short side ≥ box height.
    public func isSupported(byNative native: PixelSize) -> Bool {
        max(native.width, native.height) >= box.width && min(native.width, native.height) >= box.height
    }
    /// Host rule (`scaledSize`): aspect-fit into the box (axes swapped for portrait), never upscale,
    /// truncating like the host. Prediction only; allocation always uses the `subscribed` sizes.
    public func streamSize(forNative native: PixelSize) -> PixelSize {
        guard native.width > 0, native.height > 0 else { return PixelSize(width: 1, height: 1) }
        let cap = native.isPortrait ? (box.height, box.width) : (box.width, box.height)
        let scale = min(1.0, min(Double(cap.0) / Double(native.width), Double(cap.1) / Double(native.height)))
        return PixelSize(width: max(1, Int(Double(native.width) * scale)), height: max(1, Int(Double(native.height) * scale)))
    }
    public static func < (a: ResolutionPreset, b: ResolutionPreset) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// The resolution the host actually applied, from `subscribed.resolution`.
public enum EffectiveResolution: Equatable, Sendable {
    case native
    case preset(ResolutionPreset)
    public init?(wire: String) {
        if wire == "native" { self = .native } else if let p = ResolutionPreset(rawValue: wire) { self = .preset(p) } else { return nil }
    }
}

/// Exactly the three color choices exposed on iPhone (legacy `rgb565` is never offered).
public enum ColorMode: String, CaseIterable, Sendable, Codable {
    case full, color256, gray16
    public var title: String {
        switch self { case .full: return "Full Color"; case .color256: return "256 Colors"; case .gray16: return "16 Shades of Gray" }
    }
}

/// Content priority. Wire values are the host's quality names.
public enum ContentPriority: String, CaseIterable, Sendable, Codable {
    case automatic = "auto"
    case text = "desktop"
    case video = "motion"
    public var title: String {
        switch self { case .automatic: return "Automatic"; case .text: return "Text"; case .video: return "Video" }
    }
}

public enum ImageCodec: String, Sendable, CaseIterable {
    case png, jpeg
}

public enum AudioCodec: String, Sendable, Codable, CaseIterable {
    case aac, mulaw
}

/// Audio data rates the host accepts. 48 kbps is mono AAC; the rest are stereo AAC.
public enum AudioQuality: Int, CaseIterable, Sendable, Codable {
    case mono48 = 48000
    case stereo96 = 96000
    case stereo160 = 160000
    case stereo320 = 320000
    public var title: String {
        switch self {
        case .mono48: return "Mono 48 kbps"; case .stereo96: return "Stereo 96 kbps"
        case .stereo160: return "Stereo 160 kbps"; case .stereo320: return "Stereo 320 kbps"
        }
    }
    public var channels: Int { self == .mono48 ? 1 : 2 }
}

/// Host capabilities from `welcome`. Unknown values are kept as strings where the UI doesn't act on them.
public struct HostCapabilities: Equatable, Sendable {
    public var imageCodecs: [String]
    public var audioCodecs: [AudioCodec]
    public var colorModes: [String]
    public var maxViewers: Int?
    public init(imageCodecs: [String], audioCodecs: [AudioCodec], colorModes: [String], maxViewers: Int?) {
        self.imageCodecs = imageCodecs; self.audioCodecs = audioCodecs; self.colorModes = colorModes; self.maxViewers = maxViewers
    }
    public var supportsAudio: Bool { !audioCodecs.isEmpty }
    /// AAC when advertised, else μ-law, else no audio.
    public var preferredAudioCodec: AudioCodec? {
        audioCodecs.contains(.aac) ? .aac : (audioCodecs.contains(.mulaw) ? .mulaw : nil)
    }
}

/// A validated `host:port`. IPv6 literals are stored without brackets; `canonicalKey` binds trust pins.
public struct HostEndpoint: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let host: String
    public let port: Int
    public init?(host rawHost: String, port: Int) {
        var candidate = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("[") && candidate.hasSuffix("]") { candidate = String(candidate.dropFirst().dropLast()) }
        guard !candidate.isEmpty, candidate.utf8.count <= 253, (1...65535).contains(port),
              candidate.rangeOfCharacter(from: HostEndpoint.forbidden) == nil else { return nil }
        if candidate.contains(":") && !HostEndpoint.isIPv6Literal(candidate) { return nil }
        host = candidate
        self.port = port
    }
    private static let forbidden = CharacterSet(charactersIn: "/@?#[]%\\ \t\r\n").union(.controlCharacters)
    private static func isIPv6Literal(_ value: String) -> Bool {
        var address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
    public var isIPv6: Bool { host.contains(":") }
    /// Lowercased identity used for trust pins: `host:port` or `[v6]:port`.
    public var canonicalKey: String {
        let lower = host.lowercased()
        return isIPv6 ? "[\(lower)]:\(port)" : "\(lower):\(port)"
    }
    public var description: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }
    /// `wss://host:port/remote`, built with URLComponents (never string concatenation).
    public var webSocketURL: URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = isIPv6 ? "[\(host)]" : host
        components.port = port
        components.path = PortlightProtocol.path
        return components.url
    }
}

/// SHA-256 over the leaf certificate DER, as 32 uppercase hex pairs joined by ":" (the host's format).
public struct CertificateFingerprint: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String
    public init<Digest: Sequence>(digest: Digest) where Digest.Element == UInt8 {
        value = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    /// Accepts the host format, or 64 hex digits with or without separators, in either case.
    public init?(string: String) {
        let hex = string.uppercased().filter { !":- ".contains($0) }
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var pairs: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            pairs.append(String(hex[index..<next])); index = next
        }
        value = pairs.joined(separator: ":")
    }
    public var description: String { value }
    /// Four lines of eight pairs, for readable comparison in the trust sheet.
    public var lines: [String] {
        let pairs = value.split(separator: ":")
        return stride(from: 0, to: pairs.count, by: 8).map { pairs[$0..<min($0 + 8, pairs.count)].joined(separator: " ") }
    }
}

/// Identity of one connection attempt. Every async result carries one and is dropped when stale.
public struct ConnectionGeneration: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let none = ConnectionGeneration(rawValue: 0)
    public func next() -> ConnectionGeneration { ConnectionGeneration(rawValue: rawValue &+ 1) }
    public static func < (a: ConnectionGeneration, b: ConnectionGeneration) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "gen\(rawValue)" }
}

/// Mouse button mask on the wire: left = 1, right = 2, middle = 4.
public struct MouseButtons: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = MouseButtons(rawValue: 1)
    public static let right = MouseButtons(rawValue: 2)
    public static let middle = MouseButtons(rawValue: 4)
}
