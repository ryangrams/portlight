import Foundation

/// The editable fields of the connection detail form, validated inline and turned into a `ConnectionProfile`
/// on Save/Update.
///
/// Creating or editing a draft never touches the Keychain: whether a saved password exists comes from the
/// profile's `hasSavedPassword` hint. The typed password is kept out of `description` and `dump` output.
public struct ConnectionDraft: Equatable, Sendable {
    /// Form fields in Return/Next order: Name → Computer → Password → Port.
    public enum Field: String, CaseIterable, Sendable {
        case name, host, password, port

        public var title: String {
            switch self {
            case .name: return "Name"
            case .host: return "Computer"
            case .password: return "Password"
            case .port: return "Port"
            }
        }

        /// The field the Return/Next key moves to; nil after the last one.
        public var next: Field? {
            let all = Field.allCases
            guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
            return all[index + 1]
        }
    }

    /// Connecting needs a password (typed or saved); saving does not.
    public enum Purpose: Sendable { case connect, save }

    /// Inline error text, one fixed sentence per problem.
    public enum Message {
        public static let hostRequired = "Enter the computer's name or IP address."
        public static let hostInvalid = "Use only a host name or IP address — no wss://, path, or port."
        public static let portInvalid = "Use a port from 1 to 65535."
        public static let passwordRequired = "Enter the password set in Portlight Host."
        public static let passwordTooLong = "Use a shorter password — Portlight Host allows up to 1024 bytes."
        public static let nameTooLong = "Use a name of up to 100 characters."
        /// Note under the password field while `savedPasswordIsForOtherComputer` is true.
        public static let savedPasswordForOtherComputer = "The saved password is for a different computer, so it won't be sent to this one."
        /// After Update removed a password saved for a different computer
        /// (`ConnectionCredentials.PasswordChange.removedForOtherComputer`).
        public static let savedPasswordRemoved = "The saved password was for a different computer, so it was removed."
    }

    /// Per-field validation result for inline display.
    public struct Validation: Equatable, Sendable {
        public let errors: [Field: String]
        public init(errors: [Field: String]) { self.errors = errors }
        public var isValid: Bool { errors.isEmpty }
        public func message(for field: Field) -> String? { errors[field] }
        /// The first invalid field in form order, for moving focus to it.
        public var firstInvalidField: Field? { Field.allCases.first { errors[$0] != nil } }
    }

    public static let maxNameLength = 100
    /// Portlight Host rejects longer passwords (it counts UTF-8 bytes, not characters).
    public static let maxPasswordBytes = 1024

    /// Optional connection name, distinct from the computer address.
    public var name: String
    /// Computer: host name or IP address (IPv6 may be bracketed). No scheme, path or port.
    public var host: String
    /// Port text as typed; empty means the default 5920.
    public var port: String
    /// Exactly as typed: never trimmed or normalized, because the host verifies the raw UTF-8 bytes.
    public var password: String
    /// Whether Save/Update keeps the typed password in the Keychain; turning it off forgets a saved one.
    public var rememberPassword: Bool
    /// Group the saved profile belongs to (nil = ungrouped).
    public var groupID: UUID?
    /// The saved profile being edited; nil for a new connection.
    public private(set) var original: ConnectionProfile?

    /// A new connection, optionally created inside a group.
    public init(groupID: UUID? = nil) {
        name = ""
        host = ""
        port = String(PortlightProtocol.defaultPort)
        password = ""
        rememberPassword = true
        self.groupID = groupID
        original = nil
    }

    /// Editing a saved connection (selecting a row). The password field starts empty; no secret is read.
    /// Remember Password starts as it was saved, so a connection saved without a password never gains one
    /// silently when a password is typed only to connect.
    public init(editing profile: ConnectionProfile) {
        name = profile.name
        host = profile.host
        port = String(profile.port)
        password = ""
        rememberPassword = profile.hasSavedPassword
        groupID = profile.groupID
        original = profile
    }

    public var isNew: Bool { original == nil }

    public var saveActionTitle: String { isNew ? "Save Connection" : "Update Connection" }

    /// The validated address, or nil while the host or port is invalid.
    public var endpoint: HostEndpoint? {
        guard let port = Self.parsePort(port) else { return nil }
        return HostEndpoint(host: host, port: port)
    }

    /// True when an empty password field will use the saved password: one was saved for exactly the computer in
    /// the form, so editing Computer never sends one computer's password to another.
    public var canUseSavedPassword: Bool {
        guard let original, let endpoint else { return false }
        return original.canUseSavedPassword(for: endpoint)
    }

