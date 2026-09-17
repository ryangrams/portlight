import Foundation

/// Password handling around saved connections.
///
/// - `resolvePassword` is the only place a saved password is read. It runs when the user connects — never when a
///   row is selected or a form is edited (notes §1).
/// - A saved password is bound to the computer it was typed for (`ConnectionProfile.passwordEndpointKey`) and is
///   only ever sent to that computer's canonical address. Update deletes it when the Computer changed and no new
///   password was typed, rather than moving it to the new address.
/// - `saveConnection` is the whole Save Connection / Update Connection flow.
public enum ConnectionCredentials {
    // MARK: Connecting

    /// Where the password for `hello` comes from. `description` and `dump` never show the password.
    public enum PasswordResolution: Equatable, Sendable {
        /// Typed in the form; the Keychain was not touched.
        case typed(String)
        /// Read from the Keychain, saved for this computer.
        case saved(String)
        /// The user must type one: show `ConnectionDraft.Message.passwordRequired`.
        case needsPassword(MissingPassword)

        /// The password to send, or nil when one must be typed.
        public var password: String? {
            switch self {
            case .typed(let password), .saved(let password): return password
            case .needsPassword: return nil
            }
        }
    }

    /// Why no password can be sent without typing one.
    public enum MissingPassword: Equatable, Sendable {
        /// Nothing is saved for this connection, or it isn't a saved connection. The Keychain was not read.
        case noneSaved
        /// A password is saved, but for a different computer than this address. The Keychain was not read.
        case differentComputer
        /// The profile says a password was saved for this computer, but the Keychain has none — for example after a
        /// backup was restored to another iPhone (the item is ThisDeviceOnly). Clear the hint with
        /// `ProfileLibrary.recordSavedPassword(_:for: nil)` and save the library.
        case missingFromKeychain
    }

    /// Chooses the password to send when connecting to `endpoint`.
    ///
    /// A typed password always wins and never touches the Keychain. Otherwise the Keychain is read once, and only
    /// when the profile says a password is saved for exactly this computer.
    public static func resolvePassword(profile: ConnectionProfile?, typedPassword: String, store: SecretStore,
                                       connectingTo endpoint: HostEndpoint) throws -> PasswordResolution {
        if !typedPassword.isEmpty { return .typed(typedPassword) }
        guard let profile, profile.hasSavedPassword else { return .needsPassword(.noneSaved) }
        guard profile.canUseSavedPassword(for: endpoint) else { return .needsPassword(.differentComputer) }
        guard let password = try store.password(for: profile.secretAccount), !password.isEmpty else {
            return .needsPassword(.missingFromKeychain)
        }
        return .saved(password)
    }

    /// The password to send in `hello`, or nil when the user must type one (`resolvePassword(...).password`).
    public static func resolve(profile: ConnectionProfile?, typedPassword: String, store: SecretStore,
                               connectingTo endpoint: HostEndpoint) throws -> String? {
        try resolvePassword(profile: profile, typedPassword: typedPassword, store: store, connectingTo: endpoint).password
    }

    // MARK: Save Connection / Update Connection

    /// What Save Connection / Update Connection did with the password.
    public enum PasswordChange: Equatable, Sendable {
        /// Nothing typed: a password saved for this computer, if any, is kept.
        case unchanged
        /// The typed password is saved for this computer.
        case saved
        /// Remember Password is off: no password is saved, and any saved one was deleted.
        case forgotten
        /// Nothing typed, and the saved password was for a different computer (the Computer changed): it was
        /// deleted rather than moved to the new address. Show `ConnectionDraft.Message.savedPasswordRemoved`.
        case removedForOtherComputer
    }

    /// The outcome of `saveConnection`.
    public struct SaveResult: Sendable {
        /// The connection as stored in the library and on disk. `hasSavedPassword` says whether a saved password
        /// will be used.
        public var profile: ConnectionProfile
        /// True when a connection was added, false when one was updated.
        public var added: Bool
        /// What Save did with the password. When `passwordError` is set, it did not complete.
        public var passwordChange: PasswordChange
        /// The connection was saved but its password step failed: the Keychain refused, or saving the list again
        /// afterwards failed. At worst a password is left unused; it is never attached to another computer.
        public var passwordError: (any Error)?

