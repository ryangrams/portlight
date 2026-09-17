import Foundation

// Exact certificate pins keyed by `HostEndpoint.canonicalKey` (lowercased host, bracketed IPv6, port).
// Pins change only through `pin(_:for:)` and `removePin(for:)`; lookups never write, migrate or repair.

/// A pin lookup that can also say "can't tell right now". Persistence-local until the Core `TrustStore` seam has
/// a tri-state lookup; the engine can use it through `TrustLookupStore`.
public enum TrustLookup: Equatable, Sendable {
    /// Trusted with exactly this fingerprint.
    case pinned(CertificateFingerprint)
    /// Never approved (or the pin file was damaged): ask the user as for a first connection.
    case notPinned
    /// Pins exist but can't be used now: unreadable (for example before the first unlock) or saved by a newer
    /// Portlight. An approval couldn't be saved either, so fail the attempt with the error's message instead of
    /// asking the user to trust the computer, which would only ask again on the next attempt.
    case unavailable(PersistenceError)

    /// The pinned fingerprint, or nil: what `TrustStore.pinnedFingerprint(for:)` reports.
    public var fingerprint: CertificateFingerprint? {
        if case .pinned(let fingerprint) = self { return fingerprint }
        return nil
    }
}

/// A `TrustStore` that can tell "not pinned" from "can't tell" (`TrustLookup`). Both stores here conform.
public protocol TrustLookupStore: TrustStore {
    func lookUpPin(for endpoint: HostEndpoint) -> TrustLookup
}

/// Production `TrustStore`: one small JSON file of pins beside the saved connections.
///
/// Nothing is cached. Every lookup reads the file and every change is a read-modify-write, under one lock shared
/// by all instances, so a pin removed through one instance (a trusted-computers screen) is gone for another (the
/// session engine) and two instances' changes never overwrite each other.
///
/// A file that can't be decoded reads as "no pins" (the next connection asks for approval again, which is the
/// safe direction) and is moved aside, not overwritten, on the next pin. A file that can't be read, or that a
/// newer Portlight wrote, is never replaced: lookups report `.unavailable` and changes throw.
public final class FileTrustStore: TrustLookupStore, @unchecked Sendable {
    // Invariant for @unchecked Sendable: every stored property is immutable, and all file access happens while
    // `FileTrustStore.fileLock` is held.

    public static let fileName = "TrustedComputers.json"
    static let schemaVersion = 1
    /// Shared by every instance, so one instance's read-modify-write can't interleave with another's.
    private static let fileLock = NSLock()

