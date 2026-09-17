import Testing
@testable import PortlightKit

// `saveConnection` takes the draft and library `inout`, and `#expect`/`#require` capture operands immutably, so
// every call runs first and its result is checked after.

/// `ConnectionCredentials.saveConnection`, the Save Connection / Update Connection flow: what is stored, in which
/// order, and what survives changes made while the form was open.
@Suite("Persistence: save and update")
struct PersistenceSaveConnectionTests {
    private typealias Message = ConnectionDraft.Message
    private let id1 = PersistenceFixtures.id(1)
    private let studio = PersistenceFixtures.endpoint("studio.local")
    private let other = PersistenceFixtures.endpoint("other.local")
    private let locked = SecretStoreError.keychain(PersistenceFixtures.keychainLocked)
    private var account: String { id1.uuidString }

    /// Profile 1 ("Edit Bay" on studio.local) alone, with a password saved for studio.local when `saved`.
    private func savedLibrary(saved: Bool = true) -> ProfileLibrary {
        var library = ProfileLibrary()
        library.add(PersistenceFixtures.profile(1, name: "Edit Bay", host: "studio.local", hasSavedPassword: saved))
        return library
    }

    private func newDraft(password: String = "", remember: Bool = true) -> ConnectionDraft {
        var draft = ConnectionDraft()
        draft.name = "Edit Bay"
        draft.host = "studio.local"
        draft.password = password
        draft.rememberPassword = remember
        return draft
    }

