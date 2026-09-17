import Testing
@testable import PortlightKit

@Suite("Persistence: connection draft")
struct PersistenceConnectionDraftTests {
    private typealias Message = ConnectionDraft.Message

    private func draft(host: String = "studio.local", port: String = "5920", password: String = "", name: String = "") -> ConnectionDraft {
        var draft = ConnectionDraft()
        draft.name = name
        draft.host = host
        draft.port = port
        draft.password = password
        return draft
    }

    @Test func newDraftDefaults() {
        let draft = ConnectionDraft()
        #expect(draft.isNew)
        #expect(draft.port == "5920")
        #expect(draft.rememberPassword)
        #expect(draft.saveActionTitle == "Save Connection")
        #expect(draft.passwordPlaceholder == "Password")
        #expect(!draft.canUseSavedPassword)
        #expect(!draft.savedPasswordIsForOtherComputer)
    }

    @Test func editingDraftPrefillsWithoutAnyPassword() {
        let profile = PersistenceFixtures.profile(1, name: "Edit Bay", host: "studio.local", port: 5921,
                                                  group: PersistenceFixtures.id(100), hasSavedPassword: true)
        let draft = ConnectionDraft(editing: profile)
        #expect(!draft.isNew)
        #expect(draft.name == "Edit Bay")
        #expect(draft.host == "studio.local")
        #expect(draft.port == "5921")
        #expect(draft.password == "")
        #expect(draft.rememberPassword)
        #expect(draft.groupID == PersistenceFixtures.id(100))
        #expect(draft.original == profile)
        #expect(draft.saveActionTitle == "Update Connection")
        #expect(draft.passwordPlaceholder == "Saved password is used when connecting")
        #expect(draft.canUseSavedPassword)
        #expect(!draft.savedPasswordIsForOtherComputer)
    }

    @Test func editingAConnectionSavedWithoutAPasswordStartsWithRememberOff() {
        // Typing a password only to connect must not save it on a later Update.
        let draft = ConnectionDraft(editing: PersistenceFixtures.profile(1, hasSavedPassword: false))
        #expect(!draft.rememberPassword)
    }

    @Test func messagesAreTheSpecifiedSentences() {
        #expect(Message.hostRequired == "Enter the computer's name or IP address.")
        #expect(Message.hostInvalid == "Use only a host name or IP address — no wss://, path, or port.")
        #expect(Message.portInvalid == "Use a port from 1 to 65535.")
        #expect(Message.passwordRequired == "Enter the password set in Portlight Host.")
        #expect(Message.savedPasswordForOtherComputer == "The saved password is for a different computer, so it won't be sent to this one.")
        #expect(Message.savedPasswordRemoved == "The saved password was for a different computer, so it was removed.")
    }

    // MARK: Computer

    @Test func computerIsRequired() {
        for host in ["", "   "] {
            let validation = draft(host: host, password: "pw").validate(for: .connect)
            #expect(validation.errors == [.host: "Enter the computer's name or IP address."])
        }
    }

    @Test(arguments: ["wss://studio.local", "https://studio.local", "studio.local/remote", "studio.local:5920",
                      "user@studio.local", "studio.local?x=1", "studio local", "[::1]:5920", "fe80::1%en0", "12::34::56"])
    func computerMustBeABareAddress(_ host: String) {
        let validation = draft(host: host, password: "pw").validate(for: .save)
        #expect(validation.message(for: .host) == "Use only a host name or IP address — no wss://, path, or port.")
        #expect(draft(host: host).endpoint == nil)
    }

    @Test(arguments: ["studio.local", "Studio-Mac.local", "192.168.1.20", "fe80::1", "[fe80::1]", "2001:db8::a:1", "  studio.local  "])
    func bareAddressesAreAccepted(_ host: String) {
        #expect(draft(host: host, password: "pw").validate(for: .connect).isValid)
        #expect(draft(host: host).endpoint != nil)
    }

