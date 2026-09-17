import Foundation
import Observation
import PortlightKit

/// An inline message under one field of the connection form, from a Connect that could not start.
struct ConnectFieldError: Equatable {
    /// The saved connection it belongs to; nil for a new, unsaved form.
    var profileID: UUID?
    var field: ConnectionDraft.Field
    var message: String
}

/// App state above the session: the saved connections, navigation, and the Connect / Save / Delete flows.
///
/// Every change to the library is written through `ProfileStore`. The session controller also writes the
/// connected profile's `preferences` and `lastConnectedAt` (read-modify-write, off the main actor); those two
/// fields are owned by the session, so before each save the app takes them from the file instead of from its own
/// copy, and never reverts them.
@MainActor @Observable
final class AppModel {
    @ObservationIgnored let environment: AppEnvironment
    var library: ProfileLibrary
    var path: [ConnectionRoute] = []
    /// Non-blocking notices for the Connections screen (launch load, storage, failed saves).
    var notices: [String] = []
    var connectError: ConnectFieldError?
    /// A Connect succeeded and its session hasn't returned to idle yet (drives the session cover).
    private(set) var sessionStarted = false
    /// The name shown in the session's top bar.
    private(set) var sessionTitle = ""
    private(set) var sessionProfileID: UUID?

    var controller: SessionController { environment.controller }

    init(environment: AppEnvironment) {
        self.environment = environment
        let result = environment.profileStore.load()
        library = result.library
        if let message = Self.launchNotice(for: result.outcome) { notices.append(message) }
        if let storage = environment.storageNotice { notices.append(storage) }
        // Only a clean load proves which Keychain items are orphans.
        if result.outcome == .loaded {
            _ = try? ConnectionCredentials.removeOrphanedPasswords(after: result, store: environment.secrets)
        }
    }

    /// The Connections screen's notice for each launch outcome (exhaustive, so a new outcome must be handled).
    static func launchNotice(for outcome: ProfileStore.LoadOutcome) -> String? {
        switch outcome {
        case .loaded:
            return nil
        case .recovered, .partiallyRecovered, .unavailable, .newerVersion:
            return outcome.message
        }
    }

    var isSessionPresented: Bool { sessionStarted && controller.phase != .idle }

    // MARK: Library

    /// A list edit (reorder, group move, disclosure, rename): applied and saved.
    func applyListEdit(_ edited: ProfileLibrary) {
        guard edited != library else { return }
        library = edited
        persist()
    }

    func persist() {
        do {
            // Serialized with the session's preference writes, so none can land between this load and save.
            try controller.withProfileWritesSerialized {
                mergeSessionOwnedFields()
                try environment.profileStore.save(library)
            }
        } catch {
            post("Your change to the connections couldn’t be saved. " + Self.describe(error))
        }
    }

    /// Takes `preferences` and `lastConnectedAt` from the saved file, where the session writes them.
    func mergeSessionOwnedFields() {
        let disk = environment.profileStore.load()
        guard disk.outcome == .loaded else { return }
        for profile in library.profiles {
            guard let saved = disk.library.profile(id: profile.id),
                  saved.preferences != profile.preferences || saved.lastConnectedAt != profile.lastConnectedAt else { continue }
            var merged = profile
            merged.preferences = saved.preferences
            merged.lastConnectedAt = saved.lastConnectedAt
            _ = library.update(merged)
        }
    }

    /// Save Connection / Update Connection. Returns a message to show, or nil when there is nothing to say.
    func save(_ draft: inout ConnectionDraft) -> String? {
        let store = environment.profileStore
        do {
            // The merge and the save run together, serialized with the session's preference writes.
            let result = try controller.withProfileWritesSerialized {
                mergeSessionOwnedFields()
                return try ConnectionCredentials.saveConnection(&draft, in: &library, store: environment.secrets,
                                                                persist: { try store.save($0) })
            }
            return result?.message
        } catch {
            return "The connection couldn’t be saved. " + Self.describe(error)
        }
    }

    func forgetPassword(profileID: UUID) {
        guard let current = library.profile(id: profileID) else { return }
        do {
            let updated = try ConnectionCredentials.forgetPassword(for: current, store: environment.secrets)
            _ = library.update(updated)
            persist()
        } catch {
            post("The saved password couldn’t be removed. " + Self.describe(error))
        }
    }