    private func editing(_ library: ProfileLibrary) throws -> ConnectionDraft {
        ConnectionDraft(editing: try #require(library.profile(id: id1)))
    }

    private func resolve(_ profile: ConnectionProfile?, _ endpoint: HostEndpoint, store: SecretStore) throws
        -> ConnectionCredentials.PasswordResolution {
        try ConnectionCredentials.resolvePassword(profile: profile, typedPassword: "", store: store, connectingTo: endpoint)
    }

    // MARK: New connections

    @Test func newConnectionIsSavedBeforeItsPasswordThenBoundToItsComputer() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log)
        var library = ProfileLibrary()
        var draft = newDraft(password: "correct horse")
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist,
                                                              now: PersistenceFixtures.now, id: id1)
        let result = try #require(outcome)
        #expect(log.events == ["persist studio.local=none", "keychain set \(account)", "persist studio.local=studio.local:5920"])
        #expect(result.added)
        #expect(result.passwordChange == .saved)
        #expect(result.passwordError == nil)
        #expect(result.message == nil)
        #expect(result.profile.hasSavedPassword)
        #expect(result.profile.passwordEndpointKey == "studio.local:5920")
        #expect(result.profile.createdAt == PersistenceFixtures.now)
        #expect(library.profiles == [result.profile])
        #expect(log.persisted.last == library)
        #expect(secrets.spy.storedPassword(for: account) == "correct horse")
        #expect(secrets.spy.counts == SpySecretStore.Counts(reads: 0, writes: 1, deletes: 0))
        // The form now edits the saved connection and still holds what was typed.
        #expect(!draft.isNew)
        #expect(draft.original == result.profile)
        #expect(draft.password == "correct horse")
        #expect(draft.saveActionTitle == "Update Connection")
    }

    @Test func secondTapUpdatesInsteadOfAddingADuplicate() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log)
        var library = ProfileLibrary()
        var draft = newDraft(password: "pw")
        let first = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist, id: id1)
        let second = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist,
                                                             id: PersistenceFixtures.id(2))
        #expect(first?.added == true)
        #expect(second?.added == false)
        #expect(library.profiles.map(\.id) == [id1])
        // Same computer: the list keeps its password while the Keychain item is replaced in place.
        #expect(Array(log.events.suffix(2)) == ["persist studio.local=studio.local:5920", "keychain set \(account)"])
    }

    @Test func rememberOffSavesNoPasswordButKeepsTheTypedOneForConnect() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log)
        var library = ProfileLibrary()
        var draft = newDraft(password: "typed only", remember: false)
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist, id: id1)
        let result = try #require(outcome)
        #expect(log.events == ["persist studio.local=none"])
        #expect(result.passwordChange == .forgotten)
        #expect(!result.profile.hasSavedPassword)
        #expect(draft.validate(for: .connect).isValid)
        let resolution = try ConnectionCredentials.resolvePassword(profile: library.profile(id: id1), typedPassword: draft.password,
                                                                  store: secrets, connectingTo: studio)
        #expect(resolution == .typed("typed only"))
    }

    @Test func newConnectionWithoutAPasswordTouchesNoKeychain() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log)
        var library = ProfileLibrary()
        var draft = newDraft()
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist, id: id1)
        #expect(outcome?.passwordChange == .unchanged)
        #expect(log.events == ["persist studio.local=none"])
    }

    @Test func failedFirstSaveChangesNothingAndStoresNoPassword() {
        let log = PersistenceEventLog()
        log.failPersist(onCalls: [1])
        let secrets = PersistenceLoggingSecretStore(log: log)
        var library = ProfileLibrary()
        var draft = newDraft(password: "pw")
        var thrown: (any Error)?
        do {
            _ = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist, id: id1)
        } catch {
            thrown = error
        }
        #expect(thrown as? PersistenceError == .existingFileNotLoaded("Connections.json"))
        #expect(library.isEmpty)
        #expect(log.events == ["persist failed"])
        #expect(secrets.spy.counts == SpySecretStore.Counts())
        #expect(draft.isNew)
    }

    @Test func refusedKeychainWriteKeepsTheConnectionWithoutAPassword() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log)
        secrets.spy.injectFailures(write: locked)
        var library = ProfileLibrary()
        var draft = newDraft(password: "pw")
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist, id: id1)
        let result = try #require(outcome)
        #expect(log.events == ["persist studio.local=none", "keychain set \(account)"])
        #expect(result.passwordError as? SecretStoreError == locked)
        #expect(result.message == "The connection was saved, but its password wasn't. Keychain is locked. Unlock this iPhone, then try again.")
        #expect(!result.profile.hasSavedPassword)
        #expect(library.profiles == [result.profile])
        #expect(!draft.isNew)
    }

    @Test func failedSecondSaveLeavesThePasswordUnusedNeverMisattached() throws {
        let log = PersistenceEventLog()
        log.failPersist(onCalls: [2])
        let secrets = PersistenceLoggingSecretStore(log: log)
        var library = ProfileLibrary()
        var draft = newDraft(password: "pw")
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist, id: id1)
        let result = try #require(outcome)
        #expect(log.events == ["persist studio.local=none", "keychain set \(account)", "persist failed"])
        #expect(result.passwordError as? PersistenceError == .existingFileNotLoaded("Connections.json"))
        // Memory matches what reached the disk: no password is claimed, so none is read or sent.
        #expect(library.profile(id: id1)?.hasSavedPassword == false)
        #expect(log.persisted.last?.profile(id: id1)?.hasSavedPassword == false)
        #expect(try resolve(library.profile(id: id1), studio, store: secrets) == .needsPassword(.noneSaved))
        #expect(secrets.spy.readCount == 0)
    }

    @Test func invalidFormSavesNothing() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log)
        var library = ProfileLibrary()
        var draft = newDraft(password: "pw")
        draft.host = "wss://studio.local"
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist)
        #expect(outcome == nil)
        #expect(log.events.isEmpty)
        #expect(library.isEmpty)
        #expect(draft.isNew)
    }

    // MARK: A saved password never follows an edited Computer

    @Test func changedComputerWithoutAPasswordRemovesTheOldOne() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log, passwords: [account: "password-for-A"])
        var library = savedLibrary()
        var draft = try editing(library)
        #expect(draft.rememberPassword)
        draft.host = "other.local"
        #expect(!draft.canUseSavedPassword)
        #expect(draft.savedPasswordIsForOtherComputer)
        #expect(draft.passwordPlaceholder == "Password")

        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist)
        let result = try #require(outcome)
        #expect(log.events == ["persist other.local=none", "keychain delete \(account)"])
        #expect(result.passwordChange == .removedForOtherComputer)
        #expect(result.message == Message.savedPasswordRemoved)
        #expect(secrets.spy.storedPassword(for: account) == nil)

        // Reopened and connected: a password must be typed, and nothing is read for either computer.
        let stored = try #require(library.profile(id: id1))
        #expect(!stored.hasSavedPassword)
        let reopened = ConnectionDraft(editing: stored)
        #expect(!reopened.canUseSavedPassword)
        #expect(reopened.validate(for: .connect).message(for: .password) == Message.passwordRequired)
        #expect(try resolve(stored, other, store: secrets) == .needsPassword(.noneSaved))
        #expect(try resolve(stored, studio, store: secrets) == .needsPassword(.noneSaved))
        #expect(secrets.spy.readCount == 0)
    }

    @Test func changedComputerWithANewPasswordBindsItToTheNewComputerOnly() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log, passwords: [account: "password-for-A"])
        var library = savedLibrary()
        var draft = try editing(library)
        draft.host = "other.local"
        draft.password = "password-for-B"
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist)
        #expect(outcome?.passwordChange == .saved)
        #expect(log.events == ["persist other.local=none", "keychain set \(account)", "persist other.local=other.local:5920"])
        let stored = try #require(library.profile(id: id1))
        #expect(try resolve(stored, other, store: secrets) == .saved("password-for-B"))
        #expect(try resolve(stored, studio, store: secrets) == .needsPassword(.differentComputer))
        #expect(secrets.spy.readAccounts == [account])
    }

    @Test func sameComputerSpelledDifferentlyKeepsItsPassword() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log, passwords: [account: "saved"])
        var library = savedLibrary()
        var draft = try editing(library)
        draft.host = " STUDIO.Local "
        draft.port = " 5920"
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist)
        #expect(outcome?.passwordChange == .unchanged)
        #expect(log.events == ["persist STUDIO.Local=studio.local:5920"])
        #expect(try resolve(library.profile(id: id1), studio, store: secrets) == .saved("saved"))
    }

    @Test func changedPortIsAnotherComputer() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log, passwords: [account: "saved"])
        var library = savedLibrary()
        var draft = try editing(library)
        draft.port = "5921"
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist)
        #expect(outcome?.passwordChange == .removedForOtherComputer)
        #expect(secrets.spy.storedPassword(for: account) == nil)
    }

    @Test func rememberOffOnUpdateDeletesTheSavedPasswordAfterSavingTheList() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log, passwords: [account: "saved"])
        var library = savedLibrary()
        var draft = try editing(library)
        draft.rememberPassword = false
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist)
        #expect(outcome?.passwordChange == .forgotten)
        #expect(log.events == ["persist studio.local=none", "keychain delete \(account)"])
        #expect(secrets.spy.storedPassword(for: account) == nil)
    }

    @Test func refusedDeletionIsReportedAndThePasswordIsStillNeverSent() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log, passwords: [account: "password-for-A"])
        secrets.spy.injectFailures(delete: locked)
        var library = savedLibrary()
        var draft = try editing(library)
        draft.host = "other.local"
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist)
        let result = try #require(outcome)
        #expect(result.passwordError as? SecretStoreError == locked)
        #expect(result.message?.hasPrefix("The connection was saved, but its saved password couldn't be removed.") == true)
        #expect(secrets.spy.storedPassword(for: account) == "password-for-A")
        let stored = try #require(library.profile(id: id1))
        #expect(!stored.hasSavedPassword)
        #expect(try resolve(stored, other, store: secrets) == .needsPassword(.noneSaved))
        #expect(secrets.spy.readCount == 0)
    }

    // MARK: Changes made while the form was open

    @Test func updateKeepsChangesMadeWhileTheFormWasOpen() throws {
        var library = ProfileLibrary()
        let g1 = library.createGroup(named: "One", id: PersistenceFixtures.id(100)).id
        let g2 = library.createGroup(named: "Two", id: PersistenceFixtures.id(200)).id
        library.add(PersistenceFixtures.profile(1, name: "Bay", group: g1))
        library.add(PersistenceFixtures.profile(2, group: g2))
        var draft = try editing(library)

        // Meanwhile the session records a connection and a quality change, and the list moves the row.
        library.markConnected(id1, at: PersistenceFixtures.now)
        var changed = try #require(library.profile(id: id1))
        changed.preferences.resolution = .fhd
        library.update(changed)
        library.moveProfile(id1, toGroup: g2, at: 0)

        draft.name = "Bay 2"
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: InMemorySecretStore(), persist: { _ in })
        #expect(outcome?.added == false)
        let after = try #require(library.profile(id: id1))
        #expect(after.name == "Bay 2")
        #expect(after.lastConnectedAt == PersistenceFixtures.now)
        #expect(after.preferences.resolution == .fhd)
        #expect(after.groupID == g2)
        #expect(library.profiles(in: g2).map(\.id) == [id1, PersistenceFixtures.id(2)])
    }

    @Test func groupChosenInTheFormIsApplied() throws {
        var library = ProfileLibrary()
        let g1 = library.createGroup(named: "One", id: PersistenceFixtures.id(100)).id
        let g2 = library.createGroup(named: "Two", id: PersistenceFixtures.id(200)).id
        library.add(PersistenceFixtures.profile(2, group: g2))
        library.add(PersistenceFixtures.profile(1, group: g1))
        var draft = try editing(library)
        draft.groupID = g2
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: InMemorySecretStore(), persist: { _ in })
        #expect(outcome?.profile.groupID == g2)
        #expect(library.profiles(in: g2).map(\.id) == [PersistenceFixtures.id(2), id1])
        #expect(library.profiles(in: g1).isEmpty)
        #expect(draft.groupID == g2)
    }

    @Test func passwordHintClearedWhileTheFormWasOpenStaysCleared() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log)
        var library = savedLibrary()
        var draft = try editing(library)
        // Connecting found no Keychain item, so the session cleared the hint.
        library.recordSavedPassword(id1, for: nil)
        draft.name = "Renamed"
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist)
        #expect(outcome?.passwordChange == .unchanged)
        #expect(log.events == ["persist studio.local=none"])
        #expect(library.profile(id: id1)?.hasSavedPassword == false)
    }

    @Test func connectionDeletedWhileItsFormWasOpenIsAddedAgainWithoutAPassword() throws {
        let log = PersistenceEventLog()
        let secrets = PersistenceLoggingSecretStore(log: log)
        var library = savedLibrary()
        var draft = try editing(library)
        library.delete(profileID: id1)
        let outcome = try ConnectionCredentials.saveConnection(&draft, in: &library, store: secrets, persist: log.persist,
                                                              id: PersistenceFixtures.id(9))
        let result = try #require(outcome)
        #expect(result.added)
        #expect(result.profile.id == id1)
        #expect(!result.profile.hasSavedPassword)
        #expect(log.events == ["persist studio.local=none"])
    }
}