    // MARK: Port

    @Test(arguments: ["0", "65536", "-1", "abc", "59 20", "5920.0", "+5920", "１２３", "999999", "000005920"])
    func portMustBeDigitsInRange(_ port: String) {
        #expect(draft(port: port, password: "pw").validate(for: .connect).errors == [.port: "Use a port from 1 to 65535."])
        #expect(ConnectionDraft.parsePort(port) == nil)
    }

    @Test func validPorts() {
        #expect(ConnectionDraft.parsePort("1") == 1)
        #expect(ConnectionDraft.parsePort("65535") == 65535)
        #expect(ConnectionDraft.parsePort(" 5921 ") == 5921)
        #expect(ConnectionDraft.parsePort("05920") == 5920)
        #expect(ConnectionDraft.parsePort("") == 5920)
        #expect(draft(port: "", password: "pw").validate(for: .connect).isValid)
        #expect(draft(port: "").endpoint?.port == 5920)
    }

    // MARK: Password

    @Test func connectingANewConnectionNeedsAPasswordButSavingDoesNot() {
        #expect(draft().validate(for: .connect).errors == [.password: "Enter the password set in Portlight Host."])
        #expect(draft().validate(for: .save).isValid)
        #expect(draft(password: "pw").validate(for: .connect).isValid)
    }

    @Test func savedPasswordCoversConnectingOnlyToItsOwnComputer() {
        var editing = ConnectionDraft(editing: PersistenceFixtures.profile(1, host: "studio.local", hasSavedPassword: true))
        #expect(editing.validate(for: .connect).isValid)
        editing.host = "STUDIO.local"
        #expect(editing.validate(for: .connect).isValid)
        #expect(!editing.savedPasswordIsForOtherComputer)
        editing.host = "other.local"
        #expect(!editing.canUseSavedPassword)
        #expect(editing.savedPasswordIsForOtherComputer)
        #expect(editing.passwordPlaceholder == "Password")
        #expect(editing.validate(for: .connect).errors == [.password: Message.passwordRequired])
        editing.host = "studio.local"
        editing.port = "5921"
        #expect(editing.savedPasswordIsForOtherComputer)
        #expect(editing.validate(for: .connect).errors == [.password: Message.passwordRequired])
        editing.password = "typed"
        #expect(editing.validate(for: .connect).isValid)
    }

    @Test func passwordSavedBeforeItWasBoundCountsAsAnotherComputers() {
        var profile = PersistenceFixtures.profile(1, host: "studio.local", hasSavedPassword: true)
        profile.passwordEndpointKey = nil
        let editing = ConnectionDraft(editing: profile)
        #expect(!editing.canUseSavedPassword)
        #expect(editing.savedPasswordIsForOtherComputer)
        #expect(editing.validate(for: .connect).errors == [.password: Message.passwordRequired])
    }

    @Test func profileWithoutASavedPasswordStillNeedsOne() {
        let editing = ConnectionDraft(editing: PersistenceFixtures.profile(1))
        #expect(editing.validate(for: .connect).errors == [.password: Message.passwordRequired])
        #expect(!editing.savedPasswordIsForOtherComputer)
    }

    @Test func invalidAddressDoesNotAlsoDemandTheSavedPassword() {
        var editing = ConnectionDraft(editing: PersistenceFixtures.profile(1, hasSavedPassword: true))
        editing.host = ""
        #expect(editing.validate(for: .connect).errors == [.host: Message.hostRequired])
        #expect(!editing.savedPasswordIsForOtherComputer)
    }

    @Test func passwordLimitCountsUTF8Bytes() {
        let euros = String(repeating: "€", count: 342)
        #expect(euros.count < 1024)
        #expect(euros.utf8.count == 1026)
        let tooLong = "Use a shorter password — Portlight Host allows up to 1024 bytes."
        #expect(draft(password: euros).validate(for: .connect).errors == [.password: tooLong])
        #expect(draft(password: euros).validate(for: .save).errors == [.password: tooLong])
        #expect(draft(password: String(repeating: "a", count: 1024)).validate(for: .connect).isValid)
        #expect(draft(password: String(repeating: "a", count: 1025)).validate(for: .connect).message(for: .password) == tooLong)
    }

