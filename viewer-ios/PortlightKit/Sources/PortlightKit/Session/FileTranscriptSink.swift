import Foundation

/// Writes the engine's privacy-safe transcript (see `TranscriptSink`) to a file, one line per message, for
/// test evidence. Lines are appended in call order and flushed as written; embedded line breaks are escaped
/// so one record is always one line.
public final class FileTranscriptSink: TranscriptSink, @unchecked Sendable {
    // Invariant for @unchecked Sendable: `handle` and `count` are only touched while holding `lock`.
    public let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var count = 0

    /// Creates (or truncates) the file, creating its directory when needed.
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle?.close() }

    public func record(_ line: String) {
        let escaped = line.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        let data = Data((escaped + "\n").utf8)
        lock.withLock {
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
                count += 1
            } catch {
                // A full disk must not take the session down; evidence simply stops growing.
            }
        }
    }

    /// Lines written so far.
    public var lineCount: Int { lock.withLock { count } }

    /// Closes the file; later records are ignored.
    public func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }

    /// The lines of a transcript file.
    public static func lines(at url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
