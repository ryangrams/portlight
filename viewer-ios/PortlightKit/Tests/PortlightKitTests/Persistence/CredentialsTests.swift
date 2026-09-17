import Testing
@testable import PortlightKit

@Suite("Persistence: secrets and credentials")
struct PersistenceCredentialsTests {
    private typealias Counts = SpySecretStore.Counts
    private let id1 = PersistenceFixtures.id(1)
    private let studio = PersistenceFixtures.endpoint("studio.local")
    private let locked = SecretStoreError.keychain(PersistenceFixtures.keychainLocked)

    /// Profile n on studio.local with a password saved for studio.local.
    private func savedProfile(_ n: Int = 1) -> ConnectionProfile {
        PersistenceFixtures.profile(n, host: "studio.local", hasSavedPassword: true)
    }

    private func resolve(_ profile: ConnectionProfile?, typed: String = "", _ endpoint: HostEndpoint? = nil,
                         store: SecretStore) throws -> ConnectionCredentials.PasswordResolution {
        try ConnectionCredentials.resolvePassword(profile: profile, typedPassword: typed, store: store,
                                                  connectingTo: endpoint ?? studio)
    }

    // MARK: Stores

    @Test func keychainStoreUsesTheIOSViewerService() {
        #expect(KeychainSecretStore.defaultService == "studio.upgrade.remote.viewer.ios")
        #expect(KeychainSecretStore().service == "studio.upgrade.remote.viewer.ios")
        #expect(KeychainSecretStore(service: "tests").service == "tests")
    }

    @Test func inMemoryStoreSetsReadsListsAndDeletesIdempotently() throws {
        let store = InMemorySecretStore()
        #expect(try store.password(for: "a") == nil)
        try store.setPassword("one", for: "a")
        try store.setPassword("two", for: "a")
        try store.setPassword("other", for: "b")
        #expect(try store.password(for: "a") == "two")
        #expect(store.accounts == ["a", "b"])
        #expect(try store.listAccounts() == ["a", "b"])
        try store.deletePassword(for: "a")
        try store.deletePassword(for: "a")
        #expect(try store.password(for: "a") == nil)
        #expect(store.accounts == ["b"])
    }

    @Test func spyCountsEveryCallButNotInspection() throws {
        let spy = SpySecretStore(passwords: ["seeded": "pw"])
        #expect(spy.counts == Counts())
        #expect(spy.storedPassword(for: "seeded") == "pw")
        #expect(try spy.password(for: "seeded") == "pw")
        #expect(try spy.password(for: "missing") == nil)
        try spy.setPassword("x", for: "new")
        #expect(try spy.listAccounts() == ["new", "seeded"])
        try spy.deletePassword(for: "new")
        try spy.deletePassword(for: "new")
        #expect(spy.counts == Counts(reads: 2, writes: 1, deletes: 2, lists: 1))
        #expect(spy.readAccounts == ["seeded", "missing"])
    }

    @Test func spyInjectedFailures() throws {
        let spy = SpySecretStore()
        spy.injectFailures(read: locked, write: .keychain(-1), delete: .keychain(-2), list: .keychain(-3))
        #expect(throws: locked) { try spy.password(for: "a") }
        #expect(throws: SecretStoreError.keychain(-1)) { try spy.setPassword("x", for: "a") }
        #expect(throws: SecretStoreError.keychain(-2)) { try spy.deletePassword(for: "a") }
        #expect(throws: SecretStoreError.keychain(-3)) { try spy.listAccounts() }
        spy.injectFailures()
        try spy.setPassword("x", for: "a")
        #expect(spy.storedPassword(for: "a") == "x")
    }

    @Test func secretErrorsExplainWhatToDo() {
        #expect(locked.errorDescription == "Keychain is locked. Unlock this iPhone, then try again.")
        #expect(SecretStoreError.keychain(-25300).errorDescription?.contains("-25300") == true)
        #expect(SecretStoreError.passwordTooLong(bytes: 2000).errorDescription == ConnectionDraft.Message.passwordTooLong)
        #expect(SecretStoreError.undecodablePassword.errorDescription?.contains("Enter the password") == true)
    }

    // MARK: No Keychain reads until connecting (NET-03)