        /// Text to show after saving, or nil when there is nothing to report.
        public var message: String? {
            if let passwordError {
                let detail = (passwordError as? LocalizedError)?.errorDescription ?? passwordError.localizedDescription
                switch passwordChange {
                case .saved:
                    return "The connection was saved, but its password wasn't. " + detail
                case .forgotten, .removedForOtherComputer:
                    return "The connection was saved, but its saved password couldn't be removed. " + detail
                case .unchanged:
                    return detail
                }
            }
            return passwordChange == .removedForOtherComputer ? ConnectionDraft.Message.savedPasswordRemoved : nil
        }
    }

    /// Save Connection / Update Connection, in one step.
    ///
    /// - A new form adds a connection. An editing form applies only its own fields to the library's *current* copy
    ///   (`ConnectionDraft.makeProfile(mergingInto:)`), so changes made while it was open — a connection time,
    ///   quality preferences, a move to another group — are kept. A connection deleted meanwhile is added again.
    /// - The password follows the form: stored for this computer when typed with Remember on; deleted when
    ///   Remember is off; deleted when nothing was typed and it belongs to a different computer; otherwise kept.
    /// - Writes are ordered so that an interruption leaves at most an unused password: the list is saved first
    ///   without claiming a password the Keychain doesn't yet hold for this computer, then the Keychain changes,
    ///   then the list records the new password. A connection that failed to save never gets a Keychain item.
    /// - Afterwards `draft` edits the stored connection (`markSaved`) and keeps its typed password, so a second tap
    ///   updates instead of adding a duplicate.
    ///
    /// Returns nil, changing nothing, while the form is invalid for saving. Throws only when saving the list fails
    /// the first time; `library` is then unchanged and the Keychain untouched. Never reads a password.
    @discardableResult
    public static func saveConnection(_ draft: inout ConnectionDraft, in library: inout ProfileLibrary, store: SecretStore,
                                      persist: (ProfileLibrary) throws -> Void, now: Date = Date(),
                                      id: UUID = UUID()) throws -> SaveResult? {
        guard let endpoint = draft.endpoint else { return nil }
        let current = draft.original.flatMap { library.profile(id: $0.id) }
        var profile: ConnectionProfile
        if let current {
            guard let merged = draft.makeProfile(mergingInto: current) else { return nil }
            profile = merged
        } else {
            guard let created = draft.makeProfile(now: now, id: id) else { return nil }
            profile = created
            // New, or deleted while its form was open (its password was deleted with it).
            profile.hasSavedPassword = false
            profile.passwordEndpointKey = nil
        }
        let step = try passwordStep(typedPassword: draft.password, remember: draft.rememberPassword, for: profile)

        // 1. The connection, not yet claiming a password the Keychain doesn't hold for this computer.
        let keepsSavedPassword: Bool
        switch step {
        case .keep: keepsSavedPassword = true
        case .store: keepsSavedPassword = profile.canUseSavedPassword(for: endpoint)
        case .forget, .removeForOtherComputer: keepsSavedPassword = false
        }
        if !keepsSavedPassword {
            profile.hasSavedPassword = false
            profile.passwordEndpointKey = nil
        }
        let before = library
        if current == nil { library.add(profile) } else { library.update(profile) }
        do {
            try persist(library)
        } catch {
            library = before
            throw error
        }
        var result = SaveResult(profile: library.profile(id: profile.id) ?? profile, added: current == nil,
                                passwordChange: step.change, passwordError: nil)
        draft.markSaved(as: result.profile)

        // 2. The Keychain.
        do {
            switch step {
            case .keep:
                return result
            case .store(let password):
                try store.setPassword(password, for: profile.secretAccount)
            case .forget, .removeForOtherComputer:
                // A connection that was just added has nothing saved under its id.
                if current != nil { try store.deletePassword(for: profile.secretAccount) }
                return result
            }
        } catch {
            result.passwordError = error
            return result
        }

        // 3. Record the stored password for this computer.
        guard !keepsSavedPassword else { return result }
        let withoutPassword = library
        library.recordSavedPassword(profile.id, for: endpoint)
        do {
            try persist(library)
        } catch {
            library = withoutPassword
            result.passwordError = error
            return result
        }
        result.profile = library.profile(id: profile.id) ?? result.profile
        draft.markSaved(as: result.profile)
        return result
    }

