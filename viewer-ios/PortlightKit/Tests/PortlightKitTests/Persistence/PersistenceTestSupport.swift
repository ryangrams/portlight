import Foundation
import Security
@testable import PortlightKit

// The Persistence test files import only Testing and PortlightKit. This Mac's Command Line Tools ship
// `_Testing_Foundation.framework` without its module, so a file importing both Foundation and Testing fails to
// compile under `swift test`. Everything that needs a Foundation name lives here, in a file without Testing.

/// Shared fixtures for the Persistence tests, namespaced so other modules' test helpers can't collide.
enum PersistenceFixtures {
    /// 2026-09-10T22:15:30Z, the injected clock used for quarantine names.
    static let now = Date(timeIntervalSince1970: 1_789_078_530)
    static let nowStamp = "20260910T221530Z"

    /// `errSecInteractionNotAllowed`: the Keychain is locked.
    static let keychainLocked: OSStatus = errSecInteractionNotAllowed
    /// `errSecMissingEntitlement`: the process may not use the Keychain.
    static let keychainMissingEntitlement: OSStatus = errSecMissingEntitlement

    /// Deterministic UUID `00000000-0000-0000-0000-00000000000n`.
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", n))!
    }

    static func date(sinceReference seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    static func fingerprint(_ byte: UInt8) -> CertificateFingerprint {
        CertificateFingerprint(digest: [UInt8](repeating: byte, count: 32))
    }

    static func endpoint(_ host: String, _ port: Int = 5920) -> HostEndpoint {
        HostEndpoint(host: host, port: port)!
    }

    /// Profile n: host 192.168.1.n unless given, created n seconds after `now`. A saved password is bound to the
    /// profile's own computer.
    static func profile(_ n: Int, name: String = "", host: String? = nil, port: Int = 5920, group: UUID? = nil,
                        hasSavedPassword: Bool = false) -> ConnectionProfile {
        ConnectionProfile(id: id(n), name: name, host: host ?? "192.168.1.\(n)", port: port, groupID: group,
                          createdAt: now.addingTimeInterval(Double(n)), hasSavedPassword: hasSavedPassword)
    }

    /// A quarantine location for outcomes built by hand.
    static let asideURL = URL(fileURLWithPath: "/tmp/Connections.corrupt-\(nowStamp).json")

    /// Every load outcome except `.loaded`.
    static var uncleanOutcomes: [ProfileStore.LoadOutcome] {
        [.recovered(quarantinedFile: asideURL), .partiallyRecovered(dropped: 1, quarantinedCopy: asideURL),
         .unavailable(reason: "locked"), .newerVersion(schemaVersion: 2)]
    }

    static func offsets(_ values: [Int]) -> IndexSet { IndexSet(values) }

    static func bytes(_ text: String) -> Data { Data(text.utf8) }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The top-level JSON object the stores would write for `value`.
    static func encodedObject<Value: Encodable>(_ value: Value) throws -> [String: Any]? {
        jsonObject(try PersistenceFiles.makeEncoder().encode(value))
    }

    /// Decodes with the stores' decoder.
    static func decode<Value: Decodable>(_ type: Value.Type, json: String) throws -> Value {
        try PersistenceFiles.makeDecoder().decode(type, from: bytes(json))
    }

    /// Encodes and decodes with the stores' coders.
    static func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try PersistenceFiles.makeDecoder().decode(Value.self, from: PersistenceFiles.makeEncoder().encode(value))
    }

    static func concurrently(_ iterations: Int, _ body: (Int) -> Void) {
        DispatchQueue.concurrentPerform(iterations: iterations, execute: body)
    }

    /// A fresh directory under the system temporary directory. Call `cleanup()` in a `defer`.
    struct TemporaryDirectory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PortlightPersistenceTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func file(_ name: String) -> URL { url.appendingPathComponent(name, isDirectory: false) }

        func subdirectory(_ relativePath: String) -> URL { url.appendingPathComponent(relativePath, isDirectory: true) }

        /// Names directly inside the directory, sorted.
        var fileNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []).sorted()
        }

        func write(_ text: String, to name: String) throws { try bytes(text).write(to: file(name)) }

        func contents(of name: String) throws -> Data { try Data(contentsOf: file(name)) }

        func text(of name: String) throws -> String? { String(data: try contents(of: name), encoding: .utf8) }

        func makeDirectory(named name: String) throws {
            try FileManager.default.createDirectory(at: file(name), withIntermediateDirectories: false)
        }

        func remove(_ name: String) throws { try FileManager.default.removeItem(at: file(name)) }

        func isDirectory(_ name: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: file(name).path(percentEncoded: false), isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        /// Read-only makes creating or moving files inside fail while existing files stay readable.
        func setWritable(_ writable: Bool) {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: writable ? 0o755 : 0o555)],
                                                   ofItemAtPath: url.path(percentEncoded: false))
        }

        func cleanup() {
            setWritable(true)
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Records, in order, what a Save flow did to the saved list and the Keychain, and fails chosen list saves.
final class PersistenceEventLog: @unchecked Sendable {
    // Invariant for @unchecked Sendable: every stored property below `lock` is accessed only while `lock` is held.
    private let lock = NSLock()
    private var entries: [String] = []
    private var accepted: [ProfileLibrary] = []
    private var failingCalls: Set<Int> = []
    private var persistCalls = 0

    var events: [String] { lock.withLock { entries } }
    /// Every library `persist` accepted, in order.
    var persisted: [ProfileLibrary] { lock.withLock { accepted } }

    /// Makes these `persist` calls (1-based) throw `existingFileNotLoaded`, as a store would before the first unlock.
    func failPersist(onCalls calls: Set<Int>) { lock.withLock { failingCalls = calls } }

    func record(_ entry: String) { lock.withLock { entries.append(entry) } }

    /// For `saveConnection`'s `persist`. Logs each profile as `host=<what its saved password is bound to>`.
    func persist(_ library: ProfileLibrary) throws {
        try lock.withLock {
            persistCalls += 1
            guard !failingCalls.contains(persistCalls) else {
                entries.append("persist failed")
                throw PersistenceError.existingFileNotLoaded(ProfileStore.fileName)
            }
            accepted.append(library)
            entries.append("persist " + library.profiles.map { "\($0.host)=\(Self.binding(of: $0))" }.joined(separator: " "))
        }
    }

    private static func binding(of profile: ConnectionProfile) -> String {
        guard profile.hasSavedPassword else { return "none" }
        return profile.passwordEndpointKey ?? "unbound"
    }
}

/// A `SecretStore` that logs each call into a `PersistenceEventLog` and keeps its items in a `SpySecretStore`, for
/// counts and injected failures.
final class PersistenceLoggingSecretStore: SecretAccountListing, @unchecked Sendable {
    // Invariant for @unchecked Sendable: both properties are immutable references to lock-protected objects.
    let log: PersistenceEventLog
    let spy: SpySecretStore

    init(log: PersistenceEventLog, passwords: [String: String] = [:]) {
        self.log = log
        spy = SpySecretStore(passwords: passwords)
    }

    func password(for account: String) throws -> String? {
        log.record("keychain read \(account)")
        return try spy.password(for: account)
    }

    func setPassword(_ password: String, for account: String) throws {
        log.record("keychain set \(account)")
        try spy.setPassword(password, for: account)
    }

    func deletePassword(for account: String) throws {
        log.record("keychain delete \(account)")
        try spy.deletePassword(for: account)
    }

    func listAccounts() throws -> [String] {
        log.record("keychain list")
        return try spy.listAccounts()
    }
}

/// The protection the stores ask for, as plain strings for a test file without Foundation.
enum PersistenceFileProtection {
    /// The protection class carried by the atomic write options, or "none".
    static var fileWrite: String {
        let requested = PersistenceFiles.writeOptions.intersection(.fileProtectionMask)
        switch requested {
        case []: return "none"
        case .completeFileProtectionUntilFirstUserAuthentication: return "completeUntilFirstUserAuthentication"
        case .completeFileProtection: return "complete"
        case .completeFileProtectionUnlessOpen: return "completeUnlessOpen"
        case .noFileProtection: return "noProtection"
        default: return "unknown(\(requested.rawValue))"
        }
    }

    /// Whether every write is atomic.
    static var writesAtomically: Bool { PersistenceFiles.writeOptions.contains(.atomic) }

    /// The protection attribute given to a directory the stores create, or "none".
    static var directory: String {
        guard let attributes = PersistenceFiles.directoryAttributes else { return "none" }
        guard attributes.count == 1, let type = attributes[.protectionKey] as? FileProtectionType else { return "unexpected \(attributes)" }
        return type == .completeUntilFirstUserAuthentication ? "completeUntilFirstUserAuthentication" : type.rawValue
    }
}

/// Keychain query dictionaries as plain strings, so a test file without Foundation can compare them exactly. Keys
/// and constant values get readable names; anything unexpected shows up under its raw key.
enum PersistenceKeychainQuery {
    static func describe(_ query: [String: Any]) -> [String: String] {
        var described: [String: String] = [:]
        for (key, value) in query { described[keyNames[key] ?? "raw:\(key)"] = describe(value) }
        return described
    }

    private static let keyNames: [String: String] = [
        kSecClass as String: "class",
        kSecAttrService as String: "service",
        kSecAttrAccount as String: "account",
        kSecAttrAccessGroup as String: "accessGroup",
        kSecUseDataProtectionKeychain as String: "useDataProtectionKeychain",
        kSecAttrAccessible as String: "accessible",
        kSecAttrAccessControl as String: "accessControl",
        kSecAttrSynchronizable as String: "synchronizable",
        kSecValueData as String: "valueData",
        kSecReturnData as String: "returnData",
        kSecReturnAttributes as String: "returnAttributes",
        kSecMatchLimit as String: "matchLimit",
    ]

    private static let valueNames: [String: String] = [
        kSecClassGenericPassword as String: "genericPassword",
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String: "afterFirstUnlockThisDeviceOnly",
        kSecAttrAccessibleAfterFirstUnlock as String: "afterFirstUnlock",
        kSecAttrAccessibleWhenUnlocked as String: "whenUnlocked",
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String: "whenUnlockedThisDeviceOnly",
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String: "whenPasscodeSetThisDeviceOnly",
        kSecMatchLimitOne as String: "one",
        kSecMatchLimitAll as String: "all",
    ]

    private static func describe(_ value: Any) -> String {
        if let data = value as? Data { return "\(data.count) bytes" }
        if let text = value as? String { return valueNames[text] ?? text }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        return "\(type(of: value))"
    }
}

#if os(iOS)
/// Real-Keychain helpers for the iOS-only Keychain suite.
enum PersistenceKeychainSupport {
    /// A service no app item uses, so tests never touch the viewer's saved passwords.
    static func uniqueService() -> String { "studio.upgrade.remote.viewer.ios.tests.\(UUID().uuidString)" }

    static func uniqueAccount() -> String { UUID().uuidString }

    /// A raw `SecItemAdd`/`SecItemDelete`, made without `KeychainSecretStore` so a defect in the store can't turn
    /// its own tests into skips.
    static let probeStatus: OSStatus = {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "studio.upgrade.remote.viewer.ios.tests.probe",
            kSecAttrAccount as String: uniqueAccount(),
            kSecUseDataProtectionKeychain as String: true,
        ]
        var added = item
        added[kSecValueData as String] = Data("probe".utf8)
        let status = SecItemAdd(added as CFDictionary, nil)
        if status == errSecSuccess { _ = SecItemDelete(item as CFDictionary) }
        return status
    }()

    /// False only when this test host has no Keychain at all (an unhosted bundle without the entitlement). Any other
    /// probe failure still runs the suite, which then fails.
    static var isAvailable: Bool { probeStatus != errSecMissingEntitlement && probeStatus != errSecNotAvailable }

    /// Whether the stored item's `kSecAttrAccessible` is AfterFirstUnlockThisDeviceOnly.
    static func hasAfterFirstUnlockThisDeviceOnlyAccessibility(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return false }
        return attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    }

    /// Deletes every item of `service`.
    static func removeAll(service: String) {
        let everything: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        _ = SecItemDelete(everything as CFDictionary)
    }
}
#endif
