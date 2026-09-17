import Testing
import UIKit
import Security
import LocalAuthentication
import PortlightKit

// UIKit brings Foundation here: the viewer's tests never import Foundation next to Testing (see CLAUDE.md).

/// The Keychain adapter against the real Keychain, inside Portlight.app on the simulator. The app's signing gives
/// this hosted bundle a Keychain, which the unhosted PortlightKit bundle lacks (its real-Keychain suite skips
/// there). Nothing here skips: a Keychain failure fails the test. Each test uses its own service and deletes what
/// it created, so the app's saved passwords are never touched.
@Suite("Hosted: Keychain adapter")
struct KeychainHostedTests {
    private let service = HostedKeychain.uniqueService()
    private let studio = HostEndpoint(host: "studio.local", port: 5920)!
    private let other = HostEndpoint(host: "other.local", port: 5920)!

    private func resolve(_ profile: ConnectionProfile?, _ endpoint: HostEndpoint, store: SecretStore) throws
        -> ConnectionCredentials.PasswordResolution {
        try ConnectionCredentials.resolvePassword(profile: profile, typedPassword: "", store: store, connectingTo: endpoint)
    }

    @Test func rawKeychainWorksInsideTheApp() {
        defer { HostedKeychain.removeAll(service: service) }
        #expect(HostedKeychain.add(service: service, account: "raw", data: Data("raw".utf8)) == errSecSuccess)
        #expect(HostedKeychain.data(service: service, account: "raw") == Data("raw".utf8))
        #expect(HostedKeychain.delete(service: service, account: "raw") == errSecSuccess)
    }

    @Test func storeReadsUpdatesAndDeletesItsItem() throws {
        defer { HostedKeychain.removeAll(service: service) }
        let store = KeychainSecretStore(service: service)
        let account = UUID().uuidString
        #expect(try store.password(for: account) == nil)
        try store.setPassword("first pass", for: account)
        #expect(try store.password(for: account) == "first pass")
        try store.setPassword(" second ✓ pass ", for: account)
        #expect(try store.password(for: account) == " second ✓ pass ")
        #expect(HostedKeychain.data(service: service, account: account) == Data(" second ✓ pass ".utf8))
        try store.deletePassword(for: account)
        #expect(try store.password(for: account) == nil)
        #expect(HostedKeychain.data(service: service, account: account) == nil)
        try store.deletePassword(for: account)
    }

    @Test func itemIsDeviceOnlyAfterFirstUnlockAndNeverSynced() throws {
        defer { HostedKeychain.removeAll(service: service) }
        let store = KeychainSecretStore(service: service)
        let account = UUID().uuidString
        for password in ["added", "updated"] {
            try store.setPassword(password, for: account)
            let attributes = try #require(HostedKeychain.attributes(service: service, account: account))
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            #expect(attributes[kSecAttrSynchronizable as String] as? Bool ?? false == false)
            #expect(attributes[kSecAttrService as String] as? String == service)
            #expect(attributes[kSecAttrAccount as String] as? String == account)
        }
    }

    @Test func readingNeedsNoUserInteraction() throws {
        defer { HostedKeychain.removeAll(service: service) }
        try KeychainSecretStore(service: service).setPassword("no prompt", for: "account")
        // With interaction forbidden, an item that required Face ID or the passcode would fail to read.
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "account", kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(status == errSecSuccess)
        #expect((result as? Data).flatMap { String(data: $0, encoding: .utf8) } == "no prompt")
    }

    @Test func servicesAndAccountsAreIsolated() throws {
        let store = KeychainSecretStore(service: service)
        let neighbour = KeychainSecretStore(service: service + ".other")
        defer {
            HostedKeychain.removeAll(service: service)
            HostedKeychain.removeAll(service: neighbour.service)
        }
        try store.setPassword("mine", for: "shared-account")
        #expect(try neighbour.password(for: "shared-account") == nil)
        #expect(try store.password(for: UUID().uuidString) == nil)
    }

    @Test func accountsAreListedPerServiceWithoutPasswords() throws {
        let store = KeychainSecretStore(service: service)
        let neighbour = KeychainSecretStore(service: service + ".other")
        defer {
            HostedKeychain.removeAll(service: service)
            HostedKeychain.removeAll(service: neighbour.service)
        }
        #expect(try store.listAccounts() == [])
        try store.setPassword("b", for: "B-account")
        try store.setPassword("a", for: "A-account")
        try neighbour.setPassword("n", for: "N-account")
        #expect(try store.listAccounts() == ["A-account", "B-account"])
        #expect(try neighbour.listAccounts() == ["N-account"])
    }