    @Test func selectingEditingAndSavingNeverReadSecretsUntilConnecting() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let secrets = SpySecretStore()
        let store = ProfileStore(directory: directory.url)
        var library = store.load().library

        // Save Connection with a typed password.
        var draft = ConnectionDraft()
        draft.name = "Edit Bay"
        draft.host = "studio.local"
        draft.password = "correct horse"
        _ = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: store.save,
                                                     now: PersistenceFixtures.now, id: id1)
        #expect(secrets.counts == Counts(reads: 0, writes: 1, deletes: 0))

        // Relaunch, select the row, inspect and edit it, update it.
        library = store.load().library
        let selected = try #require(library.profile(id: id1))
        #expect(selected.hasSavedPassword)
        var editing = ConnectionDraft(editing: selected)
        #expect(editing.passwordPlaceholder == "Saved password is used when connecting")
        #expect(editing.validate(for: .connect).isValid)
        editing.name = "Edit Bay 2"
        editing.host = "other.local"
        #expect(editing.validate(for: .connect).message(for: .password) == ConnectionDraft.Message.passwordRequired)
        editing.host = "Studio.local"
        editing.port = " 5920 "
        _ = try ConnectionCredentials.saveConnection(&editing, in: &library, store: secrets, persist: store.save)
        _ = library.profiles(in: nil).map(\.displayTitle)
        #expect(secrets.counts == Counts(reads: 0, writes: 1, deletes: 0))

        // Connect: the one and only read.
        let endpoint = try #require(editing.endpoint)
        let resolution = try ConnectionCredentials.resolvePassword(profile: library.profile(id: id1), typedPassword: editing.password,
                                                                  store: secrets, connectingTo: endpoint)
        #expect(resolution == .saved("correct horse"))
        #expect(secrets.readAccounts == [id1.uuidString])
        #expect(secrets.counts == Counts(reads: 1, writes: 1, deletes: 0, lists: 0))
    }

    // MARK: resolvePassword

    @Test func typedPasswordWinsWithoutReading() throws {
        let secrets = SpySecretStore(passwords: [id1.uuidString: "saved"])
        #expect(try resolve(savedProfile(), typed: " typed ", store: secrets) == .typed(" typed "))
        #expect(secrets.readCount == 0)
    }

    @Test func savedPasswordIsOnlyUsedForItsOwnComputer() throws {
        let secrets = SpySecretStore(passwords: [id1.uuidString: "saved"])
        for other in [PersistenceFixtures.endpoint("other.local"), PersistenceFixtures.endpoint("studio.local", 5921)] {
            #expect(try resolve(savedProfile(), other, store: secrets) == .needsPassword(.differentComputer))
        }
        #expect(secrets.readCount == 0)
        #expect(try resolve(savedProfile(), PersistenceFixtures.endpoint("STUDIO.Local"), store: secrets) == .saved("saved"))
        #expect(secrets.readCount == 1)
    }

    @Test func newConnectionWithoutProfileNeedsATypedPassword() throws {
        let secrets = SpySecretStore()
        #expect(try resolve(nil, store: secrets) == .needsPassword(.noneSaved))
        #expect(secrets.readCount == 0)
    }

    @Test func profileWithoutAPasswordNeverReadsTheKeychain() throws {
        // An item left under the account (for example by an interrupted save) is not a saved password.
        let secrets = SpySecretStore(passwords: [id1.uuidString: "orphaned"])
        let profile = PersistenceFixtures.profile(1, host: "studio.local", hasSavedPassword: false)
        #expect(try resolve(profile, store: secrets) == .needsPassword(.noneSaved))
        #expect(secrets.readCount == 0)
    }

    @Test func passwordSavedBeforeItWasBoundIsNeverSent() throws {
        let secrets = SpySecretStore(passwords: [id1.uuidString: "unbound"])
        let json = #"{"id":"\#(id1.uuidString)","host":"studio.local","port":5920,"hasSavedPassword":true}"#
        let profile = try PersistenceFixtures.decode(ConnectionProfile.self, json: json)
        #expect(profile.hasSavedPassword)
        #expect(profile.passwordEndpointKey == nil)
        #expect(try resolve(profile, store: secrets) == .needsPassword(.differentComputer))
        #expect(secrets.readCount == 0)
    }

    @Test func passwordMissingFromTheKeychainIsReportedSoTheHintCanBeCleared() throws {
        // A restored backup keeps `hasSavedPassword` but not the ThisDeviceOnly Keychain item.
        let secrets = SpySecretStore(passwords: [PersistenceFixtures.id(2).uuidString: ""])
        #expect(try resolve(savedProfile(), store: secrets) == .needsPassword(.missingFromKeychain))
        #expect(try resolve(savedProfile(2), store: secrets) == .needsPassword(.missingFromKeychain))
        #expect(secrets.readCount == 2)

        var library = ProfileLibrary()
        library.add(savedProfile())
        let cleared = library.recordSavedPassword(id1, for: nil)
        #expect(cleared)
        #expect(try resolve(library.profile(id: id1), store: secrets) == .needsPassword(.noneSaved))
        #expect(secrets.readCount == 2)
    }

    @Test func keychainFailureWhileResolvingIsReported() {
        let secrets = SpySecretStore(passwords: [id1.uuidString: "saved"])
        secrets.injectFailures(read: locked)
        #expect(throws: locked) {
            try ConnectionCredentials.resolvePassword(profile: savedProfile(), typedPassword: "", store: secrets, connectingTo: studio)
        }
    }

    @Test func resolveGivesJustThePassword() throws {
        let secrets = SpySecretStore(passwords: [id1.uuidString: "saved"])
        #expect(try ConnectionCredentials.resolve(profile: savedProfile(), typedPassword: "", store: secrets, connectingTo: studio) == "saved")
        #expect(try ConnectionCredentials.resolve(profile: savedProfile(), typedPassword: "typed", store: secrets, connectingTo: studio) == "typed")
        #expect(try ConnectionCredentials.resolve(profile: nil, typedPassword: "", store: secrets, connectingTo: studio) == nil)
    }

    @Test func resolutionsNeverShowThePassword() {
        for resolution in [ConnectionCredentials.PasswordResolution.typed("hunter2-secret"), .saved("hunter2-secret")] {
            #expect(!String(describing: resolution).contains("hunter2"))
            #expect(!String(reflecting: resolution).contains("hunter2"))
            var dumped = ""
            dump(resolution, to: &dumped)
            #expect(!dumped.contains("hunter2"))
            #expect(dumped.contains("<redacted>"))
        }
        #expect(String(describing: ConnectionCredentials.PasswordResolution.needsPassword(.missingFromKeychain))
            == "needsPassword(missingFromKeychain)")
    }

    // MARK: save (single-profile step) / forget

    @Test func rememberingStoresTheTypedPasswordForThisComputer() throws {
        let secrets = SpySecretStore()
        let profile = PersistenceFixtures.profile(1, host: "Studio.Local", port: 5921)
        let saved = try ConnectionCredentials.save(typedPassword: " pass word ", remember: true, for: profile, store: secrets)
        #expect(saved.hasSavedPassword)
        #expect(saved.passwordEndpointKey == "studio.local:5921")
        #expect(secrets.storedPassword(for: profile.secretAccount) == " pass word ")
        #expect(secrets.counts == Counts(reads: 0, writes: 1, deletes: 0))
    }

    @Test func updatingWithAnEmptyPasswordKeepsTheSavedOne() throws {
        let secrets = SpySecretStore(passwords: [id1.uuidString: "saved"])
        let updated = try ConnectionCredentials.save(typedPassword: "", remember: true, for: savedProfile(), store: secrets)
        #expect(updated == savedProfile())
        #expect(secrets.counts == Counts())
        #expect(secrets.storedPassword(for: id1.uuidString) == "saved")
    }

    @Test func notRememberingForgetsTheSavedPassword() throws {
        let secrets = SpySecretStore(passwords: [id1.uuidString: "saved"])
        let updated = try ConnectionCredentials.save(typedPassword: "typed", remember: false, for: savedProfile(), store: secrets)
        #expect(!updated.hasSavedPassword)
        #expect(updated.passwordEndpointKey == nil)
        #expect(secrets.storedPassword(for: id1.uuidString) == nil)
        #expect(secrets.counts == Counts(reads: 0, writes: 0, deletes: 1))
    }

    @Test func overlongPasswordIsNeverStored() {
        let secrets = SpySecretStore()
        #expect(throws: SecretStoreError.passwordTooLong(bytes: 1025)) {
            try ConnectionCredentials.save(typedPassword: String(repeating: "a", count: 1025), remember: true,
                                           for: PersistenceFixtures.profile(1), store: secrets)
        }
        #expect(secrets.counts.writes == 0)
    }

    @Test func failedKeychainWriteIsReported() {
        let secrets = SpySecretStore()
        let missingEntitlement = SecretStoreError.keychain(PersistenceFixtures.keychainMissingEntitlement)
        secrets.injectFailures(write: missingEntitlement)
        #expect(throws: missingEntitlement) {
            try ConnectionCredentials.save(typedPassword: "pw", remember: true, for: PersistenceFixtures.profile(1), store: secrets)
        }
        #expect(secrets.storedPassword(for: id1.uuidString) == nil)
    }

    @Test func forgetPasswordIsIdempotent() throws {
        let secrets = SpySecretStore(passwords: [id1.uuidString: "saved"])
        let forgotten = try ConnectionCredentials.forgetPassword(for: savedProfile(), store: secrets)
        #expect(!forgotten.hasSavedPassword)
        #expect(forgotten.passwordEndpointKey == nil)
        #expect(try ConnectionCredentials.forgetPassword(for: forgotten, store: secrets).hasSavedPassword == false)
        #expect(secrets.storedPassword(for: id1.uuidString) == nil)
        #expect(secrets.counts == Counts(reads: 0, writes: 0, deletes: 2))
    }

    /// The review's sequence with the single-step calls: edit computer A to B, Update with the password field empty,
    /// reopen, Connect. A's password must not reach B.
    @Test func addressEditThenUpdateNeverSendsTheOldPasswordToTheNewComputer() throws {
        let secrets = SpySecretStore(passwords: [id1.uuidString: "password-for-A"])
        var library = ProfileLibrary()
        library.add(PersistenceFixtures.profile(1, name: "A", host: "computer-a.local", hasSavedPassword: true))
        var draft = ConnectionDraft(editing: try #require(library.profile(id: id1)))
        draft.host = "computer-b.local"
        let rebuilt = try #require(draft.makeProfile())
        let saved = try ConnectionCredentials.save(typedPassword: draft.password, remember: draft.rememberPassword,
                                                   for: rebuilt, store: secrets)
        #expect(!saved.hasSavedPassword)
        #expect(secrets.storedPassword(for: id1.uuidString) == nil)
        let replaced = library.update(saved)
        #expect(replaced)

        let stored = try #require(library.profile(id: id1))
        let reopened = ConnectionDraft(editing: stored)
        #expect(!reopened.canUseSavedPassword)
        #expect(reopened.validate(for: .connect).message(for: .password) == ConnectionDraft.Message.passwordRequired)
        let endpointB = try #require(reopened.endpoint)
        #expect(try ConnectionCredentials.resolve(profile: stored, typedPassword: "", store: secrets, connectingTo: endpointB) == nil)
        #expect(secrets.readCount == 0)
    }

    /// Defense in depth: a caller that edits the address and keeps the stale hint still can't send A's password to B.
    @Test func passwordBoundToAnotherComputerIsRefusedEvenWithAStaleHint() throws {
        let secrets = SpySecretStore(passwords: [id1.uuidString: "password-for-A"])
        var profile = PersistenceFixtures.profile(1, host: "computer-a.local", hasSavedPassword: true)
        profile.host = "computer-b.local"
        #expect(profile.hasSavedPassword)
        #expect(try resolve(profile, PersistenceFixtures.endpoint("computer-b.local"), store: secrets) == .needsPassword(.differentComputer))
        #expect(secrets.readCount == 0)
        #expect(!ConnectionDraft(editing: profile).canUseSavedPassword)
    }

    // MARK: Deletion

    @Test func deletingAProfileRemovesItsSecret() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ProfileStore(directory: directory.url)
        _ = store.load()
        let id2 = PersistenceFixtures.id(2)
        let secrets = SpySecretStore(passwords: [id1.uuidString: "one", id2.uuidString: "two"])
        var library = ProfileLibrary()
        library.add(savedProfile(1))
        library.add(savedProfile(2))
        try store.save(library)

        let deleted = try ConnectionCredentials.deleteProfile(id1, from: &library, store: secrets)
        #expect(deleted)
        try store.save(library)
        #expect(secrets.storedPassword(for: id1.uuidString) == nil)
        #expect(secrets.storedPassword(for: id2.uuidString) == "two")
        #expect(secrets.counts == Counts(reads: 0, writes: 0, deletes: 1))
        #expect(ProfileStore(directory: directory.url).load().library.profiles.map(\.id) == [id2])
    }

    @Test func profileStaysWhenTheKeychainRefusesDeletion() {
        let secrets = SpySecretStore(passwords: [id1.uuidString: "one"])
        secrets.injectFailures(delete: locked)
        var library = ProfileLibrary()
        library.add(savedProfile(1))
        var thrown: (any Error)?
        do {
            try ConnectionCredentials.deleteProfile(id1, from: &library, store: secrets)
        } catch {
            thrown = error
        }
        #expect(thrown as? SecretStoreError == locked)
        #expect(library.profile(id: id1) != nil)
    }

    @Test func deletingAnUnknownProfileTouchesNothing() throws {
        let secrets = SpySecretStore()
        var library = ProfileLibrary()
        let deleted = try ConnectionCredentials.deleteProfile(id1, from: &library, store: secrets)
        #expect(!deleted)
        #expect(secrets.counts == Counts())
    }

    @Test func libraryDeleteNamesTheAccountToClean() throws {
        let secrets = InMemorySecretStore(passwords: [id1.uuidString: "one"])
        var library = ProfileLibrary()
        library.add(savedProfile(1))
        let removed = library.delete(profileID: id1)
        let account = try #require(removed)
        try secrets.deletePassword(for: account)
        #expect(secrets.accounts.isEmpty)
    }

    // MARK: Orphaned passwords

    @Test func orphanedPasswordsAreRemovedOnlyAfterACleanLoad() throws {
        let known = savedProfile(1)
        var library = ProfileLibrary()
        library.add(known)
        let secrets = SpySecretStore(passwords: [known.secretAccount: "kept", "EARLIER-INSTALL": "old", "INTERRUPTED": "x"])
        for outcome in PersistenceFixtures.uncleanOutcomes {
            let removed = try ConnectionCredentials.removeOrphanedPasswords(after: ProfileStore.LoadResult(library: library, outcome: outcome),
                                                                            store: secrets)
            #expect(removed.isEmpty, "\(outcome)")
        }
        #expect(secrets.counts == Counts())

        let clean = ProfileStore.LoadResult(library: library, outcome: .loaded)
        let removed = try ConnectionCredentials.removeOrphanedPasswords(after: clean, store: secrets)
        #expect(removed == ["EARLIER-INSTALL", "INTERRUPTED"])
        #expect(secrets.storedPassword(for: known.secretAccount) == "kept")
        #expect(try secrets.listAccounts() == [known.secretAccount])
        #expect(secrets.counts == Counts(reads: 0, writes: 0, deletes: 2, lists: 2))
    }

    @Test func emptyLibraryAfterACleanLoadRemovesEveryPassword() throws {
        // A reinstall: the Keychain outlived the app, the new list is empty.
        let secrets = InMemorySecretStore(passwords: ["OLD-1": "a", "OLD-2": "b"])
        let removed = try ConnectionCredentials.removeOrphanedPasswords(after: ProfileStore.LoadResult(library: ProfileLibrary(), outcome: .loaded),
                                                                        store: secrets)
        #expect(removed == ["OLD-1", "OLD-2"])
        #expect(secrets.accounts.isEmpty)
    }

    @Test func listingFailureRemovesNothing() {
        let secrets = SpySecretStore(passwords: ["ORPHAN": "x"])
        secrets.injectFailures(list: locked)
        #expect(throws: locked) {
            try ConnectionCredentials.removeOrphanedPasswords(after: ProfileStore.LoadResult(library: ProfileLibrary(), outcome: .loaded),
                                                              store: secrets)
        }
        #expect(secrets.counts.deletes == 0)
        #expect(secrets.storedPassword(for: "ORPHAN") == "x")
    }
}