    // MARK: Errors and focus

    @Test func errorsArePerFieldAndFocusFollowsFormOrder() {
        var form = draft(host: "", port: "0", password: "")
        let connect = form.validate(for: .connect)
        #expect(connect.errors == [.host: Message.hostRequired, .password: Message.passwordRequired, .port: Message.portInvalid])
        #expect(connect.firstInvalidField == .host)
        #expect(!connect.isValid)

        form.name = String(repeating: "n", count: 101)
        let save = form.validate(for: .save)
        #expect(save.firstInvalidField == .name)
        #expect(save.message(for: .name) == "Use a name of up to 100 characters.")
        #expect(save.message(for: .password) == nil)
        #expect(form.validate(for: .connect).message(for: .name) == nil)
    }

    @Test func returnKeyOrderIsNameComputerPasswordPort() {
        typealias Field = ConnectionDraft.Field
        #expect(Field.allCases == [.name, .host, .password, .port])
        #expect(Field.name.next == .host)
        #expect(Field.host.next == .password)
        #expect(Field.password.next == .port)
        #expect(Field.port.next == nil)
        #expect(Field.allCases.map(\.title) == ["Name", "Computer", "Password", "Port"])
    }

    // MARK: Building profiles

    @Test func newConnectionBuildsANormalizedProfile() throws {
        var form = ConnectionDraft(groupID: PersistenceFixtures.id(100))
        form.name = "  Color Suite "
        form.host = " [FE80::1] "
        form.port = " 5921"
        form.password = "typed, not stored here"
        let profile = try #require(form.makeProfile(now: PersistenceFixtures.now, id: PersistenceFixtures.id(9)))
        #expect(profile.id == PersistenceFixtures.id(9))
        #expect(profile.name == "Color Suite")
        #expect(profile.host == "FE80::1")
        #expect(profile.port == 5921)
        #expect(profile.groupID == PersistenceFixtures.id(100))
        #expect(profile.createdAt == PersistenceFixtures.now)
        #expect(profile.lastConnectedAt == nil)
        #expect(!profile.hasSavedPassword)
        #expect(profile.passwordEndpointKey == nil)
        #expect(profile.preferences == .standard)
        #expect(profile.endpoint?.canonicalKey == "[fe80::1]:5921")
    }

