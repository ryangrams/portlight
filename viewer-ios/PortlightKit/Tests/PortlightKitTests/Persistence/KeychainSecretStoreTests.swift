#if os(iOS)
import Testing
@testable import PortlightKit

/// Real Keychain round trips, run on the iOS Simulator or a device only (macOS runs the in-memory stores, and
/// `PersistenceKeychainQueryTests` checks every attribute on any platform). Availability comes from a raw
/// `SecItemAdd`, never from the store under test, and only a host with no Keychain at all skips — the unhosted
/// package bundle gets errSecMissingEntitlement. The hosted AppTests (`KeychainHostedTests`) always run these paths.
/// Each test uses its own service so the app's items are never touched.
@Suite("Persistence: Keychain (iOS)",
       .enabled(if: PersistenceKeychainSupport.isAvailable, "No Keychain in this test host (errSecMissingEntitlement or errSecNotAvailable)"))
struct PersistenceKeychainTests {
    private let store = KeychainSecretStore(service: PersistenceKeychainSupport.uniqueService())

    @Test func missingItemReadsAsNil() throws {
        #expect(try store.password(for: PersistenceKeychainSupport.uniqueAccount()) == nil)
    }

    @Test func setUpdateAndIdempotentDelete() throws {
        let account = PersistenceKeychainSupport.uniqueAccount()
        defer { PersistenceKeychainSupport.removeAll(service: store.service) }
        try store.setPassword("first pass", for: account)
        #expect(try store.password(for: account) == "first pass")
        try store.setPassword(" second ✓ pass ", for: account)
        #expect(try store.password(for: account) == " second ✓ pass ")
        try store.deletePassword(for: account)
        #expect(try store.password(for: account) == nil)
        try store.deletePassword(for: account)
    }

    @Test func itemIsDeviceOnlyAndAvailableAfterFirstUnlock() throws {
        let account = PersistenceKeychainSupport.uniqueAccount()
        defer { PersistenceKeychainSupport.removeAll(service: store.service) }
        try store.setPassword("pw", for: account)
        #expect(PersistenceKeychainSupport.hasAfterFirstUnlockThisDeviceOnlyAccessibility(service: store.service, account: account))
    }

    @Test func servicesAndAccountsAreIsolated() throws {
        let account = PersistenceKeychainSupport.uniqueAccount()
        let other = KeychainSecretStore(service: store.service + ".other")
        defer {
            PersistenceKeychainSupport.removeAll(service: store.service)
            PersistenceKeychainSupport.removeAll(service: other.service)
        }
        try store.setPassword("mine", for: account)
        #expect(try other.password(for: account) == nil)
        #expect(try store.password(for: PersistenceKeychainSupport.uniqueAccount()) == nil)
    }

    @Test func accountsAreListedAndOrphansRemoved() throws {
        defer { PersistenceKeychainSupport.removeAll(service: store.service) }
        let kept = PersistenceFixtures.profile(1, hasSavedPassword: true)
        var library = ProfileLibrary()
        library.add(kept)
        try store.setPassword("kept", for: kept.secretAccount)
        try store.setPassword("orphan", for: "ORPHAN")
        #expect(try store.listAccounts() == [kept.secretAccount, "ORPHAN"].sorted())
        let removed = try ConnectionCredentials.removeOrphanedPasswords(after: ProfileStore.LoadResult(library: library, outcome: .loaded),
                                                                        store: store)
        #expect(removed == ["ORPHAN"])
        #expect(try store.listAccounts() == [kept.secretAccount])
    }

    @Test func credentialsRoundTripThroughTheKeychain() throws {
        defer { PersistenceKeychainSupport.removeAll(service: store.service) }
        let profile = PersistenceFixtures.profile(1, host: "studio.local")
        let saved = try ConnectionCredentials.save(typedPassword: "from keychain", remember: true, for: profile, store: store)
        let endpoint = PersistenceFixtures.endpoint("studio.local")
        #expect(try ConnectionCredentials.resolvePassword(profile: saved, typedPassword: "", store: store, connectingTo: endpoint)
            == .saved("from keychain"))
        var library = ProfileLibrary()
        library.add(saved)
        let deleted = try ConnectionCredentials.deleteProfile(saved.id, from: &library, store: store)
        #expect(deleted)
        #expect(try store.password(for: profile.secretAccount) == nil)
    }
}
#endif