    func delete(_ profile: ConnectionProfile) {
        do {
            _ = try ConnectionCredentials.deleteProfile(profile.id, from: &library, store: environment.secrets)
        } catch {
            post("The saved password for \(profile.displayTitle) couldn’t be removed. " + Self.describe(error))
            _ = library.delete(profileID: profile.id)
        }
        persist()
        path.removeAll { $0 == .edit(profile.id) }
    }

    func dismissNotice(_ notice: String) {
        notices.removeAll { $0 == notice }
    }

    private func post(_ notice: String) {
        if !notices.contains(notice) { notices.append(notice) }
    }

    // MARK: Connect

    /// Connect from the form: its current fields (saved or not) and its typed password.
    func connect(draft: ConnectionDraft) {
        connectError = nil
        let profile: ConnectionProfile?
        if let original = draft.original, let current = library.profile(id: original.id) {
            profile = draft.makeProfile(mergingInto: current)
        } else {
            profile = draft.makeProfile()
        }
        guard let profile else {
            connectError = ConnectFieldError(profileID: draft.original?.id, field: .host,
                                             message: SessionConnectError.invalidAddress.errorDescription ?? "")
            return
        }
        start(profile, typedPassword: draft.password, formProfileID: draft.original?.id)
    }

    /// Connect from a row's context menu: the saved connection and its saved password. Its form is pushed first,
    /// so leaving the session (or a password prompt) lands there.
    func connectFromList(_ profile: ConnectionProfile) {
        connectError = nil
        if path.last != .edit(profile.id) { path.append(.edit(profile.id)) }
        start(profile, typedPassword: "", formProfileID: profile.id)
    }

    private func start(_ profile: ConnectionProfile, typedPassword: String, formProfileID: UUID?) {
        do {
            try controller.connect(profile: profile, typedPassword: typedPassword)
            sessionTitle = profile.isUnnamed ? (profile.endpoint?.description ?? profile.displayTitle) : profile.displayTitle
            sessionProfileID = formProfileID
            sessionStarted = true
        } catch let error as SessionConnectError {
            connectError = fieldError(for: error, profile: profile, typedPassword: typedPassword, formProfileID: formProfileID)
        } catch {
            connectError = ConnectFieldError(profileID: formProfileID, field: .password, message: Self.describe(error))
        }
    }

    static let missingSavedPassword = "The saved password isn’t in this iPhone’s Keychain any more. Enter it to connect."

    private func fieldError(for error: SessionConnectError, profile: ConnectionProfile, typedPassword: String,
                            formProfileID: UUID?) -> ConnectFieldError {
        switch error {
        case .invalidAddress:
            return ConnectFieldError(profileID: formProfileID, field: .host, message: error.errorDescription ?? "")
        case .keychain(let message):
            return ConnectFieldError(profileID: formProfileID, field: .password, message: message)
        case .passwordRequired:
            // The session says why. An item missing from the Keychain (for example after a restore to another
            // iPhone) leaves a stale "saved" hint, which is cleared.
            if typedPassword.isEmpty, controller.missingPassword == .missingFromKeychain {
                if library.profile(id: profile.id) != nil {
                    _ = library.recordSavedPassword(profile.id, for: nil)
                    persist()
                }
                return ConnectFieldError(profileID: formProfileID, field: .password, message: Self.missingSavedPassword)
            }
            return ConnectFieldError(profileID: formProfileID, field: .password, message: ConnectionDraft.Message.passwordRequired)
        }
    }

    /// Try Again on the failure card. When the password must be typed again (it was rejected), the session
    /// closes and the form asks for it.
    func retry() {
        guard !controller.retry() else { return }
        let id = sessionProfileID
        controller.cancel()
        connectError = ConnectFieldError(profileID: id, field: .password, message: ConnectionDraft.Message.passwordRequired)
    }

    /// The session returned to idle (disconnect, cancel, dismissed failure).
    func sessionPhaseChanged(_ phase: ConnectionPhase) {
        guard phase == .idle, sessionStarted else { return }
        sessionStarted = false
        mergeSessionOwnedFields()
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
