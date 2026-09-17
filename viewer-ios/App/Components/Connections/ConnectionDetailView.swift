import SwiftUI
import UIKit
import Combine
import PortlightKit

/// SwiftUI's `SecureField` has no smart-punctuation modifiers, so the traits are set on its backing
/// `UITextField` as it starts editing: the host compares the password byte for byte.
enum PasswordFieldTraits {
    @MainActor
    static func apply(to object: Any?) {
        guard let field = object as? UITextField, field.isSecureTextEntry, field.smartQuotesType != .no else { return }
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.spellCheckingType = .no
        field.autocorrectionType = .no
        field.reloadInputViews()
    }
}

/// Edits one connection (UI-SPEC §3), bound to a `ConnectionDraft`.
///
/// Connect and Save/Update are closures, so this view never touches the Keychain or the network. Inline
/// messages come from `ConnectionDraft.validate` and appear once a field was edited or an action was pressed,
/// never on first load. Return moves Name → Computer → Password, and Go on the password connects.
struct ConnectionDetailView: View {
    @Binding var draft: ConnectionDraft
    private let connectBlocker: String?
    private let onConnect: @MainActor () -> Void
    private let onSave: @MainActor () -> Void
    private let onForgetPassword: (@MainActor () -> Void)?
    private let fieldError: (field: ConnectionDraft.Field, message: String)?

    @FocusState private var focus: ConnectionDraft.Field?
    @State private var edited: Set<ConnectionDraft.Field> = []
    /// The last action pressed; its validation is then shown for every field.
    @State private var attempted: ConnectionDraft.Purpose?

    /// - Parameters:
    ///   - connectBlocker: why Connect can't be used right now (for example, another session is active).
    ///   - revealValidation: show that action's validation immediately (returning from a failed attempt).
    ///   - fieldError: why the last Connect could not start (a password is needed, the Keychain refused), shown
    ///     under that field until the owner clears it.
    ///   - onForgetPassword: shown as "Forget Saved Password" while the saved password applies.
    init(draft: Binding<ConnectionDraft>,
         connectBlocker: String? = nil,
         revealValidation: ConnectionDraft.Purpose? = nil,
         fieldError: (field: ConnectionDraft.Field, message: String)? = nil,
         onConnect: @escaping @MainActor () -> Void,
         onSave: @escaping @MainActor () -> Void,
         onForgetPassword: (@MainActor () -> Void)? = nil) {
        _draft = draft
        self.connectBlocker = connectBlocker
        _attempted = State(initialValue: revealValidation)
        self.fieldError = fieldError
        self.onConnect = onConnect
        self.onSave = onSave
        self.onForgetPassword = onForgetPassword
    }

    var body: some View {
        Form {
            Section {
                field(.name, title: "Name") {
                    TextField("Name", text: $draft.name, prompt: Text("Optional"))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.next)
                        .onSubmit { focus = .host }
                }
                field(.host, title: "Computer") {
                    TextField("Computer", text: $draft.host, prompt: Text("Mac name or IP address"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                }
                field(.password, title: "Password") {
                    SecureField("Password", text: $draft.password, prompt: Text(passwordPrompt))
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { connect() }
                }
                field(.port, title: "Port") {
                    TextField("Port", text: $draft.port, prompt: Text(verbatim: String(PortlightProtocol.defaultPort)))
                        .keyboardType(.numberPad)
                }
            }

            Section {
                Toggle("Remember Password", isOn: $draft.rememberPassword)
                if draft.canUseSavedPassword, let onForgetPassword {
                    Button(role: .destructive) {
                        onForgetPassword()
                    } label: {
                        Text("Forget Saved Password")
                            .foregroundStyle(PortlightTheme.error)
                    }
                }
            } footer: {
                Text("Passwords stay in this iPhone’s Keychain and are sent only after you trust the computer.")
                    .foregroundStyle(PortlightTheme.secondaryText)
            }

            Section {
                VStack(spacing: 12) {
                    Button {
                        connect()
                    } label: {
                        Text("Connect")
                            .font(.headline)
                            .onAccentLabel()
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(blocker != nil)
                    .accessibilityHint(blocker ?? "")
                    .accessibilityIdentifier("connection.connect")

                    Button {
                        save()
                    } label: {
                        Text(draft.saveActionTitle)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .secondaryActionStyle()
                    .controlSize(.large)
                    .accessibilityIdentifier("connection.save")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if let blocker {
                    Text(blocker)
                        .foregroundStyle(PortlightTheme.secondaryText)
                        .padding(.top, 4)
                }
            }
        }
        .navigationTitle(draft.isNew ? "New Connection" : (draft.original?.displayTitle ?? "Connection"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focus == .port {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
        }
        .onChange(of: draft.name) { edited.insert(.name) }
        .onChange(of: draft.host) { edited.insert(.host) }
        .onChange(of: draft.password) { edited.insert(.password) }
        .onChange(of: draft.port) { edited.insert(.port) }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { note in
            PasswordFieldTraits.apply(to: note.object)
        }
    }

    /// "Saved in Keychain" while an empty field will use the saved password (UI-SPEC §3).
    private var passwordPrompt: String {
        draft.canUseSavedPassword ? "Saved in Keychain" : "Required"
    }

    /// One reason Connect is disabled; also its VoiceOver hint. Before the first press Connect stays enabled,
    /// because pressing it is how the missing fields are revealed.
    private var blocker: String? {
        if let connectBlocker { return connectBlocker }
        if attempted == .connect, !draft.validate(for: .connect).isValid {
            return "Fix the highlighted fields to connect."
        }
        return nil
    }

    private func message(for field: ConnectionDraft.Field) -> String? {
        if let fieldError, fieldError.field == field { return fieldError.message }
        switch attempted {
        case .connect?:
            return draft.validate(for: .connect).message(for: field)
        case .save?:
            return draft.validate(for: .save).message(for: field)
        case nil:
            // While typing, show format problems only; a missing password is reported when Connect is pressed.
            return edited.contains(field) ? draft.validate(for: .save).message(for: field) : nil
        }
    }

    private func connect() {
        attempted = .connect
        if let invalid = draft.validate(for: .connect).firstInvalidField {
            focus = invalid
            return
        }
        focus = nil
        onConnect()
    }

    private func save() {
        attempted = .save
        if let invalid = draft.validate(for: .save).firstInvalidField {
            focus = invalid
            return
        }
        onSave()
    }

    @ViewBuilder
    private func field<Input: View>(_ field: ConnectionDraft.Field, title: String,
                                    @ViewBuilder input: () -> Input) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PortlightTheme.secondaryText)
                .accessibilityHidden(true)
            input()
                .focused($focus, equals: field)
                .frame(minHeight: 32)
                .accessibilityIdentifier("connection.field.\(field.rawValue)")
            if let message = message(for: field) {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(PortlightTheme.error)
                    .accessibilityLabel("\(title): \(message)")
                    .accessibilityIdentifier("connection.error.\(field.rawValue)")
            }
        }
        .padding(.vertical, 2)
    }
}