    public let fileURL: URL
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - directory: Production passes `ProfileStore.defaultDirectory()`.
    ///   - now: Clock for the quarantine timestamp of a corrupt file.
    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.now = now
    }

    /// Nil also when the file can't be used; `lookUpPin(for:)` tells the two apart.
    public func pinnedFingerprint(for endpoint: HostEndpoint) -> CertificateFingerprint? {
        lookUpPin(for: endpoint).fingerprint
    }

    public func lookUpPin(for endpoint: HostEndpoint) -> TrustLookup {
        Self.fileLock.withLock {
            switch readPins() {
            case .unavailable(let error):
                return .unavailable(error)
            case .pins(let pins, _):
                return pins[endpoint.canonicalKey].map(TrustLookup.pinned) ?? .notPinned
            }
        }
    }

    /// Saves (or replaces) the exact pin for this endpoint. Call only after the user approved this fingerprint.
    public func pin(_ fingerprint: CertificateFingerprint, for endpoint: HostEndpoint) throws {
        try Self.fileLock.withLock {
            switch readPins() {
            case .unavailable(let error):
                throw error
            case .pins(var pins, let isCorrupt):
                // A damaged file is kept beside the new one, never overwritten.
                if isCorrupt { _ = try PersistenceFiles.quarantine(fileURL, at: now()) }
                pins[endpoint.canonicalKey] = fingerprint
                try write(pins)
            }
        }
    }

    /// Idempotent: removing a missing pin changes nothing.
    public func removePin(for endpoint: HostEndpoint) throws {
        try Self.fileLock.withLock {
            switch readPins() {
            case .unavailable(let error):
                throw error
            case .pins(var pins, _):
                // A damaged file holds no usable pins, so it is left for the next `pin` to move aside.
                guard pins.removeValue(forKey: endpoint.canonicalKey) != nil else { return }
                try write(pins)
            }
        }
    }

    /// Every pin by canonical key (for a "trusted computers" list); empty when the file can't be used.
    public var pins: [String: CertificateFingerprint] {
        Self.fileLock.withLock {
            if case .pins(let pins, _) = readPins() { return pins }
            return [:]
        }
    }

    private struct TrustFile: Encodable {
        var schemaVersion: Int
        var pins: [String: String]
    }

    /// The decoding side of `TrustFile`, where one malformed pin is dropped instead of failing the file.
    private struct LossyTrustFile: Decodable {
        var schemaVersion: Int
        var pins: [String: LossyDecodable<String>]
    }

    private enum Contents {
        /// Pins by canonical key. `isCorrupt`: the file exists but couldn't be decoded, so it reads as no pins.
        case pins([String: CertificateFingerprint], isCorrupt: Bool)
        case unavailable(PersistenceError)
    }

    /// Reads the file afresh. Called with `fileLock` held.
    private func readPins() -> Contents {
        switch PersistenceFiles.read(fileURL) {
        case .missing:
            return .pins([:], isCorrupt: false)
        case .unreadable:
            return .unavailable(.existingFileNotLoaded(Self.fileName))
        case .data(let data):
            if let version = PersistenceFiles.schemaVersion(of: data), version > Self.schemaVersion {
                return .unavailable(.savedByNewerVersion(Self.fileName))
            }
            guard let file = try? PersistenceFiles.makeDecoder().decode(LossyTrustFile.self, from: data),
                  file.schemaVersion == Self.schemaVersion else { return .pins([:], isCorrupt: true) }
            var pins: [String: CertificateFingerprint] = [:]
            // A malformed pin is dropped: that computer simply needs approval again.
            for (key, value) in file.pins {
                if let text = value.value, let fingerprint = CertificateFingerprint(string: text) { pins[key] = fingerprint }
            }
            return .pins(pins, isCorrupt: false)
        }
    }

    private func write(_ pins: [String: CertificateFingerprint]) throws {
        let file = TrustFile(schemaVersion: Self.schemaVersion, pins: pins.mapValues(\.value))
        try PersistenceFiles.writeAtomically(try PersistenceFiles.makeEncoder().encode(file), to: fileURL)
    }
}

/// Heap-backed `TrustStore` for previews and tests, with the same keying as `FileTrustStore`.
public final class InMemoryTrustStore: TrustLookupStore, @unchecked Sendable {
    // Invariant for @unchecked Sendable: `storage` is accessed only while `lock` is held.
    private let lock = NSLock()
    private var storage: [String: CertificateFingerprint]

    public init(pins: [HostEndpoint: CertificateFingerprint] = [:]) {
        storage = Dictionary(pins.map { ($0.key.canonicalKey, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    public func pinnedFingerprint(for endpoint: HostEndpoint) -> CertificateFingerprint? {
        lock.withLock { storage[endpoint.canonicalKey] }
    }

    public func lookUpPin(for endpoint: HostEndpoint) -> TrustLookup {
        pinnedFingerprint(for: endpoint).map(TrustLookup.pinned) ?? .notPinned
    }

    public func pin(_ fingerprint: CertificateFingerprint, for endpoint: HostEndpoint) throws {
        lock.withLock { storage[endpoint.canonicalKey] = fingerprint }
    }

    public func removePin(for endpoint: HostEndpoint) throws {
        _ = lock.withLock { storage.removeValue(forKey: endpoint.canonicalKey) }
    }

    /// Every pin by canonical key.
    public var pins: [String: CertificateFingerprint] { lock.withLock { storage } }
}