    @Test func orphanedPasswordsAreRemovedOnlyAfterACleanLoad() throws {
        defer { HostedKeychain.removeAll(service: service) }
        let store = KeychainSecretStore(service: service)
        let kept = ConnectionProfile(host: "studio.local", hasSavedPassword: true)
        var library = ProfileLibrary()
        library.add(kept)
        let orphan = UUID().uuidString
        try store.setPassword("kept", for: kept.secretAccount)
        try store.setPassword("left behind", for: orphan)

        let unavailable = ProfileStore.LoadResult(library: library, outcome: .unavailable(reason: "locked"))
        #expect(try ConnectionCredentials.removeOrphanedPasswords(after: unavailable, store: store) == [])
        #expect(try store.listAccounts().count == 2)

        let clean = ProfileStore.LoadResult(library: library, outcome: .loaded)
        #expect(try ConnectionCredentials.removeOrphanedPasswords(after: clean, store: store) == [orphan])
        #expect(try store.listAccounts() == [kept.secretAccount])
        #expect(try store.password(for: kept.secretAccount) == "kept")
    }

    @Test func nonTextItemIsReportedAsUndecodable() {
        defer { HostedKeychain.removeAll(service: service) }
        #expect(HostedKeychain.add(service: service, account: "bytes", data: Data([0xFF, 0xFE, 0xFD])) == errSecSuccess)
        #expect(throws: SecretStoreError.undecodablePassword) {
            try KeychainSecretStore(service: service).password(for: "bytes")
        }
    }

    @Test func saveUpdateConnectAndDeleteWithTheRealKeychain() throws {
        let store = KeychainSecretStore(service: service)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeychainHostedTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            HostedKeychain.removeAll(service: service)
            try? FileManager.default.removeItem(at: directory)
        }
        let profiles = ProfileStore(directory: directory)
        var library = profiles.load().library

        var draft = ConnectionDraft()
        draft.name = "Edit Bay"
        draft.host = "studio.local"
        draft.password = "first"
        let addedOutcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: store, persist: profiles.save)
        let added = try #require(addedOutcome)
        let id = added.profile.id
        let account = added.profile.secretAccount
        #expect(added.passwordChange == .saved)
        #expect(HostedKeychain.data(service: service, account: account) == Data("first".utf8))
        #expect(try resolve(library.profile(id: id), studio, store: store) == .saved("first"))

        // Changing the Computer without typing a password deletes the password; it never moves to the new address.
        var editing = ConnectionDraft(editing: try #require(library.profile(id: id)))
        editing.host = "other.local"
        let moved = try ConnectionCredentials.saveConnection(&editing, in: &library, store: store, persist: profiles.save)
        #expect(moved?.passwordChange == .removedForOtherComputer)
        #expect(HostedKeychain.data(service: service, account: account) == nil)
        #expect(try resolve(library.profile(id: id), other, store: store) == .needsPassword(.noneSaved))

        // The new computer's password is saved for it alone.
        editing.password = "second"
        let rebound = try ConnectionCredentials.saveConnection(&editing, in: &library, store: store, persist: profiles.save)
        #expect(rebound?.passwordChange == .saved)
        let stored = try #require(library.profile(id: id))
        #expect(try resolve(stored, other, store: store) == .saved("second"))
        #expect(try resolve(stored, studio, store: store) == .needsPassword(.differentComputer))
        #expect(ProfileStore(directory: directory).load().library == library)

        let deleted = try ConnectionCredentials.deleteProfile(id, from: &library, store: store)
        #expect(deleted)
        #expect(HostedKeychain.data(service: service, account: account) == nil)
        #expect(try store.listAccounts() == [])
    }

    @Test func missingItemIsReportedSoTheHintCanBeCleared() throws {
        let store = KeychainSecretStore(service: service)
        let profile = ConnectionProfile(host: "studio.local", hasSavedPassword: true)
        #expect(try resolve(profile, studio, store: store) == .needsPassword(.missingFromKeychain))
        var library = ProfileLibrary()
        library.add(profile)
        library.recordSavedPassword(profile.id, for: nil)
        #expect(library.profile(id: profile.id)?.hasSavedPassword == false)
    }
}

/// Raw Security calls that bypass `KeychainSecretStore`, to see what it really stored.
enum HostedKeychain {
    static func uniqueService() -> String { "studio.upgrade.remote.viewer.ios.hosted-tests.\(UUID().uuidString)" }

    static func add(service: String, account: String, data: Data) -> OSStatus {
        var item = query(service: service, account: account)
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func data(service: String, account: String) -> Data? {
        var match = query(service: service, account: account)
        match[kSecReturnData as String] = true
        match[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(match as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func attributes(service: String, account: String) -> [String: Any]? {
        var match = query(service: service, account: account)
        match[kSecReturnAttributes as String] = true
        match[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(match as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    @discardableResult
    static func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }

    /// Deletes every item of `service`.
    static func removeAll(service: String) {
        let everything: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        _ = SecItemDelete(everything as CFDictionary)
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