    @Test func snapshotUpdateKeepsIdentityPositionDatesAndPreferences() throws {
        var original = PersistenceFixtures.profile(4, name: "Old", host: "old.local", group: PersistenceFixtures.id(100), hasSavedPassword: true)
        original.sortIndex = 3
        original.lastConnectedAt = PersistenceFixtures.now
        original.preferences = ViewerPreferences(resolution: .uhd, inputMode: .direct)
        var form = ConnectionDraft(editing: original)
        form.name = "New"
        form.host = "new.local"
        form.port = "6000"
        let updated = try #require(form.makeProfile(now: PersistenceFixtures.now.addingTimeInterval(999), id: PersistenceFixtures.id(77)))
        #expect(updated.id == original.id)
        #expect(updated.sortIndex == 3)
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.lastConnectedAt == PersistenceFixtures.now)
        #expect(updated.preferences == original.preferences)
        #expect(updated.hasSavedPassword)
        #expect(updated.groupID == PersistenceFixtures.id(100))
        #expect(updated.name == "New")
        #expect(updated.host == "new.local")
        #expect(updated.port == 6000)
        // The hint still names old.local, so the saved password is never used for new.local.
        #expect(updated.passwordEndpointKey == "old.local:5920")
        #expect(!updated.canUseSavedPassword(for: PersistenceFixtures.endpoint("new.local", 6000)))
    }

    @Test func mergingAppliesOnlyTheFormsFieldsToTheCurrentCopy() throws {
        let original = PersistenceFixtures.profile(4, name: "Old", host: "old.local", group: PersistenceFixtures.id(100), hasSavedPassword: true)
        var form = ConnectionDraft(editing: original)
        form.name = " New "
        form.host = "new.local"
        form.port = "6000"
        // Changed elsewhere while the form was open.
        var current = original
        current.lastConnectedAt = PersistenceFixtures.now
        current.preferences = ViewerPreferences(resolution: .uhd, inputMode: .direct)
        current.groupID = PersistenceFixtures.id(200)
        current.sortIndex = 5
        current.hasSavedPassword = false
        current.passwordEndpointKey = nil

        let merged = try #require(form.makeProfile(mergingInto: current))
        #expect(merged.name == "New")
        #expect(merged.host == "new.local")
        #expect(merged.port == 6000)
        var expected = current
        expected.name = "New"
        expected.host = "new.local"
        expected.port = 6000
        #expect(merged == expected)
    }

    @Test func mergingAppliesAGroupChosenInTheForm() throws {
        let original = PersistenceFixtures.profile(4, group: PersistenceFixtures.id(100))
        var form = ConnectionDraft(editing: original)
        form.groupID = nil
        var current = original
        current.groupID = PersistenceFixtures.id(200)
        #expect(try #require(form.makeProfile(mergingInto: current)).groupID == nil)
    }

    @Test func mergingIntoAnotherConnectionOrFromAnInvalidFormGivesNothing() {
        var form = ConnectionDraft(editing: PersistenceFixtures.profile(4))
        #expect(form.makeProfile(mergingInto: PersistenceFixtures.profile(5)) == nil)
        form.port = "0"
        #expect(form.makeProfile(mergingInto: PersistenceFixtures.profile(4)) == nil)
    }

    @Test func markSavedTurnsANewFormIntoAnUpdateAndKeepsWhatWasTyped() throws {
        var form = draft(password: "typed pw")
        form.rememberPassword = false
        form.groupID = PersistenceFixtures.id(999)
        var profile = try #require(form.makeProfile(now: PersistenceFixtures.now, id: PersistenceFixtures.id(1)))
        profile.groupID = nil   // the library had no such group
        form.markSaved(as: profile)
        #expect(!form.isNew)
        #expect(form.original == profile)
        #expect(form.saveActionTitle == "Update Connection")
        #expect(form.password == "typed pw")
        #expect(!form.rememberPassword)
        #expect(form.groupID == nil)
        #expect(form.validate(for: .connect).isValid)
    }

    @Test func invalidDraftBuildsNoProfile() {
        #expect(draft(host: "wss://studio.local").makeProfile() == nil)
        #expect(draft(port: "70000").makeProfile() == nil)
        #expect(draft(password: String(repeating: "a", count: 1025)).makeProfile() == nil)
        #expect(draft(name: String(repeating: "n", count: 101)).makeProfile() == nil)
        #expect(draft().makeProfile() != nil)
    }

    @Test func unnamedSaveStaysUnnamed() throws {
        let profile = try #require(draft(host: "10.0.0.5").makeProfile())
        #expect(profile.name == "")
        #expect(profile.displayTitle == "Saved Connection")
        #expect(profile.subtitle == "10.0.0.5")
    }

    @Test func descriptionsNeverShowThePassword() {
        let form = draft(password: "hunter2-secret")
        #expect(!String(describing: form).contains("hunter2"))
        #expect(!"\(form)".contains("hunter2"))
        #expect(!form.debugDescription.contains("hunter2"))
        var dumped = ""
        dump(form, to: &dumped)
        #expect(!dumped.contains("hunter2"))
        #expect(dumped.contains("studio.local"))
        #expect(String(describing: form).contains("<redacted>"))
    }
}
