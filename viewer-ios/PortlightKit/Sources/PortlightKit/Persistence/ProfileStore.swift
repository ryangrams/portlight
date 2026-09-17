import Foundation

/// Loads and saves the `ProfileLibrary` as one JSON file.
///
/// Thread-safe: every file operation happens while `lock` is held, so saves from any thread are serialized
/// and a load never observes a half-finished save.
///
/// Recovery rules:
/// - A file that can't be *decoded* is moved aside with a timestamp and an empty library is returned (the copy
///   is never lost).
/// - A file with some undecodable items loads without them. The original is copied aside first, then replaced
///   by the list without them.
/// - A file that can't be *read* — for example protected data before the first unlock — is left alone, and
///   `save` refuses to replace it until a later `load` succeeds.
/// - A file saved by a newer version of Portlight is never replaced or moved: `save` refuses, so updating the
///   app brings the connections back.
public final class ProfileStore: @unchecked Sendable {
    // Invariant for @unchecked Sendable: `state` and all file access are touched only while `lock` is held;
    // `directory` and `now` are immutable.

    public static let fileName = "Connections.json"

    public enum LoadOutcome: Equatable, Sendable {
        /// Read successfully, or no file yet (a new, empty library).
        case loaded
        /// The file couldn't be decoded. It was kept at `quarantinedFile` and an empty library was returned.
        case recovered(quarantinedFile: URL)
        /// `dropped` saved items couldn't be decoded and were left out; the rest loaded. The original file was
        /// copied to `quarantinedCopy` before the list without them replaced it.
        case partiallyRecovered(dropped: Int, quarantinedCopy: URL)
        /// The file exists but couldn't be read. Nothing was changed; load again later.
        case unavailable(reason: String)
        /// A newer version of Portlight saved the file (schema `schemaVersion`). It was left untouched and saving
        /// is refused, so the connections come back after updating.
        case newerVersion(schemaVersion: Int)

        /// Text for the connections screen, or nil when there is nothing to report.
        public var message: String? {
            switch self {
            case .loaded:
                return nil
            case .recovered(let file):
                return "Saved connections couldn't be read, so Portlight started a new list. The unreadable file was kept as \(file.lastPathComponent)."
            case .partiallyRecovered(let dropped, let file):
                let items = dropped == 1 ? "One saved item couldn't be read and was" : "\(dropped) saved items couldn't be read and were"
                return "\(items) left out. The original list was kept as \(file.lastPathComponent)."
            case .unavailable:
                return "Saved connections can't be opened right now. Unlock this iPhone, then reopen Portlight."
            case .newerVersion:
                return "A newer version of Portlight saved these connections. Update Portlight to open and change them."
            }
        }
    }

    public struct LoadResult: Equatable, Sendable {
        public var library: ProfileLibrary
        public var outcome: LoadOutcome
        public init(library: ProfileLibrary, outcome: LoadOutcome) {
            self.library = library
            self.outcome = outcome
        }
    }

    /// Whether `save` may replace an existing file.
    private enum FileState {
        /// Not read successfully: an existing file may hold data that is only unavailable.
        case notLoaded
        /// Read, repaired, or found missing.
        case loaded
        /// Written by a newer version: never replaced.
        case newerVersion
    }

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var state = FileState.notLoaded

    /// - Parameters:
    ///   - directory: Where the file lives. Production passes `ProfileStore.defaultDirectory()`; tests a temp directory.
    ///   - now: Clock for quarantine timestamps (injected for deterministic tests).
    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// `Application Support/Portlight` in the app's container (created if needed). Also used by `FileTrustStore`.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Portlight", isDirectory: true)
    }

    /// Never throws and never crashes on bad data; see `LoadOutcome`.
    public func load() -> LoadResult {
        lock.withLock {
            let url = fileURL
            switch PersistenceFiles.read(url) {
            case .missing:
                state = .loaded
                return LoadResult(library: ProfileLibrary(), outcome: .loaded)
            case .unreadable(let error):
                state = .notLoaded
                return LoadResult(library: ProfileLibrary(), outcome: .unavailable(reason: error.localizedDescription))
            case .data(let data):
                return load(data, from: url)
            }
        }
    }

    /// Atomically replaces the file. Throws `PersistenceError.existingFileNotLoaded` when a file exists that this
    /// store has not loaded successfully, so an unreadable library is never overwritten by an empty one, and
    /// `PersistenceError.savedByNewerVersion` when a newer version of Portlight wrote it.
    public func save(_ library: ProfileLibrary) throws {
        try lock.withLock {
            let url = fileURL
            if PersistenceFiles.exists(url) {
                switch state {
                case .loaded: break
                case .notLoaded: throw PersistenceError.existingFileNotLoaded(url.lastPathComponent)
                case .newerVersion: throw PersistenceError.savedByNewerVersion(url.lastPathComponent)
                }
            }
            try write(library, to: url)
            state = .loaded
        }
    }

    /// Decodes a file that was read. Called with `lock` held.
    private func load(_ data: Data, from url: URL) -> LoadResult {
        if let version = PersistenceFiles.schemaVersion(of: data), version > ProfileLibrary.currentSchemaVersion {
            state = .newerVersion
            return LoadResult(library: ProfileLibrary(), outcome: .newerVersion(schemaVersion: version))
        }
        guard let file = try? PersistenceFiles.makeDecoder().decode(ProfileLibraryFile.self, from: data) else {
            do {
                let aside = try PersistenceFiles.quarantine(url, at: now())
                state = .loaded
                return LoadResult(library: ProfileLibrary(), outcome: .recovered(quarantinedFile: aside))
            } catch {
                // Couldn't move it aside: keep it in place and protect it from being overwritten.
                state = .notLoaded
                return LoadResult(library: ProfileLibrary(), outcome: .unavailable(reason: error.localizedDescription))
            }
        }
        guard file.droppedElements > 0 else {
            state = .loaded
            return LoadResult(library: file.library, outcome: .loaded)
        }
        let copy: URL
        do {
            copy = try PersistenceFiles.copyAside(url, at: now())
        } catch {
            // Without a copy the dropped items would be lost on the next save: protect the original instead.
            state = .notLoaded
            return LoadResult(library: ProfileLibrary(), outcome: .unavailable(reason: error.localizedDescription))
        }
        state = .loaded
        // Replace the original now so the next load is clean and doesn't copy it again. If this fails, the original
        // stays in place until the next save; its copy is already safe.
        try? write(file.library, to: url)
        return LoadResult(library: file.library, outcome: .partiallyRecovered(dropped: file.droppedElements, quarantinedCopy: copy))
    }

    private func write(_ library: ProfileLibrary, to url: URL) throws {
        try PersistenceFiles.writeAtomically(try PersistenceFiles.makeEncoder().encode(library), to: url)
    }
}
