import Testing
@testable import PortlightKit

/// Every attribute `KeychainSecretStore` passes to the Keychain, checked on any platform. The real-Keychain suites
/// run only where the process has a Keychain (iOS, hosted), so these catch a wrong attribute everywhere.
@Suite("Persistence: Keychain queries")
struct PersistenceKeychainQueryTests {
    private let store = KeychainSecretStore()
    private let account = PersistenceFixtures.id(7).uuidString

    /// One item: generic password, the viewer's service, the profile's UUID, in the data-protection keychain.
    private var item: [String: String] {
        [
            "class": "genericPassword",
            "service": "studio.upgrade.remote.viewer.ios",
            "account": "00000000-0000-0000-0000-000000000007",
            "useDataProtectionKeychain": "true",
        ]
    }

    @Test func oneGenericPasswordPerProfileInTheViewerService() {
        #expect(PersistenceKeychainQuery.describe(store.itemQuery(account: account)) == item)
        #expect(PersistenceFixtures.profile(7).secretAccount == account)
        #expect(PersistenceKeychainQuery.describe(store.serviceQuery()) == item.filter { $0.key != "account" })
    }

    @Test func addedItemIsDeviceOnlyAfterFirstUnlockWithoutAccessControlOrSync() {
        let added = PersistenceKeychainQuery.describe(store.addQuery(account: account, password: "pass ✓"))
        #expect(added == item.merging(["accessible": "afterFirstUnlockThisDeviceOnly", "valueData": "8 bytes"]) { $1 })
        #expect(added["accessControl"] == nil)
        #expect(added["synchronizable"] == nil)
    }

    @Test func updatesRewriteTheSecretWithTheSameAccessibility() {
        #expect(PersistenceKeychainQuery.describe(KeychainSecretStore.writeAttributes(password: "pw")) == [
            "accessible": "afterFirstUnlockThisDeviceOnly", "valueData": "2 bytes",
        ])
    }

    @Test func readReturnsOneItemsDataAndListingReturnsAttributesOnly() {
        #expect(PersistenceKeychainQuery.describe(store.readQuery(account: account))
            == item.merging(["returnData": "true", "matchLimit": "one"]) { $1 })
        let list = PersistenceKeychainQuery.describe(store.listQuery())
        #expect(list == item.filter { $0.key != "account" }.merging(["returnAttributes": "true", "matchLimit": "all"]) { $1 })
        #expect(list["returnData"] == nil)
    }

    @Test func testsCanUseTheirOwnService() {
        let isolated = KeychainSecretStore(service: "studio.upgrade.remote.viewer.ios.tests.x")
        #expect(PersistenceKeychainQuery.describe(isolated.itemQuery(account: account))["service"] == "studio.upgrade.remote.viewer.ios.tests.x")
    }
}
