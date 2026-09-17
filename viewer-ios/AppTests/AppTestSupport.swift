import UIKit
import PortlightKit
@testable import Portlight

/// Helpers for the hosted app tests. This file doesn't import Testing; Foundation types come through UIKit, as in
/// the other hosted test files.
enum AppTestSupport {
    /// A fresh data directory and in-memory secrets, no transcript, the standard defaults.
    static func configuration() -> AppConfiguration {
        AppConfiguration(dataDirectory: temporaryDirectory(), usesTestStores: true, transcriptURL: nil, defaultsSuiteName: nil)
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("portlight-app-tests-" + UUID().uuidString, isDirectory: true)
    }

    static func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func text(at url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A form filled in as a user would for the fixture computer.
    static func draft(name: String = "Fixture", host: String = "127.0.0.1", port: Int = 5999, password: String = "",
                      remember: Bool = true) -> ConnectionDraft {
        var draft = ConnectionDraft()
        draft.name = name
        draft.host = host
        draft.port = String(port)
        draft.password = password
        draft.rememberPassword = remember
        return draft
    }

    /// A 1206 × 2622 px portrait surface at 3× with 59 pt / 34 pt safe-area insets (a 6.3-inch iPhone).
    static let portraitSurface = SurfaceGeometry(drawableSize: PixelSize(width: 1206, height: 2622),
                                                 usableRect: DrawableRect(x: 0, y: 177, width: 1206, height: 2343),
                                                 contentScale: 3)
}