    /// True when a password is saved for this connection but for a different computer than the one in the form
    /// (the Computer was edited, or the password was saved before it was bound to a computer). It is never sent
    /// here, and Update removes it unless a new password is typed. Show `Message.savedPasswordForOtherComputer`.
    public var savedPasswordIsForOtherComputer: Bool {
        guard let original, original.hasSavedPassword, endpoint != nil else { return false }
        return !canUseSavedPassword
    }

    public var passwordPlaceholder: String {
        canUseSavedPassword ? "Saved password is used when connecting" : "Password"
    }

    public func validate(for purpose: Purpose) -> Validation {
        var errors: [Field: String] = [:]
        if purpose == .save, trimmedName.count > Self.maxNameLength {
            errors[.name] = Message.nameTooLong
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty {
            errors[.host] = Message.hostRequired
        } else if HostEndpoint(host: trimmedHost, port: PortlightProtocol.defaultPort) == nil {
            errors[.host] = Message.hostInvalid
        }
        if Self.parsePort(port) == nil {
            errors[.port] = Message.portInvalid
        }
        if password.utf8.count > Self.maxPasswordBytes {
            errors[.password] = Message.passwordTooLong
        } else if purpose == .connect, password.isEmpty, needsTypedPassword {
            errors[.password] = Message.passwordRequired
        }
        return Validation(errors: errors)
    }

    /// The profile to store on Save, or nil while the form is invalid for saving. A new connection gets `id` and
    /// `now` as its creation time.
    ///
    /// For an editing draft this applies the form to the snapshot taken when the form opened. To update a saved
    /// connection use `makeProfile(mergingInto:)` with the library's current copy (or
    /// `ConnectionCredentials.saveConnection`), which keeps changes made elsewhere while the form was open.
    public func makeProfile(now: Date = Date(), id: UUID = UUID()) -> ConnectionProfile? {
        guard validate(for: .save).isValid, let endpoint else { return nil }
        var profile = original ?? ConnectionProfile(id: id, host: endpoint.host, port: endpoint.port, createdAt: now)
        profile.name = trimmedName
        profile.host = endpoint.host
        profile.port = endpoint.port
        profile.groupID = groupID
        return profile
    }

    /// The profile to store on Update: the library's current copy of this connection with only the form's own
    /// fields applied — name, Computer and port, and the group only when it was changed in this form. Everything
    /// else (connection time, preferences, position, saved-password hint) stays as it is now, even if it changed
    /// while the form was open. Nil while the form is invalid for saving, or when `current` is another connection.
    public func makeProfile(mergingInto current: ConnectionProfile) -> ConnectionProfile? {
        guard original == nil || original?.id == current.id, validate(for: .save).isValid, let endpoint else { return nil }
        var profile = current
        profile.name = trimmedName
        profile.host = endpoint.host
        profile.port = endpoint.port
        if groupID != original?.groupID { profile.groupID = groupID }
        return profile
    }

    /// After Save/Update succeeded: the form now edits `profile`, so another tap updates it instead of adding a
    /// second connection. The typed password and Remember choice stay, so Connect can still use them.
    public mutating func markSaved(as profile: ConnectionProfile) {
        original = profile
        groupID = profile.groupID
    }

    /// Parses the port field: ASCII digits only, 1...65535; blank means the default port.
    public static func parsePort(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return PortlightProtocol.defaultPort }
        guard trimmed.count <= 5, trimmed.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let value = Int(trimmed), (1...65535).contains(value) else { return nil }
        return value
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// With a saved password and an address that can't be judged yet (the host error is already shown),
    /// don't also demand a password the saved one may cover.
    private var needsTypedPassword: Bool {
        guard let original, original.hasSavedPassword else { return true }
        return endpoint != nil && !canUseSavedPassword
    }
}

extension ConnectionDraft: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "ConnectionDraft(name: \(name.debugDescription), host: \(host.debugDescription), port: \(port.debugDescription), "
            + "password: \(redactedPassword), rememberPassword: \(rememberPassword), editing: \(original?.id.uuidString ?? "new"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "name": name, "host": host, "port": port, "password": redactedPassword,
            "rememberPassword": rememberPassword, "groupID": groupID as Any, "original": original as Any,
        ], displayStyle: .struct)
    }

    private var redactedPassword: String { password.isEmpty ? "<empty>" : "<redacted>" }
}
