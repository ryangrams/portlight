import Foundation
import Security

/// Why a `SecretStore` operation failed, with text the app can show.
public enum SecretStoreError: Error, Equatable, Sendable, LocalizedError {
    case keychain(OSStatus)
    /// The stored item is not UTF-8 text.
    case undecodablePassword
    /// Longer than Portlight Host accepts; never stored.
    case passwordTooLong(bytes: Int)

    public var errorDescription: String? {
        switch self {
        case .keychain(errSecInteractionNotAllowed):
            return "Keychain is locked. Unlock this iPhone, then try again."
        case .keychain(let status):
            return "Keychain couldn't complete the request (error \(status)). Try again, or enter the password when connecting."
        case .undecodablePassword:
            return "The saved password couldn't be read. Enter the password set in Portlight Host."
        case .passwordTooLong:
            return ConnectionDraft.Message.passwordTooLong
        }
    }
}

/// A `SecretStore` that can list the accounts it holds, so passwords that no saved connection names can be
/// removed (`ConnectionCredentials.removeOrphanedPasswords`). Persistence-local: the Core seam has no listing.
public protocol SecretAccountListing: SecretStore {
    /// Every account that holds a password, sorted. Reads item attributes only, never a password.
    func listAccounts() throws -> [String]
}

/// Production `SecretStore`: one generic-password Keychain item per saved connection.
///
/// Items are `AfterFirstUnlockThisDeviceOnly` — usable by the foreground app after the first unlock, never
/// synced or restored to another device — and carry no access control, so selecting or connecting never shows
/// a biometric prompt. `ConnectionCredentials.resolvePassword` is the only production caller of `password(for:)`.
public struct KeychainSecretStore: SecretAccountListing {
    public static let defaultService = "studio.upgrade.remote.viewer.ios"

    public let service: String

    /// - Parameter service: Keychain service. Tests pass a unique value so they never touch the app's items.
    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    public func password(for account: String) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery(account: account) as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.undecodablePassword
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    /// Update-or-add, so a saved password is replaced in place and its accessibility is refreshed.
    public func setPassword(_ password: String, for account: String) throws {
        let query = itemQuery(account: account)
        let attributes = Self.writeAttributes(password: password)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(addQuery(account: account, password: password) as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // Added concurrently between the update and the add: update the item that now exists.
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    /// Idempotent: deleting a missing item succeeds.
    public func deletePassword(for account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }

    public func listAccounts() throws -> [String] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(listQuery() as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        case errSecItemNotFound:
            return []
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    // MARK: Queries (internal so a test on any platform can check every attribute)

    /// Every item of this store: generic passwords of `service` in the data-protection keychain (iOS's only
    /// keychain; it makes a signed Mac build behave the same way).
    func serviceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Exactly one item: the account is the profile's UUID.
    func itemQuery(account: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = account
        return query
    }

    func readQuery(account: String) -> [String: Any] {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// Attributes only: listing never returns a password.
    func listQuery() -> [String: Any] {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        return query
    }

    /// What every write sets: the secret, and accessibility after the first unlock on this device only. There is
    /// deliberately no `kSecAttrAccessControl` (no biometric or passcode prompt) and no `kSecAttrSynchronizable`.
    static func writeAttributes(password: String) -> [String: Any] {
        [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    /// The complete item added when none exists yet.
    func addQuery(account: String, password: String) -> [String: Any] {
        itemQuery(account: account).merging(Self.writeAttributes(password: password)) { _, new in new }
    }
}

/// Heap-backed `SecretStore` for previews and tests.
public final class InMemorySecretStore: SecretAccountListing, @unchecked Sendable {
    // Invariant for @unchecked Sendable: `passwords` is accessed only while `lock` is held.
    private let lock = NSLock()
    private var passwords: [String: String]

    public init(passwords: [String: String] = [:]) {
        self.passwords = passwords
    }

    public func password(for account: String) throws -> String? {
        lock.withLock { passwords[account] }
    }

    public func setPassword(_ password: String, for account: String) throws {
        lock.withLock { passwords[account] = password }
    }

    public func deletePassword(for account: String) throws {
        _ = lock.withLock { passwords.removeValue(forKey: account) }
    }

    public func listAccounts() throws -> [String] { accounts }

    /// Accounts that currently hold a password, sorted.
    public var accounts: [String] { lock.withLock { passwords.keys.sorted() } }
}

/// `SecretStore` that records every call, for asserting when the Keychain is (not) touched.
/// Failures can be injected per operation.
public final class SpySecretStore: SecretAccountListing, @unchecked Sendable {
    // Invariant for @unchecked Sendable: every stored property below `lock` is accessed only while `lock` is held.
    public struct Counts: Equatable, Sendable {
        public var reads = 0
        public var writes = 0
        public var deletes = 0
        /// `listAccounts()` calls, which read attributes only.
        public var lists = 0
        public init(reads: Int = 0, writes: Int = 0, deletes: Int = 0, lists: Int = 0) {
            self.reads = reads
            self.writes = writes
            self.deletes = deletes
            self.lists = lists
        }
    }

    private typealias Failures = (read: SecretStoreError?, write: SecretStoreError?, delete: SecretStoreError?,
                                  list: SecretStoreError?)

    private let lock = NSLock()
    private var passwords: [String: String]
    private var recorded = Counts()
    private var accountsRead: [String] = []
    private var failures: Failures = (nil, nil, nil, nil)

    /// Seeded passwords are not counted as writes.
    public init(passwords: [String: String] = [:]) {
        self.passwords = passwords
    }

    public var counts: Counts { lock.withLock { recorded } }
    public var readCount: Int { counts.reads }
    public var writeCount: Int { counts.writes }
    public var deleteCount: Int { counts.deletes }
    /// Accounts passed to `password(for:)`, in call order.
    public var readAccounts: [String] { lock.withLock { accountsRead } }

    /// Inspects storage without counting as a read.
    public func storedPassword(for account: String) -> String? {
        lock.withLock { passwords[account] }
    }

    /// Makes later calls of each kind throw until cleared with nil.
    public func injectFailures(read: SecretStoreError? = nil, write: SecretStoreError? = nil, delete: SecretStoreError? = nil,
                               list: SecretStoreError? = nil) {
        lock.withLock { failures = (read, write, delete, list) }
    }

    public func password(for account: String) throws -> String? {
        try lock.withLock {
            recorded.reads += 1
            accountsRead.append(account)
            if let failure = failures.read { throw failure }
            return passwords[account]
        }
    }

    public func setPassword(_ password: String, for account: String) throws {
        try lock.withLock {
            recorded.writes += 1
            if let failure = failures.write { throw failure }
            passwords[account] = password
        }
    }

    public func deletePassword(for account: String) throws {
        try lock.withLock {
            recorded.deletes += 1
            if let failure = failures.delete { throw failure }
            passwords.removeValue(forKey: account)
        }
    }

    public func listAccounts() throws -> [String] {
        try lock.withLock {
            recorded.lists += 1
            if let failure = failures.list { throw failure }
            return passwords.keys.sorted()
        }
    }
}
