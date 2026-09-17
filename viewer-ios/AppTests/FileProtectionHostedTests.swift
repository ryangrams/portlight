import Testing
import UIKit
import PortlightKit

// UIKit brings Foundation here: the viewer's tests never import Foundation next to Testing (see CLAUDE.md).

/// The data-protection class of the files the stores write, inside Portlight.app. They must stay readable after the
/// first unlock (completeUntilFirstUserAuthentication) so the app can reconnect while the phone is locked.
///
/// On a device a file reports the class it was written with. The iOS Simulator gives every file its container
/// default — this same class — whatever was requested (measured on iOS 26.5, where even `.completeFileProtection`
/// writes report it). There these tests confirm the class the files end up with, and the unit suite
/// `PersistenceFileProtectionTests` confirms the class the stores request.
@Suite("Hosted: file protection")
struct FileProtectionHostedTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileProtectionHostedTests-\(UUID().uuidString)", isDirectory: true)
    private let studio = HostEndpoint(host: "studio.local", port: 5920)!
    private let other = HostEndpoint(host: "other.local", port: 5920)!

    /// Created by the stores themselves, as `Application Support/Portlight` is on first launch.
    private var directory: URL { root.appendingPathComponent("Portlight", isDirectory: true) }

    @Test func connectionsFileIsReadableAfterFirstUnlockAcrossSaves() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(directory: directory)
        var library = store.load().library
        library.add(ConnectionProfile(host: "studio.local"))
        try store.save(library)
        #expect(HostedFiles.protection(of: store.fileURL) == .completeUntilFirstUserAuthentication)

        // An atomic save puts a new file in the old one's place; it must get the same class.
        library.add(ConnectionProfile(host: "other.local"))
        try store.save(library)
        #expect(HostedFiles.protection(of: store.fileURL) == .completeUntilFirstUserAuthentication)
        #expect(ProfileStore(directory: directory).load().library == library)
    }

    @Test func trustFileIsReadableAfterFirstUnlockAcrossChanges() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileTrustStore(directory: directory)
        let fingerprint = CertificateFingerprint(digest: [UInt8](repeating: 0xA1, count: 32))
        try store.pin(fingerprint, for: studio)
        #expect(HostedFiles.protection(of: store.fileURL) == .completeUntilFirstUserAuthentication)
        try store.pin(fingerprint, for: other)
        try store.removePin(for: studio)
        #expect(HostedFiles.protection(of: store.fileURL) == .completeUntilFirstUserAuthentication)
        #expect(store.lookUpPin(for: other) == .pinned(fingerprint))
        #expect(store.lookUpPin(for: studio) == .notPinned)
    }

    @Test func repairedConnectionsFileIsReadableAfterFirstUnlock() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ProfileStore(directory: directory)
        let damaged = #"{"schemaVersion":1,"profiles":[{"id":"\#(UUID().uuidString)","host":"studio.local","port":5920},{"host":"no id"}]}"#
        try Data(damaged.utf8).write(to: store.fileURL)

        let result = store.load()
        guard case .partiallyRecovered(let dropped, let copy) = result.outcome else {
            Issue.record("Expected a partial recovery, got \(result.outcome)")
            return
        }
        #expect(dropped == 1)
        #expect(result.library.profiles.count == 1)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(HostedFiles.protection(of: store.fileURL) == .completeUntilFirstUserAuthentication)
    }

    @Test func filesGetTheRequestedClassWhereThePlatformAppliesClasses() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let control = root.appendingPathComponent("control.txt")
        try Data("control".utf8).write(to: control, options: [.atomic, .completeFileProtection])
        let store = ProfileStore(directory: directory)
        _ = store.load()
        try store.save(ProfileLibrary())

        if HostedFiles.protection(of: control) == .complete {
            // A device: classes are applied as requested, so this is the stores' own request.
            #expect(HostedFiles.protection(of: store.fileURL) == .completeUntilFirstUserAuthentication)
        } else {
            // The Simulator: every file gets the container default, which is the class the stores need.
            #expect(HostedFiles.protection(of: control) == .completeUntilFirstUserAuthentication)
            #expect(HostedFiles.protection(of: store.fileURL) == .completeUntilFirstUserAuthentication)
        }
    }

    @Test func storesLiveInApplicationSupportInsideTheAppContainer() throws {
        let production = try ProfileStore.defaultDirectory()
        #expect(production.lastPathComponent == "Portlight")
        #expect(production.deletingLastPathComponent().lastPathComponent == "Application Support")
        #expect(production.path.hasPrefix(NSHomeDirectory()))
        #expect(ProfileStore(directory: production).fileURL.lastPathComponent == "Connections.json")
        #expect(FileTrustStore(directory: production).fileURL.deletingLastPathComponent().lastPathComponent == "Portlight")
    }
}

/// File-system reads for the hosted tests.
enum HostedFiles {
    /// The data-protection class the file reports, read afresh (resource values are cached per URL).
    static func protection(of url: URL) -> URLFileProtection? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.fileProtectionKey]))?.fileProtection
    }
}
