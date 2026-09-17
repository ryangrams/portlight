import Foundation

/// Failures of the file-backed stores that the app reports to the user.
public enum PersistenceError: Error, Equatable, Sendable, LocalizedError {
    /// The existing file (named here) has not been read successfully, so it was not replaced: it may still hold
    /// saved data that is merely unavailable, for example before the first unlock after a restart.
    case existingFileNotLoaded(String)
    /// The file (named here) was written by a newer version of Portlight. It is never replaced or moved aside, so
    /// its data is still there once the app is updated again (for example after going back to an older test build).
    case savedByNewerVersion(String)

    public var errorDescription: String? {
        switch self {
        case .existingFileNotLoaded:
            return "Portlight couldn't open its saved data, so it didn't overwrite it. Unlock this iPhone, reopen Portlight, and try again."
        case .savedByNewerVersion:
            return "A newer version of Portlight saved this data, so this version didn't change it. Update Portlight, then try again."
        }
    }
}

/// File mechanics shared by `ProfileStore` and `FileTrustStore`. Callers hold their own lock around every call.
enum PersistenceFiles {
    enum ReadResult {
        case missing
        case data(Data)
        /// Present but not readable (I/O or data-protection failure). Never treated as corrupt.
        case unreadable(Error)
    }

    static func read(_ url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return .missing }
        do {
            return .data(try Data(contentsOf: url))
        } catch {
            return .unreadable(error)
        }
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Writes via a temporary file and rename, so a crash leaves either the old or the new file, never half of one.
    /// On iOS the file and a newly created directory get `protection`.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: directoryAttributes)
        try data.write(to: url, options: writeOptions)
    }

    /// iOS protection class of the stores' files and directory: readable after the first unlock, because the app
    /// may reconnect while the phone is locked. Nil where the platform has none to set (macOS).
    static var protection: FileProtectionType? {
        #if os(iOS)
        return .completeUntilFirstUserAuthentication
        #else
        return nil
        #endif
    }

    static var writeOptions: Data.WritingOptions {
        protection == nil ? [.atomic] : [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    }

    static var directoryAttributes: [FileAttributeKey: Any]? {
        protection.map { [.protectionKey: $0] }
    }

    /// The `schemaVersion` of a JSON object, read before anything else so that a file from a newer version is
    /// recognised as such instead of as damage. Nil when it is missing or not an integer.
    static func schemaVersion(of data: Data) -> Int? {
        (try? makeDecoder().decode(SchemaHeader.self, from: data))?.schemaVersion
    }

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int?
    }

    /// Moves an undecodable file aside as `<name>.corrupt-<UTC timestamp>[-n].<ext>` so it is never lost or
    /// overwritten, and returns the new location.
    static func quarantine(_ url: URL, at date: Date) throws -> URL {
        let aside = try asideURL(for: url, at: date)
        try FileManager.default.moveItem(at: url, to: aside)
        return aside
    }

    /// Copies a file aside under the same naming as `quarantine`, leaving the original in place until a repaired
    /// version replaces it atomically, and returns the copy.
    static func copyAside(_ url: URL, at date: Date) throws -> URL {
        let aside = try asideURL(for: url, at: date)
        try FileManager.default.copyItem(at: url, to: aside)
        return aside
    }

    private static func asideURL(for url: URL, at date: Date) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        let base = "\(stem).corrupt-\(timestamp(date))"
        for attempt in 1...1000 {
            let name = attempt == 1 ? base + suffix : "\(base)-\(attempt)\(suffix)"
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if !exists(candidate) { return candidate }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Filesystem-safe UTC timestamp, e.g. `20260910T221530Z`.
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Sorted, pretty-printed JSON. Dates stay Foundation's own reference-date seconds: converting to 1970-based
    /// seconds and back can change the last bit, which would make a reloaded library differ from the saved one.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}

/// One element of a saved array or dictionary that decodes to nil instead of failing its whole container, so
/// one damaged item can't make every other one unreadable.
struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
