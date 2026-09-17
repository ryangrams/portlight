import Testing
@testable import PortlightKit

@Suite("Persistence: trust pins")
struct PersistenceTrustStoreTests {
    enum Kind: String, CaseIterable, Sendable { case memory, file }

    private let pinA = PersistenceFixtures.fingerprint(0xA1)
    private let pinB = PersistenceFixtures.fingerprint(0xB2)

    private func endpoint(_ host: String, _ port: Int = 5920) -> HostEndpoint { PersistenceFixtures.endpoint(host, port) }

    /// Runs `body` against a fresh store of `kind`.
    private func withStore(_ kind: Kind, _ body: (any TrustLookupStore) throws -> Void) throws {
        switch kind {
        case .memory:
            try body(InMemoryTrustStore())
        case .file:
            let directory = try PersistenceFixtures.TemporaryDirectory()
            defer { directory.cleanup() }
            try body(FileTrustStore(directory: directory.url, now: { PersistenceFixtures.now }))
        }
    }

    @Test func canonicalKeysIgnoreCaseAndBrackets() {
        #expect(endpoint("Studio.Local").canonicalKey == "studio.local:5920")
        #expect(endpoint("studio.local", 5921).canonicalKey == "studio.local:5921")
        #expect(endpoint("192.168.1.20").canonicalKey == "192.168.1.20:5920")
        #expect(endpoint("[FE80::1]").canonicalKey == "[fe80::1]:5920")
        #expect(endpoint("fe80::1").canonicalKey == "[fe80::1]:5920")
        #expect(endpoint("  studio.local ").canonicalKey == "studio.local:5920")
    }

    @Test(arguments: Kind.allCases)
    func pinReplaceAndRemove(_ kind: Kind) throws {
        try withStore(kind) { store in
            let studio = endpoint("Studio.Local")
            #expect(store.pinnedFingerprint(for: studio) == nil)
            #expect(store.lookUpPin(for: studio) == .notPinned)
            try store.pin(pinA, for: studio)
            #expect(store.pinnedFingerprint(for: endpoint("studio.local")) == pinA)
            #expect(store.lookUpPin(for: endpoint("STUDIO.LOCAL")) == .pinned(pinA))
            #expect(store.pinnedFingerprint(for: endpoint("studio.local", 5921)) == nil)
            #expect(store.pinnedFingerprint(for: endpoint("studio")) == nil)

            try store.pin(pinB, for: endpoint("studio.local"))
            #expect(store.pinnedFingerprint(for: studio) == pinB)

            try store.removePin(for: endpoint("STUDIO.local"))
            #expect(store.pinnedFingerprint(for: studio) == nil)
            try store.removePin(for: studio)
        }
    }

    @Test(arguments: Kind.allCases)
    func ipv6FormsShareOnePin(_ kind: Kind) throws {
        try withStore(kind) { store in
            try store.pin(pinA, for: endpoint("[fe80::1]"))
            #expect(store.pinnedFingerprint(for: endpoint("fe80::1")) == pinA)
            #expect(store.pinnedFingerprint(for: endpoint("[FE80::1]")) == pinA)
            #expect(store.pinnedFingerprint(for: endpoint("fe80::1", 5921)) == nil)
        }
    }

    @Test(arguments: Kind.allCases)
    func pinsAreSeparatePerComputer(_ kind: Kind) throws {
        try withStore(kind) { store in
            try store.pin(pinA, for: endpoint("studio.local"))
            try store.pin(pinB, for: endpoint("10.0.0.5"))
            try store.removePin(for: endpoint("studio.local"))
            #expect(store.pinnedFingerprint(for: endpoint("studio.local")) == nil)
            #expect(store.pinnedFingerprint(for: endpoint("10.0.0.5")) == pinB)
        }
    }

    @Test func filePinsSurviveRelaunch() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        try FileTrustStore(directory: directory.url).pin(pinA, for: endpoint("[fe80::1]"))
        let reopened = FileTrustStore(directory: directory.url)
        #expect(reopened.pinnedFingerprint(for: endpoint("FE80::1")) == pinA)
        #expect(reopened.pins == ["[fe80::1]:5920": pinA])
        #expect(reopened.fileURL.lastPathComponent == "TrustedComputers.json")