    /// Applies the password choice of Save/Update to `profile` alone and returns it with `hasSavedPassword` and
    /// `passwordEndpointKey` updated. Never reads the Keychain. Prefer `saveConnection`, which also merges the form
    /// and orders the writes; with this function, save the profile without a password hint *before* storing a
    /// password for a changed Computer.
    ///
    /// - Remember with a typed password: stores it (update-or-add) for this profile's computer.
    /// - Remember with an empty field: keeps a password saved for this computer, and deletes one saved for a
    ///   different computer so it can't follow an edited address.
    /// - Don't remember: deletes any saved password.
    ///
    /// On failure the error is thrown and nothing about the profile changes, so the caller can still save the
    /// connection and report that the password wasn't stored.
    public static func save(typedPassword: String, remember: Bool, for profile: ConnectionProfile,
                            store: SecretStore) throws -> ConnectionProfile {
        var updated = profile
        switch try passwordStep(typedPassword: typedPassword, remember: remember, for: profile) {
        case .keep:
            break
        case .store(let password):
            try store.setPassword(password, for: profile.secretAccount)
            updated.hasSavedPassword = true
            updated.passwordEndpointKey = profile.endpoint?.canonicalKey
        case .forget, .removeForOtherComputer:
            try store.deletePassword(for: profile.secretAccount)
            updated.hasSavedPassword = false
            updated.passwordEndpointKey = nil
        }
        return updated
    }

    /// Deletes the saved password (idempotent) and returns the profile with `hasSavedPassword` cleared.
    public static func forgetPassword(for profile: ConnectionProfile, store: SecretStore) throws -> ConnectionProfile {
        try store.deletePassword(for: profile.secretAccount)
        var updated = profile
        updated.hasSavedPassword = false
        updated.passwordEndpointKey = nil
        return updated
    }

    // MARK: Deleting

    /// Deletes a saved connection together with its password. The secret goes first: if the Keychain refuses,
    /// the profile stays so the deletion can be retried rather than leaving an orphaned password.
    /// Returns false for an unknown profile. Persist `library` afterwards.
    @discardableResult
    public static func deleteProfile(_ id: UUID, from library: inout ProfileLibrary, store: SecretStore) throws -> Bool {
        guard let account = library.profile(id: id)?.secretAccount else { return false }
        try store.deletePassword(for: account)
        library.delete(profileID: id)
        return true
    }

    /// Deletes saved passwords that no connection in the loaded library names: left by an interrupted save, or by an
    /// earlier installation (Keychain items outlive the app). Does nothing unless the load was clean (`.loaded`),
    /// because after a partial or failed load the library may lack connections whose passwords must stay. Call it
    /// once after launching, before any Save. Reads item attributes only, never a password. Returns the removed
    /// accounts.
    @discardableResult
    public static func removeOrphanedPasswords(after load: ProfileStore.LoadResult, store: SecretAccountListing) throws -> [String] {
        guard load.outcome == .loaded else { return [] }
        let known = Set(load.library.profiles.map(\.secretAccount))
        let orphans = try store.listAccounts().filter { !known.contains($0) }
        for account in orphans { try store.deletePassword(for: account) }
        return orphans
    }

    // MARK: Password step

    private enum PasswordStep {
        case keep
        case store(String)
        case forget
        case removeForOtherComputer

        var change: PasswordChange {
            switch self {
            case .keep: return .unchanged
            case .store: return .saved
            case .forget: return .forgotten
            case .removeForOtherComputer: return .removedForOtherComputer
            }
        }
    }

    private static func passwordStep(typedPassword: String, remember: Bool, for profile: ConnectionProfile) throws -> PasswordStep {
        guard remember else { return .forget }
        if !typedPassword.isEmpty {
            let bytes = typedPassword.utf8.count
            guard bytes <= ConnectionDraft.maxPasswordBytes else { throw SecretStoreError.passwordTooLong(bytes: bytes) }
            return .store(typedPassword)
        }
        guard profile.hasSavedPassword else { return .keep }
        let isForThisComputer = profile.endpoint.map { profile.canUseSavedPassword(for: $0) } ?? false
        return isForThisComputer ? .keep : .removeForOtherComputer
    }
}

extension ConnectionCredentials.PasswordResolution: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .typed: return "typed(<redacted>)"
        case .saved: return "saved(<redacted>)"
        case .needsPassword(let reason): return "needsPassword(\(reason))"
        }
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        switch self {
        case .typed: return Mirror(self, children: ["typed": "<redacted>"], displayStyle: .enum)
        case .saved: return Mirror(self, children: ["saved": "<redacted>"], displayStyle: .enum)
        case .needsPassword(let reason): return Mirror(self, children: ["needsPassword": reason], displayStyle: .enum)
        }
    }
}