        let object = try #require(PersistenceFixtures.jsonObject(try directory.contents(of: "TrustedComputers.json")))
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["pins"] as? [String: String] == ["[fe80::1]:5920": pinA.value])
        #expect(directory.fileNames == ["TrustedComputers.json"])
    }

    @Test func lookupsNeverWrite() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = FileTrustStore(directory: directory.url)
        #expect(store.pinnedFingerprint(for: endpoint("studio.local")) == nil)
        #expect(store.lookUpPin(for: endpoint("studio.local")) == .notPinned)
        #expect(store.pins.isEmpty)
        try store.removePin(for: endpoint("studio.local"))
        #expect(directory.fileNames.isEmpty)
    }

    // MARK: Several instances on one file (nothing is cached)

    @Test func pinRemovedThroughOneInstanceIsGoneForAnother() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let session = FileTrustStore(directory: directory.url)
        let settings = FileTrustStore(directory: directory.url)
        try session.pin(pinA, for: endpoint("studio.local"))
        #expect(settings.pinnedFingerprint(for: endpoint("studio.local")) == pinA)

        try settings.removePin(for: endpoint("studio.local"))
        #expect(session.pinnedFingerprint(for: endpoint("studio.local")) == nil)
        #expect(session.lookUpPin(for: endpoint("studio.local")) == .notPinned)

        // The session's next approval must not bring the removed pin back.
        try session.pin(pinB, for: endpoint("other.local"))
        let fresh = FileTrustStore(directory: directory.url)
        #expect(fresh.pins == ["other.local:5920": pinB])
    }

    @Test func interleavedPinsFromTwoInstancesAllSurvive() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let a = FileTrustStore(directory: directory.url)
        let b = FileTrustStore(directory: directory.url)
        try a.pin(pinA, for: endpoint("one.local"))
        try b.pin(pinB, for: endpoint("two.local"))
        try a.pin(pinA, for: endpoint("three.local"))
        try b.removePin(for: endpoint("one.local"))
        #expect(FileTrustStore(directory: directory.url).pins == ["two.local:5920": pinB, "three.local:5920": pinA])
        #expect(a.pins == b.pins)
    }

    @Test func concurrentPinsFromManyInstancesAllPersist() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let fingerprint = pinA
        let url = directory.url
        PersistenceFixtures.concurrently(48) { n in
            try? FileTrustStore(directory: url).pin(fingerprint, for: PersistenceFixtures.endpoint("host\(n).local"))
        }
        #expect(FileTrustStore(directory: directory.url).pins.count == 48)
    }

    @Test func deletedOrReplacedFileIsSeenImmediately() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = FileTrustStore(directory: directory.url)
        try store.pin(pinA, for: endpoint("studio.local"))
        try directory.remove("TrustedComputers.json")
        #expect(store.pinnedFingerprint(for: endpoint("studio.local")) == nil)

        try directory.write(#"{"schemaVersion":1,"pins":{"studio.local:5920":"\#(pinB.value)"}}"#, to: "TrustedComputers.json")
        #expect(store.pinnedFingerprint(for: endpoint("studio.local")) == pinB)
    }

    // MARK: Damaged, unreadable and newer files

    @Test func corruptFileReadsAsUnpinnedAndIsKeptWhenReplaced() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        try directory.write("not json", to: "TrustedComputers.json")
        let store = FileTrustStore(directory: directory.url, now: { PersistenceFixtures.now })

        #expect(store.pinnedFingerprint(for: endpoint("studio.local")) == nil)
        #expect(store.lookUpPin(for: endpoint("studio.local")) == .notPinned)
        try store.removePin(for: endpoint("studio.local"))
        #expect(try directory.text(of: "TrustedComputers.json") == "not json")

        try store.pin(pinA, for: endpoint("studio.local"))
        #expect(directory.fileNames == ["TrustedComputers.corrupt-20260910T221530Z.json", "TrustedComputers.json"])
        #expect(try directory.text(of: "TrustedComputers.corrupt-20260910T221530Z.json") == "not json")
        #expect(FileTrustStore(directory: directory.url).pinnedFingerprint(for: endpoint("studio.local")) == pinA)
    }

    @Test func unreadableFileIsNeverReplacedAndReportsUnavailable() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        try directory.makeDirectory(named: "TrustedComputers.json")
        let store = FileTrustStore(directory: directory.url)
        let unavailable = PersistenceError.existingFileNotLoaded("TrustedComputers.json")
        #expect(store.pinnedFingerprint(for: endpoint("studio.local")) == nil)
        #expect(store.lookUpPin(for: endpoint("studio.local")) == .unavailable(unavailable))
        #expect(throws: unavailable) { try store.pin(pinA, for: endpoint("studio.local")) }
        #expect(throws: unavailable) { try store.removePin(for: endpoint("studio.local")) }
        #expect(store.pins.isEmpty)
        #expect(directory.isDirectory("TrustedComputers.json"))
        #expect(directory.fileNames == ["TrustedComputers.json"])
    }

    @Test func fileFromANewerVersionIsNeverReplacedOrMoved() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let future = #"{"schemaVersion":2,"pins":{"studio.local:5920":"\#(pinA.value)"}}"#
        try directory.write(future, to: "TrustedComputers.json")
        let store = FileTrustStore(directory: directory.url, now: { PersistenceFixtures.now })
        let newer = PersistenceError.savedByNewerVersion("TrustedComputers.json")

        #expect(store.lookUpPin(for: endpoint("studio.local")) == .unavailable(newer))
        #expect(store.pinnedFingerprint(for: endpoint("studio.local")) == nil)
        #expect(throws: newer) { try store.pin(pinB, for: endpoint("other.local")) }
        #expect(throws: newer) { try store.removePin(for: endpoint("studio.local")) }
        #expect(try directory.text(of: "TrustedComputers.json") == future)
        #expect(directory.fileNames == ["TrustedComputers.json"])
    }

    @Test func malformedPinEntriesAreDropped() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let json = #"{"schemaVersion":1,"pins":{"bad.local:5920":"ZZ:ZZ","number.local:5920":5,"good.local:5920":"\#(pinB.value)"}}"#
        try directory.write(json, to: "TrustedComputers.json")
        let store = FileTrustStore(directory: directory.url)
        #expect(store.pins == ["good.local:5920": pinB])
        #expect(store.pinnedFingerprint(for: endpoint("bad.local")) == nil)
        #expect(store.pinnedFingerprint(for: endpoint("Good.Local")) == pinB)
    }

    @Test func inMemoryStoreSeedsByCanonicalKey() {
        let store = InMemoryTrustStore(pins: [endpoint("Studio.Local"): pinA])
        #expect(store.pinnedFingerprint(for: endpoint("studio.local")) == pinA)
        #expect(store.lookUpPin(for: endpoint("studio.local")) == .pinned(pinA))
        #expect(store.pins == ["studio.local:5920": pinA])
    }

    @Test func lookupFingerprintMatchesTheCoreLookup() {
        #expect(TrustLookup.pinned(pinA).fingerprint == pinA)
        #expect(TrustLookup.notPinned.fingerprint == nil)
        #expect(TrustLookup.unavailable(.savedByNewerVersion("TrustedComputers.json")).fingerprint == nil)
    }
}
